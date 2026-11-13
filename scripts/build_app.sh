#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'VERSION must contain a three-part version such as 0.0.1.' >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swift-cache"
SWIFT_BUILD_DIR="$ROOT_DIR/.build/swift-$APP_VERSION"
swift build --disable-sandbox --build-path "$SWIFT_BUILD_DIR" -c release
BIN_DIR="$(swift build --disable-sandbox --build-path "$SWIFT_BUILD_DIR" -c release --show-bin-path)"
WHISPER_BIN="$ROOT_DIR/.build/whisper.cpp-build/bin/whisper-cli"
WHISPER_MODEL="$ROOT_DIR/.build/whisper-models/ggml-base.bin"
if [[ ! -x "$WHISPER_BIN" || ! -f "$WHISPER_MODEL" ]]; then
    echo 'The bundled Whisper engine or model is missing. Run bash scripts/setup_whisper.sh first.' >&2
    exit 1
fi
APP_DIR="${MEMOBRIDGE_APP_OUTPUT:-$ROOT_DIR/dist/MemoBridge.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/models"
# Remove the previous executable first: on case-insensitive APFS, a prior
# differently cased name otherwise remains on disk and confuses code signing.
rm -f "$APP_DIR/Contents/MacOS/MemoBridge"
cp "$BIN_DIR/MemoBridge" "$APP_DIR/Contents/MacOS/MemoBridge"
cp "$WHISPER_BIN" "$APP_DIR/Contents/Resources/whisper-cli"
cp "$WHISPER_MODEL" "$APP_DIR/Contents/Resources/models/ggml-base.bin"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/.build/whisper.cpp/LICENSE" "$APP_DIR/Contents/Resources/WHISPER-LICENSE.txt"
swiftc -module-cache-path "$ROOT_DIR/.build/swift-cache" -target "$(uname -m)-apple-macosx13.0" -O \
    Sources/MemoBridgeApp/MemoStore.swift Sources/MemoBridgeApp/MemoIndex.swift Sources/MemoBridgeApp/HiddenRecordings.swift Sources/MemoBridgeApp/TranscriptDocument.swift Sources/MemoBridgeApp/TranscriptionService.swift \
    Sources/MemoBridgeApp/AudioConverter.swift Sources/MemoBridgeApp/AudioLinkRemoval.swift Sources/MemoBridgeApp/BatchProcessor.swift Sources/MemoBridgeCLI/BatchMain.swift \
    -lsqlite3 -o "$APP_DIR/Contents/MacOS/MemoBridgeCLI"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.memobridge.app</string>
<key>CFBundleName</key><string>MemoBridge</string>
<key>CFBundleDisplayName</key><string>MemoBridge</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>MemoBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppDataUsageDescription</key><string>MemoBridge needs access to Voice Memos to list and transcribe recordings.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR/Contents/Resources/whisper-cli"
codesign --force --sign - "$APP_DIR/Contents/MacOS/MemoBridgeCLI"
codesign --force --sign - "$APP_DIR"
if [[ "$APP_DIR" == "$ROOT_DIR/dist/MemoBridge.app" ]]; then
cat > "$ROOT_DIR/dist/memobridge" <<SH
#!/bin/sh
APP_DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)/MemoBridge.app"
exec "\$APP_DIR/Contents/MacOS/MemoBridgeCLI" "\$@"
SH
chmod +x "$ROOT_DIR/dist/memobridge"
fi
echo "Built $APP_DIR"
