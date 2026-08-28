#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRODUCIR — pipeline estandarizado MiniMax-H3
#  Uso:  producir.sh <guion> [nombre]
#  Ej:   producir.sh guiones/existencialismo.guion existencialismo
#
#  Lee un .guion (ver formato en el propio fichero), genera los planos HABLA
#  encadenando los marcados "encadena", inserta los BROLL ya existentes y
#  ensambla el vídeo final en ~/Vídeos.
#
#  RESUMIBLE: los planos ya generados en obra/<nombre>/ se saltan.
#  NO destructivo: nunca sobrescribe material de entrada.
# ═══════════════════════════════════════════════════════════════════════════
set -u
MD=/home/stev/Modelos-IA/minimax-h3
PROD=$MD/produccion
DEST=/home/stev/Vídeos

GUION=${1:?falta el guion}
NOMBRE=${2:-$(basename "$GUION" .guion)}
W=${W:-1376}; H=${H:-768}; FRAMES=${FRAMES:-107}; STEPS=${STEPS:-20}
SEED=${SEED:-100}

OBRA=$PROD/obra/$NOMBRE
mkdir -p "$OBRA" "$PROD/logs"
[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }

# ── parsear cabecera ───────────────────────────────────────────────────────
ESCENA=$(grep -m1 '^@ESCENA '   "$GUION" | sed 's/^@ESCENA //')
AMBIENTE=$(grep -m1 '^@AMBIENTE ' "$GUION" | sed 's/^@AMBIENTE //')
MUSICA=$(grep -m1 '^@MUSICA '   "$GUION" | sed 's/^@MUSICA //')

# ── generar un plano hablado ───────────────────────────────────────────────
generar_habla() {   # $1=idx  $2=dialogo  $3=init_img(o vacio)  $4=encuadre
  local IDX=$1 DIA=$2 INIT=$3 ENC=${4:-}
  local OUT=$OBRA/p$IDX
  [ -f "$OUT.avi" ] && { echo "  p$IDX ya existe, salto"; return 0; }
  local PROMPT="detailed_description:
The target video is in realistic photographic style. [Shot 1] $ESCENA ${ENC:+$ENC. }He pauses, then speaks with calm deliberation. Subject 1 (S1) says, <d>[Spanish] $DIA</d> Exactly as his voice stops, his lips settle closed and he holds the gaze, breathing slowly.

overall_soundscape:
$AMBIENTE

non_diegetic_music:
$MUSICA"
  local EXTRA=(); [ -n "$INIT" ] && EXTRA+=(--init-img "$INIT")
  local T0=$SECONDS
  $MD/bin/sd-cli -M vid_gen \
    --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
    --vae $MD/vae/minimax_h3_video_vae_fp16.safetensors \
    --audio-vae $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
    --llm $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
    -p "$PROMPT" -s $((SEED + 10#$IDX)) \
    --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu,vae=cpu" \
    --max-vram "cuda0=2" --stream-layers \
    -o "$OUT.mp4" "${EXTRA[@]}" > "$PROD/logs/$NOMBRE-p$IDX.log" 2>&1
  if [ -f "$OUT.mp4.avi" ]; then
    mv "$OUT.mp4.avi" "$OUT.avi"
    echo "  p$IDX OK en $((SECONDS-T0))s${INIT:+ (encadenado)}"
    return 0
  fi
  # OOM transitorio (picos de VRAM del escritorio): reintentar hasta 4 veces
  if grep -qa "out of memory" "$PROD/logs/$NOMBRE-p$IDX.log" 2>/dev/null; then
    local try=1
    while [ $try -le 4 ]; do
      echo "  p$IDX OOM, reintento $try/4 en 90s (VRAM libre: $(nvidia-smi -i 0 --query-gpu=memory.free --format=csv,noheader))"
      sleep 90
      T0=$SECONDS
      $MD/bin/sd-cli -M vid_gen \
        --diffusion-model $MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf \
        --vae $MD/vae/minimax_h3_video_vae_fp16.safetensors \
        --audio-vae $MD/vae/minimax_h3_audio_vae_fp32.safetensors \
        --llm $MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf \
        -p "$PROMPT" -s $((SEED + 10#$IDX)) \
        --cfg-scale 1.0 -W $W -H $H --fps 24 --video-frames $FRAMES --steps $STEPS \
        --diffusion-fa --rng cpu \
        --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu,vae=cpu" \
        --max-vram "cuda0=2" --stream-layers \
        -o "$OUT.mp4" "${EXTRA[@]}" > "$PROD/logs/$NOMBRE-p$IDX.log" 2>&1
      if [ -f "$OUT.mp4.avi" ]; then
        mv "$OUT.mp4.avi" "$OUT.avi"
        echo "  p$IDX OK en $((SECONDS-T0))s (reintento $try)${INIT:+ (encadenado)}"
        return 0
      fi
      try=$((try+1))
    done
  fi
  echo "  p$IDX FALLO DEFINITIVO"; grep -aoE "out of memory|allocating [0-9.]+ MiB" "$PROD/logs/$NOMBRE-p$IDX.log" | tail -2
  return 1
}

ultimo_frame() {  # $1=avi  $2=png destino
  ffmpeg -y -v error -sseof -0.05 -i "$1" -frames:v 1 -update 1 "$2" 2>/dev/null
  [ -f "$2" ] || ffmpeg -y -v error -i "$1" -vf "select=eq(n\,$((FRAMES-1)))" -frames:v 1 -update 1 "$2" 2>/dev/null
}

# ── recorrer el guion ──────────────────────────────────────────────────────
echo "═══ PRODUCIENDO: $NOMBRE ═══  $(date '+%F %H:%M:%S')"
echo "    ${W}x${H}, ${FRAMES}f, ${STEPS} pasos"
IDX=0; PREV=""; ENC_TRAMO=""; : > "$OBRA/orden.txt"
while IFS='|' read -r TIPO CONT MODO ENCU; do
  case "$TIPO" in
    HABLA)
      IDX=$((IDX+1)); N=$(printf "%02d" $IDX)
      case "${MODO:-}" in
        encadena) ENCU="${ENCU:-$ENC_TRAMO}" ;;
        ancla:*)  PREV="$OBRA/${MODO#ancla:}"; ENC_TRAMO="${ENCU:-}"
                  [ -f "$PREV" ] || { echo "  ANCLA NO ENCONTRADA: $PREV"; PREV=""; } ;;
        *)        PREV=""; ENC_TRAMO="${ENCU:-}" ;;
      esac
      if generar_habla "$N" "$CONT" "$PREV" "${ENCU:-}"; then
        case "${MODO:-}" in encadena) MARCA="cont";; *) MARCA="tramo";; esac
        echo "$OBRA/p$N.avi $MARCA" >> "$OBRA/orden.txt"
        PREV=$OBRA/last$N.png; ultimo_frame "$OBRA/p$N.avi" "$PREV"
        [ -f "$PREV" ] || PREV=""
      fi
      ;;
    BROLL)
      SRC="$MD/proyecto-minuto/$CONT"
      [ -f "$SRC" ] || SRC="$CONT"
      if [ -f "$SRC" ]; then
        echo "$SRC" >> "$OBRA/orden.txt"; echo "  broll: $(basename $SRC)"
      else
        echo "  broll NO ENCONTRADO: $CONT"
      fi
      PREV=""    # tras un corte visual no se encadena
      ;;
  esac
done < <(grep -E "^(HABLA|BROLL)\|" "$GUION")

# ── ensamblar ──────────────────────────────────────────────────────────────
echo "═══ ENSAMBLANDO ($(wc -l < "$OBRA/orden.txt") planos) ═══"
MONT=$OBRA/montaje; mkdir -p "$MONT"; rm -f "$MONT"/*.mp4 "$MONT/lista.txt" 2>/dev/null
DUR=$(awk "BEGIN{printf \"%.4f\", $FRAMES/24}")
i=0
while read -r f marca; do
  i=$((i+1)); n=$(printf "%02d" $i)
  [ "$marca" = "tramo" ] && [ $i -gt 1 ] && echo "$n" >> "$MONT/tramos.txt"
  CLIPDUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
  CLIPDUR=${CLIPDUR:-$DUR}
  ffmpeg -nostdin -y -v error -i "$f" \
    -af "loudnorm=I=-19:TP=-2:LRA=7,afade=t=in:st=0:d=0.25,afade=t=out:st=$(awk "BEGIN{print $CLIPDUR-0.25}"):d=0.25" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k "$MONT/$n.mp4"
  echo "file '$MONT/$n.mp4'" >> "$MONT/lista.txt"
done < "$OBRA/orden.txt"

STAMP=$(date +%Y%m%d-%H%M%S)
SEC=$(awk "BEGIN{printf \"%.0f\", $i*$DUR}")
FINAL="$DEST/$NOMBRE-${W}x${H}-${SEC}s-$STAMP.mp4"
# Union DURA dentro de cada tramo (la continuidad es exacta), FUNDIDO entre tramos.
if [ -s "$MONT/tramos.txt" ]; then
  echo "  fundidos entre tramos: $(tr '\n' ' ' < $MONT/tramos.txt)"
  python3 "$PROD/fundir.py" "$MONT" "$FINAL" || \
    ffmpeg -nostdin -y -v error -f concat -safe 0 -i "$MONT/lista.txt" -c copy "$FINAL"
else
  ffmpeg -nostdin -y -v error -f concat -safe 0 -i "$MONT/lista.txt" -c copy "$FINAL"
fi
[ -f "$FINAL" ] || { echo "FALLO al ensamblar"; exit 1; }
echo "═══ LISTO: $FINAL ═══"
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
