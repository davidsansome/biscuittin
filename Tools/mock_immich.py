#!/usr/bin/env python3
"""Minimal mock Immich server for verifying Biscuit Tin end to end.

Mirrors a real v3.1.0 server's conventions where they have been checked: the
public server/ping|version|features|config endpoints, `.well-known/immich`,
server/about requiring auth, login rejecting a wrong password with 401, and
API keys in `x-api-key`. Assets are synthetic, with solid-colour PNG thumbnails
so remote tiles are visually distinguishable from local ones. `sync/stream`
answers with no changes; the asset stream itself is not modelled.

OAuth is off by default, as on a stock server. `--oauth` turns it on and serves
a stand-in identity provider at /mock-idp/authorize that redirects to the
app.immich callback, checking state and the PKCE S256 challenge on the way back
exactly as the real server does. `--no-password-login` and `--oauth-auto-launch`
mirror the matching admin settings.

Test credentials: MOCK_EMAIL / MOCK_PASSWORD, or API key MOCK_API_KEY.
"""

import argparse
import secrets

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
REQUEST_LOG = []
# checksum -> server asset id, so bulk-upload-check can report duplicates
UPLOADED_CHECKSUMS = {}
UPLOAD_COUNT = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # keep stdout for our own summary

    def _send(self, code, payload, content_type="application/json"):
        body = json.dumps(payload).encode() if content_type == "application/json" else payload
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
            return self._send(200, b"", content_type="application/jsonlines+json")

        if path == "/api/sync/ack":
            if not self._authorized():
                return self._send(401, {"message": "Authentication required"})
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
            new_id = f"uploaded-{len(UPLOADED_CHECKSUMS):04d}"
            UPLOADED_CHECKSUMS[checksum] = new_id
            UPLOAD_COUNT.append(new_id)
            print(f"  UPLOAD #{len(UPLOAD_COUNT)} checksum={checksum[:16]}... "
                  f"bytes={len(raw)}", flush=True)
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

    def do_DELETE(self):
        REQUEST_LOG.append(("DELETE", self.path))
        print(f"DELETE {self.path}", flush=True)
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
    args = parser.parse_args()
    PORT = args.port
    if args.no_assets:
        ASSETS = []
    EXPIRE_SESSIONS = args.expire_sessions
    FEATURES.update(oauth=args.oauth, oauthAutoLaunch=args.oauth_auto_launch,
                    passwordLogin=not args.no_password_login)
    print(f"Features: {FEATURES}", flush=True)
    print(f"Mock Immich {SERVER_VERSION} on http://127.0.0.1:{PORT} "
          f"({len(ASSETS)} assets)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
