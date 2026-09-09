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
descargar_fijado \
    face_recognition_sface_2021dec.onnx \
    https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx \
    0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
descargar_fijado \
    ggml-small.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
    1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b
descargar_fijado \
    ggml-silero-v6.2.0.bin \
    https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin \
    2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987

printf '\nEvaluador listo. Ejecutalo con:\n  %s/bin/python calidad/v2/evaluar_obra.py --help\n' "$VENV"
