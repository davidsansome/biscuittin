#!/usr/bin/env python3
"""Minimal mock Immich server for verifying the OnlyDaves read path end to end.

Serves only the endpoints M5 uses: server/about, auth/login, users/me,
search/metadata and asset thumbnails. Assets are synthetic, with solid-colour
PNG thumbnails so remote tiles are visually distinguishable from local ones.
"""

import json
import struct
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 4567
TOKEN = "mock-access-token"
SERVER_VERSION = "v3.1.0"

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
            "deviceAssetId": f"mock-device-asset-{i}",
            "deviceId": "mock-server-device",
            "type": "VIDEO" if is_video else "IMAGE",
            "originalFileName": f"immich-{i:02d}.{'mp4' if is_video else 'jpg'}",
            "checksum": f"mockchecksum{i:040d}",
            "fileCreatedAt": captured.isoformat(),
            "fileModifiedAt": captured.isoformat(),
            "localDateTime": captured.isoformat(),
            "updatedAt": now.isoformat(),
            "duration": "0:00:37.000" if is_video else "0:00:00.00000",
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
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_GET(self):
        path = self.path.split("?")[0]
        REQUEST_LOG.append(("GET", path))
        print(f"GET  {self.path}", flush=True)

        if path == "/api/server/about":
            return self._send(200, {"version": SERVER_VERSION, "versionUrl": ""})

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
            return self._send(200, {
                "accessToken": TOKEN,
                "userId": "user-1",
                "userEmail": "dave@example.com",
                "name": "Dave",
            })

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
        return self._send(204, {})


if __name__ == "__main__":
    print(f"Mock Immich {SERVER_VERSION} on http://127.0.0.1:{PORT} "
          f"({len(ASSETS)} assets)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
