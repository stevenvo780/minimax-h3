#!/bin/bash
# 14 planos independientes a 1376x768, 107 frames, 20 pasos. RESUMIBLE:
# si shots/sNN.avi ya existe, lo salta. Relanzar tras un fallo continua donde quedo.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
P=$MD/proyecto-minuto
params_defecto 1376 768 107 20
mkdir -p $P/shots $P/logs

echo "===== INICIO $(date '+%F %H:%M:%S') ====="
for i in $(seq -w 1 14); do
  OUT=$P/shots/s$i.avi
  if [ -f "$OUT" ]; then echo "### s$i ya existe, saltando"; continue; fi
  echo "### s$i/14  $(date '+%H:%M:%S') ###"
  T0=$SECONDS
  sd_vid_gen "$(cat $P/prompts/s$i.txt)" "$P/shots/tmp$i.mp4" -s $((200 + 10#$i)) > $P/logs/s$i.log 2>&1
  if [ -f "$(sd_salida "$P/shots/tmp$i.mp4")" ]; then
    mv "$(sd_salida "$P/shots/tmp$i.mp4")" "$OUT"
    echo "###   s$i OK en $((SECONDS-T0))s"
  else
    echo "###   s$i FALLO"; grep -aoE "out of memory|allocating [0-9.]+ MiB" $P/logs/s$i.log | tail -2
  fi
done
echo "===== GENERACION TERMINADA $(date '+%F %H:%M:%S') ====="
ls -1 $P/shots/*.avi 2>/dev/null | wc -l | xargs echo "planos completados:"
