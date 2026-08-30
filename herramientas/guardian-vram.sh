#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  GUARDIAN DE VRAM — protege el margen de GPU del usuario.
#
#  SOLO mata procesos PROPIOS (sd-cli). La primera version cortaba a quien
#  ocupara la GPU sin mirar de quien era, y matO un proceso python del usuario
#  mientras aqui no habia nada generando. Un guardian que protege el margen
#  matando los procesos de la persona a la que protege no sirve de nada.
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
    # SOLO se mata lo NUESTRO. La primera version cortaba a quien ocupara la GPU,
    # sin mirar de quien era: el 2026-08-30 mato un proceso python del usuario
    # mientras aqui no habia NADA generando. Un guardian que protege el margen
    # matando los procesos de la persona a la que protege no sirve de nada.
    #
    # Se cruzan dos fuentes: los PID que la GPU declara ocupados y los procesos
    # que se llaman EXACTAMENTE sd-cli. Si el que ocupa no es nuestro, se avisa y
    # no se toca: sera el escritorio o una herramienta del usuario, y ahi la
    # decision es suya.
    ocupan=$(nvidia-smi -i "$GPU" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ')
    mios=$(ps -eo pid,comm | awk '$2=="sd-cli"{print $1}')
    pid=""
    for o in $ocupan; do
      for m in $mios; do [ "$o" = "$m" ] && pid=$o && break 2; done
    done
    if [ -n "$pid" ]; then
      echo "GUARDIAN: solo $libre MiB libres — corto sd-cli (pid $pid) para dejarte margen"
      kill -TERM "$pid" 2>/dev/null
      sleep 30   # dejar que libere antes de volver a mirar
    else
      echo "GUARDIAN: solo $libre MiB libres, pero quien ocupa la GPU NO es sd-cli. No toco nada."
      sleep 60   # no repetir el aviso cada 10 s
    fi
  fi
  sleep 10
done
