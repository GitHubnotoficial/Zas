#!/bin/bash
# Compila build/Zas.app para Apple Silicon e Intel. La usan instalar.sh y GitHub Actions.
set -euo pipefail

APP_NAME="Zas"
BUNDLE_ID="local.zas.app"
MIN_MACOS="13.0"
VERSION="0.2.0"

cd "$(dirname "$0")"

BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUNDLE/Contents/MacOS"

for ARCH in arm64 x86_64; do
    echo "Compilando para $ARCH..."
    xcrun swiftc \
        -O \
        -swift-version 5 \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -o "$BUILD_DIR/$APP_NAME-$ARCH" \
        Sources/*.swift
done

lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" \
    -output "$BUNDLE/Contents/MacOS/$APP_NAME"
rm "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Zas necesita ver la pantalla para tomar capturas y grabar video.</string>
</dict>
</plist>
PLIST

echo "Firmando..."
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --verbose "$BUNDLE"
