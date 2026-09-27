#!/bin/bash
# Frames every raw capture in build/screenshots/captures into fastlane/screenshots/en-AU/, which
# is committed: the App Store workflow uploads that folder, replacing whatever App Store Connect
# has, and orders it by filename. The captions live here. See README.md.
#
#   Tools/screenshots/compose_all.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
IN="build/screenshots/captures"
# en-AU is the app's primary language. A folder for a language the app does not have yet makes
# the workflow add that localization to the App Store listing.
OUT="fastlane/screenshots/en-AU"
mkdir -p "$OUT"
rm -f "$OUT"/*.jpg

# Keep each caption to what fits: an orphaned last word on its own line looks careless, and the
# iPad's wider text column wraps differently from the phone's, so check both after changing one.
compose() { swift Tools/screenshots/compose.swift "$IN/$1" "$OUT/$2" "$3" "$4" "$5" "$6"; }

compose p_grid.png     iPhone-1-timeline.jpg phone "All your photos." "One timeline." \
    "Your iPhone library and your Immich server, merged into one fast grid."
compose p_search.png   iPhone-2-search.jpg   phone "Search by" "what's in them." \
    "Type “sunset by the sea” and find it. On device, and fully offline."
compose p_map.png      iPhone-3-map.jpg      phone "See where" "you've been." \
    "Move the map and the grid follows, showing every photo taken there."
compose p_info.png     iPhone-4-details.jpg  phone "Every detail," "at a glance." \
    "Camera, exposure and location for every shot."
compose p_backup.png   iPhone-5-backup.jpg   phone "Back up to" "your own server." \
    "Photos upload automatically to Immich, not someone else's cloud."

compose i_grid.png     iPad-1-timeline.jpg    ipad "All your photos." "One timeline." \
    "Your iPad library and your Immich server, merged into one fast grid."
compose i_search.png   iPad-2-search.jpg      ipad "Search by" "what's in them." \
    "Type “sunset by the sea” and find it. On device, fully offline."
compose i_map.png      iPad-3-map.jpg         ipad "See where" "you've been." \
    "Move the map and the grid shows every photo taken there."
compose i_viewer.png   iPad-4-viewer.jpg      ipad "Every photo," "edge to edge." \
    "Swipe through your whole library, with nothing in the way."
compose i_backup.png   iPad-5-backup.jpg      ipad "Back up to" "your own server." \
    "Photos upload automatically to Immich, not someone else's cloud."

ls -l "$OUT"
