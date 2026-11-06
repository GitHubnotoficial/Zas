#!/bin/bash
# Compila build/Zas.app para Apple Silicon e Intel. La usan instalar.sh y GitHub Actions.
set -euo pipefail

APP_NAME="Zas"
BUNDLE_ID="local.zas.app"
MIN_MACOS="13.0"
VERSION="0.8.0"

cd "$(dirname "$0")"

BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "Creando icono..."
xcrun swift Tools/icono.swift "$BUILD_DIR/Zas.iconset" "$BUILD_DIR/icono.png"
iconutil -c icns "$BUILD_DIR/Zas.iconset" -o "$BUNDLE/Contents/Resources/Zas.icns"
rm -rf "$BUILD_DIR/Zas.iconset"

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
    <key>CFBundleIconFile</key><string>Zas</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Zas necesita ver la pantalla para tomar capturas y grabar video.</string>
    <key>NSMicrophoneUsageDescription</key><string>Zas usa el micrófono solo cuando activas grabar tu voz en los videos.</string>
</dict>
</plist>
PLIST

echo "Firmando..."
# En GitHub se firma con el certificado de Zas para que macOS recuerde el permiso entre versiones.
codesign --force --deep --sign "${ZAS_SIGN_ID:--}" "$BUNDLE"
codesign --verify --verbose "$BUNDLE"
codesign --display --requirements - "$BUNDLE"
