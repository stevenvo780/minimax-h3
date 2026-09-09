#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRODUCIR ANCLADO — varias tomas largas, ninguna encadenada.
#
#  Uso: producir-anclado.sh <guion> <nombre> [frames] [W] [H] [pasos]
#
#  El guion lleva UNA linea HABLA por toma. La primera se genera limpia; de ella
#  se extraen frames PRISTINOS que sirven de ancla para las demas. Ninguna toma
#  usa como ancla el final de otra: asi no hay acumulacion.
#
#  POR QUE, medido:
#    - una toma sola no se degrada dentro del techo medido (hasta 345f a 736x416)
#    - encadenar si: 1 plano 95.0 · 2 89.0 · 3 87.7 · 4 68.7
#    - pero el ANCLA borra la deriva: en obra/existencialismo el salto de bordes
#      es -3% en un enlace normal y -16.2 / -15.5 / -17.3 % en cada ancla.
#    Luego: tomas lo mas largas que quepan (345 frames = 14.4 s) y ancladas.
#
#  Las anclas se toman REPARTIDAS por la primera toma, no todas del mismo sitio:
#  anclas distintas dan poses distintas y el corte no parece un salto atras.
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe flock python3 sha256sum || exit 1
. "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/prompt.sh"
PROD=$MD/produccion
CAL=$MD/calidad   # las herramientas de medida viven aparte
PLANIFICADOR=$MD/harness/planificar.py
ESTADO_OBRA=$MD/lib/estado_obra.py
SELECTOR_ANCLA=$CAL/seleccionar-ancla.py
ANCLA_PYTHON=$MD/.venv-calidad/bin/python

# Resuelve exactamente igual que seleccionar-ancla.py: primero el modelo
# fijado y, si no esta, el primer YuNet en orden lexicografico. Esta resolucion
# ocurre antes de calcular la receta para que el run_fingerprint describa el
# modelo que realmente se usara, no solo el video que resulte por casualidad.
resolver_modelo_yunet() {
  local carpeta=$MD/modelos/evaluacion
  local preferido=$carpeta/face_detection_yunet_2023mar.onnx
  if [ -f "$preferido" ]; then
    printf '%s\n' "$preferido"
    return 0
  fi
  local candidatos=("$carpeta"/face_detection_yunet*.onnx)
  [ -f "${candidatos[0]}" ] || {
    echo "falta el modelo YuNet en $carpeta; ejecuta calidad/preparar-modelos-evaluacion.sh" >&2
    return 1
  }
  printf '%s\n' "${candidatos[0]}"
}

validar_selector_neutral() {  # imprime la ruta del modelo efectivo
  [ -x "$ANCLA_PYTHON" ] || {
    echo "falta $ANCLA_PYTHON; ejecuta calidad/preparar-modelos-evaluacion.sh" >&2
    return 1
  }
  [ -f "$SELECTOR_ANCLA" ] || {
    echo "falta el selector de ancla neutral: $SELECTOR_ANCLA" >&2
    return 1
  }
  if ! "$ANCLA_PYTHON" -c \
      'import cv2,sys; sys.exit(0 if hasattr(cv2,"FaceDetectorYN") or hasattr(cv2,"FaceDetectorYN_create") else 1)' \
      >/dev/null 2>&1; then
    echo "falta el backend OpenCV FaceDetectorYN en .venv-calidad; no uso un instante temporal como fallback" >&2
    return 1
  fi
  resolver_modelo_yunet
}

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}
# 685f a 736x416 contradice el techo medido y era, sin embargo, el default.
# 345f es el maximo probado para esta resolucion (14.4 s por toma).
FRAMES=${3:-345}; W=${4:-736}; H=${5:-416}; PASOS=${6:-20}
ANCLA_NEUTRAL=${ANCLA_NEUTRAL:-0}
case "$ANCLA_NEUTRAL" in
  0|1) : ;;
  *) echo "ANCLA_NEUTRAL debe ser 0 o 1" >&2; exit 2 ;;
esac
case "$NOMBRE" in
  ''|.*|*[!A-Za-z0-9_-]*)
    echo "nombre de obra invalido: '$NOMBRE' (usa letras, numeros, _ y -)" >&2
    exit 2 ;;
esac
# ── Cuanta RAM hace falta ANTES de arrancar una toma ──────────────────────
# Estaba a ojo: 8000 MiB para arrancar y 10000 para reintentar. MEDIDO el
# 2026-08-29 muestreando memory.current cada 5 s durante una generacion, sd-cli
# llega a 14.2 GB de RSS. Los dos umbrales se quedaban MUY cortos, asi que el
# script daba luz verde con 13.4 GB libres —lo dijo su propio log: "toma 3: 13408
# MiB libres, reintento"— y el OOM killer lo mataba en el paso 7 de 20. Tres
# veces seguidas en la misma toma.
#
# Descartado por el camino, midiendo: NO era el presupuesto de VRAM (se bajo de
# cuda0=7 a 4 y murio igual) ni la cache de pagina (el desglose del cgroup dio
# anon 17.6 GB contra file 3.5 GB). Era arrancar sin sitio, sin mas.
#
# TERCERA correccion, y la que vale. Muestreando a 1 Hz sale un pico de 19.3 GB,
# y de ahi puse 19500... que NUNCA se alcanza: con la sesion del usuario y sus
# herramientas siempre hay 3-5 GB ocupados, asi que el script se quedaba
# esperando una condicion imposible y la maquina parecia parada. Steven lo vio
# antes que yo: "veo la PC quieta".
#
# El razonamiento tambien estaba mal: ese pico de 19.3 GB INCLUYE cache mapeada,
# que el kernel va reclamando segun sd-cli crece. Comparar un pico que incluye
# cache contra "RAM libre" es comparar cosas distintas.
#
# 12000 es alcanzable y sigue siendo generoso: las ~20 tomas que salieron bien
# arrancaron con el umbral viejo de 8000. No hace falta mas.
# Cuantas veces reintentar una toma que muere por OOM.
#
# Sube de 3 a 6 por una razon medida, no por insistir a ciegas: los pesos NO
# CABEN en el contenedor. El modelo podado ocupa 10.6 GB y el codificador de
# texto otros 17.0, o sea 27.6 GB de pesos en un cgroup de 24. Funciona solo
# porque estan mapeados desde disco y el kernel va expulsando paginas —el
# codificador no hace falta durante la difusion— y REVIENTA cuando el desalojo
# no llega a tiempo.
#
# Eso hace que el fallo sea probabilistico y dependa del ritmo de paginacion, no
# de la configuracion. Explica lo que parecia inexplicable: 16 tomas seguidas sin
# un fallo un dia, y fallos constantes al siguiente con los mismos parametros.
# Cinco ajustes distintos (umbral de RAM, tope de VRAM, descuento de VRAM,
# ram_libre_mb, menos fotogramas) no cambiaron nada porque ninguno tocaba la
# causa.
#
# Contra un fallo probabilistico la respuesta correcta es reintentar, no seguir
# afinando parametros. Cada reintento cuesta tiempo; perder la toma cuesta mas.
# Donde viven los parametros de cada modulo.
#
# NO PROBADO todavia contra el fallo real, y lo digo antes de que parezca un
# arreglo: 'te=disk' deja los 17 GB del codificador de texto en el FICHERO en vez
# de en RAM. Solo hace falta al principio, para condicionar el prompt; despues es
# peso muerto que compite con la difusion en un cgroup de 24 GB donde los pesos
# suman 27.6.
#
# Lo comprobado hasta ahora: una generacion corta con te=disk termina bien
# (rc=0, salida correcta). Lo que NO se ha comprobado: que baje la tasa de OOM en
# tomas ancladas de 345 fotogramas, que es donde falla. Se mide con las piezas
# que vienen.
#
# RESULTADO 2026-08-30, medido tras aplicarlo:
#     reintentos    10 en la cola antes  ->  0 desde te=disk
#     oom_kill      subiendo sin parar   ->  CONGELADO en 46
#     tomas         cinismo t2 cayo 6 veces -> 3 seguidas sin un fallo, una anclada
# El contador de OOM del kernel no se movio: no es que los reintentos lo tapen,
# es que no hay OOM. Cautela: son 3 tomas y el fallo era probabilistico, asi que
# es señal fuerte y no prueba cerrada.
#
# Para volver atras: PARAMS_BK="diffusion=cpu"
PARAMS_BK=${PARAMS_BK:-diffusion=cpu,te=disk}

REINTENTOS=${REINTENTOS:-6}
REINTENTO_REPOSO=${REINTENTO_REPOSO:-120}
case "$REINTENTO_REPOSO" in
  ''|*[!0-9]*) echo "REINTENTO_REPOSO debe ser un entero no negativo" >&2; exit 2 ;;
esac

RAM_NECESARIA=${RAM_NECESARIA:-8000}

MODELO=${MODELO:-$MODELO_DIFF}   # una sola fuente de verdad: lib/comun.sh

[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }
[ -f "$PLANIFICADOR" ] || { echo "no existe el planificador: $PLANIFICADOR"; exit 1; }
[ -f "$ESTADO_OBRA" ] || { echo "no existe el gestor de estado: $ESTADO_OBRA"; exit 1; }

# El opt-in neutral es parte de la receta GLOBAL. Validarlo antes de obtener la
# huella evita dos estados ambiguos: un plan neutral que comparte identidad con
# el temporal, y una corrida que genera la toma 1 antes de descubrir que le
# falta el evaluador requerido para las siguientes. En modo temporal no se
# resuelve, importa ni hashea ninguna dependencia facial.
ANCLA_RECETA_MODO=temporal-v1
MODELO_YUNET_NEUTRAL=""
RECETA_ANCLA_ARGS=(--setting "ancla_neutral=$ANCLA_RECETA_MODO")
if [ "$ANCLA_NEUTRAL" = 1 ]; then
  ANCLA_RECETA_MODO=neutral-yunet-v1
  MODELO_YUNET_NEUTRAL=$(validar_selector_neutral) || exit 1
  RECETA_ANCLA_ARGS=(
    --component "selector_ancla=$SELECTOR_ANCLA"
    --component "modelo_yunet=$MODELO_YUNET_NEUTRAL"
    --setting "ancla_neutral=$ANCLA_RECETA_MODO"
  )
fi

# Compilar el guion ANTES de crear una obra o tocar la GPU. El plan contiene la
# huella de cada toma y de la corrida completa: a partir de aqui "ya existe" no
# significa "sirve" salvo que artefacto y huella coincidan.
PLAN_TMP=$(mktemp "${TMPDIR:-/tmp}/h3-plan.XXXXXX.json") || exit 1
RECETA_TMP=""
ESTADO_ACTIVO=0
ESTADO_EXITO=0
ESTADO_FICHERO=""
limpiar_salida() {
  local rc=$?
  rm -f "$PLAN_TMP"
  [ -z "$RECETA_TMP" ] || rm -f "$RECETA_TMP"
  if [ "$ESTADO_ACTIVO" = 1 ] && [ "$ESTADO_EXITO" != 1 ]; then
    python3 "$ESTADO_OBRA" state "$ESTADO_FICHERO" --phase failed \
      --name "$NOMBRE" --run-fingerprint "${RUN_FP:-desconocida}" \
      --message "la ejecucion termino con rc=$rc" --pid $$ >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap limpiar_salida EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reserva global de obra completa compartida por UI, runners legacy, escalado y
# terminal. Se usa EL MISMO fichero que `con_cerrojo`: durante montaje, medida o
# espera tampoco puede entrar otro consumidor de GPU/RAM. Las marcas permiten
# que las llamadas internas a con_cerrojo sean reentrantes en este mismo Bash.
if [ "${VALIDAR:-0}" != 1 ]; then
  reservar_generacion_completa || exit $?
fi

# Identidad de TODA la receta que puede cambiar los bytes generados. La primera
# corrida real calcula SHA-256 de unos 33 GB; despues reutiliza el digest sólo
# mientras device+inode+size+mtime+ctime sigan iguales. Esto detecta incluso un
# `cp -p` con el mismo tamano y fecha. VALIDAR no va a producir ni reutilizar
# artefactos, así que usa una identidad explícita y evita esa lectura costosa.
if [ "${VALIDAR:-0}" = 1 ]; then
  if [ "$ANCLA_NEUTRAL" = 1 ]; then
    # VALIDAR evita hashear decenas de GB de pesos, pero su plan impreso sigue
    # distinguiendo el opt-in y las dos dependencias pequenas que lo definen.
    MODELO_ID=$(printf 'preflight-sin-generacion\nancla_neutral=%s\nselector=%s\nyunet=%s\n' \
      "$ANCLA_RECETA_MODO" \
      "$(sha256sum "$SELECTOR_ANCLA" | awk '{print $1}')" \
      "$(sha256sum "$MODELO_YUNET_NEUTRAL" | awk '{print $1}')" \
      | sha256sum | awk '{print $1}') || exit 1
  else
    MODELO_ID=preflight-sin-generacion
  fi
else
  RECETA_TMP=$(mktemp "${TMPDIR:-/tmp}/h3-receta.XXXXXX.json") || exit 1
  if ! MODELO_ID=$(python3 "$ESTADO_OBRA" recipe-fingerprint \
    --cache "$PROD/obra/.cache/recipe-hashes.json" \
    --manifest "$RECETA_TMP" \
    --component "diffusion=$MODELO" \
    --component "vae=$MODELO_VAE" \
    --component "audio_vae=$MODELO_AVAE" \
    --component "llm=$MODELO_LLM" \
    --component "sd_cli=$SDCLI" \
    --component "runner=$PROD/producir-anclado.sh" \
    --component "vram_policy=$MD/lib/vram.sh" \
    "${RECETA_ANCLA_ARGS[@]}" \
    --setting 'recipe=anclado-v3' \
    --setting "cfg=${CFG:-1.0}" \
    --setting 'backend=diffusion=CUDA0,te=cpu,vae=CUDA0' \
    --setting "params_backend=$PARAMS_BK" \
    --setting 'rng=cpu' \
    --setting 'diffusion_fa=on' \
    --setting 'stream_layers=on'); then
    echo "FALLO: no pude identificar por contenido la pila de modelos" >&2
    exit 1
  fi
fi
if ! python3 "$PLANIFICADOR" "$GUION" --nombre "$NOMBRE" \
    --frames "$FRAMES" --width "$W" --height "$H" --steps "$PASOS" \
    --fps 24 --seed "${SEED:-100}" --model-id "$MODELO_ID" > "$PLAN_TMP"; then
  echo "FALLO: el guion no produjo un plan valido" >&2
  exit 2
fi
read -r RUN_FP N_PLAN < <(python3 - "$PLAN_TMP" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
print(p["run_fingerprint"], len(p["tomas"]))
PY
)
[ -n "$RUN_FP" ] && [ "${N_PLAN:-0}" -gt 0 ] || { echo "plan de obra incompleto"; exit 1; }

# El plan es el UNICO parser. Antes este bloque repetia grep/cut/awk y podia
# discrepar del preflight (HABLA y los modos llegaron a tener dos semanticas).
# NUL permite transportar texto sin interpretarlo como shell ni perder espacios.
plan_cabecera() {
  python3 - "$PLAN_TMP" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["cabecera"][sys.argv[2]])
PY
}
plan_array() {
  python3 - "$PLAN_TMP" "$1" <<'PY'
import json, sys
p=json.load(open(sys.argv[1], encoding="utf-8")); key=sys.argv[2]
for toma in p["tomas"]:
    value=toma[key]
    if key in ("escena", "ambiente") and value == p["cabecera"][key]:
        value=""  # el runner necesita distinguir valor global de override propio
    sys.stdout.write(str(value)+"\0")
PY
}

TIPO_DEF=$(plan_cabecera tipo)
ESCENA=$(plan_cabecera escena)
AMBIENTE=$(plan_cabecera ambiente)
MUSICA=$(plan_cabecera musica)
mapfile -d '' -t CONTENIDOS < <(plan_array contenido)
mapfile -d '' -t TIPOS      < <(plan_array tipo)
mapfile -d '' -t MODOS      < <(plan_array modo)
mapfile -d '' -t ESCENAS    < <(plan_array escena)
mapfile -d '' -t AMBIENTES  < <(plan_array ambiente)
mapfile -d '' -t SEMILLAS   < <(plan_array semilla)
N=${#CONTENIDOS[@]}
for t in "${TIPOS[@]}"; do
  tipo_valido "$t" || { echo "tipo de plano desconocido en el guion: '$t' (validos: $PROMPT_TIPOS)"; exit 1; }
done
[ "$N" -eq "$N_PLAN" ] || {
  echo "FALLO INTERNO: shell encontro $N tomas y el planificador $N_PLAN" >&2
  exit 1
}

# Los modos se validan antes de VALIDAR=1. Antes el preflight salia en la linea
# anterior a esta comprobacion y declaraba validos guiones que luego fallaban,
# despues de que el usuario ya hubiera lanzado la tanda.
for k in $(seq 1 "$N"); do
  m=${MODOS[$((k-1))]}
  case "$m" in
    ancla:*)
      ref=${m#ancla:}
      case "$ref" in
        anclas/*.png)
          # Dialecto del pipeline historico. producir-anclado siempre lo ignoro
          # y uso la toma 1; conservar esa semantica, pero hacerlo explicito.
          MODOS[$((k-1))]=ancla
          echo "  aviso: toma $k usa '$m' (legacy); aqui equivale a ancla:1" >&2
          ;;
        ''|*[!0-9]*)
          echo "toma $k: 'ancla:$ref' no es una toma anterior ni un ancla legacy" >&2
          exit 1 ;;
        *)
          [ "$ref" -ge 1 ] || { echo "toma $k: ancla:$ref — no hay toma $ref"; exit 1; }
          [ "$ref" -lt "$k" ] || {
            echo "toma $k: ancla:$ref apunta hacia adelante; la toma $ref aun no existe" >&2
            exit 1
          } ;;
      esac
      ;;
    ancla|inicio|encadena) : ;;
    *) echo "toma $k: modo desconocido '$m'" >&2; exit 1 ;;
  esac
done
MODOS[0]=inicio

mapfile -t PLAN_WARNINGS < <(python3 - "$PLAN_TMP" <<'PY'
import json, sys
for warning in json.load(open(sys.argv[1], encoding="utf-8")).get("warnings", []):
    print(warning)
PY
)
for aviso in "${PLAN_WARNINGS[@]}"; do echo "  aviso del plan: $aviso" >&2; done

# ── VALIDAR=1: comprobar el guion sin gastar un segundo de GPU ─────────────
# Antes no habia forma de revisar un guion sin producirlo. Comprobar "¿parsea
# bien esto?" arrancaba una generacion de verdad, que ademas competia por el
# cerrojo con la tanda en curso. Con VALIDAR=1 se hace todo el trabajo previo
# —cabecera, tipos, prompts— se imprimen los prompts y se sale antes de tocar
# la GPU. Sirve tambien para LEER el prompt exacto que recibira el modelo, que
# es lo que de verdad hay que revisar cuando un plano sale raro.
if [ "${VALIDAR:-0}" = 1 ]; then
  echo "═══ VALIDACION de $GUION (no se genera nada) ═══"
  echo "    plan: ${RUN_FP:0:12} · tomas: $N · tipos: $(printf '%s ' "${TIPOS[@]}")"
  for i in "${!CONTENIDOS[@]}"; do
    n=$((i+1))
    echo "───── toma $n [${TIPOS[$i]}] ─────"
    # La MISMA escena que usara generar(): si VALIDAR enseñara $ESCENA mientras la
    # generacion usa la escena propia de la toma, estaria mintiendo justo en lo
    # unico que sirve para revisar un guion sin gastar GPU.
    _e=${ESCENAS[$i]:-}; _e=${_e:-$ESCENA}
    [ -n "${ESCENAS[$i]:-}" ] && echo "  (escena propia de esta toma)"
    _a=${AMBIENTES[$i]:-}; _a=${_a:-$AMBIENTE}
    [ -n "${AMBIENTES[$i]:-}" ] && echo "  (ambiente propio de esta toma)"
    construir_prompt "${TIPOS[$i]}" "$_e" "${CONTENIDOS[$i]}" "$_a" "$MUSICA" \
      || { echo "  FALLO construyendo el prompt de la toma $n"; exit 1; }
    echo
  done
  echo "═══ guion valido ═══"
  exit 0
fi

# Un cerrojo por OBRA cubre toda la corrida, no solo los minutos dentro de
# sd-cli. Evita que dos POST/terminales escriban las mismas tomas, logs y montaje
# durante esperas de RAM, reintentos o postproceso.
OBRA=$PROD/obra/$NOMBRE
mkdir -p "$OBRA/anclas" "$OBRA/historial" "$OBRA/fallos" "$PROD/logs"
exec 7>"$OBRA/.obra.lock" || { echo "no pude abrir el cerrojo de $OBRA"; exit 1; }
if ! flock -n 7; then
  echo "la obra '$NOMBRE' ya tiene otra ejecucion activa" >&2
  exit 1
fi

PLAN=$OBRA/plan.json
if [ -f "$PLAN" ]; then
  OLD_FP=$(python3 - "$PLAN" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("run_fingerprint", ""))
PY
  )
  if [ -n "$OLD_FP" ] && [ "$OLD_FP" != "$RUN_FP" ]; then
    cp -p -- "$PLAN" "$OBRA/historial/plan-${OLD_FP:0:12}-$(date +%Y%m%d-%H%M%S-%N).json" || exit 1
  fi
fi
cp "$PLAN_TMP" "$OBRA/.plan.$$.json" || exit 1
mv -f "$OBRA/.plan.$$.json" "$PLAN" || exit 1
cp "$RECETA_TMP" "$OBRA/.recipe.$$.json" || exit 1
mv -f "$OBRA/.recipe.$$.json" "$OBRA/recipe.json" || exit 1

ESTADO_FICHERO=$OBRA/estado.json
ESTADO_ACTIVO=1
estado() {
  python3 "$ESTADO_OBRA" state "$ESTADO_FICHERO" --name "$NOMBRE" \
    --run-fingerprint "$RUN_FP" --plan "$PLAN" --pid $$ "$@" \
    || echo "  aviso: no pude actualizar $ESTADO_FICHERO" >&2
}
estado --phase planned --completed 0 --total "$N"

SD=$(compat_sdcli) || { echo "sd-cli no es ejecutable aqui"; exit 1; }

SEG=$(awk "BEGIN{printf \"%.1f\", $FRAMES/24}")
echo "═══ ANCLADO: $NOMBRE · $N tomas de ${SEG}s = $(awk "BEGIN{printf \"%.0f\", $N*$FRAMES/24}")s ═══"
echo "    ${W}x${H} · ${FRAMES}f · ${PASOS} pasos · $(basename "$MODELO")"
echo "    plan ${RUN_FP:0:12} · tipos: $(printf '%s ' "${TIPOS[@]}")"

validar_video() {  # <ruta> [decodificar=0|1]
  local args=(check-video "$1" --width "$W" --height "$H" --require-audio)
  [ "${2:-0}" = 1 ] && args+=(--decode)
  python3 "$ESTADO_OBRA" "${args[@]}"
}

validar_toma() {  # <ruta>
  python3 "$ESTADO_OBRA" check-video "$1" --width "$W" --height "$H" \
    --frames "$FRAMES" --fps 24 --require-audio
}

fallo_recuperable() {  # <rc> <log> <offset-en-bytes>
  local rc=$1 log=$2 offset=$3
  # SIGKILL (137) es la firma directa del OOM killer. SIGABRT y SIGSEGV
  # tambien representan bugs deterministas, por lo que sólo se reintentan si
  # el tramo de ESTE intento demuestra un fallo de asignacion/memoria.
  [ "$rc" -eq 137 ] && return 0
  tail -c "+$((offset+1))" "$log" 2>/dev/null \
    | grep -Eqi 'out of memory|(^|[^[:alnum:]_])oom([^[:alnum:]_]|$)|cuda.*(alloc|memory)|alloc.*(failed|memory)|cannot allocate memory'
}

archivar_toma() {  # <indice> <base-sin-extension> <motivo>
  local i=$1 out=$2 motivo=$3
  local dir=$OBRA/historial/$(date +%Y%m%d-%H%M%S-%N)-${RUN_FP:0:12}
  mkdir -p "$dir" || return 1
  if [ -e "$out.avi" ] || [ -L "$out.avi" ]; then
    mv -n -- "$out.avi" "$dir/" || return 1
    [ ! -e "$out.avi" ] && [ ! -L "$out.avi" ] || return 1
  fi
  if [ -e "$out.fingerprint" ] || [ -L "$out.fingerprint" ]; then
    mv -n -- "$out.fingerprint" "$dir/" || return 1
    [ ! -e "$out.fingerprint" ] && [ ! -L "$out.fingerprint" ] || return 1
  fi
  echo "  toma $i: artefacto anterior preservado en $dir ($motivo)"
}

generar() {  # $1=indice  $2=contenido  $3=ancla(o vacio)  $4=tipo
  local i=$1 cont=$2 ancla=${3:-} tipo=${4:-habla}
  local out=$OBRA/t$(printf %02d "$i")
  local esc_toma=${ESCENAS[$((i-1))]:-}
  local esc=${esc_toma:-$ESCENA}
  [ -n "$esc_toma" ] && echo "  toma $i: escena propia (sustituye a @ESCENA)"
  local amb_toma=${AMBIENTES[$((i-1))]:-}
  local amb=${amb_toma:-$AMBIENTE}
  [ -n "$amb_toma" ] && echo "  toma $i: ambiente propio (sustituye a @AMBIENTE)"
  local prompt; prompt=$(construir_prompt "$tipo" "$esc" "$cont" "$amb" "$MUSICA") || return 1
  local extra=(); [ -n "$ancla" ] && extra+=(--init-img "$ancla")
  local fp_args=(shot-fingerprint "$PLAN" "$i")
  [ -n "$ancla" ] && fp_args+=(--anchor "$ancla")
  local fingerprint; fingerprint=$(python3 "$ESTADO_OBRA" "${fp_args[@]}") || return 1
  # Dos metodos pueden elegir los mismos pixeles. Para un ancla neutral no
  # alcanza entonces con el SHA del PNG que incluye shot-fingerprint: se liga
  # tambien la procedencia completa escrita por extraer_ancla (fuente,
  # selector, modelo, PNG, sidecar y modo). Asi una toma temporal nunca se
  # reutiliza como si hubiera pasado por el selector semantico, ni viceversa.
  if [ -n "$ancla" ] && [ -s "$ancla.json" ]; then
    local procedencia_ancla
    procedencia_ancla=$(python3 - "$ancla.fingerprint" <<'PY'
import json, re, sys
try:
    value=json.load(open(sys.argv[1], encoding="ascii")).get("fingerprint", "")
except (OSError, ValueError):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit(1)
print(value)
PY
    ) || { echo "toma $i: falta la procedencia verificable del ancla neutral" >&2; return 1; }
    fingerprint=$(printf 'schema=toma-con-ancla-neutral/v1\ntoma=%s\nprocedencia_ancla=%s\n' \
      "$fingerprint" "$procedencia_ancla" | sha256sum | awk '{print $1}') || return 1
  fi

  # Compatibilidad cauta: una obra anterior a los manifiestos se puede reanudar
  # si el AVI es sano, pero NO se le inventa una huella. Todo artefacto generado
  # desde esta version si queda direccionado por contenido.
  if [ -e "$out.avi" ] || [ -L "$out.avi" ]; then
    if python3 "$ESTADO_OBRA" match-fingerprint "$out.fingerprint" "$fingerprint" \
        --artifact "$out.avi"; then
      if validar_toma "$out.avi" >/dev/null; then
        echo "  toma $i verificada (huella ${fingerprint:0:12}), salto"
        estado --phase generating --completed "$i" --total "$N" \
          --message "toma $i reutilizada con huella verificada"
        return 0
      fi
      archivar_toma "$i" "$out" "la huella coincide pero el video no valida" || return 1
    elif [ ! -f "$out.fingerprint" ] && validar_toma "$out.avi" >/dev/null; then
      if [ "${REUTILIZAR_LEGACY:-0}" = 1 ]; then
        echo "  ADVERTENCIA: toma $i legacy sin huella reutilizada por peticion explicita"
        echo "    no se puede demostrar que corresponda a este guion, semilla o modelo"
        estado --phase generating --completed "$i" --total "$N" \
          --message "toma $i legacy reutilizada por opcion insegura explicita"
        return 0
      fi
      archivar_toma "$i" "$out" "legacy sin huella; regeneracion segura por defecto" || return 1
    else
      archivar_toma "$i" "$out" "huella distinta o video invalido" || return 1
    fi
  elif [ -e "$out.fingerprint" ] || [ -L "$out.fingerprint" ]; then
    archivar_toma "$i" "$out" "huella huerfana sin video" || return 1
  fi

  # Consciente del tamaño del trabajo: el buffer de computo crece con
  # frames x pixeles, y pedir MAS modelo residente hace que NO quepa.
  # La ruta anclada engorda el buffer ~1.7 GB: hay que decirselo al presupuesto
  # o autoriza mas modelo del que cabe y el guardian corta la toma a medias.
  local maxv; maxv=$(vram_arg_trabajo 0 "$FRAMES" "$W" "$H" "$([ -n "$ancla" ] && echo 1 || echo 0)")
  estado --phase waiting_resources --completed "$((i-1))" --total "$N" \
    --message "toma $i esperando margen de VRAM y RAM"
  vram_esperar 0 5000 900 || echo "  aviso: margen de VRAM justo, arranco igual"
  # Esperar tambien a la RAM: una generacion usa casi los 24 GB del contenedor y
  # arrancar sin sitio la mata el OOM killer a mitad. Paso de verdad: la toma 3
  # murio en el paso 16/20 tras 18 min de GPU porque habia mediciones en paralelo.
  local t=0
  while [ "$(ram_libre_mb)" -lt "$RAM_NECESARIA" ] && [ $t -lt 900 ]; do
    [ $t = 0 ] && echo "  esperando RAM: solo $(ram_libre_mb) MiB libres de los $RAM_NECESARIA que hacen falta"
    sleep 20; t=$((t+20))
  done
  echo "  toma $i [$tipo] · $maxv ${ancla:+· anclada a $(basename "$ancla")}"
  # Reintento ante OOM, como ya hacia producir.sh y yo no habia copiado.
  # El pico de memoria NO esta en la difusion sino en el decodificado de video,
  # que convierte los latentes en los 345 fotogramas de golpe. Medido: la toma 4
  # completo los 20 pasos (1261 s) y el audio VAE, y murio justo ahi. Las tomas
  # 1-3 pasaron ese punto por poco. Reintentar cuesta tiempo pero no calidad.
  local intento=1
  local log=$PROD/logs/$NOMBRE-t$i.log
  while [ $intento -le $REINTENTOS ]; do
  if [ $intento -gt 1 ]; then
    # El log tiene que decir que esta ESPERANDO y hasta cuando. Sin esto, los
    # 120 s de reposo mas la espera de RAM parecen la maquina colgada: Steven lo
    # reporto dos veces como "veo la PC quieta", y las dos tuvo que mirar el log
    # alguien para saber si estaba trabajando o muerta.
    echo "  toma $i: reintento $intento/$REINTENTOS tras OOM · reposo de ${REINTENTO_REPOSO}s hasta $(date -d "+$REINTENTO_REPOSO seconds" +%H:%M:%S)"
    sleep "$REINTENTO_REPOSO"
    local w=0
    while [ "$(ram_libre_mb)" -lt "$RAM_NECESARIA" ] && [ $w -lt 900 ]; do
      [ $((w % 60)) = 0 ] && echo "  toma $i: esperando RAM ${w}s · $(ram_libre_mb)/$RAM_NECESARIA MiB"
      sleep 20; w=$((w+20))
    done
    # Y esperar tambien la VRAM. Hay DOS fallos distintos y el reintento solo
    # cubria uno: "Killed" es el OOM killer por RAM, y "Aborted (core dumped)"
    # con cudaMalloc en el log es falta de VRAM. Reintentar tras un fallo de VRAM
    # sin comprobar la VRAM es tirar 20 minutos de GPU a lo mismo: paso dos veces
    # seguidas en 4-fenomenologia, y el log anunciaba "11774 MiB libres" hablando
    # de RAM mientras lo que faltaba era memoria de la tarjeta.
    VRAM_NECESARIA=$(awk -v f="$FRAMES" -v w="$W" -v h="$H" -v k="$VRAM_MIB_POR_PXFRAME_ANCLA" \
                     -v fijo="${VRAM_FIJA_MODELO:-5558}" \
                     'BEGIN{printf "%d", fijo + f*w*h*k + 600}')
    if ! vram_esperar 0 "$VRAM_NECESARIA" 900; then
      echo "  toma $i: tras 15 min la GPU sigue sin $VRAM_NECESARIA MiB." \
           "Con el escritorio ocupando VRAM, esta toma NO CABE a $FRAMES fotogramas."
    fi
    echo "  toma $i: $(ram_libre_mb) MiB libres, reintento"
  fi
  local t0=$SECONDS
  local temporal=$OBRA/.t$(printf %02d "$i")-${RUN_FP:0:12}-$$-$intento.mp4
  local real
  real=$(sd_salida "$temporal")
  rm -f "$temporal" "$real"
  {
    echo
    echo "===== toma $i intento $intento/$REINTENTOS · $(date -Is) · plan ${RUN_FP:0:12} ====="
  } >> "$log"
  local log_inicio
  log_inicio=$(wc -c < "$log")
  estado --phase generating --completed "$((i-1))" --total "$N" \
    --message "generando toma $i, intento $intento/$REINTENTOS"
  local rc
  # Última comprobacion justo antes de ejecutar: el hash se hizo sobre un solo
  # descriptor con fstat y este manifiesto impide abrir pesos/binario que hayan
  # sido sustituidos desde entonces.
  if ! python3 "$ESTADO_OBRA" verify-recipe "$RECETA_TMP" >> "$log" 2>&1; then
    echo "  toma $i: la receta cambio despues del preflight; aborto sin generar" >&2
    return 1
  fi
  con_cerrojo 10800 "$SD" -M vid_gen \
    --diffusion-model "$MODELO" --vae "$MODELO_VAE" \
    --audio-vae "$MODELO_AVAE" --llm "$MODELO_LLM" \
    -p "$prompt" -s "${SEMILLAS[$((i-1))]}" \
    --cfg-scale "${CFG:-1.0}" -W "$W" -H "$H" --fps 24 \
    --video-frames "$FRAMES" --steps "$PASOS" \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "$PARAMS_BK" \
    --max-vram "$maxv" --stream-layers \
    -o "$temporal" "${extra[@]}" >> "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && validar_toma "$real" >> "$log" 2>&1; then
    mv -n -- "$real" "$out.avi" || return 1
    [ ! -e "$real" ] && [ -s "$out.avi" ] || return 1
    python3 "$ESTADO_OBRA" write-fingerprint "$out.fingerprint" "$fingerprint" \
      --artifact "$out.avi" || return 1
    echo "  toma $i OK en $((SECONDS-t0))s${ancla:+ (anclada)} · huella ${fingerprint:0:12}"
    estado --phase generating --completed "$i" --total "$N" --message "toma $i terminada"
    return 0
  fi
  if [ -f "$real" ]; then
    local fallo=$OBRA/fallos/t$(printf %02d "$i")-${RUN_FP:0:12}-$(date +%Y%m%d-%H%M%S-%N)-intento$intento.avi
    mv -n "$real" "$fallo" || true
  fi
  echo "  toma $i intento $intento fallo (rc=$rc) tras $((SECONDS-t0))s"
  tr '\r' '\n' < "$log" | tail -3 | sed 's/^/      /'
  if ! fallo_recuperable "$rc" "$log" "$log_inicio"; then
    echo "  toma $i: fallo no transitorio; no gasto mas intentos repitiendo lo mismo"
    break
  fi
  intento=$((intento+1))
  done
  local ejecutados=$intento
  [ "$ejecutados" -gt "$REINTENTOS" ] && ejecutados=$REINTENTOS
  echo "  toma $i FALLO DEFINITIVO tras $ejecutados intento(s), maximo $REINTENTOS"
  return 1
}

# ── anclas: de que toma sale la imagen de partida de cada una ──────────────
#
# Hasta aqui TODAS las anclas salian de la toma 1, y una toma solo podia elegir
# entre eso o nada. Se ve el limite en 5-dialectica: las tres tomas de la
# segunda interlocutora van en modo 'inicio' —obligadas, porque anclarlas a la
# toma 1 les metia la cara del hombre— y al no tener ancla ninguna, su encuadre
# y su escala DERIVAN entre si. Mirando la pieza: sus tres planos tienen tres
# tamaños distintos y uno queda descentrado. Ninguna metrica lo vio.
#
# 'ancla:N' resuelve justo eso: anclar a un fotograma pristino de la toma N, no
# de la 1. Con eso el segundo personaje se ancla a SU primera aparicion y se
# mantiene igual a si mismo, sin heredar la cara del primero.
#
#   ancla      = ancla:1  (lo de siempre)
#   ancla:N    = a un fotograma de la toma N, que debe ser anterior
#   inicio     = sin ancla; el sujeto se reinventa
#
# La extraccion es PEREZOSA: el ancla de la toma k se saca justo antes de
# generarla, cuando la toma N de la que sale ya existe.

huella_ancla() {  # metodo orig dest tipo pos fuente_sha PNG [JSON modelo]
  local metodo=$1 orig=$2 dest=$3 tipo=$4 pos=$5 fuente_fp=$6 A=$7
  local J=${8:-} modelo=${9:-}
  local png_fp selector_fp=ninguno modelo_fp=ninguno sidecar_fp=ninguno
  png_fp=$(sha256sum "$A" | awk '{print $1}') || return 1
  if [ "$metodo" = neutral-yunet-v1 ]; then
    [ -s "$J" ] && [ -f "$SELECTOR_ANCLA" ] && [ -f "$modelo" ] || return 1
    selector_fp=$(sha256sum "$SELECTOR_ANCLA" | awk '{print $1}') || return 1
    modelo_fp=$(sha256sum "$modelo" | awk '{print $1}') || return 1
    sidecar_fp=$(sha256sum "$J" | awk '{print $1}') || return 1
  fi
  printf 'schema=ancla-generacion/v2\nmetodo=%s\norigen=%s\ndestino=%s\ntipo_destino=%s\npos=%s\nfuente=%s\nselector=%s\nmodelo=%s\npng=%s\nsidecar=%s\n' \
    "$metodo" "$orig" "$dest" "$tipo" "$pos" "$fuente_fp" \
    "$selector_fp" "$modelo_fp" "$png_fp" "$sidecar_fp" \
    | sha256sum | awk '{print $1}'
}

# saca un fotograma pristino de la toma $1 para usarlo como ancla de la toma $2
extraer_ancla() {   # $1=origen $2=destino $3=tipo destino -> imprime la ruta
  local orig=$1 dest=$2 tipo_destino=${3:-habla}
  local fuente=$OBRA/t$(printf %02d "$orig").avi
  [ -f "$fuente" ] || { echo "no existe la toma $orig para anclar la $dest" >&2; return 1; }
  local A=$OBRA/anclas/a$(printf %02d "$dest").png
  local J=$A.json
  local metodo=temporal-v1 pos modelo="" selector_fp_antes="" modelo_fp_antes=""
  if [ "$ANCLA_NEUTRAL" = 1 ] && [ "$tipo_destino" = habla ]; then
    metodo=neutral-yunet-v1
    pos=selector-denso
    modelo=$(validar_selector_neutral) || return 1
    [ "$modelo" = "$MODELO_YUNET_NEUTRAL" ] || {
      echo "FALLO: el modelo YuNet efectivo cambio despues de calcular la receta" >&2
      return 1
    }
    selector_fp_antes=$(sha256sum "$SELECTOR_ANCLA" | awk '{print $1}') || return 1
    modelo_fp_antes=$(sha256sum "$modelo" | awk '{print $1}') || return 1
  else
    local dur
    dur=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$fuente")
    [ -n "$dur" ] || { echo "no pude medir la toma $orig para extraer el ancla" >&2; return 1; }
    # Repartidas por la toma origen y evitando los extremos: el ultimo fotograma
    # es justo el que arrastra mas realce, y es lo que NO queremos como ancla.
    pos=$(awk -v k="$dest" -v n="$N" -v d="$dur" 'BEGIN{printf "%.2f", d*(k-1)/(n+1)}')
  fi

  # El nombre aNN no basta: al cambiar ancla:1 por ancla:3 antes se reutilizaba
  # silenciosamente el PNG viejo. La huella incluye todos los insumos del
  # metodo; se calcula tambien sobre el artefacto para detectar sustituciones.
  local fuente_fp
  fuente_fp=$(sha256sum "$fuente" | awk '{print $1}') || return 1
  local anchor_fp=""
  local cache_estructura=0
  if [ "$metodo" = neutral-yunet-v1 ]; then
    [ -s "$J" ] && cache_estructura=1
  elif [ ! -e "$J" ] && [ ! -L "$J" ]; then
    cache_estructura=1
  fi
  if [ -s "$A" ] && [ "$cache_estructura" = 1 ]; then
    anchor_fp=$(huella_ancla "$metodo" "$orig" "$dest" "$tipo_destino" \
      "$pos" "$fuente_fp" "$A" "$J" "$modelo") || anchor_fp=""
  fi
  if [ -n "$anchor_fp" ] \
      && python3 "$ESTADO_OBRA" match-fingerprint "$A.fingerprint" "$anchor_fp" --artifact "$A" \
      && [ -n "$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$A" 2>/dev/null)" ]; then
    echo "$A"
    return 0
  fi

  if [ -e "$A" ] || [ -L "$A" ] || [ -e "$J" ] || [ -L "$J" ] \
      || [ -e "$A.fingerprint" ] || [ -L "$A.fingerprint" ]; then
    local adir=$OBRA/historial/anclas-$(date +%Y%m%d-%H%M%S-%N)-${RUN_FP:0:12}
    mkdir -p "$adir" || return 1
    if [ -e "$A" ] || [ -L "$A" ]; then
      mv -n -- "$A" "$adir/" || return 1
      [ ! -e "$A" ] && [ ! -L "$A" ] || return 1
    fi
    if [ -e "$J" ] || [ -L "$J" ]; then
      mv -n -- "$J" "$adir/" || return 1
      [ ! -e "$J" ] && [ ! -L "$J" ] || return 1
    fi
    if [ -e "$A.fingerprint" ] || [ -L "$A.fingerprint" ]; then
      mv -n -- "$A.fingerprint" "$adir/" || return 1
      [ ! -e "$A.fingerprint" ] && [ ! -L "$A.fingerprint" ] || return 1
    fi
    echo "  ancla vieja de la toma $dest preservada en $adir" >&2
  fi

  if [ "$metodo" = neutral-yunet-v1 ]; then
    if ! "$ANCLA_PYTHON" "$SELECTOR_ANCLA" "$fuente" --salida "$A" \
        --json "$J" --modelo "$modelo" >&2; then
      echo "FALLO: no pude seleccionar un ancla facial neutral para la toma $dest; no uso fallback temporal" >&2
      return 1
    fi
    [ -s "$A" ] && [ -s "$J" ] || {
      echo "FALLO: el selector no publico PNG y sidecar para la toma $dest" >&2
      return 1
    }
    if [ "$(sha256sum "$SELECTOR_ANCLA" | awk '{print $1}')" != "$selector_fp_antes" ] \
        || [ "$(sha256sum "$modelo" | awk '{print $1}')" != "$modelo_fp_antes" ]; then
      echo "FALLO: selector o modelo YuNet cambiaron durante la extraccion; no publico una huella ambigua" >&2
      return 1
    fi
    local png_fp modelo_fp
    png_fp=$(sha256sum "$A" | awk '{print $1}') || return 1
    modelo_fp=$(sha256sum "$modelo" | awk '{print $1}') || return 1
    if ! python3 - "$J" "$fuente_fp" "$modelo_fp" "$png_fp" <<'PY'
import json, sys
try:
    data=json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
if (
    data.get("schema") != "seleccionar-ancla/v1"
    or data.get("estado") != "seleccionado"
    or data.get("video", {}).get("sha256") != sys.argv[2]
    or data.get("modelo", {}).get("sha256") != sys.argv[3]
    or data.get("seleccion", {}).get("sha256_png") != sys.argv[4]
):
    raise SystemExit(1)
PY
    then
      echo "FALLO: sidecar inconsistente del ancla neutral para la toma $dest" >&2
      return 1
    fi
    echo "  ancla neutral de la toma $dest seleccionada densamente desde la toma $orig" >&2
  else
    local temporal=$OBRA/anclas/.a$(printf %02d "$dest")-$$.png
    rm -f "$temporal"
    ff -y -v error -ss "$pos" -i "$fuente" -frames:v 1 -update 1 "$temporal" || return 1
    [ -s "$temporal" ] || { echo "ancla vacia para la toma $dest" >&2; return 1; }
    mv -n -- "$temporal" "$A" || return 1
    [ ! -e "$temporal" ] && [ -s "$A" ] || return 1
    echo "  ancla de la toma $dest: segundo $pos de la toma $orig" >&2
  fi
  anchor_fp=$(huella_ancla "$metodo" "$orig" "$dest" "$tipo_destino" \
    "$pos" "$fuente_fp" "$A" "$J" "$modelo") || return 1
  python3 "$ESTADO_OBRA" write-fingerprint "$A.fingerprint" "$anchor_fp" \
    --artifact "$A" || return 1
  echo "$A"
}

generar 1 "${CONTENIDOS[0]}" "" "${TIPOS[0]}" || exit 1

for k in $(seq 2 "$N"); do
  m=${MODOS[$((k-1))]}
  case "$m" in
    inicio)
      echo "  toma $k: modo 'inicio' — arranca limpia, sin ancla (sujeto nuevo)"
      generar "$k" "${CONTENIDOS[$((k-1))]}" "" "${TIPOS[$((k-1))]}" || exit 1 ;;
    *)
      # 'encadena' cae aqui y se comporta como 'ancla'. Es deliberado y esta
      # dicho en voz alta: encadenar de verdad (arrancar del ULTIMO fotograma
      # de la toma anterior) degrada medido —68,7 contra 85,9 en cuatro tomas—
      # porque el fotograma reinyectado ya lleva el realce del modelo y el
      # modelo realza encima. El modo se acepta por compatibilidad con guiones
      # viejos, no porque haga lo que su nombre dice.
      [ "$m" = encadena ] && echo "  toma $k: 'encadena' se trata como 'ancla' (encadenar de verdad degrada; ver COMO-LANZAR.md)"
      ref=1; [ "${m#ancla:}" != "$m" ] && ref=${m#ancla:}
      A=$(extraer_ancla "$ref" "$k" "${TIPOS[$((k-1))]}") || exit 1
      [ "$ref" != 1 ] && echo "  toma $k: anclada a la toma $ref, no a la 1"
      generar "$k" "${CONTENIDOS[$((k-1))]}" "$A" "${TIPOS[$((k-1))]}" || exit 1 ;;
  esac
done

# ── montaje: corte seguro por defecto; transiciones explicitas en fundir.py ─
echo "═══ montando $N tomas ═══"
estado --phase mounting --completed "$N" --total "$N" --message "validando y montando $N tomas"
MONT=$OBRA/montaje
mkdir -p "$MONT"
rm -f "$MONT"/*.mp4 "$MONT/lista.txt" "$MONT/tramos.txt"

# Gate fail-closed: se monta EXACTAMENTE lo enumerado por el plan. Un glob sobre
# t?? incluia restos de un guion anterior mas largo; y un clip que fallaba se
# omitia, pero la pieza parcial se publicaba igualmente como LISTO.
for i in $(seq 1 "$N"); do
  f=$OBRA/t$(printf %02d "$i").avi
  if ! validar_toma "$f" >/dev/null; then
    echo "FALLO: la toma $i falta o no es un video ${W}x${H} completo; no publico una pieza parcial" >&2
    exit 1
  fi
done
# La toma 1 es la referencia de luminancia: es la unica generada limpia, sin
# ancla, asi que es el aspecto "verdadero" de la escena. Las demas se igualan a
# ella. Ver luminancia_mediana() en comun.sh para el porque.
REF=$OBRA/t01.avi
for i in $(seq 1 "$N"); do
  n=$(printf %02d "$i")
  f=$OBRA/t$n.avi
  D=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$f")
  [ -n "$D" ] || { echo "FALLO: no pude medir la toma $i" >&2; exit 1; }
  VF=""
  # Solo se nivela lo que DEBERIA parecerse a la toma 1: las tomas ancladas a
  # ella y sin escena propia. Ahi la diferencia de luminancia es deriva del
  # anclado y corregirla es arreglar un defecto.
  #
  # Una toma en modo 'inicio' con escena propia es otra imagen A PROPOSITO: un
  # puerto frio al amanecer, un plano de madera con luz rasante, la cara de un
  # segundo interlocutor. Igualarla a un primer plano calido no corrige nada,
  # DESTRUYE la decision. En una pieza documental el contraste entre el rostro
  # y lo que se muestra es la mitad de la forma.
  _propia=${ESCENAS[$((i-1))]:-}
  _modo=${MODOS[$((i-1))]:-ancla}
  if [ "$i" -gt 1 ] && [ -n "$REF" ] && [ -z "$_propia" ] && [ "$_modo" != inicio ]; then
    G=$(ganancia_nivel "$f" "$REF")
    # Por debajo del 2% no se toca: corregir ruido de medida solo añade una
    # pasada de filtro y no arregla nada que se vea.
    if awk -v g="$G" 'BEGIN{exit !(g<0.98 || g>1.02)}'; then
      VF="-vf lutyuv=y=val*$G"
      echo "  toma $n: nivelada a la toma 1 (ganancia $G)"
    fi
  elif [ "$i" -gt 1 ] && { [ -n "$_propia" ] || [ "$_modo" = inicio ]; }; then
    echo "  toma $n: imagen propia a proposito, NO se nivela"
  fi
  if ! ff -y -v error -i "$f" $VF \
      -af "loudnorm=I=-19:TP=-2:LRA=7,afade=t=in:st=0:d=0.25,afade=t=out:st=$(awk "BEGIN{print $D-0.25}"):d=0.25" \
      -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k "$MONT/$n.mp4"; then
    echo "FALLO: no pude procesar la toma $i; conservo todas las tomas y no publico" >&2
    exit 1
  fi
  echo "file '$MONT/$n.mp4'" >> "$MONT/lista.txt"
  [ "$i" -gt 1 ] && printf '%s\n' "$n" >> "$MONT/tramos.txt"
done
[ "$(wc -l < "$MONT/lista.txt")" -eq "$N" ] || {
  echo "FALLO: el montaje no contiene exactamente $N tomas" >&2
  exit 1
}
STAMP=$(date +%Y%m%d-%H%M%S-%N)
FINAL="$OBRA/.montando-$STAMP.mp4"
rm -f "$FINAL"
python3 "$PROD/fundir.py" "$MONT" "$FINAL" || {
  echo "FALLO: el montaje con la transicion solicitada fallo; no publico una alternativa silenciosa" >&2
  exit 1
}
if ! validar_video "$FINAL" >/dev/null; then
  echo "FALLO: el video montado no supera ffprobe; queda en $FINAL" >&2
  exit 1
fi
RWH=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$FINAL")
RS=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$FINAL")
DEST_F="$DEST/$NOMBRE-${RWH%,*}x${RWH#*,}-$(awk "BEGIN{printf \"%.0f\",$RS}")s-$STAMP.mp4"
mkdir -p "$DEST"
PUBLICACION_MANIFEST=$DEST_F.minimax-h3.json
if [ -e "$DEST_F" ] || [ -L "$DEST_F" ] \
    || [ -e "$PUBLICACION_MANIFEST" ] || [ -L "$PUBLICACION_MANIFEST" ]; then
  echo "FALLO: el destino ya existe y no se sobrescribira: $DEST_F" >&2
  exit 1
fi
PUBLICANDO=$DEST/.publicando-$NOMBRE-$STAMP-$$.mp4
PUBLICANDO_MANIFEST=$PUBLICANDO.minimax-h3.json
if [ -e "$PUBLICANDO" ] || [ -L "$PUBLICANDO" ] \
    || [ -e "$PUBLICANDO_MANIFEST" ] || [ -L "$PUBLICANDO_MANIFEST" ]; then
  echo "FALLO: ya existe el temporal de publicacion: $PUBLICANDO" >&2
  exit 1
fi
cp -- "$FINAL" "$PUBLICANDO" || exit 1
if ! validar_video "$PUBLICANDO" 1 >/dev/null; then
  echo "FALLO: la copia de publicacion no decodifica completa; originales preservados" >&2
  exit 1
fi
python3 - "$PUBLICANDO" <<'PY' || exit 1
import os, sys
with open(sys.argv[1], "rb") as handle:
    os.fsync(handle.fileno())
PY
# El SHA se calcula mientras el MP4 todavía es oculto. Publicar primero el
# sidecar y después el video garantiza que un SIGKILL sólo pueda dejar un JSON
# huérfano invisible, nunca una entrega visible sin procedencia demostrable.
python3 "$ESTADO_OBRA" write-fingerprint "$PUBLICANDO_MANIFEST" "$RUN_FP" \
  --artifact "$PUBLICANDO" || exit 1
mv -n -- "$PUBLICANDO_MANIFEST" "$PUBLICACION_MANIFEST" || exit 1
[ ! -e "$PUBLICANDO_MANIFEST" ] && [ -s "$PUBLICACION_MANIFEST" ] || {
  echo "FALLO: no pude publicar el manifiesto sin sobrescribir" >&2
  exit 1
}
python3 - "$DEST" <<'PY' || exit 1
import os, sys
fd=os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
if ! mv -n -- "$PUBLICANDO" "$DEST_F" \
    || [ -e "$PUBLICANDO" ] || [ -L "$PUBLICANDO" ] || [ ! -s "$DEST_F" ]; then
  mv -n -- "$PUBLICACION_MANIFEST" "$PUBLICANDO_MANIFEST" || true
  echo "FALLO: no pude publicar atomicamente; el montaje queda en $FINAL" >&2
  exit 1
fi
python3 "$ESTADO_OBRA" verify-artifact "$PUBLICACION_MANIFEST" "$DEST_F" \
  || { echo "FALLO: la entrega publicada no coincide con su manifiesto" >&2; exit 1; }
python3 - "$DEST" <<'PY' || exit 1
import os, sys
fd=os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
rm -f -- "$FINAL"
estado --phase review_pending --completed "$N" --total "$N" --final "$DEST_F" \
  --message "ensamblado y decodificado; pendiente de revision visual"
# Desde aqui la entrega tecnica ya existe y supero el gate. Contacto y medidas
# son asesoras: una interrupcion durante ellas no debe reescribir este estado
# como `failed` ni hacer creer que se perdio una pieza valida.
ESTADO_EXITO=1
echo "═══ LISTO PARA REVISION: $DEST_F ═══"
python3 "$CAL/auditar.py" contacto "$DEST_F" "$OBRA/contacto.jpg" >/dev/null && echo "    contactos: $OBRA/contacto.jpg"
# La cobertura de voz SOLO significa algo si la pieza tiene dialogo. En un
# plano de manos o un paisaje no hay nadie hablando: el detector lee el cello y
# el ambiente como voz continua, saca "voz 100.0%" y dictamina ATROPELLADO. Es
# una falsa alarma del mismo tipo que el recorte central de evaluar2 — la medida
# da por hecho el formato de retrato hablado.
# La cobertura de voz se mide sobre la pieza ENTERA, asi que solo significa algo
# si la palabra es lo dominante. En 4-fenomenologia —2 tomas habladas de 6— dio
# "voz 98.2% -> ATROPELLADO" en una pieza pensada para estar callada media
# duracion: el cello continuo rellena los silencios y el detector lo cuenta como
# voz. Es la quinta falsa alarma de este tipo, asi que ahora la medida solo se
# aplica cuando al menos la MITAD de las tomas son habladas.
_nhabla=$(printf '%s\n' "${TIPOS[@]}" | grep -cx 'habla')
if [ "$_nhabla" -eq 0 ]; then
  echo "  (sin tomas habladas: me salto la cobertura de voz, no aplica)"
elif [ $((_nhabla * 2)) -lt "$N" ]; then
  echo "  ($_nhabla de $N tomas habladas: me salto la cobertura de voz, que se mide"
  echo "   sobre la pieza entera y daria un ATROPELLADO falso)"
else
  python3 "$CAL/auditar.py" habla "$DEST_F" || true
fi
python3 "$CAL/auditar.py" audio "$DEST_F" || true
exit 0
