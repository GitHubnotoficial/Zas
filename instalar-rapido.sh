#!/bin/bash
# Descarga la última versión de Zas y la instala en /Applications.
# No necesita las herramientas de desarrollo de Apple.
set -euo pipefail

APP_NAME="Zas"
URL="https://github.com/GitHubnotoficial/Zas/releases/latest/download/Zas.zip"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Este instalador se corre en un Mac."
    exit 1
fi

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

echo "Descargando $APP_NAME..."
curl -fL --progress-bar "$URL" -o "$TEMP/$APP_NAME.zip"
ditto -x -k "$TEMP/$APP_NAME.zip" "$TEMP"
codesign --verify "$TEMP/$APP_NAME.app"

echo "Instalando en /Applications..."
# Cierre ordenado: si estaba grabando, el video termina bien.
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
sleep 1
cp -R "$TEMP/$APP_NAME.app" "/Applications/.$APP_NAME-nuevo.app"
rm -rf "/Applications/$APP_NAME.app"
mv "/Applications/.$APP_NAME-nuevo.app" "/Applications/$APP_NAME.app"

open "/Applications/$APP_NAME.app"

echo
echo "Listo. Zas está en la barra de menú, arriba a la derecha."
