#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
PROD=$MD/produccion
NOMBRE=${1:-existencialismo}
G=$PROD/guiones/$NOMBRE.guion
OBRA=$PROD/obra/$NOMBRE
TOTAL=$(grep -cE "^HABLA\|" "$G" 2>/dev/null)
HECHOS=$(ls -1 $OBRA/p*.avi 2>/dev/null | wc -l)
BROLL=$(grep -cE "^BROLL\|" "$G" 2>/dev/null)
TOTAL=${TOTAL:-0}
BROLL=${BROLL:-0}

barra() { local n=$1 t=$2 i o=""; [ "$t" -le 0 ] && { echo "(sin guion)"; return; }; for ((i=1;i<=t;i++)); do [ $i -le $n ] && o="$o#" || o="$o."; done; echo "$o"; }
echo "════════ $NOMBRE ════════  $(date '+%H:%M:%S')"
printf "  HABLADOS  %2d/%-2d  [%s]\n" $HECHOS $TOTAL "$(barra $HECHOS $TOTAL)"
printf "  B-roll    %2d      (ya generados, se reutilizan)\n" $BROLL
echo
if pgrep -f "producir\.sh" >/dev/null; then
  L=$(ls -t $PROD/logs/$NOMBRE-p*.log 2>/dev/null | head -1)
  if [ -n "$L" ] && [ -f "$L" ]; then
    echo "  generando: $(basename "$L" .log | sed "s/$NOMBRE-//") -> $(tr '\r' '\n' < "$L" | grep -oE "[0-9]+/$STEPS - [0-9.]+s/it" | tail -1)"
  else
    echo "  generando: arrancando..."
  fi
  REST=$((TOTAL-HECHOS))
  # Tiempo típico: ~1470s/plano para 1376x768/107f/20 pasos. Derivar de STEPS si es distinto.
  TIEMPO_POR_PLANO=$(awk "BEGIN{printf \"%.0f\", 1470*$STEPS/20}")
  [ $REST -gt 0 ] && echo "  faltan $REST planos ≈ $(awk "BEGIN{printf \"%.1f\", $REST*$TIEMPO_POR_PLANO/3600}") h"
else
  grep -q "LISTO" $PROD/logs/$NOMBRE.log 2>/dev/null && echo "  producción: TERMINADA" || echo "  producción: no activa"
fi
pgrep -f "escalar-2060" >/dev/null && echo "  2060: escalando B-roll a 1080p"
echo
echo "  GPUs:"; nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader | sed 's/^/    /'
echo
V=$DEST/$NOMBRE
echo "  VER RESULTADOS  ->  $V/"
if [ -d "$V" ]; then
  ls -1t "$V"/*.mp4 2>/dev/null | head -6 | sed "s|$V/|    |"
else
  echo "    (aún sin planos publicados)"
fi
echo
echo "  guion: $G"
