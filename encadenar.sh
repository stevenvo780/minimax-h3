#!/bin/bash
# Genera un video largo encadenando segmentos: el ultimo frame de cada uno
# es el frame inicial (--init-img) del siguiente. Calidad nativa sin techo de duracion.
# Uso: [SEGS=3 FRAMES=124 W=1376 H=768 STEPS=20 NAME=x] encadenar.sh "prompt"
set -u
MD=/home/stev/Modelos-IA/minimax-h3
DEST=/home/stev/Vídeos
WORK=$(mktemp -d /tmp/h3-chain-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

W=${W:-1376}; H=${H:-768}; FRAMES=${FRAMES:-124}; STEPS=${STEPS:-20}
SEGS=${SEGS:-3}; NAME=${NAME:-cadena}; SEED=${SEED:-42}
PROMPT="$1"
STAMP=$(date +%Y%m%d-%H%M%S)

PREV=""
for i in $(seq 1 $SEGS); do
  echo "### segmento $i/$SEGS  (${W}x${H}, ${FRAMES}f, ${STEPS} pasos) $(date '+%H:%M:%S') ###"
  EXTRA=()
  [ -n "$PREV" ] && EXTRA+=(--init-img "$PREV")
  T0=$SECONDS
  $MD/bin/sd-cli -M vid_gen \
    --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
    --vae $MD/vae/minimax_h3_video_vae_fp16.safetensors \
    --audio-vae $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
    --llm $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
    -p "$PROMPT" -s $((SEED + i)) \
    --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu" \
    --max-vram "cuda0=2" --stream-layers \
    -o $WORK/seg$i.mp4 "${EXTRA[@]}" > $WORK/seg$i.log 2>&1
  RC=$?
  if [ $RC -ne 0 ] || [ ! -f "$WORK/seg$i.mp4.avi" ]; then
    echo "### FALLO en segmento $i (rc=$RC)"; grep -aoE "out of memory|allocating [0-9.]+ MiB" $WORK/seg$i.log | tail -2; exit 1
  fi
  echo "###   segmento $i OK en $((SECONDS-T0))s"
  # ultimo frame -> semilla visual del siguiente
  PREV=$WORK/last$i.png
  ffmpeg -y -v error -sseof -0.05 -i "$WORK/seg$i.mp4.avi" -frames:v 1 -update 1 "$PREV" 2>/dev/null \
    || ffmpeg -y -v error -i "$WORK/seg$i.mp4.avi" -vf "select=eq(n\,$((FRAMES-1)))" -frames:v 1 -update 1 "$PREV"
  [ ! -f "$PREV" ] && { echo "### FALLO extrayendo ultimo frame del segmento $i"; exit 1; }
done

echo "### concatenando $SEGS segmentos ###"
: > $WORK/lista.txt
for i in $(seq 1 $SEGS); do echo "file '$WORK/seg$i.mp4.avi'" >> $WORK/lista.txt; done
TOT=$((FRAMES*SEGS)); SEC=$(awk "BEGIN{printf \"%.1f\", $TOT/24}")
FINAL="$DEST/${NAME}-${W}x${H}-${SEC}s-${STAMP}.mp4"
ffmpeg -y -v error -f concat -safe 0 -i $WORK/lista.txt \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k "$FINAL"
[ ! -f "$FINAL" ] && { echo "### FALLO al concatenar"; exit 1; }
echo "### LISTO: $FINAL ###"
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
