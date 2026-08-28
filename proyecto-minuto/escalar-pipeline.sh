#!/bin/bash
# Escalado x4 -> 1080p, plano a plano. FASE 1: solo 2060 (en paralelo con la generacion).
# FASE 2: la 5070 Ti se suma al terminar de generar.
# NO toca shots/ (originales). Salida: up-mp4/sNN.mp4. Limpia los PNG de cada plano al acabarlo.
set -u
MD=/home/stev/Modelos-IA/minimax-h3
P=$MD/proyecto-minuto
mkdir -p $P/up-mp4 $P/wk $P/claims

escalar_plano() {   # $1=sNN  $2=device  $3=tile
  local B=$1 DEV=$2 TILE=$3
  local IN=$P/wk/$B-in OUT=$P/wk/$B-out
  mkdir -p $IN $OUT
  ffmpeg -y -v error -i $P/shots/$B.avi $IN/%04d.png 2>/dev/null
  ffmpeg -y -v error -i $P/shots/$B.avi -vn -acodec pcm_s16le $P/wk/$B.wav 2>/dev/null
  local N=$(ls $IN/*.png 2>/dev/null | wc -l)
  [ "$N" -eq 0 ] && { echo "  [$DEV] $B sin frames"; return 1; }
  for f in $IN/*.png; do
    local b=$(basename "$f")
    [ -f "$OUT/$b" ] && continue
    $MD/bin/sd-cli -M upscale -i "$f" --upscale-model $MD/upscalers/RealESRGAN_x4plus.pth \
      --upscale-tile-size $TILE --backend "$DEV" -o "$OUT/$b" >/dev/null 2>&1
  done
  local M=$(ls $OUT/*.png 2>/dev/null | wc -l)
  if [ "$M" -ne "$N" ]; then echo "  [$DEV] $B INCOMPLETO ($M/$N)"; return 1; fi
  ffmpeg -y -v error -framerate 24 -i $OUT/%04d.png -i $P/wk/$B.wav \
    -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
    -c:a aac -b:a 192k $P/up-mp4/$B.mp4
  rm -rf $IN $OUT $P/wk/$B.wav
  echo "  [$DEV] $B LISTO -> up-mp4/$B.mp4"
}

worker() {  # $1=device $2=tile
  local DEV=$1 TILE=$2
  while :; do
    local GOT=""
    for f in $P/shots/s*.avi; do
      [ -f "$f" ] || continue
      local b=$(basename "$f" .avi)
      [ -f "$P/up-mp4/$b.mp4" ] && continue
      if mkdir "$P/claims/$b" 2>/dev/null; then GOT="$b"; break; fi
    done
    if [ -z "$GOT" ]; then
      [ -f "$P/GENERACION_LISTA" ] && break
      sleep 30; continue
    fi
    local T0=$SECONDS
    escalar_plano "$GOT" "$DEV" "$TILE" || rmdir "$P/claims/$GOT" 2>/dev/null
    echo "  [$DEV] $GOT en $((SECONDS-T0))s"
  done
  echo "  [$DEV] worker terminado"
}

echo "===== PIPELINE ESCALADO $(date '+%H:%M:%S') ====="
echo "FASE 1: solo 2060"
worker CUDA1 256 & W1=$!
( while pgrep -f "proyecto-minuto/generar.sh" >/dev/null 2>&1; do sleep 60; done
  touch $P/GENERACION_LISTA
  echo "===== FASE 2: se suma la 5070 Ti $(date '+%H:%M:%S') ====="
  worker CUDA0 512 ) & W2=$!
wait $W1 $W2
echo "===== ESCALADO TERMINADO $(date '+%H:%M:%S') ====="
ls -1 $P/up-mp4/*.mp4 2>/dev/null | wc -l | xargs echo "planos escalados:"
