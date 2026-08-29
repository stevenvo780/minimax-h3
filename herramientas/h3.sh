#!/bin/bash
# MiniMax-H3 en kratos (5070 Ti). Uso:
#   h3.sh "prompt"                        -> 864x480, 56 frames (2.3s), 20 pasos
#   W=1280 H=704 h3.sh "prompt"           -> 720p
#   FRAMES=90 h3.sh "prompt"              -> clip de 3.75s  (frames validos: 5,22,39,56,73,90...)
#   STEPS=8 h3.sh "prompt"                -> mas rapido, menos calidad
#   IMG=foto.png h3.sh "prompt"           -> condicionado por primer frame (I2VA)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
params_defecto 864 480 56 20
PARAMS_BACKEND="diffusion=cpu"; MAXVRAM="cuda0=8"

OUT=${OUT:-$DEST/h3-$(date +%Y%m%d-%H%M%S).mp4}
mkdir -p "$(dirname "$OUT")"
EXTRA=()
[ -n "$IMG" ] && EXTRA+=(--init-img "$IMG")

sd_vid_gen "$1" "$OUT" "${EXTRA[@]}"

REAL=$(sd_salida "$OUT")
if [ -f "$REAL" ]; then
  echo "Vídeo generado: $REAL"
else
  echo "Error: no se generó el fichero esperado: $REAL" >&2
  exit 1
fi
