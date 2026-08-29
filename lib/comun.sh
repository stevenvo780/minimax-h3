#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  COMÚN — configuración y llamadas compartidas de la pipeline MiniMax-H3
#
#  Se sourcea desde cualquier script del proyecto:
#      . "$(dirname "${BASH_SOURCE[0]}")/lib/comun.sh"        # desde la raíz
#      . "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"     # desde produccion/
#
#  MD (raíz del proyecto) se deduce de dónde está ESTE fichero, así el proyecto
#  funciona esté donde esté montado. Se puede forzar con MD=... en el entorno.
# ═══════════════════════════════════════════════════════════════════════════

MD=${MD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# HOME puede venir sin definir (cron, systemd, sudo sin -H); sin este respaldo
# DEST valdria "/Vídeos" y los videos acabarian en la raiz del disco.
DEST=${DEST:-${HOME:-/home/$(id -un)}/Vídeos}

SDCLI=$MD/bin/sd-cli
MODELO_DIFF=$MD/diffusion_models/minimax_h3_fl2va-Q4_K_M.gguf
MODELO_VAE=$MD/vae/minimax_h3_video_vae_fp16.safetensors
MODELO_AVAE=$MD/vae/minimax_h3_audio_vae_fp32.safetensors
MODELO_LLM=$MD/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf
UPSCALER=$MD/upscalers/RealESRGAN_x4plus.pth

# ── Parámetros de generación ───────────────────────────────────────────────
# Lo que el usuario puso en el ENTORNO manda siempre. Se guarda aquí antes de
# aplicar ningún default, para que `params_defecto` pueda respetarlo.
_W_ENV=${W:-}; _H_ENV=${H:-}; _FRAMES_ENV=${FRAMES:-}; _STEPS_ENV=${STEPS:-}

W=${W:-1376}; H=${H:-768}; FRAMES=${FRAMES:-107}; STEPS=${STEPS:-20}
FPS=${FPS:-24}; CFG=${CFG:-1.0}
BACKEND=${BACKEND:-"diffusion=CUDA0,te=cpu,vae=CUDA0"}
PARAMS_BACKEND=${PARAMS_BACKEND:-"diffusion=cpu"}
MAXVRAM=${MAXVRAM:-"cuda0=2"}

# params_defecto <W> <H> <FRAMES> <STEPS>
#   Fija los valores propios de UN script sin pisar lo que venga del entorno.
#   Llámalo DESPUÉS de sourcear este fichero. Existe porque escribir
#   `W=${W:-864}` después del source NO funciona: aquí W ya vale 1376 y el
#   `:-` no se dispara — el script correría a otra resolución en silencio.
params_defecto() {
  W=${_W_ENV:-$1}; H=${_H_ENV:-$2}; FRAMES=${_FRAMES_ENV:-$3}; STEPS=${_STEPS_ENV:-$4}
}

# ── ffmpeg SIEMPRE con -nostdin ────────────────────────────────────────────
# Sin -nostdin, ffmpeg lee del stdin del bucle `while read` que lo invoca y se
# come líneas del guion: planos que desaparecen sin un solo mensaje de error.
# Usar ff/ffp en lugar de ffmpeg/ffprobe en TODO el proyecto.
ff()  { ffmpeg -nostdin "$@"; }
ffp() { ffprobe "$@"; }

# ── sd-cli: una sola definición de la llamada de generación ────────────────
# Uso:  sd_vid_gen "<prompt>" "<salida.mp4>" [args extra: -s N, --init-img f...]
# OJO: sd-cli escribe en "<salida>.avi", no en "<salida>". Usar sd_salida().
sd_vid_gen() {
  local PROMPT=$1 OUT=$2; shift 2
  "$SDCLI" -M vid_gen \
    --diffusion-model "$MODELO_DIFF" \
    --vae            "$MODELO_VAE" \
    --audio-vae      "$MODELO_AVAE" \
    --llm            "$MODELO_LLM" \
    -p "$PROMPT" \
    --cfg-scale "$CFG" -W "$W" -H "$H" --fps "$FPS" \
    --video-frames "$FRAMES" --steps "$STEPS" \
    --diffusion-fa --rng cpu \
    --backend "$BACKEND" --params-backend "$PARAMS_BACKEND" \
    --max-vram "$MAXVRAM" --stream-layers \
    -o "$OUT" "$@" < /dev/null
}

# Ruta real del fichero que deja sd-cli cuando le pides "-o algo.mp4".
sd_salida() { echo "$1.avi"; }

# ── sd-cli: escalado ───────────────────────────────────────────────────────
# Uso:  sd_upscale <entrada.png> <salida.png> <backend: CUDA0|CUDA1> [tile]
sd_upscale() {
  "$SDCLI" -M upscale -i "$1" \
    --upscale-model "$UPSCALER" \
    --upscale-tile-size "${4:-512}" --backend "$3" \
    -o "$2" < /dev/null
}

# ── Comprobación de dependencias externas ──────────────────────────────────
# Uso:  requiere ffmpeg ffprobe   -> aborta con un mensaje claro si falta algo
requiere() {
  local falta=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || falta="$falta $c"; done
  [ -z "$falta" ] || { echo "faltan comandos requeridos:$falta" >&2; return 1; }
}

# ── Cerrojo de generacion ──────────────────────────────────────────────────
# En un contenedor con 24 GB de RAM, DOS generaciones a la vez se matan entre
# si: los modelos ocupan 33 GB repartidos entre RAM y swap y no caben dos.
# Paso de verdad: una prueba y una comparacion A/B lanzadas en paralelo
# murieron LAS DOS con SIGKILL del OOM killer, sin dejar nada util.
# Toda generacion debe pasar por aqui.
#
#   con_cerrojo <segundos_de_espera> <comando...>
con_cerrojo() {
  local espera=$1; shift
  local lock=${CERROJO:-${TMPDIR:-/tmp}/h3-generacion.lock}
  local t=0
  exec 9>"$lock" || { echo "cerrojo: no puedo abrir $lock" >&2; return 1; }
  while ! flock -n 9; do
    if [ "$t" -ge "$espera" ]; then
      echo "cerrojo: otra generacion lleva mas de ${espera}s ocupando el turno" >&2
      exec 9>&-; return 1
    fi
    [ "$t" = 0 ] && echo "cerrojo: hay otra generacion en curso, espero mi turno" >&2
    sleep 10; t=$((t+10))
  done
  "$@"; local rc=$?
  flock -u 9; exec 9>&-
  return $rc
}

# ── Guardia de memoria ─────────────────────────────────────────────────────
# El contenedor tiene 24 GB y una generacion usa casi todos. Medir mientras
# genera (evaluar2 lanza decenas de ffmpeg) se lleva el resto y el OOM killer
# mata la generacion. Paso de verdad: la toma 3 murio en el paso 16/20 tras 18
# minutos de GPU porque yo estaba midiendo las tomas 1 y 2 en paralelo.
#
#   ram_libre_mb            -> MiB disponibles dentro del cgroup
#   hay_generacion_en_curso -> 0 si hay una generacion viva
ram_libre_mb() {
  local max cur
  max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  [ "$max" = max ] && max=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
  cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
  echo $(( (max - cur) / 1048576 ))
}

hay_generacion_en_curso() {
  local lock=${CERROJO:-${TMPDIR:-/tmp}/h3-generacion.lock}
  [ -e "$lock" ] || return 1
  exec 8>"$lock" 2>/dev/null || return 1
  if flock -n 8; then flock -u 8; exec 8>&-; return 1; fi
  exec 8>&-; return 0
}
