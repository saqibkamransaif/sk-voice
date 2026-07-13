#!/bin/zsh
# Builds SK Voice.app — a real bundle is required for stable TCC permissions
# (microphone, accessibility, input monitoring). The Node sidecar (dist + node_modules)
# is bundled into Contents/Resources/sidecar/. Signs with Apple Development identity
# when available, ad-hoc otherwise.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
SIDECAR_DIR="$ROOT_DIR/sidecar"
BUILD_CONFIG="${1:-release}"
BUNDLE_NAME="SK Voice.app"
DIST="$ROOT_DIR/dist"
BUNDLE="$DIST/$BUNDLE_NAME"

echo "==> Building sidecar"
cd "$SIDECAR_DIR"
npm run build >/dev/null

echo "==> swift build -c $BUILD_CONFIG"
cd "$APP_DIR"
swift build -c "$BUILD_CONFIG" --product SKVoiceApp

BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/SKVoiceApp"

echo "==> Assembling $BUNDLE_NAME"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/sidecar"
cp "$BIN" "$BUNDLE/Contents/MacOS/SKVoice"

echo "==> Bundling sidecar runtime"
cp -R "$SIDECAR_DIR/dist" "$BUNDLE/Contents/Resources/sidecar/dist"
# The SDK stays external to the esbuild bundle (bundling breaks its cli.js discovery),
# so ship node_modules alongside. package.json marks the bundle as ESM.
cp -R "$SIDECAR_DIR/node_modules" "$BUNDLE/Contents/Resources/sidecar/node_modules"
cp "$SIDECAR_DIR/package.json" "$BUNDLE/Contents/Resources/sidecar/package.json"

echo "==> Icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if [[ ! -f "$DIST/icon-1024.png" ]]; then
    swift "$ROOT_DIR/scripts/icongen.swift" "$DIST/icon-1024.png" 1024
fi
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$DIST/icon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$DIST/icon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>SK Voice</string>
    <key>CFBundleDisplayName</key>        <string>SK Voice</string>
    <key>CFBundleIdentifier</key>         <string>com.saqibkamran.skvoice</string>
    <key>CFBundleVersion</key>            <string>1.0.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundleExecutable</key>         <string>SKVoice</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>26.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SK Voice records your voice while you hold Fn to dictate.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>SK Voice transcribes your dictation on-device.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>SK Voice needs accessibility access to paste text into your applications.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
ENTITLEMENTS="$DIST/entitlements.plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -n "${IDENTITY:-}" ]]; then
    echo "    using identity: $IDENTITY"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$BUNDLE"
else
    echo "    no Apple Development identity found — ad-hoc signing"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE"
fi
codesign --verify --deep "$BUNDLE" && echo "    signature OK"

echo "==> Built: $BUNDLE"
echo "    Install with: cp -R \"$BUNDLE\" /Applications/"
