#!/bin/bash
# Xcode Cloud post-clone hook: fetches the gitignored MobileCLIP-S0 CoreML
# models and CLIP tokenizer files so archived builds include search.
set -euo pipefail

"$CI_PRIMARY_REPOSITORY_PATH/Tools/fetch_models.sh"
