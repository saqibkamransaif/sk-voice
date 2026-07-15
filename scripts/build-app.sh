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
# whisper.cpp is a system-library SPM target resolved via pkg-config; the augmented .pc
# adds the ggml formula's headers/libs (runtime deps: brew install whisper-cpp pkgconf).
export PKG_CONFIG_PATH="$ROOT_DIR/scripts/pkgconfig:${PKG_CONFIG_PATH:-}"
swift build -c "$BUILD_CONFIG" --product SKVoiceApp

BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/SKVoiceApp"

echo "==> Assembling $BUNDLE_NAME"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/sidecar"
cp "$BIN" "$BUNDLE/Contents/MacOS/SKVoice"

echo "==> Bundling whisper/ggml libraries (self-contained, re-signed — no library-validation exception)"
FRAMEWORKS="$BUNDLE/Contents/Frameworks"
BACKENDS="$BUNDLE/Contents/Resources/ggml-backends"
mkdir -p "$FRAMEWORKS" "$BACKENDS"

# Copy the linked dylibs (resolving symlinks) and the ggml backend plugins.
cp -L /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib "$FRAMEWORKS/"
cp -L /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$FRAMEWORKS/"
cp -L /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$FRAMEWORKS/"
cp -L /opt/homebrew/opt/libomp/lib/libomp.dylib "$FRAMEWORKS/"
cp -L /opt/homebrew/opt/ggml/libexec/*.so "$BACKENDS/"

# Point the main binary at the bundled copies.
MAIN="$BUNDLE/Contents/MacOS/SKVoice"
install_name_tool -change /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib @rpath/libwhisper.1.dylib \
                  -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib \
                  -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
                  -add_rpath @executable_path/../Frameworks "$MAIN" 2>/dev/null || true

# Normalize ids and inter-library references inside the bundle.
for LIB in "$FRAMEWORKS"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$LIB")" "$LIB" 2>/dev/null || true
    for DEP in $(otool -L "$LIB" | awk '/\/opt\/homebrew/{print $1}'); do
        install_name_tool -change "$DEP" "@rpath/$(basename "$DEP")" "$LIB" 2>/dev/null || true
    done
done
# Backend plugins already use @rpath deps; give them an rpath to Contents/Frameworks.
for SO in "$BACKENDS"/*.so; do
    for DEP in $(otool -L "$SO" | awk '/\/opt\/homebrew/{print $1}'); do
        install_name_tool -change "$DEP" "@rpath/$(basename "$DEP")" "$SO" 2>/dev/null || true
    done
    install_name_tool -add_rpath @loader_path/../../Frameworks "$SO" 2>/dev/null || true
done

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
    <key>CFBundleVersion</key>            <string>1.6.0</string>
    <key>CFBundleShortVersionString</key> <string>1.6.0</string>
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
SIGN_ID="${IDENTITY:--}"
[[ -n "${IDENTITY:-}" ]] && echo "    using identity: $IDENTITY" || echo "    ad-hoc signing"
# Sign nested code first (inside-out), then the bundle. Everything carries the same
# Team ID, so hardened-runtime library validation stays fully enabled.
for NESTED in "$FRAMEWORKS"/*.dylib "$BACKENDS"/*.so; do
    codesign --force --options runtime --sign "$SIGN_ID" "$NESTED"
done
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$BUNDLE"
else
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE"
fi
codesign --verify --deep "$BUNDLE" && echo "    signature OK"

echo "==> Built: $BUNDLE"
echo "    Install with: cp -R \"$BUNDLE\" /Applications/"
