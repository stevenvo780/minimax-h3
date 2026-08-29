#!/bin/bash
# Genera un video largo encadenando segmentos: el ultimo frame de cada uno
# es el frame inicial (--init-img) del siguiente. Calidad nativa sin techo de duracion.
# Uso: [SEGS=3 FRAMES=124 W=1376 H=768 STEPS=20 NAME=x] encadenar.sh "prompt"
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"

WORK=$(mktemp -d /tmp/h3-chain-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

params_defecto 1376 768 124 20
PARAMS_BACKEND="diffusion=cpu"; MAXVRAM="cuda0=2"
SEGS=${SEGS:-3}; NAME=${NAME:-cadena}; SEED=${SEED:-42}
PROMPT="$1"
STAMP=$(date +%Y%m%d-%H%M%S)

PREV=""
for i in $(seq 1 $SEGS); do
  echo "### segmento $i/$SEGS  (${W}x${H}, ${FRAMES}f, ${STEPS} pasos) $(date '+%H:%M:%S') ###"
  EXTRA=()
  [ -n "$PREV" ] && EXTRA+=(--init-img "$PREV")
  T0=$SECONDS
  sd_vid_gen "$PROMPT" "$WORK/seg$i.mp4" -s $((SEED + i)) "${EXTRA[@]}" > $WORK/seg$i.log 2>&1
  RC=$?
  SEGAVI=$(sd_salida "$WORK/seg$i.mp4")
  if [ $RC -ne 0 ] || [ ! -f "$SEGAVI" ]; then
    echo "### FALLO en segmento $i (rc=$RC)"; grep -aoE "out of memory|allocating [0-9.]+ MiB" $WORK/seg$i.log | tail -2; exit 1
  fi
  echo "###   segmento $i OK en $((SECONDS-T0))s"
  # ultimo frame -> semilla visual del siguiente
  PREV=$WORK/last$i.png
  ff -y -v error -sseof -0.05 -i "$SEGAVI" -frames:v 1 -update 1 "$PREV" 2>/dev/null \
    || ff -y -v error -i "$SEGAVI" -vf "select=eq(n\,$((FRAMES-1)))" -frames:v 1 -update 1 "$PREV"
  [ ! -f "$PREV" ] && { echo "### FALLO extrayendo ultimo frame del segmento $i"; exit 1; }
done

echo "### concatenando $SEGS segmentos ###"
: > $WORK/lista.txt
for i in $(seq 1 $SEGS); do echo "file '$(sd_salida "$WORK/seg$i.mp4")'" >> $WORK/lista.txt; done
TOT=$((FRAMES*SEGS)); SEC=$(awk "BEGIN{printf \"%.1f\", $TOT/24}")
FINAL="$DEST/${NAME}-${W}x${H}-${SEC}s-${STAMP}.mp4"
ff -y -v error -f concat -safe 0 -i $WORK/lista.txt \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k "$FINAL"
[ ! -f "$FINAL" ] && { echo "### FALLO al concatenar"; exit 1; }
echo "### LISTO: $FINAL ###"
ffp -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
