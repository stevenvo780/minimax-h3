#!/usr/bin/env bash
set -euo pipefail

# Instala las capacidades semanticas opcionales del evaluador V2 sin tocar el
# entorno Python del proyecto. Los artefactos se fijan por version y SHA-256;
# `modelos/` y `.venv-calidad/` estan fuera de Git.

RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VENV="$RAIZ/.venv-calidad"
DESTINO="$RAIZ/modelos/evaluacion"

mkdir -p "$DESTINO"
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check \
    'opencv-python-headless==4.12.0.88'

descargar_fijado() {
    local nombre=$1 url=$2 sha=$3 destino="$DESTINO/$1" temporal
    if [[ -f "$destino" ]]; then
        local actual
        actual=$(sha256sum "$destino" | awk '{print $1}')
        if [[ "$actual" == "$sha" ]]; then
            printf 'OK existente  %s\n' "$nombre"
            return
        fi
        printf 'ERROR: %s existe pero su SHA-256 no coincide; no se sobrescribe.\n' "$destino" >&2
        return 1
    fi
    temporal=$(mktemp "$DESTINO/.${nombre}.XXXXXX")
    trap 'rm -f -- "$temporal"' RETURN
    curl --fail --location --retry 3 --output "$temporal" "$url"
    printf '%s  %s\n' "$sha" "$temporal" | sha256sum --check --status
    mv -- "$temporal" "$destino"
    trap - RETURN
    printf 'OK descargado %s\n' "$nombre"
}

descargar_fijado \
    face_detection_yunet_2023mar.onnx \
    https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx \
    8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
# SFace, whisper y silero los descargaba este script para el evaluador v2, que
# ya no existe: 503 MB que nada leia. YuNet SI se queda, porque lo usa
# calidad/seleccionar-ancla.py, que corre EN CALIENTE durante la generacion
# para elegir el fotograma de ancla de cada toma.

printf '\nSelector de ancla listo. Compruebalo con:\n  %s/bin/python calidad/seleccionar-ancla.py --help\n' "$VENV"
