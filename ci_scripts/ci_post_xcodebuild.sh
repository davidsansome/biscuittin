#!/bin/bash
# Xcode Cloud post-xcodebuild hook: fail archived builds if the CLIP models
# were not bundled, rather than shipping a build with no search bar.
set -euo pipefail

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ] || [ -z "${CI_ARCHIVE_PATH:-}" ]; then
    exit 0
fi

app_bundle=$(echo "$CI_ARCHIVE_PATH"/Products/Applications/*.app)
missing=()
for name in \
    mobileclip_s0_image.mlmodelc \
    mobileclip_s0_text.mlmodelc \
    clip_vocab.json \
    clip_merges.txt; do
    if [ ! -e "$app_bundle/$name" ]; then
        missing+=("$name")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: Not bundled in $app_bundle: ${missing[*]}. Check ci_scripts/ci_post_clone.sh." >&2
    exit 1
fi
