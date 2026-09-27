#!/bin/bash
# Downloads the App Store screenshot photos listed in photos.json from Unsplash's image CDN.
# The photos are free to use commercially under the Unsplash licence; they are not committed
# because they are ~100 MB. See README.md.
#
#   Tools/screenshots/fetch_photos.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="build/screenshots/raw"
mkdir -p "$OUT"

python3 - "$OUT" <<'EOF'
import concurrent.futures, json, subprocess, sys
out = sys.argv[1]
photos = json.load(open("Tools/screenshots/photos.json"))

def fetch(p):
    # images.unsplash.com accepts plain curl; unsplash.com itself (search, napi) does not.
    url = f"https://images.unsplash.com/{p['unsplash']}?w=2400&q=82&fm=jpg"
    return p["file"], subprocess.run(["curl", "-sf", "--retry", "3", "-o", f"{out}/{p['file']}", url]).returncode

with concurrent.futures.ThreadPoolExecutor(8) as pool:
    failed = [f for f, rc in pool.map(fetch, photos) if rc]
print(f"{len(photos) - len(failed)} of {len(photos)} photos in {out}")
if failed:
    sys.exit(f"failed: {failed}")
EOF
