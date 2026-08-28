#!/bin/bash
MD=/home/stev/Modelos-IA/minimax-h3
PROD=$MD/produccion
NOMBRE=${1:-existencialismo}
G=$PROD/guiones/$NOMBRE.guion
OBRA=$PROD/obra/$NOMBRE
TOTAL=$(grep -cE "^HABLA\|" "$G" 2>/dev/null || echo 0)
HECHOS=$(ls -1 $OBRA/p*.avi 2>/dev/null | wc -l)
BROLL=$(grep -cE "^BROLL\|" "$G" 2>/dev/null || echo 0)

barra() { local n=$1 t=$2 i o=""; for ((i=1;i<=t;i++)); do [ $i -le $n ] && o="$o#" || o="$o."; done; echo "$o"; }
echo "════════ $NOMBRE ════════  $(date '+%H:%M:%S')"
printf "  HABLADOS  %2d/%-2d  [%s]\n" $HECHOS $TOTAL "$(barra $HECHOS $TOTAL)"
printf "  B-roll    %2d      (ya generados, se reutilizan)\n" $BROLL
echo
if pgrep -f "bash producir.sh" >/dev/null; then
  L=$(ls -t $PROD/logs/$NOMBRE-p*.log 2>/dev/null | head -1)
  if [ -n "$L" ] && [ -f "$L" ]; then
    echo "  generando: $(basename "$L" .log | sed "s/$NOMBRE-//") -> $(tr '\r' '\n' < "$L" | grep -oE '[0-9]+/20 - [0-9.]+s/it' | tail -1)"
  else
    echo "  generando: arrancando..."
  fi
  REST=$((TOTAL-HECHOS))
  [ $REST -gt 0 ] && echo "  faltan $REST planos ≈ $(awk "BEGIN{printf \"%.1f\", $REST*1470/3600}") h"
else
  grep -q "LISTO" $PROD/logs/$NOMBRE.log 2>/dev/null && echo "  producción: TERMINADA" || echo "  producción: no activa"
fi
pgrep -f "escalar-2060" >/dev/null && echo "  2060: escalando B-roll a 1080p"
echo
echo "  GPUs:"; nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader | sed 's/^/    /'
echo
V=/home/stev/Vídeos/$NOMBRE
echo "  VER RESULTADOS  ->  $V/"
if [ -d "$V" ]; then
  ls -1t "$V"/*.mp4 2>/dev/null | head -6 | sed "s|$V/|    |"
else
  echo "    (aún sin planos publicados)"
fi
echo
echo "  guion: $G"
