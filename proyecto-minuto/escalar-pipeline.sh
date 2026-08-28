#!/bin/bash
# Escalado x4 -> 1080p, plano a plano. FASE 1: solo 2060 (en paralelo con la generacion).
# FASE 2: la 5070 Ti se suma al terminar de generar.
# NO toca shots/ (originales). Salida: up-mp4/sNN.mp4. Limpia los PNG de cada plano al acabarlo.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
P=$MD/proyecto-minuto
mkdir -p $P/up-mp4 $P/wk $P/claims

# Limpiar al arrancar los claims huerfanos (planos sin su up-mp4 terminado) y las
# marcas de fallo permanente: relanzar el script ES el reintento.
# LIMITACION: asume UNA sola instancia. Si lanzas dos a la vez, la segunda borra
# los claims que la primera tiene en vuelo y ambas escalarian el mismo plano.
rm -f "$P"/claims/*.FALLIDO 2>/dev/null
for claim_dir in $P/claims/*/; do
  [ -d "$claim_dir" ] || continue
  b=$(basename "$claim_dir")
  if [ ! -f "$P/up-mp4/$b.mp4" ]; then
    echo "  limpiando claim huérfano: $b"
    rmdir "$claim_dir" 2>/dev/null || true
  fi
done

escalar_plano() {   # $1=sNN  $2=device  $3=tile
  local B=$1 DEV=$2 TILE=$3
  local IN=$P/wk/$B-in OUT=$P/wk/$B-out
  mkdir -p $IN $OUT
  ff -y -v error -i $P/shots/$B.avi $IN/%04d.png 2>/dev/null
  ff -y -v error -i $P/shots/$B.avi -vn -acodec pcm_s16le $P/wk/$B.wav 2>/dev/null
  local N=$(ls $IN/*.png 2>/dev/null | wc -l)
  [ "$N" -eq 0 ] && { echo "  [$DEV] $B sin frames"; return 1; }
  for f in $IN/*.png; do
    local b=$(basename "$f")
    [ -f "$OUT/$b" ] && continue
    sd_upscale "$f" "$OUT/$b" "$DEV" "${TILE}" >/dev/null 2>&1
  done
  local M=$(ls $OUT/*.png 2>/dev/null | wc -l)
  if [ "$M" -ne "$N" ]; then echo "  [$DEV] $B INCOMPLETO ($M/$N)"; return 1; fi
  ff -y -v error -framerate 24 -i $OUT/%04d.png -i $P/wk/$B.wav \
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
      [ -f "$P/claims/$b.FALLIDO" ] && continue  # Skip permanently failed planos
      if mkdir "$P/claims/$b" 2>/dev/null; then GOT="$b"; break; fi
    done
    if [ -z "$GOT" ]; then
      [ -f "$P/GENERACION_LISTA" ] && break
      sleep 30; continue
    fi
    local T0=$SECONDS INTENTOS=0
    while [ $INTENTOS -lt 3 ]; do
      escalar_plano "$GOT" "$DEV" "$TILE" && break
      INTENTOS=$((INTENTOS+1))
      if [ $INTENTOS -lt 3 ]; then
        echo "  [$DEV] $GOT REINTENTANDO ($INTENTOS/3) en 60s..."
        sleep 60
      fi
    done
    if [ $INTENTOS -ge 3 ]; then
      echo "  [$DEV] $GOT FALLIDO PERMANENTEMENTE (agotados 3 intentos)"
      touch "$P/claims/$GOT.FALLIDO"
      rmdir "$P/claims/$GOT" 2>/dev/null || true
    else
      rmdir "$P/claims/$GOT" 2>/dev/null || true
      echo "  [$DEV] $GOT en $((SECONDS-T0))s"
    fi
  done
  echo "  [$DEV] worker terminado"
}

echo "===== PIPELINE ESCALADO $(date '+%H:%M:%S') ====="
echo "FASE 1: solo 2060"
worker CUDA1 256 & W1=$!
( while pgrep -f '[/ ]generar\.sh' >/dev/null 2>&1; do sleep 60; done
  touch $P/GENERACION_LISTA
  echo "===== FASE 2: se suma la 5070 Ti $(date '+%H:%M:%S') ====="
  worker CUDA0 512 ) & W2=$!
wait $W1 $W2
echo "===== ESCALADO TERMINADO $(date '+%H:%M:%S') ====="
ls -1 $P/up-mp4/*.mp4 2>/dev/null | wc -l | xargs echo "planos escalados:"
