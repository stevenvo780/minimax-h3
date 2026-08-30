#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  GUARDIAN DE VRAM — protege el margen de GPU del usuario.
#
#  Steven puso UNA condicion para dejar usar el hardware: "solo dejame un
#  pedacito para operar yo". Esto la hace cumplir: si la VRAM libre baja del
#  umbral, corta la generacion. No avisa: corta. Perder una toma cuesta 20
#  minutos; dejarle sin escritorio le cuesta el dia.
#
#  Ya actuo dos veces de verdad, y las dos tenia razon: a 1155 MiB y a 87 MiB
#  libres, cuando el escritorio del usuario crecio y la generacion dejo de caber.
#
#  IMPORTANTE — como identifica a quien matar:
#  con nvidia-smi --query-compute-apps, NO con un patron sobre la linea de
#  comandos. Un patron haria match con este mismo script y se mataria solo. Ese
#  error se cometio TRES veces en una sesion con pkill -f y pgrep -f.
#
#  Uso:  guardian-vram.sh [umbral_MiB] [gpu]      (por defecto 1200 y 0)
# ═══════════════════════════════════════════════════════════════════════════
set -u
UMBRAL=${1:-1200}
GPU=${2:-0}

command -v nvidia-smi >/dev/null || { echo "GUARDIAN: sin nvidia-smi, no puedo vigilar" >&2; exit 1; }
echo "GUARDIAN: vigilando la GPU $GPU · corto si bajan de $UMBRAL MiB libres"

while true; do
  libre=$(nvidia-smi -i "$GPU" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  if [[ "$libre" =~ ^[0-9]+$ ]] && [ "$libre" -lt "$UMBRAL" ]; then
    # El PID lo da la propia GPU: quien de verdad la esta ocupando.
    pid=$(nvidia-smi -i "$GPU" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "GUARDIAN: solo $libre MiB libres — corto el pid $pid, que ocupa la GPU, para dejarte margen"
      kill -TERM "$pid" 2>/dev/null
      sleep 30   # dejar que libere antes de volver a mirar
    fi
  fi
  sleep 10
done
