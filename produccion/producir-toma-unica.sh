#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRODUCIR TOMA UNICA — un plano largo, cero eslabones.
#
#  Uso: producir-toma-unica.sh <guion> <nombre> [frames] [W] [H] [pasos]
#
#  Existe porque esta medido que el eslabon es lo unico que degrada: un plano
#  solo aguanta 25/25 de gradacion y 20/20 de estructura hasta 345 frames,
#  mientras que encadenar cuatro hunde el montaje de 95.0 a 68.7.
#
#  Deja margen de hardware al usuario: el techo de VRAM sale de lib/vram.sh,
#  que lo calcula sobre lo LIBRE en ese instante, no sobre el total.
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
PROD=$MD/produccion

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}
FRAMES=${3:-345}; W=${4:-736}; H=${5:-416}; PASOS=${6:-20}
MODELO=${MODELO:-$MD/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf}

OBRA=$PROD/obra/$NOMBRE; mkdir -p "$OBRA" "$PROD/logs"
[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }
SD=$(compat_sdcli) || { echo "sd-cli no es ejecutable en esta maquina"; exit 1; }

ESCENA=$(grep -m1 '^@ESCENA '   "$GUION" | sed 's/^@ESCENA //')
AMBIENTE=$(grep -m1 '^@AMBIENTE ' "$GUION" | sed 's/^@AMBIENTE //')
MUSICA=$(grep -m1 '^@MUSICA '   "$GUION" | sed 's/^@MUSICA //')
DIA=$(grep -m1 '^HABLA|' "$GUION" | cut -d'|' -f2)
[ -n "$DIA" ] || { echo "el guion no tiene ninguna linea HABLA"; exit 1; }

PROMPT="detailed_description:
The target video is in realistic photographic style. [Shot 1] $ESCENA He speaks with calm deliberation, unhurried, pausing naturally between sentences. Subject 1 (S1) says, <d>[Spanish] $DIA</d> When his voice stops, his lips settle closed and he holds the gaze, breathing slowly.

overall_soundscape:
$AMBIENTE

non_diegetic_music:
$MUSICA"

OUT=$OBRA/toma.mp4
LOG=$PROD/logs/$NOMBRE-toma.log
SEG=$(awk "BEGIN{printf \"%.1f\", $FRAMES/24}")
echo "═══ TOMA UNICA: $NOMBRE ═══  $(date '+%F %H:%M:%S')"
echo "    ${W}x${H} · ${FRAMES} frames (${SEG}s) · ${PASOS} pasos · $(basename "$MODELO")"
vram_informe

MAXV=$(vram_arg_trabajo 0 "$FRAMES" "$W" "$H")
echo "    techo de VRAM: --max-vram $MAXV (deja libre el resto para el escritorio)"
vram_esperar 0 5000 600 || echo "    aviso: sigo sin margen holgado, arranco igual"

T0=$SECONDS
# con_cerrojo: nunca dos generaciones a la vez (ver lib/comun.sh)
con_cerrojo 7200 "$SD" -M vid_gen \
  --diffusion-model "$MODELO" \
  --vae "$MODELO_VAE" --audio-vae "$MODELO_AVAE" --llm "$MODELO_LLM" \
  -p "$PROMPT" -s "${SEED:-100}" \
  --cfg-scale "${CFG:-1.0}" -W "$W" -H "$H" --fps 24 \
  --video-frames "$FRAMES" --steps "$PASOS" \
  --diffusion-fa --rng cpu \
  --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu" \
  --max-vram "$MAXV" --stream-layers \
  -o "$OUT" > "$LOG" 2>&1
RC=$?
REAL=$(sd_salida "$OUT")
if [ $RC -ne 0 ] || [ ! -f "$REAL" ]; then
  echo "FALLO (rc=$RC) tras $((SECONDS-T0))s. Ultimas lineas:"
  tr '\r' '\n' < "$LOG" | tail -8 | sed 's/^/    /'
  exit 1
fi
mv "$REAL" "$OBRA/p01.avi"
echo "    OK en $((SECONDS-T0))s -> $OBRA/p01.avi"
echo "═══ midiendo ═══"
python3 "$PROD/auditar.py" plano "$OBRA/p01.avi"
python3 "$PROD/auditar.py" contacto "$OBRA/p01.avi" "$OBRA/contacto.jpg" >/dev/null \
  && echo "    hoja de contactos: $OBRA/contacto.jpg"
