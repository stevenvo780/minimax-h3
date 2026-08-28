#!/bin/bash
# MiniMax-H3 en kratos (5070 Ti). Uso:
#   h3.sh "prompt"                        -> 864x480, 56 frames (2.3s), 20 pasos
#   W=1280 H=704 h3.sh "prompt"           -> 720p
#   FRAMES=90 h3.sh "prompt"              -> clip de 3.75s  (frames validos: 5,22,39,56,73,90...)
#   STEPS=8 h3.sh "prompt"                -> mas rapido, menos calidad
#   IMG=foto.png h3.sh "prompt"           -> condicionado por primer frame (I2VA)
MD=/home/stev/Modelos-IA/minimax-h3
W=${W:-864}; H=${H:-480}; FRAMES=${FRAMES:-56}; STEPS=${STEPS:-20}
OUT=${OUT:-$MD/salidas/h3-$(date +%Y%m%d-%H%M%S).mp4}
mkdir -p "$(dirname "$OUT")"
EXTRA=()
[ -n "$IMG" ] && EXTRA+=(--init-img "$IMG")

exec $MD/bin/sd-cli -M vid_gen \
  --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
  --vae            $MD/vae/minimax_h3_video_vae_fp16.safetensors \
  --audio-vae      $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
  --llm            $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
  -p "$1" \
  --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
  --diffusion-fa --rng cpu \
  --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" \
  --params-backend "diffusion=cpu" \
  --max-vram "cuda0=8" --stream-layers \
  -o "$OUT" "${EXTRA[@]}"
