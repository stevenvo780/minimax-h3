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
# Las piezas van a videos/entregas del PROYECTO, no a ~/Vídeos: alli el autor
# no las ve. Se puede apuntar a otro sitio exportando DEST.
DEST=${DEST:-$MD/videos/entregas}

# sd-cli no arranca tal cual en este contenedor: le falta libcudart.so.13 y se
# compilo contra una glibc mas nueva. compat.sh resuelve las dos cosas (busca
# CUDA en los venv del disco y copia el binario sin la exigencia de version).
# Se sourcea AQUI, no en cada script: seis scripts que usan sd-cli no lo
# sourceaban y morian con "libcudart.so.13: cannot open shared object file"
# nada mas tocar la GPU. Paso de verdad: sd_upscale devolvia 127 desde
# herramientas/generar-1080p.sh.
if [ -z "${COMPAT_LISTO:-}" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/compat.sh"
  COMPAT_LISTO=1
fi
SDCLI=$(compat_sdcli "$MD/bin/sd-cli" 2>/dev/null) || SDCLI=$MD/bin/sd-cli

# El modelo por defecto es el PODADO (11.4 GB), no el entero (18.8 GB).
# No es una preferencia de calidad: el codificador de texto ocupa 17 GB y el
# cgroup son 24 GB. 18.8+17 = 35.8 GB no entran y el OOM killer se lleva la
# generacion con un "Killed" seco. Con el podado, 11.4+17 = 28.4 GB entran
# mandando el codificador a disco (PARAMS_BK=diffusion=cpu,te=disk).
MODELO_DIFF=${MODELO_DIFF:-$MD/modelos/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf}
MODELO_VAE=$MD/modelos/vae/minimax_h3_video_vae_fp16.safetensors
MODELO_AVAE=$MD/modelos/vae/minimax_h3_audio_vae_fp32.safetensors
MODELO_LLM=$MD/modelos/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf
UPSCALER=$MD/modelos/upscalers/RealESRGAN_x4plus.pth

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
# ── continuidad de luminancia entre tomas ──────────────────────────────────
# El modelo, al re-anclar en una escena oscura, devuelve una toma mas CLARA que
# la de partida. Medido en 'paisaje': la toma 2 salio un 50% mas clara que la 1,
# y en la hoja de contactos se ve como si alguien subiera las luces a mitad de
# pieza. El ancla NO tiene la culpa: se comprobo que el PNG extraido es identico
# pixel a pixel al fotograma de origen (diferencia maxima 0 en RGB24).
#
# Lo importante: ese escalon de brillo se disfraza de perdida de calidad. La
# misma pieza medida sin corregir daba +38% de energia de bordes entre la toma 1
# y la 2, lo que parece realce acumulado; igualando SOLO la luminancia el escalon
# cae a -7.1%. No habia nada mas nitido — una imagen mas clara enseña bordes que
# estaban escondidos en la sombra.
#
# Por eso esto NO es la palanca de desenfoque que se descarto: aquella devolvia
# la energia de bordes a base de destruir poro y pelo de barba. Esta es una
# ganancia lineal de luminancia, y se comprobo que la deriva interna de la toma
# no se mueve (bordes +1.8% antes, +2.3% despues).
luminancia_mediana() {  # <video> -> YAVG mediana, o vacio si no se puede medir
  ffmpeg -nostdin -v info -i "$1" -an \
    -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 \
  | sed -n 's/.*YAVG=\([0-9.]*\).*/\1/p' \
  | sort -n | awk '{v[NR]=$1} END{ if (NR) print v[int((NR+1)/2)] }'
}

# Ganancia para llevar <video> al nivel de <referencia>. Acotada a [0.5, 2.0]:
# una medicion loca no puede arrasar una toma buena, solo dejarla a medio
# corregir. Devuelve 1 (no tocar) si algo no se puede medir.
ganancia_nivel() {  # <video> <referencia>
  local y r g
  y=$(luminancia_mediana "$1"); r=$(luminancia_mediana "$2")
  case "$y" in ''|0|0.0|0.00) echo 1; return 0 ;; esac
  case "$r" in ''|0|0.0|0.00) echo 1; return 0 ;; esac
  g=$(awk -v r="$r" -v y="$y" 'BEGIN{ g=r/y; if(g<0.5)g=0.5; if(g>2.0)g=2.0; printf "%.4f", g }')
  echo "$g"
}

# ── comprobacion de herramientas ───────────────────────────────────────────
# ffmpeg y ffprobe NO son opcionales: sin ellos no hay extraccion de anclas ni
# montaje. Se comprueba AL ARRANCAR y no al usarlos, porque el primer uso real
# ocurre despues de generar la toma 1: ~23 minutos de GPU tirados para morir
# con "ffmpeg: command not found". Medido — paso de verdad el 2026-08-29,
# cuando los binarios vivian en un venv del scratchpad de la sesion y este se
# quedo fuera del PATH del proceso de produccion.
exigir_herramientas() {
  local faltan=()
  local h
  for h in "$@"; do command -v "$h" >/dev/null 2>&1 || faltan+=("$h")
  done
  [ ${#faltan[@]} -eq 0 ] && return 0
  {
    echo "FALTAN HERRAMIENTAS: ${faltan[*]}"
    echo "  PATH=$PATH"
    echo "  Instalalas o ponlas en el PATH antes de producir. Sin ellas la"
    echo "  generacion correria igual y moriria al extraer anclas o al montar."
  } >&2
  return 1
}

ff()  { ffmpeg -nostdin "$@"; }
ffp() { ffprobe "$@"; }

# ── sd-cli: una sola definición de la llamada de generación ────────────────
# Tres horas cubren las tomas largas que ya usa produccion/anclado. Se puede
# acortar por trabajo; un valor invalido falla cerrado y nunca lanza sd-cli.
SD_VID_GEN_ESPERA=${SD_VID_GEN_ESPERA:-10800}

# Runner privado: sd_vid_gen es la unica entrada publica y pone el cerrojo.
_sd_vid_gen_ejecutar() {
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

# Uso:  sd_vid_gen "<prompt>" "<salida.mp4>" [args extra: -s N, --init-img f...]
# OJO: sd-cli escribe en "<salida>.avi", no en "<salida>". Usar sd_salida().
sd_vid_gen() {
  local PROMPT=$1 OUT=$2; shift 2
  con_cerrojo "$SD_VID_GEN_ESPERA" _sd_vid_gen_ejecutar "$PROMPT" "$OUT" "$@"
}

# Ruta real del fichero que deja sd-cli cuando le pides "-o algo.mp4".
sd_salida() { echo "$1.avi"; }

# ── sd-cli: escalado ───────────────────────────────────────────────────────
# Uso:  sd_upscale <entrada.png> <salida.png> <backend: CUDA0|CUDA1> [tile]
# El escalado participa del mismo contrato global que vid_gen. Aunque use otra
# GPU, ffmpeg/modelos compiten por la RAM del mismo cgroup.
SD_UPSCALE_ESPERA=${SD_UPSCALE_ESPERA:-10800}
_sd_upscale_ejecutar() {
  "$SDCLI" -M upscale -i "$1" \
    --upscale-model "$UPSCALER" \
    --upscale-tile-size "${4:-512}" --backend "$3" \
    -o "$2" < /dev/null
}

sd_upscale() {
  con_cerrojo "$SD_UPSCALE_ESPERA" _sd_upscale_ejecutar "$@"
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
#   reservar_generacion_completa   -> retiene el recurso hasta salir del script
#   con_cerrojo <segundos_de_espera> <comando...>
reservar_generacion_completa() {
  local lock=${CERROJO:-${TMPDIR:-/tmp}/h3-generacion.lock}
  local proceso=${BASHPID:-$$}
  local fd

  if [ -n "${CERROJO_OBRAS:-}" ] && [ "$CERROJO_OBRAS" != "$lock" ]; then
    echo "cerrojo: CERROJO_OBRAS no puede diferir de CERROJO" >&2
    return 2
  fi
  if [ "${_H3_CERROJO_BASHPID:-}" = "$proceso" ] \
      && [ "${_H3_CERROJO_RUTA:-}" = "$lock" ]; then
    return 0
  fi
  command -v flock >/dev/null 2>&1 || {
    echo "cerrojo: falta el comando flock; no reservo el recurso" >&2
    return 1
  }
  if ! exec {fd}>"$lock"; then
    echo "cerrojo: no puedo abrir $lock" >&2
    return 1
  fi
  if ! flock -n "$fd"; then
    echo "cerrojo: ya hay otra obra o generacion activa; no solapo el trabajo" >&2
    exec {fd}>&- || true
    return 1
  fi

  # Globales a proposito: el descriptor queda abierto hasta que termine este
  # Bash y con_cerrojo reconoce las llamadas anidadas del mismo BASHPID.
  H3_CERROJO_FD=$fd
  CERROJO=$lock
  CERROJO_OBRAS=$lock
  _H3_CERROJO_BASHPID=$proceso
  _H3_CERROJO_RUTA=$lock
}

con_cerrojo() {
  local espera=${1:-}
  [ "$#" -gt 0 ] && shift
  local lock=${CERROJO:-${TMPDIR:-/tmp}/h3-generacion.lock}
  local proceso=${BASHPID:-$$}
  local fd lock_rc rc

  case "$espera" in
    ''|*[!0-9]*)
      echo "cerrojo: el tiempo de espera debe ser un entero no negativo (recibido: '$espera')" >&2
      return 2
      ;;
  esac
  [ "$#" -gt 0 ] || { echo "cerrojo: falta el comando" >&2; return 2; }

  # Bash da alcance dinamico a los local: una llamada anidada en ESTE proceso
  # ve estas marcas y no intenta adquirir dos veces el mismo flock. BASHPID
  # evita que un subshell heredado confunda el cerrojo del padre con el suyo.
  if [ "${_H3_CERROJO_BASHPID:-}" = "$proceso" ] &&
     [ "${_H3_CERROJO_RUTA:-}" = "$lock" ]; then
    if "$@"; then rc=0; else rc=$?; fi
    return "$rc"
  fi

  command -v flock >/dev/null 2>&1 || {
    echo "cerrojo: falta el comando flock; no lanzo la generacion" >&2
    return 1
  }

  if ! exec {fd}>"$lock"; then
    echo "cerrojo: no puedo abrir $lock" >&2
    return 1
  fi
  if flock -n "$fd"; then
    lock_rc=0
  else
    lock_rc=$?
  fi
  if [ "$lock_rc" -ne 0 ]; then
    echo "cerrojo: hay otra generacion en curso, espero mi turno" >&2
    if flock -w "$espera" "$fd"; then
      lock_rc=0
    else
      lock_rc=$?
    fi
    if [ "$lock_rc" -ne 0 ]; then
      echo "cerrojo: otra generacion lleva mas de ${espera}s ocupando el turno" >&2
      exec {fd}>&- || true
      return 1
    fi
  fi

  local _H3_CERROJO_BASHPID=$proceso
  local _H3_CERROJO_RUTA=$lock
  if "$@"; then rc=0; else rc=$?; fi
  flock -u "$fd" || true
  exec {fd}>&- || true
  return "$rc"
}

# ── Guardia de memoria ─────────────────────────────────────────────────────
# El contenedor tiene 24 GB y una generacion usa casi todos. Medir mientras
# genera (evaluar2 lanza decenas de ffmpeg) se lleva el resto y el OOM killer
# mata la generacion. Paso de verdad: la toma 3 murio en el paso 16/20 tras 18
# minutos de GPU porque yo estaba midiendo las tomas 1 y 2 en paralelo.
#
#   ram_libre_mb            -> MiB disponibles dentro del cgroup
#   hay_generacion_en_curso -> 0 si hay una generacion viva
# MiB REALMENTE disponibles en el cgroup.
#
# La version anterior hacia (memory.max - memory.current), y memory.current
# INCLUYE la cache de pagina, que el kernel libera en cuanto hace falta. Con la
# cache llena esta cuenta daba "2 MiB libres" mientras la generacion corria
# perfectamente con 11.6 GB de cache reclamable. Y sobre esa cifra enga~nosa se
# calibraron los umbrales de espera: por eso un umbral de 19500 era inalcanzable
# y dejaba la maquina parada esperando una condicion imposible.
#
# Ahora se descuenta inactive_file, que es la parte de la cache que el kernel
# puede tirar sin pensarlo. Lo mapeado y activo (active_file) NO se descuenta,
# porque sd-cli mantiene mapeados los GGUF del modelo y esas paginas no se van a
# liberar mientras genere.
ram_libre_mb() {
  local max cur inact
  max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  [ "$max" = max ] && max=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
  cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
  # NO se descuenta inactive_file. Es tentador —la cache es reclamable y sin
  # descontarla esta cuenta reporta "2 MiB libres" con la generacion corriendo
  # tan campante— pero al descontarla la cifra SUBE, y todos los umbrales de
  # espera estan calibrados contra la cuenta pesimista. Se probo el 2026-08-29:
  # con la version "correcta" el guardian quedo mas PERMISIVO de lo que era y
  # volvieron los OOM. La cuenta pesimista funciona como margen de seguridad.
  # Si algun dia se cambia, hay que recalibrar los umbrales A LA VEZ.
  echo $(( (max - cur) / 1048576 ))
}

hay_generacion_en_curso() {
  local lock=${CERROJO:-${TMPDIR:-/tmp}/h3-generacion.lock}
  local fd
  [ -e "$lock" ] || return 1
  command -v flock >/dev/null 2>&1 || return 1
  exec {fd}>"$lock" 2>/dev/null || return 1
  if flock -n "$fd"; then
    flock -u "$fd" || true
    exec {fd}>&- || true
    return 1
  fi
  exec {fd}>&- || true
  return 0
}

# ── El resto de la libreria ────────────────────────────────────────────────
# comun.sh es el contrato central del proyecto, pero no lo era del todo: cada
# script tenia que acordarse de sourear ADEMAS compat.sh, prompt.sh y vram.sh.
# Olvidarse no da un error al cargar, da un "command not found" a mitad de
# trabajo. Paso dos veces el mismo dia: seis scripts sin compat.sh morian al
# tocar la GPU, y la sonda de resolucion espero HORA Y MEDIA a que se liberase
# la tarjeta para caerse en la primera linea con "construir_prompt: command not
# found". Sourear comun.sh basta.
if [ -z "${H3_LIB_LISTA:-}" ]; then
  H3_LIB_LISTA=1
  _libdir=$(dirname "${BASH_SOURCE[0]}")
  [ -f "$_libdir/prompt.sh" ] && . "$_libdir/prompt.sh"
  [ -f "$_libdir/vram.sh" ]   && . "$_libdir/vram.sh"
  unset _libdir
fi
