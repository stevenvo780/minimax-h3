#!/bin/bash
# 14 planos independientes a 1376x768, 107 frames, 20 pasos. RESUMIBLE:
# si shots/sNN.avi ya existe, lo salta. Relanzar tras un fallo continua donde quedo.
set -u
MD=/home/stev/Modelos-IA/minimax-h3
P=$MD/proyecto-minuto
W=1376; H=768; FRAMES=107; STEPS=20

echo "===== INICIO $(date '+%F %H:%M:%S') ====="
for i in $(seq -w 1 14); do
  OUT=$P/shots/s$i.avi
  if [ -f "$OUT" ]; then echo "### s$i ya existe, saltando"; continue; fi
  echo "### s$i/14  $(date '+%H:%M:%S') ###"
  T0=$SECONDS
  $MD/bin/sd-cli -M vid_gen \
    --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
    --vae $MD/vae/minimax_h3_video_vae_fp16.safetensors \
    --audio-vae $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
    --llm $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
    -p "$(cat $P/prompts/s$i.txt)" -s $((200 + 10#$i)) \
    --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu" \
    --max-vram "cuda0=2" --stream-layers \
    -o $P/shots/tmp$i.mp4 > $P/logs/s$i.log 2>&1
  if [ -f "$P/shots/tmp$i.mp4.avi" ]; then
    mv "$P/shots/tmp$i.mp4.avi" "$OUT"
    echo "###   s$i OK en $((SECONDS-T0))s"
  else
    echo "###   s$i FALLO"; grep -aoE "out of memory|allocating [0-9.]+ MiB" $P/logs/s$i.log | tail -2
  fi
done
echo "===== GENERACION TERMINADA $(date '+%F %H:%M:%S') ====="
ls -1 $P/shots/*.avi 2>/dev/null | wc -l | xargs echo "planos completados:"
