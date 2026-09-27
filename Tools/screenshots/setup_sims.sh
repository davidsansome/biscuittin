#!/bin/bash
# Creates (or erases and reuses) the two simulators the App Store screenshots are taken on, and
# prepares them: app installed, photo access granted, the tagged photos added, dark mode, month
# grouping and a 9:41 status bar. Prints the UDIDs to drive them with. See README.md.
#
#   Tools/screenshots/setup_sims.sh [path/to/BiscuitTin.app]
#
# Dedicated simulators, never the ones used for day-to-day work: this erases them.
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="${1:-build/DerivedData/Build/Products/Debug-iphonesimulator/BiscuitTin.app}"
PHOTOS="build/screenshots/tagged"
BUNDLE="com.davidsansome.biscuittin"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(max(ios, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"])')"

[ -d "$APP" ] || { echo "No app at $APP; build it first (AGENTS.md)."; exit 1; }
ls "$PHOTOS"/*.jpg >/dev/null 2>&1 || { echo "No photos in $PHOTOS; run fetch_photos.sh and tag_photos.swift."; exit 1; }

# App Store Connect's required sizes: 6.9" iPhone (1320x2868) and 13" iPad (2064x2752).
setup() {
    local name="$1" type="$2" columns="$3" udid
    udid="$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == '$name': print(d['udid']); sys.exit()")"
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl erase "$udid"
    else
        udid="$(xcrun simctl create "$name" "$type" "$RUNTIME")"
    fi
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl install "$udid" "$APP"
    xcrun simctl privacy "$udid" grant photos "$BUNDLE"
    xcrun simctl addmedia "$udid" "$PHOTOS"/*.jpg
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl spawn "$udid" defaults write "$BUNDLE" grid.grouping month
    xcrun simctl spawn "$udid" defaults write "$BUNDLE" grid.columns -int "$columns"
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active \
        --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    xcrun simctl launch "$udid" "$BUNDLE" >/dev/null
    echo "$name: $udid"
}

setup "Screenshots iPhone 17 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max 4
setup "Screenshots iPad Pro 13" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB 6
