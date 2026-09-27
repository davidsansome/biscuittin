#!/bin/bash
# Frames every raw capture in build/screenshots/captures into build/screenshots/final/, ready to
# upload to App Store Connect in filename order. The captions live here. See README.md.
#
#   Tools/screenshots/compose_all.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
IN="build/screenshots/captures"
OUT="build/screenshots/final"
rm -rf "$OUT"
mkdir -p "$OUT/iPhone-6.9" "$OUT/iPad-13"

# Keep each caption to what fits: an orphaned last word on its own line looks careless, and the
# iPad's wider text column wraps differently from the phone's, so check both after changing one.
compose() { swift Tools/screenshots/compose.swift "$IN/$1" "$OUT/$2" "$3" "$4" "$5" "$6"; }

compose p_grid.png     iPhone-6.9/1-timeline.png phone "All your photos." "One timeline." \
    "Your iPhone library and your Immich server, merged into one fast grid."
compose p_search.png   iPhone-6.9/2-search.png   phone "Search by" "what's in them." \
    "Type “sunset by the sea” and find it. On device, and fully offline."
compose p_map.png      iPhone-6.9/3-map.png      phone "See where" "you've been." \
    "Move the map and the grid follows, showing every photo taken there."
compose p_info.png     iPhone-6.9/4-details.png  phone "Every detail," "at a glance." \
    "Camera, exposure and location for every shot."
compose p_backup.png   iPhone-6.9/5-backup.png   phone "Back up to" "your own server." \
    "Photos upload automatically to Immich, not someone else's cloud."

compose i_grid.png     iPad-13/1-timeline.png    ipad "All your photos." "One timeline." \
    "Your iPad library and your Immich server, merged into one fast grid."
compose i_search.png   iPad-13/2-search.png      ipad "Search by" "what's in them." \
    "Type “sunset by the sea” and find it. On device, fully offline."
compose i_map.png      iPad-13/3-map.png         ipad "See where" "you've been." \
    "Move the map and the grid shows every photo taken there."
compose i_viewer.png   iPad-13/4-viewer.png      ipad "Every photo," "edge to edge." \
    "Swipe through your whole library, with nothing in the way."
compose i_backup.png   iPad-13/5-backup.png      ipad "Back up to" "your own server." \
    "Photos upload automatically to Immich, not someone else's cloud."

ls "$OUT"/*/*.png
