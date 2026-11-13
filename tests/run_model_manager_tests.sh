#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT_DIR/.build/whisper-models/ggml-base.bin"
if [[ ! -f "$MODEL" ]]; then
    echo "The offline test needs .build/whisper-models/ggml-base.bin; prepare it before running this test." >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/MemoBridge-model-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
APP="$TEST_ROOT/Test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/models"
ln "$MODEL" "$APP/Contents/Resources/models/ggml-base.bin" 2>/dev/null || cp "$MODEL" "$APP/Contents/Resources/models/ggml-base.bin"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.memobridge.modeltests</string><key>CFBundleExecutable</key><string>ModelManagerTests</string></dict></plist>
PLIST
export CLANG_MODULE_CACHE_PATH="$TEST_ROOT/clang-cache"
swiftc -swift-version 5 -parse-as-library "$ROOT_DIR/Sources/MemoBridgeApp/ModelManager.swift" \
    "$ROOT_DIR/tests/ModelManagerTests.swift" -o "$APP/Contents/MacOS/ModelManagerTests"
"$APP/Contents/MacOS/ModelManagerTests"
