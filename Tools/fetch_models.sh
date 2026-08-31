#!/bin/bash
# Downloads the MobileCLIP-S0 CoreML encoders and the CLIP BPE vocabulary (DESIGN.md D22).
#
# These are NOT committed to git: ~108 MB of weights would dominate the repository and they
# are reproducible from a pinned upstream revision. Run this once after cloning, and again
# whenever MODEL_REVISION changes.
#
#   ./Tools/fetch_models.sh
#
# Output lands in BiscuitTin/Resources/Models/, which the Xcode target bundles.
set -euo pipefail

REPO="apple/coreml-mobileclip"
# Pinned: an unpinned "main" would silently change the embeddings under an existing index.
# Bumping this is a model upgrade — bump `CLIPModel.version` with it so stored embeddings
# re-index rather than being compared across models (D22).
MODEL_REVISION="main"

TOKENIZER_REPO="openai/clip-vit-base-patch32"
TOKENIZER_REVISION="main"

cd "$(dirname "$0")/.."
DEST="BiscuitTin/Resources/Models"
mkdir -p "$DEST"

fetch() {
    local url="$1" out="$2"
    if [ -f "$out" ]; then
        echo "  have $(basename "$out")"
        return
    fi
    echo "  get  $(basename "$out")"
    mkdir -p "$(dirname "$out")"
    curl -fsSL --retry 3 "$url" -o "$out"
}

echo "MobileCLIP-S0 encoders ($REPO @ $MODEL_REVISION):"
for variant in image text; do
    pkg="$DEST/mobileclip_s0_${variant}.mlpackage"
    base="https://huggingface.co/$REPO/resolve/$MODEL_REVISION/mobileclip_s0_${variant}.mlpackage"
    fetch "$base/Manifest.json" "$pkg/Manifest.json"
    fetch "$base/Data/com.apple.CoreML/model.mlmodel" "$pkg/Data/com.apple.CoreML/model.mlmodel"
    fetch "$base/Data/com.apple.CoreML/weights/weight.bin" "$pkg/Data/com.apple.CoreML/weights/weight.bin"
done

echo "CLIP BPE vocabulary ($TOKENIZER_REPO @ $TOKENIZER_REVISION):"
# MobileCLIP uses the standard OpenAI CLIP tokenizer, so the vocabulary comes from the
# reference CLIP repo rather than Apple's CoreML export (which ships weights only).
fetch "https://huggingface.co/$TOKENIZER_REPO/resolve/$TOKENIZER_REVISION/vocab.json" "$DEST/clip_vocab.json"
fetch "https://huggingface.co/$TOKENIZER_REPO/resolve/$TOKENIZER_REVISION/merges.txt" "$DEST/clip_merges.txt"

echo
du -sh "$DEST"
echo "Done. $DEST is gitignored; the Xcode target bundles it."
