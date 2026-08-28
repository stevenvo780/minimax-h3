#!/bin/bash
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
set -u
nombre="params-defecto"
fallo() { echo "FALLA $nombre: $1"; exit 1; }

RAIZ="${RAIZ:?falta RAIZ}"

WD=$(mktemp -d /tmp/params-defecto-check.XXXXXX) || fallo "no se pudo crear tmpdir"
trap 'rm -rf "$WD"' EXIT

COMUN="$RAIZ/lib/comun.sh"
[ -f "$COMUN" ] || fallo "no existe $COMUN (params_defecto vive ahi: sin el, cada script vuelve a fijar W/H/FRAMES/STEPS por su cuenta)"

# script -> "W H FRAMES STEPS" propios (sin entorno)
SCRIPTS="h3.sh generar-1080p.sh encadenar.sh produccion/producir.sh proyecto-minuto/generar.sh"
esperado_de() {
  case "$1" in
    "h3.sh")                      echo "864 480 56 20" ;;
    "generar-1080p.sh")           echo "512 288 56 20" ;;
    "encadenar.sh")               echo "1376 768 124 20" ;;
    "produccion/producir.sh")     echo "1376 768 107 20" ;;
    "proyecto-minuto/generar.sh") echo "1376 768 107 20" ;;
    *) return 1 ;;
  esac
}

# ═══ PARTE 1 — estatica: cada script llama params_defecto con SUS numeros,
#     DESPUES de sourcear comun.sh, y no vuelve a pisar W/H/FRAMES/STEPS.
for rel in $SCRIPTS; do
  f="$RAIZ/$rel"
  [ -f "$f" ] || fallo "no existe $f"
  esp=$(esperado_de "$rel")

  pd=$(grep -n -m1 -E '^[[:space:]]*params_defecto[[:space:]]' "$f") \
    || fallo "$rel ya no llama a params_defecto (si fija W/H/FRAMES/STEPS a mano tras sourcear comun.sh, el \${VAR:-} NO se dispara y corre a 1376x768x107)"
  pd_ln=${pd%%:*}
  vals=$(printf '%s' "${pd#*:}" | sed -E 's/^[[:space:]]*params_defecto[[:space:]]+//; s/[[:space:]]+$//')
  [ "$vals" = "$esp" ] || fallo "$rel llama params_defecto con '$vals', se esperaba '$esp'"

  src=$(grep -n -m1 -E '^[[:space:]]*(\.|source)[[:space:]].*lib/comun\.sh' "$f") \
    || fallo "$rel no sourcea lib/comun.sh"
  src_ln=${src%%:*}
  [ "$src_ln" -lt "$pd_ln" ] || fallo "$rel llama params_defecto en la linea $pd_ln pero sourcea comun.sh en la $src_ln: params_defecto aun no existe ahi, la llamada no hace nada y el script corre con el default global"

  pisa=$(awk -v n="$pd_ln" 'NR>n && /^[[:space:]]*(W|H|FRAMES|STEPS)=/ {print NR": "$0}' "$f")
  [ -z "$pisa" ] || fallo "$rel vuelve a asignar W/H/FRAMES/STEPS despues de params_defecto (linea $pd_ln), pisando el entorno: $pisa"
done

# ═══ PARTE 2 — comun.sh: params_defecto respeta el entorno y rescata _*_ENV
for caso in "sin-entorno::864 480 56 20" "W=1280::1280 480 56 20" "FRAMES=90::864 480 90 20"; do
  ov=${caso%%::*}; esp=${caso#*::}
  if [ "$ov" = "sin-entorno" ]; then set -- ; else set -- "$ov"; fi
  got=$(env -u W -u H -u FRAMES -u STEPS -u OUT -u MD "$@" bash -c '
    . "$1" || exit 9
    params_defecto 864 480 56 20
    echo "$W $H $FRAMES $STEPS"' _ "$COMUN" 2>&1) \
    || fallo "comun.sh ($ov): fallo al sourcear/llamar params_defecto: $got"
  [ "$got" = "$esp" ] || fallo "comun.sh [entorno: $ov]: params_defecto 864 480 56 20 dio '$got', se esperaba '$esp' (si dio '1376 768 107 20' el default global de comun.sh pisa al del script; si el entorno no gano, params_defecto perdio el rescate _W_ENV/_H_ENV/_FRAMES_ENV/_STEPS_ENV)"
done

# ═══ PARTE 3 — extremo a extremo con los 5 scripts REALES y un sd-cli falso.
#     comun.sh respeta MD del entorno a proposito: apuntamos MD a una raiz
#     de mentira en /tmp, asi nada toca el repo.
STUB="$WD/sd-cli"
cat > "$STUB" <<'EOSTUB'
#!/bin/bash
W=""; H=""; FRAMES=""; STEPS=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -W) W=$2; shift 2 ;;
    -H) H=$2; shift 2 ;;
    --video-frames) FRAMES=$2; shift 2 ;;
    --steps) STEPS=$2; shift 2 ;;
    -o) OUT=$2; shift 2 ;;
    --diffusion-fa|--stream-layers) shift 1 ;;
    -M|--diffusion-model|--vae|--audio-vae|--llm|-p|--cfg-scale|--fps|--backend|--params-backend|--max-vram|--rng|--init-img|-s|--upscale-model|--upscale-tile-size|-i)
      shift 2 ;;
    *) shift 1 ;;
  esac
done
[ -n "${STUB_LOG:-}" ] || { echo "sd-cli falso: sin STUB_LOG" >&2; exit 1; }
[ -n "$OUT" ] || { echo "sd-cli falso: sin -o" >&2; exit 1; }
echo "W=$W H=$H FRAMES=$FRAMES STEPS=$STEPS" >> "$STUB_LOG"
: > "${OUT}.avi"
EOSTUB
chmod +x "$STUB" || fallo "no se pudo dar permisos al stub"

GUION="$WD/humo.guion"
printf '%s\n' '@ESCENA escena de humo' '@AMBIENTE ambiente de humo' '@MUSICA musica de humo' 'HABLA|linea de humo|inicio|' > "$GUION"

n=0
correr() {   # $1=rel  $2=etiqueta  $3=esperado  $4...=asignaciones de entorno
  local rel=$1 etiq=$2 esp=$3; shift 3
  n=$((n+1))
  local ROOT="$WD/md$n" LOG="$WD/log$n"
  mkdir -p "$ROOT/bin" "$ROOT/proyecto-minuto/prompts" "$ROOT/proyecto-minuto/shots" \
           "$ROOT/produccion" "$ROOT/dest" || return 1
  cp "$STUB" "$ROOT/bin/sd-cli" || return 1
  echo "prompt de humo" > "$ROOT/proyecto-minuto/prompts/s01.txt"
  local i; for i in 02 03 04 05 06 07 08 09 10 11 12 13 14; do : > "$ROOT/proyecto-minuto/shots/s$i.avi"; done
  : > "$LOG"

  # rc ignorado a proposito: sin ffmpeg estos scripts mueren DESPUES de llamar
  # a sd-cli. Lo que se juzga es con que parametros lo llamaron.
  env -u W -u H -u FRAMES -u STEPS -u OUT -u IMG -u NAME -u SEED -u FPS -u CFG \
      -u BACKEND -u PARAMS_BACKEND -u MAXVRAM \
      MD="$ROOT" DEST="$ROOT/dest" STUB_LOG="$LOG" SEGS=1 "$@" \
      bash "$RAIZ/$rel" $ARGS > "$WD/out$n" 2>&1

  local got; got=$(head -n1 "$LOG" 2>/dev/null || true)
  [ -n "$got" ] || fallo "$rel [$etiq]: el script NUNCA llamo a sd-cli. Ultimas lineas: $(tail -5 "$WD/out$n" | tr '\n' ' ')"
  local espl="W=${esp%% *}"; set -- $esp
  espl="W=$1 H=$2 FRAMES=$3 STEPS=$4"
  [ "$got" = "$espl" ] || fallo "$rel [$etiq] invoco sd-cli con '$got', se esperaba '$espl'. Si salio 'W=1376 H=768 FRAMES=107 STEPS=20' es EL BUG (default global de comun.sh en vez del propio del script); si el entorno no se respeto, params_defecto perdio el rescate _W_ENV/_H_ENV/_FRAMES_ENV/_STEPS_ENV"
}

for rel in $SCRIPTS; do
  espA=$(esperado_de "$rel")
  set -- $espA; espB="1280 $2 $3 $4"     # W=1280 del entorno debe ganar
  case "$rel" in
    "produccion/producir.sh")     ARGS="$GUION humo" ;;
    "proyecto-minuto/generar.sh") ARGS="" ;;
    *)                            ARGS="prompt-de-humo" ;;
  esac
  correr "$rel" "sin entorno" "$espA"
  correr "$rel" "W=1280"      "$espB" W=1280
done

echo "PASA $nombre"
exit 0