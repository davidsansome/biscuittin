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
MODEL_REVISION="3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"

TOKENIZER_REPO="openai/clip-vit-base-patch32"
TOKENIZER_REVISION="3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268"

cd "$(dirname "$0")/.."
DEST="BiscuitTin/Resources/Models"

# A git worktree starts without $DEST, because it is gitignored, and a build without it silently
# ships no search bar. Clone the main checkout's copy (APFS copy-on-write, so instant and
# free) rather than re-downloading 120 MB. Anything still missing afterwards is fetched below.
MAIN_CHECKOUT="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
if [ -n "$MAIN_CHECKOUT" ] && [ "$MAIN_CHECKOUT" != "$(pwd -P)" ] \
        && [ -d "$MAIN_CHECKOUT/$DEST" ] && [ ! -e "$DEST" ]; then
    echo "Copying models from the main checkout ($MAIN_CHECKOUT):"
    mkdir -p "$(dirname "$DEST")"
    cp -cR "$MAIN_CHECKOUT/$DEST" "$DEST" 2>/dev/null || cp -R "$MAIN_CHECKOUT/$DEST" "$DEST"
fi

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
