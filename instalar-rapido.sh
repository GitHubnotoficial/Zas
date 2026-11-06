#!/bin/bash
# Descarga la última versión de Zas y la instala en /Applications.
# No necesita las herramientas de desarrollo de Apple.
set -euo pipefail

APP_NAME="Zas"
URL="${ZAS_URL:-https://github.com/GitHubnotoficial/Zas/releases/latest/download/Zas.zip}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Este instalador se corre en un Mac."
    exit 1
fi

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

# Sin permisos de administrador se instala solo para este usuario.
DESTINATION="/Applications"
if [[ ! -w "$DESTINATION" ]]; then
    DESTINATION="$HOME/Applications"
    mkdir -p "$DESTINATION"
fi

echo "Descargando $APP_NAME..."
curl -fL --progress-bar "$URL" -o "$TEMP/$APP_NAME.zip"
ditto -x -k "$TEMP/$APP_NAME.zip" "$TEMP"
codesign --verify "$TEMP/$APP_NAME.app"

echo "Instalando en $DESTINATION..."
# Cierre ordenado: si estaba grabando, el video termina bien antes de reemplazar la app.
if pkill -TERM -x "$APP_NAME" 2>/dev/null; then
    for _ in $(seq 1 60); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.25
    done
    pkill -KILL -x "$APP_NAME" 2>/dev/null || true
fi

cp -R "$TEMP/$APP_NAME.app" "$DESTINATION/.$APP_NAME-nuevo.app"
rm -rf "${DESTINATION:?}/$APP_NAME.app"
mv "$DESTINATION/.$APP_NAME-nuevo.app" "$DESTINATION/$APP_NAME.app"

open "$DESTINATION/$APP_NAME.app"

echo
echo "Listo. Zas está en la barra de menú, arriba a la derecha."
