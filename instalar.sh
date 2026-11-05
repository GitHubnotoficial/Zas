#!/bin/bash
# Compila Zas en este Mac y lo instala en /Applications.
# Uso: bash instalar.sh
set -euo pipefail

APP_NAME="Zas"
BUNDLE_ID="local.zas.app"

cd "$(dirname "$0")"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Este instalador se corre en un Mac."
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Faltan las herramientas de desarrollo de Apple."
    echo "Se abrirá el instalador. Cuando termine, vuelve a correr: bash instalar.sh"
    xcode-select --install || true
    exit 1
fi

bash compilar.sh

echo "Instalando en /Applications..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "build/$APP_NAME.app" "/Applications/$APP_NAME.app"

# Cada compilación cambia la firma, y macOS deja de reconocer el permiso anterior.
# Se borra para que no quede un permiso activado que en realidad no funciona.
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true

open "/Applications/$APP_NAME.app"

echo
echo "Listo. Zas está en la barra de menú, arriba a la derecha."
echo "Si pide permiso de Grabación de pantalla, actívalo y pulsa \"Reiniciar Zas\"."
