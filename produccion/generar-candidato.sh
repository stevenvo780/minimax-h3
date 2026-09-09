#!/bin/bash
# Genera una unica toma en un banco content-addressed sin modificar la obra base.
#
# Uso minimo:
#   generar-candidato.sh --plan produccion/obra/mi-obra/plan.json \
#     --toma 1 --modelo modelos/diffusion_models/modelo.gguf
#
# Los parametros omitidos se heredan de la toma efectiva del plan. --dry-run
# construye y muestra la solicitud exacta, incluidos todos sus SHA, sin GPU.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$MD/lib/compat.sh"
. "$MD/lib/vram.sh"
. "$MD/lib/prompt.sh"

ESTADO_OBRA=$MD/lib/estado_obra.py
CANDIDATOS=$MD/harness/candidatos.py
BANCO=${BANCO_CANDIDATOS:-$MD/produccion/candidatos}
PLAN=""
TOMA=""
MODELO=${MODELO:-}
ANCLA=""
W_OPT=""
H_OPT=""
FRAMES_OPT=""
FPS_OPT=""
STEPS_OPT=""
SEED_OPT=""
MAX_VRAM_OPT=""
DRY_RUN=0
ARTIFACT_VERSION=${CANDIDATE_ARTIFACT_VERSION:-h3-candidate-video/v1}

uso() {
  cat <<'EOF'
Uso: generar-candidato.sh --plan PLAN --toma N --modelo MODELO [opciones]

Opciones:
  --width N --height N      resolucion (por defecto, la del plan)
  --size WxH                atajo para la resolucion
  --frames N --fps N        longitud y frecuencia (por defecto, las del plan)
  --steps N --seed N        receta de muestreo (por defecto, la del plan)
  --anchor PNG              ancla opcional; se identifica por SHA-256
  --max-vram cuda0=N        techo explicito y reproducible para sd-cli
  --bank DIR                raiz del banco (no la obra base)
  --dry-run                 muestra la solicitud exacta sin adquirir GPU
  -h, --help                esta ayuda

La salida real queda en BANCO/<obra>/tNN/<huella>/video.avi. Un directorio de
candidato existente nunca se reemplaza: solo se reutiliza si supera todas las
comprobaciones de integridad y video.
EOF
}

valor() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "falta valor para $1" >&2; exit 2; }
}

ejecutar_hook_prueba() {
  local fase=$1 hook=${CANDIDATE_TEST_HOOK:-}
  [ -n "$hook" ] || return 0
  [ "${CANDIDATE_TEST_MODE:-0}" = 1 ] || {
    echo "CANDIDATE_TEST_HOOK solo se permite con CANDIDATE_TEST_MODE=1" >&2
    return 1
  }
  [ -n "$ANCLA" ] || { echo "el hook de ancla requiere --anchor" >&2; return 1; }
  case "$hook" in /*) ;; *) echo "el hook de prueba debe ser una ruta absoluta" >&2; return 1 ;; esac
  [ -f "$hook" ] && [ ! -L "$hook" ] && [ -x "$hook" ] || {
    echo "hook de prueba invalido o symlink: $hook" >&2
    return 1
  }
  "$hook" "$fase" "$ANCLA" "$ANCLA_STAGED" || {
    echo "fallo el hook de prueba en fase $fase" >&2
    return 1
  }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) valor "$@"; PLAN=$2; shift 2 ;;
    --toma|--take) valor "$@"; TOMA=$2; shift 2 ;;
    --modelo|--model) valor "$@"; MODELO=$2; shift 2 ;;
    --anchor|--ancla) valor "$@"; ANCLA=$2; shift 2 ;;
    --width) valor "$@"; W_OPT=$2; shift 2 ;;
    --height) valor "$@"; H_OPT=$2; shift 2 ;;
    --size)
      valor "$@"
      case "$2" in
        *x*) W_OPT=${2%%x*}; H_OPT=${2#*x} ;;
        *) echo "--size espera WxH (recibido: '$2')" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --frames) valor "$@"; FRAMES_OPT=$2; shift 2 ;;
    --fps) valor "$@"; FPS_OPT=$2; shift 2 ;;
    --steps) valor "$@"; STEPS_OPT=$2; shift 2 ;;
    --seed) valor "$@"; SEED_OPT=$2; shift 2 ;;
    --max-vram) valor "$@"; MAX_VRAM_OPT=$2; shift 2 ;;
    --bank|--banco) valor "$@"; BANCO=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) uso; exit 0 ;;
    *) echo "opcion desconocida: $1" >&2; uso >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ] || { echo "falta --plan" >&2; exit 2; }
[ -n "$TOMA" ] || { echo "falta --toma" >&2; exit 2; }
[ -n "$MODELO" ] || { echo "falta --modelo" >&2; exit 2; }
case "$TOMA" in ''|*[!0-9]*|0) echo "--toma debe ser un entero positivo" >&2; exit 2 ;; esac
[ -f "$PLAN" ] && [ ! -L "$PLAN" ] || { echo "plan invalido o symlink: $PLAN" >&2; exit 2; }
[ -f "$MODELO" ] && [ ! -L "$MODELO" ] || { echo "modelo invalido o symlink: $MODELO" >&2; exit 2; }
if [ -n "$ANCLA" ]; then
  [ -f "$ANCLA" ] && [ ! -L "$ANCLA" ] || { echo "ancla invalida o symlink: $ANCLA" >&2; exit 2; }
fi
[ -f "$ESTADO_OBRA" ] && [ -f "$CANDIDATOS" ] || {
  echo "faltan herramientas de estado/candidatos" >&2
  exit 1
}
exigir_herramientas python3 sha256sum flock ffmpeg ffprobe || exit 1

TMP_TRABAJO=$(mktemp -d "${TMPDIR:-/tmp}/h3-candidato.XXXXXX") || exit 1
STAGE=""
ANCLA_STAGED=""
ANCLA_RECORD=""
limpiar() {
  local rc=$?
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    case "$STAGE" in "$BANCO"/*/t??/.*.tmp.*) rm -rf -- "$STAGE" ;; esac
  fi
  case "$TMP_TRABAJO" in "${TMPDIR:-/tmp}"/h3-candidato.*) rm -rf -- "$TMP_TRABAJO" ;; esac
  exit "$rc"
}
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TAKE_FIELDS=$TMP_TRABAJO/take-fields.bin
if ! python3 "$CANDIDATOS" extraer --plan "$PLAN" --take "$TOMA" > "$TAKE_FIELDS"; then
  exit 2
fi
mapfile -d '' -t CAMPOS < "$TAKE_FIELDS"
[ "${#CAMPOS[@]}" -eq 12 ] || { echo "el plan devolvio una toma incompleta" >&2; exit 1; }
TIPO=${CAMPOS[0]}
ESCENA=${CAMPOS[1]}
CONTENIDO=${CAMPOS[2]}
AMBIENTE=${CAMPOS[3]}
MUSICA=${CAMPOS[4]}
W=${W_OPT:-${CAMPOS[5]}}
H=${H_OPT:-${CAMPOS[6]}}
FRAMES=${FRAMES_OPT:-${CAMPOS[7]}}
FPS=${FPS_OPT:-${CAMPOS[8]}}
STEPS=${STEPS_OPT:-${CAMPOS[9]}}
SEED=${SEED_OPT:-${CAMPOS[10]}}
NOMBRE_OBRA=${CAMPOS[11]}

for par in "width:$W" "height:$H" "frames:$FRAMES" "fps:$FPS" "steps:$STEPS"; do
  etiqueta=${par%%:*}; numero=${par#*:}
  case "$numero" in ''|*[!0-9]*|0) echo "$etiqueta debe ser un entero positivo" >&2; exit 2 ;; esac
done
case "$SEED" in ''|*[!0-9]*) echo "seed debe ser un entero no negativo" >&2; exit 2 ;; esac
W=$((10#$W)); H=$((10#$H)); FRAMES=$((10#$FRAMES)); FPS=$((10#$FPS)); STEPS=$((10#$STEPS))
SEED=$((10#$SEED))
[ $((W % 8)) -eq 0 ] && [ $((H % 8)) -eq 0 ] || {
  echo "width y height deben ser multiplos de 8" >&2
  exit 2
}
[ "$FRAMES" -ge 5 ] && [ $(((FRAMES - 5) % 17)) -eq 0 ] || {
  echo "frames debe cumplir 17k+5" >&2
  exit 2
}
tipo_valido "$TIPO" || { echo "tipo de toma invalido: $TIPO" >&2; exit 2; }
case "$MAX_VRAM_OPT" in
  '') ;;
  cuda0=[1-9]|cuda0=[1-9][0-9]) ;;
  *) echo "--max-vram debe tener forma cuda0=N" >&2; exit 2 ;;
esac
case "$ARTIFACT_VERSION" in
  ''|*[!A-Za-z0-9._/-]*) echo "version de artefacto invalida" >&2; exit 2 ;;
esac

PROMPT_FILE=$TMP_TRABAJO/prompt.txt
construir_prompt "$TIPO" "$ESCENA" "$CONTENIDO" "$AMBIENTE" "$MUSICA" > "$PROMPT_FILE" \
  || { echo "no pude construir el prompt" >&2; exit 1; }

mkdir -p "$BANCO" || exit 1
[ ! -L "$BANCO" ] || { echo "el banco no puede ser un symlink: $BANCO" >&2; exit 2; }
BANCO=$(cd "$BANCO" && pwd -P) || exit 1
RECETA=$TMP_TRABAJO/recipe.json
REQUEST=$TMP_TRABAJO/request.json

# El techo de VRAM forma parte de la receta. Quien necesite repetir bytes entre
# maquinas debe pasarlo explicitamente; si se omite, usamos el presupuesto vivo.
if [ -n "$MAX_VRAM_OPT" ]; then
  MAXVRAM_CANDIDATO=$MAX_VRAM_OPT
else
  MAXVRAM_CANDIDATO=$(vram_arg_trabajo 0 "$FRAMES" "$W" "$H" "$([ -n "$ANCLA" ] && echo 1 || echo 0)")
fi
PARAMS_CANDIDATO=${PARAMS_BK:-diffusion=cpu,te=disk}
BACKEND_CANDIDATO=${BACKEND_CANDIDATO:-diffusion=CUDA0,te=cpu,vae=CUDA0}

if ! python3 "$ESTADO_OBRA" recipe-fingerprint \
  --cache "$BANCO/.cache/recipe-hashes.json" \
  --manifest "$RECETA" \
  --component "diffusion=$MODELO" \
  --component "vae=$MODELO_VAE" \
  --component "audio_vae=$MODELO_AVAE" \
  --component "llm=$MODELO_LLM" \
  --component "sd_cli=$SDCLI" \
  --component "runner=$MD/produccion/generar-candidato.sh" \
  --component "prompt_engine=$MD/lib/prompt.sh" \
  --component "vram_policy=$MD/lib/vram.sh" \
  --component "state_tool=$ESTADO_OBRA" \
  --setting 'recipe=candidato-v1' \
  --setting "artifact_version=$ARTIFACT_VERSION" \
  --setting "width=$W" --setting "height=$H" \
  --setting "frames=$FRAMES" --setting "fps=$FPS" \
  --setting "steps=$STEPS" --setting "seed=$SEED" \
  --setting "cfg=${CFG:-1.0}" \
  --setting "backend=$BACKEND_CANDIDATO" \
  --setting "params_backend=$PARAMS_CANDIDATO" \
  --setting "max_vram=$MAXVRAM_CANDIDATO" \
  --setting 'rng=cpu' --setting 'diffusion_fa=on' --setting 'stream_layers=on' \
  >/dev/null; then
  echo "no pude identificar la receta completa" >&2
  exit 1
fi

IDENT_ARGS=(
  identificar --plan "$PLAN" --take "$TOMA" --recipe "$RECETA"
  --model "$MODELO" --prompt-file "$PROMPT_FILE"
  --width "$W" --height "$H" --frames "$FRAMES" --fps "$FPS"
  --steps "$STEPS" --seed "$SEED" --artifact-version "$ARTIFACT_VERSION"
  --bank "$BANCO" --output "$REQUEST"
)
[ -z "$ANCLA" ] || IDENT_ARGS+=(--anchor "$ANCLA")
python3 "$CANDIDATOS" "${IDENT_ARGS[@]}" || exit 1

FP=$(python3 - "$REQUEST" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["fingerprint"])
PY
) || exit 1
CANDIDATE=$(python3 - "$REQUEST" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["candidate_dir"])
PY
) || exit 1
[ -n "$FP" ] && [ -n "$CANDIDATE" ] || { echo "solicitud incompleta" >&2; exit 1; }

if [ "$DRY_RUN" = 1 ]; then
  python3 - "$REQUEST" <<'PY'
import json,sys
request=json.load(open(sys.argv[1],encoding="utf-8"))
request["dry_run"] = True
print(json.dumps(request,ensure_ascii=False,indent=2,sort_keys=True))
PY
  exit 0
fi

PARENT=$(dirname "$CANDIDATE")
mkdir -p "$PARENT" "$BANCO/.locks" || exit 1
exec 8>"$BANCO/.locks/$FP.lock" || exit 1
flock 8 || exit 1
if [ -e "$CANDIDATE" ] || [ -L "$CANDIDATE" ]; then
  if python3 "$CANDIDATOS" verificar "$CANDIDATE" --technical >/dev/null; then
    echo "candidato verificado, se reutiliza: $CANDIDATE"
    exit 0
  fi
  echo "el destino existe pero no es un candidato valido; no se reemplaza: $CANDIDATE" >&2
  exit 1
fi

STAGE=$(mktemp -d "$PARENT/.$FP.tmp.XXXXXX") || exit 1
cp -- "$RECETA" "$STAGE/recipe.json" || exit 1
cp -- "$PROMPT_FILE" "$STAGE/prompt.txt" || exit 1
ejecutar_hook_prueba despues-identificar || exit 1
if [ -n "$ANCLA" ]; then
  ANCLA_STAGED=$STAGE/anchor-input.png
  ANCLA_RECORD=$TMP_TRABAJO/staged-anchor.json
  if ! python3 "$CANDIDATOS" preparar-ancla \
    --request "$REQUEST" --source "$ANCLA" \
    --output "$ANCLA_STAGED" --record "$ANCLA_RECORD"; then
    echo "el ancla cambio antes de preparar su copia inmutable; aborto" >&2
    exit 1
  fi
fi
LOG=$STAGE/generation.log
SOLICITUD_SD=$STAGE/candidate.mp4
VIDEO=$(sd_salida "$SOLICITUD_SD")

MODELO_DIFF=$MODELO
MAXVRAM=$MAXVRAM_CANDIDATO
PARAMS_BACKEND=$PARAMS_CANDIDATO
BACKEND=$BACKEND_CANDIDATO
EXTRA=(-s "$SEED")
[ -z "$ANCLA_STAGED" ] || EXTRA+=(--init-img "$ANCLA_STAGED")

echo "═══ CANDIDATO ${FP:0:12} · toma $TOMA [$TIPO] ═══"
echo "    ${W}x${H} · ${FRAMES}f @ ${FPS} · ${STEPS} pasos · seed $SEED"
echo "    modelo $(basename "$MODELO") · $MAXVRAM_CANDIDATO${ANCLA:+ · anclado}"
if [ "${CANDIDATE_SKIP_RESOURCE_WAIT:-0}" != 1 ]; then
  vram_esperar 0 5000 900 || echo "  aviso: margen de VRAM justo; el cerrojo evitara solapamientos" >&2
fi
if ! python3 "$ESTADO_OBRA" verify-recipe "$RECETA" >> "$LOG" 2>&1; then
  echo "la receta cambio antes de generar; aborto" >&2
  exit 1
fi
ejecutar_hook_prueba antes-gpu || exit 1
if [ -n "$ANCLA" ] && ! python3 "$CANDIDATOS" verificar-ancla \
  --request "$REQUEST" --source "$ANCLA" \
  --staged "$ANCLA_STAGED" --record "$ANCLA_RECORD"; then
  echo "el ancla fuente o su copia staged cambio antes de usar GPU; aborto" >&2
  exit 1
fi
sd_vid_gen "$(<"$PROMPT_FILE")" "$SOLICITUD_SD" "${EXTRA[@]}" >> "$LOG" 2>&1
rc=$?
if [ -n "$ANCLA" ] && ! python3 "$CANDIDATOS" verificar-ancla \
  --request "$REQUEST" --source "$ANCLA" \
  --staged "$ANCLA_STAGED" --record "$ANCLA_RECORD"; then
  echo "el ancla fuente o su copia staged cambio durante la generacion; no se publica" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "sd-cli fallo (rc=$rc); ultimas lineas:" >&2
  tr '\r' '\n' < "$LOG" | tail -8 >&2
  exit "$rc"
fi
[ -f "$VIDEO" ] && [ ! -L "$VIDEO" ] || {
  echo "sd-cli no produjo un AVI regular: $VIDEO" >&2
  exit 1
}
if [ -n "$ANCLA_STAGED" ]; then
  rm -- "$ANCLA_STAGED" || exit 1
  ANCLA_STAGED=""
fi

TECH=$STAGE/technical.json
if ! python3 "$ESTADO_OBRA" check-video "$VIDEO" \
  --width "$W" --height "$H" --frames "$FRAMES" --fps "$FPS" \
  --require-audio --decode --json > "$TECH"; then
  echo "el candidato generado no supera la validacion tecnica" >&2
  exit 1
fi
mv -n -- "$VIDEO" "$STAGE/video.avi" || exit 1
[ ! -e "$VIDEO" ] && [ -f "$STAGE/video.avi" ] || exit 1
rm -f -- "$SOLICITUD_SD"
python3 "$ESTADO_OBRA" write-fingerprint "$STAGE/video.fingerprint.json" "$FP" \
  --artifact "$STAGE/video.avi" || exit 1
python3 "$CANDIDATOS" finalizar \
  --request "$REQUEST" --video "$STAGE/video.avi" \
  --artifact-sidecar "$STAGE/video.fingerprint.json" --technical-json "$TECH" \
  --recipe "$STAGE/recipe.json" --prompt-file "$STAGE/prompt.txt" \
  --output "$STAGE/manifest.json" || exit 1
rm -f -- "$TECH"

# mkdir es el commit de reserva. Los datos se mueven primero y manifest.json al
# final: un crash nunca deja algo que verificar pueda confundir con completo.
mkdir "$CANDIDATE" || { echo "el candidato aparecio durante la publicacion" >&2; exit 1; }
for archivo in recipe.json prompt.txt generation.log video.avi video.fingerprint.json; do
  mv -n -- "$STAGE/$archivo" "$CANDIDATE/$archivo" || exit 1
done
mv -n -- "$STAGE/manifest.json" "$CANDIDATE/manifest.json" || exit 1
rmdir "$STAGE" || exit 1
STAGE=""
python3 "$CANDIDATOS" verificar "$CANDIDATE" --technical >/dev/null || exit 1
echo "candidato publicado: $CANDIDATE"
