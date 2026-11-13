#!/bin/bash
# Build a pinned whisper.cpp and obtain its multilingual base model locally.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$PROJECT_DIR/.build"
SOURCE_DIR="$CACHE_DIR/whisper.cpp"
BUILD_DIR="$CACHE_DIR/whisper.cpp-build"
MODEL_DIR="$CACHE_DIR/whisper-models"
MODEL_FILE="$MODEL_DIR/ggml-base.bin"
MODEL_SHA256="60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
WHISPER_COMMIT="a8d002cfd879315632a579e73f0148d06959de36"

command -v git >/dev/null || { echo 'Git is required.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'CMake is required.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }
mkdir -p "$CACHE_DIR" "$MODEL_DIR"
if [ ! -d "$SOURCE_DIR/.git" ]; then
    if [ -e "$SOURCE_DIR" ]; then
        echo "The source directory exists but is not a Git repository: $SOURCE_DIR" >&2
        exit 1
    fi
    echo 'Downloading whisper.cpp v1.7.6 source…'
    git clone --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git "$SOURCE_DIR"
fi
ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$WHISPER_COMMIT" ]; then
    echo "The whisper.cpp version does not match the pinned commit: $ACTUAL_COMMIT" >&2
    exit 1
fi

echo 'Building whisper-cli…'
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$BUILD_DIR" --target whisper-cli --config Release -j 2

if [ -f "$MODEL_FILE" ] && printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_FILE" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo 'The multilingual Base model is already cached.'
else
    TEMP_MODEL="$MODEL_FILE.download"
    trap 'rm -f "$TEMP_MODEL"' EXIT
    echo 'Downloading the multilingual Whisper Base model (about 148 MB)…'
    curl --fail --location --retry 2 --connect-timeout 20 \
        --output "$TEMP_MODEL" \
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin'
    printf '%s  %s\n' "$MODEL_SHA256" "$TEMP_MODEL" | shasum -a 256 -c -
    mv -f "$TEMP_MODEL" "$MODEL_FILE"
    trap - EXIT
fi
printf 'Whisper is ready:\n  Engine: %s\n  Model: %s\n' "$BUILD_DIR/bin/whisper-cli" "$MODEL_FILE"
