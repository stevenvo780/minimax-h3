#!/bin/bash
# Genera en la 5070 Ti a baja resolucion y escala x4 repartiendo frames entre AMBAS GPU -> 1080p.
# Uso: [FRAMES=345 STEPS=20 W=512 H=288 NAME=mi-clip] generar-1080p.sh "prompt"
set -u
MD=/home/stev/Modelos-IA/minimax-h3
DEST=/home/stev/Vídeos
WORK=$(mktemp -d /tmp/h3-1080p-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

W=${W:-512}; H=${H:-288}; FRAMES=${FRAMES:-56}; STEPS=${STEPS:-20}
NAME=${NAME:-h3}
STAMP=$(date +%Y%m%d-%H%M%S)
PROMPT="$1"

echo "=== [1/4] generacion ${W}x${H} ${FRAMES}f ${STEPS}pasos en la 5070 Ti ==="
T0=$SECONDS
$MD/bin/sd-cli -M vid_gen \
  --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
  --vae $MD/vae/minimax_h3_video_vae_fp16.safetensors \
  --audio-vae $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
  --llm $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
  -p "$PROMPT" \
  --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
  --diffusion-fa --rng cpu \
  --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu" \
  --max-vram "cuda0=6" --stream-layers \
  -o $WORK/raw.mp4 > $WORK/gen.log 2>&1
RC=$?
RAW=$WORK/raw.mp4.avi
if [ $RC -ne 0 ] || [ ! -f "$RAW" ]; then
  echo "FALLO en generacion (rc=$RC). Ultimas lineas:"; tail -5 $WORK/gen.log; exit 1
fi
TGEN=$((SECONDS-T0)); echo "    generacion OK en ${TGEN}s"

echo "=== [2/4] extrayendo frames y audio ==="
mkdir -p $WORK/in $WORK/out
ffmpeg -y -v error -i "$RAW" $WORK/in/f_%05d.png
ffmpeg -y -v error -i "$RAW" -vn -acodec pcm_s16le $WORK/audio.wav 2>/dev/null
N=$(ls $WORK/in/*.png 2>/dev/null | wc -l)
echo "    $N frames extraidos"
[ "$N" -eq 0 ] && { echo "FALLO: sin frames"; exit 1; }

echo "=== [3/4] escalado x4: 2 workers por GPU, reparto 50/50 ==="
T1=$SECONDS
worker() {  # $1=device  $2=lista
  while read -r f; do
    $MD/bin/sd-cli -M upscale -i "$f" \
      --upscale-model $MD/upscalers/RealESRGAN_x4plus.pth \
      --upscale-tile-size 512 --backend "$1" \
      -o "$WORK/out/$(basename "$f")" >/dev/null 2>&1
  done < "$2"
}
ls $WORK/in/*.png > $WORK/all.txt
rm -f $WORK/part-*
split -n r/4 -d $WORK/all.txt $WORK/part-      # 4 trozos: 2 por GPU
worker CUDA0 $WORK/part-00 & W1=$!
worker CUDA0 $WORK/part-01 & W2=$!
worker CUDA1 $WORK/part-02 & W3=$!
worker CUDA1 $WORK/part-03 & W4=$!
echo "    5070 Ti: $(( $(wc -l < $WORK/part-00) + $(wc -l < $WORK/part-01) )) frames (2 workers)"
echo "    2060   : $(( $(wc -l < $WORK/part-02) + $(wc -l < $WORK/part-03) )) frames (2 workers)"
for pid in $W1 $W2 $W3 $W4; do wait "$pid"; done
TUP=$((SECONDS-T1))
NOUT=$(ls $WORK/out/*.png 2>/dev/null | wc -l)
echo "    escalado OK en ${TUP}s ($NOUT/$N frames)"
if [ "$NOUT" -ne "$N" ]; then echo "FALLO: faltan frames escalados ($NOUT de $N)"; exit 1; fi

echo "=== [4/4] reensamblando a 1080p con audio ==="
mkdir -p "$DEST"
SEC=$(awk "BEGIN{printf \"%.1f\", $N/24}")
FINAL="$DEST/${NAME}-1080p-${SEC}s-${STAMP}.mp4"
if [ -f $WORK/audio.wav ]; then
  ffmpeg -y -v error -framerate 24 -i $WORK/out/f_%05d.png -i $WORK/audio.wav \
    -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 192k "$FINAL"
else
  ffmpeg -y -v error -framerate 24 -i $WORK/out/f_%05d.png \
    -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p "$FINAL"
fi
[ ! -f "$FINAL" ] && { echo "FALLO en reensamblado"; exit 1; }
echo "=== LISTO: $FINAL ==="
echo "    tiempos: generacion ${TGEN}s | escalado ${TUP}s | total $((SECONDS))s"
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,codec_name,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
