#!/usr/bin/env python3
"""Minimal mock Immich server for verifying Biscuit Tin end to end.

Mirrors a real v3.1.0 server's conventions where they have been checked: the
public server/ping|version|features|config endpoints, `.well-known/immich`,
server/about requiring auth, login rejecting a wrong password with 401, and
API keys in `x-api-key`. Assets are synthetic, with solid-colour PNG thumbnails
so remote tiles are visually distinguishable from local ones. `sync/stream`
sends them as `AssetV2`/`AssetExifV1` lines until acked, keeping one checkpoint
per ack prefix as the real server does; `reset: true` clears the checkpoints.
`--sync-reset` starts the session with a pending sync reset, as a server does once
a session's checkpoint is older than its 30-day audit retention: every non-reset
stream is answered with a lone `SyncResetV1` line until a `reset: true` stream, or
an ack of that line, clears it and the checkpoints (v3.2.4's `SyncService`).

`/video/playback` serves a real H.264 clip for the synthetic video, honouring
HTTP range requests the way AVPlayer issues them. The clip is made with ffmpeg
at startup, or taken from `--video FILE`.

OAuth is off by default, as on a stock server. `--oauth` turns it on and serves
a stand-in identity provider at /mock-idp/authorize that redirects to the
app.immich callback, checking state and the PKCE S256 challenge on the way back
exactly as the real server does. `--no-password-login` and `--oauth-auto-launch`
mirror the matching admin settings.

Uploads are remembered, so `GET /api/assets/{id}` describes them the way a real
server does. `--upload-delay` holds each upload's response back, which keeps the
window between export and link open long enough to edit the photo by hand;
`--save-uploads DIR` writes each uploaded file there, to inspect what arrived.

Test credentials: MOCK_EMAIL / MOCK_PASSWORD, or API key MOCK_API_KEY.
"""

import argparse
import os
import re
import secrets
import time

import base64
import hashlib
import json
import struct
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

PORT = 4567
TOKEN = "mock-access-token"
SERVER_VERSION = "v3.1.0"
MOCK_EMAIL = "dave@example.com"
MOCK_PASSWORD = "biscuit"
MOCK_API_KEY = "mock-api-key"
# Rejects every credential, as a server does once a session has been revoked.
EXPIRE_SESSIONS = False
# A pending sync reset for the (single) session; see --sync-reset.
PENDING_SYNC_RESET = False
FEATURES = {"oauth": False, "oauthAutoLaunch": False, "passwordLogin": True}
# code -> (state, code_challenge), issued by the stand-in identity provider
OAUTH_CODES = {}
# state -> code_challenge, recorded by /api/oauth/authorize
OAUTH_PENDING = {}

LOGIN_RESPONSE = {
    "accessToken": TOKEN, "userId": "user-1", "userEmail": MOCK_EMAIL, "name": "Dave",
    "profileImagePath": "", "isAdmin": False, "shouldChangePassword": False, "isOnboarded": True,
}

# Vivid, saturated colours that stand out against the generated local library.
COLOURS = [
    (20, 20, 20), (240, 240, 240), (255, 0, 128), (0, 200, 255),
    (255, 200, 0), (140, 0, 255), (0, 255, 140), (255, 80, 0),
    (0, 90, 255), (200, 255, 0), (255, 0, 40), (0, 255, 255),
]


def solid_png(width, height, rgb):
    """Builds a solid-colour PNG without any imaging library."""
    raw = b""
    row = bytes(rgb) * width
    for _ in range(height):
        raw += b"\x00" + row

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def build_assets():
    now = datetime.now(timezone.utc)
    assets = []
    for i in range(12):
        # Interleave with the local library: a few today, the rest spread back.
        captured = now - timedelta(days=[0, 0, 1, 2, 4, 6, 9, 12, 16, 23, 38, 52][i],
                                   hours=i)
        is_video = (i == 5)
        assets.append({
            "id": f"remote-asset-{i:02d}",
            # v3.1.0 does not echo these back, so the mock must not either — the client
            # cannot rely on them for facet linking (D5).
            "deviceAssetId": None,
            "deviceId": None,
            "width": 4000 if not is_video else 1920,
            "height": 3000 if not is_video else 1080,
            "type": "VIDEO" if is_video else "IMAGE",
            "originalFileName": f"immich-{i:02d}.{'mp4' if is_video else 'jpg'}",
            # Real Immich returns SHA-1 base64-encoded, NOT hex. Mirroring that here is what
            # exposes checksum-normalisation bugs in the client (verified against v3.1.0).
            "checksum": base64.b64encode(hashlib.sha1(f"mock-{i}".encode()).digest()).decode(),
            "fileCreatedAt": captured.isoformat(),
            "fileModifiedAt": captured.isoformat(),
            "localDateTime": captured.isoformat(),
            "updatedAt": now.isoformat(),
            # Real v3.1.0 sends integer MILLISECONDS for videos and null for images.
            "duration": 37000 if is_video else None,
            "isTrashed": False,
            "isOffline": False,
            "livePhotoVideoId": None,
            "exifInfo": {
                "make": "Immich",
                "model": f"Server Camera {i % 3 + 1}",
                "lensModel": "Mock 35mm",
                "fNumber": 2.8,
                "focalLength": 35,
                "iso": 200,
                "exposureTime": "1/250",
                "latitude": 48.8584 + i * 0.01,
                "longitude": 2.2945 + i * 0.01,
                "city": "Paris",
                "state": "Ile-de-France",
                "country": "France",
                "fileSizeInByte": 2_500_000 + i * 1000,
                "exifImageWidth": 4000 if not is_video else 1920,
                "exifImageHeight": 3000 if not is_video else 1080,
                "dateTimeOriginal": captured.isoformat(),
                "description": None,
            },
        })
    return assets


ASSETS = build_assets()
# Checkpoint type -> last ack, as the server keeps per session.
SYNC_CHECKPOINTS = {}
VIDEO_PATH = None


def sync_lines(types):
    """Every asset line not yet acked, in the server's order: assets, then their EXIF."""
    lines = []
    if "AssetsV2" in types:
        for asset in ASSETS:
            lines.append({"type": "AssetV2", "ack": f"AssetV2|{asset['id']}", "data": {
                "id": asset["id"], "ownerId": "user-1",
                "originalFileName": asset["originalFileName"], "thumbhash": None,
                "checksum": asset["checksum"], "fileCreatedAt": asset["fileCreatedAt"],
                "fileModifiedAt": asset["fileModifiedAt"], "createdAt": asset["updatedAt"],
                "localDateTime": asset["localDateTime"], "duration": asset["duration"],
                "type": asset["type"], "deletedAt": None, "isFavorite": False,
                "visibility": "timeline", "livePhotoVideoId": None, "stackId": None,
                "libraryId": None, "width": asset["width"], "height": asset["height"],
                "isEdited": False}})
    if "AssetExifsV1" in types:
        for asset in ASSETS:
            exif = asset["exifInfo"]
            lines.append({"type": "AssetExifV1", "ack": f"AssetExifV1|{asset['id']}", "data": {
                "assetId": asset["id"], "orientation": "1", "modifyDate": None, "timeZone": None,
                "projectionType": None, "profileDescription": None, "rating": None, "fps": None,
                **exif}})
    unacked = [line for line in lines if line["ack"].split("|")[0] not in SYNC_CHECKPOINTS]
    unacked.append({"type": "SyncCompleteV1", "ack": "SyncCompleteV1|now", "data": {}})
    return unacked


def make_video():
    """A short real clip, so AVPlayer has something genuine to decode."""
    path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "mock-immich-playback.mp4")
    if not os.path.exists(path):
        import subprocess
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "testsrc=duration=37:size=1280x720:rate=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=37",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                        "-movflags", "+faststart", "-shortest", path], check=True)
    return path
REQUEST_LOG = []
# checksum -> server asset id, so bulk-upload-check can report duplicates
UPLOADED_CHECKSUMS = {}
UPLOAD_COUNT = []
# server asset id -> AssetResponseDto, for GET /api/assets/{id}
UPLOADED_ASSETS = {}
UPLOAD_DELAY = 0.0
SAVE_UPLOADS = None


def multipart_parts(raw):
    """(fields, filename, file bytes) from a multipart/form-data body."""
    boundary = raw.split(b"\r\n", 1)[0]
    fields, filename, data = {}, None, b""
    for part in raw.split(boundary)[1:]:
        if part.startswith(b"--"):
            break
        head, _, body = part.partition(b"\r\n\r\n")
        body = body[:-2] if body.endswith(b"\r\n") else body
        name = re.search(rb'name="([^"]*)"', head)
        file_match = re.search(rb'filename="([^"]*)"', head)
        if file_match:
            filename, data = file_match.group(1).decode(), body
        elif name:
            fields[name.group(1).decode()] = body.decode(errors="replace")
    return fields, filename, data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # keep stdout for our own summary

    def _send(self, code, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_range(self, file_path, content_type):
        """Serves a file whole or by `Range: bytes=a-b`, as Immich does for playback."""
        with open(file_path, "rb") as f:
            data = f.read()
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if not match:
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        start = int(match.group(1)) if match.group(1) else len(data) - int(match.group(2))
        end = int(match.group(2)) if match.group(1) and match.group(2) else len(data) - 1
        end = min(end, len(data) - 1)
        chunk = data[start:end + 1]
        print(f"  range {start}-{end}/{len(data)}", flush=True)
        self.send_response(206)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        self.wfile.write(chunk)

    def _authorized(self):
        if EXPIRE_SESSIONS:
            return False
        return (self.headers.get("Authorization") == f"Bearer {TOKEN}"
                or self.headers.get("x-api-key") == MOCK_API_KEY)

    def do_GET(self):
        path = self.path.split("?")[0]
        REQUEST_LOG.append(("GET", path))
        print(f"GET  {self.path}", flush=True)

        if path == "/api/server/ping":
            return self._send(200, {"res": "pong"})

        if path == "/api/server/version":
            major, minor, patch = (int(p) for p in SERVER_VERSION.lstrip("v").split("."))
            return self._send(200, {"major": major, "minor": minor, "patch": patch,
                                    "prerelease": None})

        if path == "/api/server/features":
            return self._send(200, {"smartSearch": True, "facialRecognition": True,
                                    "duplicateDetection": True, "map": False,
                                    "reverseGeocoding": True, "importFaces": False,
                                    "sidecar": True, "search": True, "trash": True, "ocr": True,
                                    "configFile": False, "email": False,
                                    "realtimeTranscoding": False, **FEATURES})

        if path == "/api/server/config":
            return self._send(200, {"loginPageMessage": "", "trashDays": 30,
                                    "userDeleteDelay": 7, "oauthButtonText": "Login with OAuth",
                                    "isInitialized": True, "isOnboarded": True,
                                    "externalDomain": "", "publicUsers": True,
                                    "maintenanceMode": False, "minFaces": 3})

        if path == "/.well-known/immich":
            return self._send(200, {"api": {"endpoint": "/api"}})

        if path == "/api/server/about":
            # Authenticated on a real server: 401 without a token.
            if not self._authorized():
                return self._send(401, {"message": "Authentication required"})
            return self._send(200, {"version": SERVER_VERSION, "versionUrl": ""})

        if path == "/mock-idp/authorize":
            query = parse_qs(urlparse(self.path).query)
            code = secrets.token_urlsafe(12)
            state = query.get("state", [""])[0]
            OAUTH_CODES[code] = (state, query.get("code_challenge", [""])[0])
            target = f"{query['redirect_uri'][0]}?code={code}&state={state}"
            page = (f"<html><body style='font:20px -apple-system;padding:40px'>"
                    f"<h2>Mock identity provider</h2>"
                    f"<p><a id='approve' href='{target}'>Approve sign-in</a></p>"
                    f"<p><a href='{query['redirect_uri'][0]}?error=access_denied"
                    f"&error_description=User+declined&state={state}'>Decline</a></p>"
                    f"</body></html>").encode()
            return self._send(200, page, content_type="text/html")

        if path == "/api/users/me":
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            return self._send(200, {"id": "user-1", "email": "dave@example.com", "name": "Dave"})

        if path.startswith("/api/assets/") and path.count("/") == 3:
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            asset = UPLOADED_ASSETS.get(path.split("/")[3]) \
                or next((a for a in ASSETS if a["id"] == path.split("/")[3]), None)
            if asset is None:
                return self._send(404, {"message": "Asset not found"})
            return self._send(200, asset)

        if path.startswith("/api/assets/") and path.endswith("/video/playback"):
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            return self._send_range(VIDEO_PATH, "video/mp4")

        if path.startswith("/api/assets/") and path.endswith("/thumbnail"):
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            asset_id = path.split("/")[3]
            index = int(asset_id.split("-")[-1]) if asset_id.split("-")[-1].isdigit() else 0
            size = 512 if "preview" in self.path else 256
            return self._send(200, solid_png(size, size, COLOURS[index % len(COLOURS)]),
                              content_type="image/png")

        return self._send(404, {"message": "not found"})

    def do_POST(self):
        global PENDING_SYNC_RESET
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        if path == "/api/assets":
            pass  # raw holds the multipart body; only its size matters here
        REQUEST_LOG.append(("POST", path))
        print(f"POST {path}  body={raw[:120]!r}", flush=True)

        if path == "/api/auth/login":
            if not FEATURES["passwordLogin"]:
                return self._send(401, {"message": "Login with username and password is disabled."})
            body = json.loads(raw or b"{}")
            if body.get("email") != MOCK_EMAIL or body.get("password") != MOCK_PASSWORD:
                return self._send(401, {"message": "Incorrect email or password"})
            return self._send(201, LOGIN_RESPONSE)

        if path == "/api/oauth/authorize":
            if not FEATURES["oauth"]:
                return self._send(400, {"message": "OAuth is not enabled"})
            body = json.loads(raw or b"{}")
            OAUTH_PENDING[body.get("state")] = body.get("codeChallenge")
            host = self.headers.get("Host", f"127.0.0.1:{PORT}")
            query = urlencode({"redirect_uri": body["redirectUri"], "state": body.get("state", ""),
                               "code_challenge": body.get("codeChallenge", ""),
                               "code_challenge_method": "S256"})
            return self._send(201, {"url": f"http://{host}/mock-idp/authorize?{query}"})

        if path == "/api/oauth/callback":
            if not FEATURES["oauth"]:
                return self._send(400, {"message": "OAuth is not enabled"})
            body = json.loads(raw or b"{}")
            query = parse_qs(urlparse(body.get("url", "")).query)
            code = query.get("code", [""])[0]
            issued = OAUTH_CODES.pop(code, None)
            if not body.get("state") or not body.get("codeVerifier"):
                return self._send(400, {"message": "OAuth state is missing"})
            verifier_hash = base64.urlsafe_b64encode(
                hashlib.sha256(body["codeVerifier"].encode()).digest()).rstrip(b"=").decode()
            if (issued is None or issued[0] != body["state"]
                    or issued[1] != verifier_hash):
                print("  OAuth callback rejected: state or PKCE mismatch", flush=True)
                return self._send(400, {"message": "OAuth login failed"})
            print("  OAuth callback accepted: state and PKCE verified", flush=True)
            return self._send(201, LOGIN_RESPONSE)

        if path == "/api/sync/stream":
            if not self._authorized():
                return self._send(401, {"message": "Authentication required"})
            body = json.loads(raw or b"{}")
            if body.get("reset"):
                SYNC_CHECKPOINTS.clear()
                PENDING_SYNC_RESET = False
            if PENDING_SYNC_RESET:
                line = json.dumps({"type": "SyncResetV1", "data": {}, "ack": "SyncResetV1|reset"})
                print("  sync/stream: SyncResetV1", flush=True)
                return self._send(200, (line + "\n").encode(),
                                  content_type="application/jsonlines+json")
            lines = sync_lines(body.get("types", []))
            print(f"  sync/stream: {len(lines)} lines", flush=True)
            payload = "".join(json.dumps(line) + "\n" for line in lines).encode()
            return self._send(200, payload, content_type="application/jsonlines+json")

        if path == "/api/sync/ack":
            if not self._authorized():
                return self._send(401, {"message": "Authentication required"})
            for ack in json.loads(raw or b"{}").get("acks", []):
                if ack.startswith("SyncResetV1|"):
                    # As the real server: a reset ack drops every checkpoint, and the rest of
                    # the batch with it.
                    SYNC_CHECKPOINTS.clear()
                    PENDING_SYNC_RESET = False
                    break
                SYNC_CHECKPOINTS[ack.split("|")[0]] = ack
            return self._send(204, b"", content_type="application/json")

        if path == "/api/assets/bulk-upload-check":
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            body = json.loads(raw or b"{}")
            results = []
            for item in body.get("assets", []):
                known = item["checksum"] in UPLOADED_CHECKSUMS
                results.append({
                    "id": item["id"],
                    "action": "reject" if known else "accept",
                    "reason": "duplicate" if known else None,
                    "assetId": UPLOADED_CHECKSUMS.get(item["checksum"]),
                })
            print(f"  bulk-upload-check: {len(results)} items, "
                  f"{sum(1 for r in results if r['action'] == 'reject')} duplicates", flush=True)
            return self._send(200, {"results": results})

        if path == "/api/assets":
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            checksum = self.headers.get("x-immich-checksum", "")
            if checksum in UPLOADED_CHECKSUMS:
                # As the real server does: the same bytes again are a duplicate of the asset
                # already holding them, not a second asset.
                existing = UPLOADED_CHECKSUMS[checksum]
                print(f"  UPLOAD duplicate of {existing}", flush=True)
                return self._send(200, {"id": existing, "status": "duplicate"})
            new_id = f"uploaded-{len(UPLOAD_COUNT):04d}"
            UPLOADED_CHECKSUMS[checksum] = new_id
            UPLOAD_COUNT.append(new_id)
            fields, filename, data = multipart_parts(raw)
            now = datetime.now(timezone.utc).isoformat()
            UPLOADED_ASSETS[new_id] = {
                "id": new_id,
                "type": "VIDEO" if (filename or "").lower().endswith((".mov", ".mp4")) else "IMAGE",
                "originalFileName": filename,
                # Base64, as the real server reports it; the upload header carries hex.
                "checksum": base64.b64encode(bytes.fromhex(checksum)).decode() if checksum else None,
                "fileCreatedAt": fields.get("fileCreatedAt"),
                "fileModifiedAt": fields.get("fileModifiedAt"),
                "localDateTime": fields.get("fileCreatedAt"),
                "updatedAt": now,
                # Metadata extraction has not run on a just-uploaded asset.
                "width": None,
                "height": None,
                "duration": None,
                "isTrashed": False,
                "isOffline": False,
                "livePhotoVideoId": None,
                "exifInfo": None,
            }
            if SAVE_UPLOADS and filename:
                with open(os.path.join(SAVE_UPLOADS, f"{new_id}-{filename}"), "wb") as f:
                    f.write(data)
            print(f"  UPLOAD #{len(UPLOAD_COUNT)} {new_id} {filename} checksum={checksum[:16]}... "
                  f"bytes={len(data)}", flush=True)
            if UPLOAD_DELAY:
                print(f"  holding the response for {UPLOAD_DELAY:g}s", flush=True)
                time.sleep(UPLOAD_DELAY)
            return self._send(201, {"id": new_id, "status": "created"})

        if path == "/api/search/metadata":
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            body = json.loads(raw or b"{}")
            page = body.get("page", 1)
            # Single page is enough for the fixture set; nextPage null ends the loop.
            items = ASSETS if page == 1 else []
            return self._send(200, {
                "assets": {
                    "items": items,
                    "total": len(ASSETS),
                    "count": len(items),
                    "nextPage": None,
                }
            })

        return self._send(404, {"message": "not found"})

    def do_PUT(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        REQUEST_LOG.append(("PUT", path))
        print(f"PUT  {path}  body={raw[:120]!r}", flush=True)
        if not self._authorized():
            return self._send(401, {"message": "Authentication required"})
        asset = UPLOADED_ASSETS.get(path.split("/")[-1])
        if asset is None:
            return self._send(404, {"message": "Asset not found"})
        return self._send(200, asset)

    def do_DELETE(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        REQUEST_LOG.append(("DELETE", self.path))
        print(f"DELETE {self.path}  body={raw[:120]!r}", flush=True)
        if not self._authorized():
            return self._send(401, {"message": "Authentication required"})
        return self._send(204, b"", content_type="application/json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--oauth", action="store_true", help="enable OAuth login")
    parser.add_argument("--oauth-auto-launch", action="store_true")
    parser.add_argument("--no-password-login", action="store_true")
    parser.add_argument("--expire-sessions", action="store_true",
                        help="reject every credential, to exercise re-sign-in")
    parser.add_argument("--port", type=int, default=PORT,
                        help="listen port; a real server's default is 2283")
    parser.add_argument("--no-assets", action="store_true",
                        help="serve an empty library, so no synthetic tiles join the grid")
    parser.add_argument("--upload-delay", type=float, default=0,
                        help="seconds to hold each upload's response")
    parser.add_argument("--save-uploads", metavar="DIR",
                        help="write each uploaded file into DIR")
    parser.add_argument("--sync-reset", action="store_true",
                        help="answer sync streams with SyncResetV1 until the app replays")
    parser.add_argument("--video", metavar="FILE",
                        help="clip to serve from /video/playback (default: made with ffmpeg)")
    args = parser.parse_args()
    VIDEO_PATH = args.video or make_video()
    UPLOAD_DELAY = args.upload_delay
    SAVE_UPLOADS = args.save_uploads
    PORT = args.port
    if args.no_assets:
        ASSETS = []
    EXPIRE_SESSIONS = args.expire_sessions
    PENDING_SYNC_RESET = args.sync_reset
    FEATURES.update(oauth=args.oauth, oauthAutoLaunch=args.oauth_auto_launch,
                    passwordLogin=not args.no_password_login)
    print(f"Features: {FEATURES}", flush=True)
    print(f"Mock Immich {SERVER_VERSION} on http://127.0.0.1:{PORT} "
          f"({len(ASSETS)} assets)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
