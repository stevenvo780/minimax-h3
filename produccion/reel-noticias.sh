#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  REEL DE NOTICIAS — de un titular al MP4 9:16 para TikTok / Instagram.
#
#  Encadena lo que ya existe, no lo duplica:
#    1. harness/noticias.py     recorta el texto (sin inventar)
#    2. harness/componer.py     .guion de la categoria noticias
#    3. producir-anclado.sh     MiniMax-H3 a 416x736
#    4. subtitular.py           quemado en zona segura
#    5. exportar-reel.sh        1080x1920 +faststart -14 LUFS
#
#  Uso:
#    produccion/reel-noticias.sh --titular "..." --texto "..." --nombre corte
#    produccion/reel-noticias.sh --fichero noticia.txt --nombre corte
#    produccion/reel-noticias.sh --rss URL [--indice 0] --nombre corte
#    produccion/reel-noticias.sh --tema "avion miami" --nombre corte
#
#  VALIDAR=1     compone y valida el guion, no toca la GPU
#  SOLO_GUION=1  escribe el .guion y sale
#  BROLL=1       intercalas apoyos; fuerza tomas de 107 f (4,5 s)
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas python3 || exit 1

NOTICIAS=$MD/harness/noticias.py
INVESTIGAR=$MD/harness/investigar.py
COMPONER=$MD/harness/componer.py
RUNNER=$MD/produccion/producir-anclado.sh
SUBS=$MD/produccion/subtitular.py
EXPORT=$MD/produccion/exportar-reel.sh
CAT=$MD/harness/categorias/noticias.json

TITULAR=""
TEXTO=""
FICHERO=""
RSS=""
TEMA=""
INDICE=0
NOMBRE=""
# Duracion del reel. Con tomas de 8 s (192 f) son cuatro tomas: el reel de dos
# tomas que salia antes eran 16 s en los que solo cabia el titular y su
# reformulacion, y lo que de verdad habia pasado no se llegaba a decir.
SEG_OBJ=32
FRAMES=""
ANCHO=""
ALTO=""
PASOS=""

uso() {
  sed -n '2,22p' "$0" | sed 's/^# \?//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --titular) TITULAR=${2:?}; shift 2 ;;
    --texto)   TEXTO=${2:?}; shift 2 ;;
    --fichero) FICHERO=${2:?}; shift 2 ;;
    --rss)     RSS=${2:?}; shift 2 ;;
    --tema)    TEMA=${2:?}; shift 2 ;;
    --indice)  INDICE=${2:?}; shift 2 ;;
    --nombre)  NOMBRE=${2:?}; shift 2 ;;
    --seg-objetivo) SEG_OBJ=${2:?}; shift 2 ;;
    --frames)  FRAMES=${2:?}; shift 2 ;;
    -h|--help) uso ;;
    *) echo "argumento desconocido: $1" >&2; uso ;;
  esac
done

[ -n "$NOMBRE" ] || { echo "falta --nombre" >&2; exit 2; }
case "$NOMBRE" in
  ''|.*|*[!A-Za-z0-9_-]*)
    echo "nombre invalido: '$NOMBRE' (usa letras, numeros, _ y -)" >&2
    exit 2 ;;
esac

# Resolucion nativa 9:16: mismo producto de pixeles que 736x416, que es lo
# medido. No se inventa un tamaño nuevo para el modelo.
if [ -z "$ANCHO" ] || [ -z "$ALTO" ] || [ -z "$FRAMES" ] || [ -z "$PASOS" ]; then
  eval "$(python3 - "$CAT" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
f=c.get("formato") or {}
print("ANCHO=%s" % f.get("ancho",416))
print("ALTO=%s" % f.get("alto",736))
print("FRAMES_CAT=%s" % f.get("frames",192))
print("PASOS=%s" % f.get("pasos",20))
PY
)"
  : "${FRAMES:=$FRAMES_CAT}"
  : "${PASOS:=$PASOS}"
fi

RITMO=""
if [ "${BROLL:-0}" = 1 ]; then
  # Ya no hace falta encoger TODAS las tomas para que el apoyo no sean ocho
  # segundos de silencio: cada toma lleva su duracion, y el compositor le da
  # al apoyo la suya (107 f = 4,5 s).
  RITMO="informativo,detalle,informativo"
fi

case "$FRAMES" in
  ''|*[!0-9]*) echo "--frames debe ser un entero" >&2; exit 2 ;;
esac
SEG_TOMA=$(awk -v f="$FRAMES" 'BEGIN{printf "%.4f", f/24}')

DIR=$MD/produccion/guiones/noticias/generados
mkdir -p "$DIR" || exit 1
GUION=$DIR/${NOMBRE}.guion

ARGS=(--guion "$GUION" --seg-objetivo "$SEG_OBJ" --seg-por-toma "$SEG_TOMA" --categoria noticias)
[ -n "$RITMO" ] && ARGS+=(--ritmo "$RITMO")
if [ -n "$TEMA" ]; then
  FICHERO=$DIR/${NOMBRE}.noticia.txt
  python3 "$INVESTIGAR" --tema "$TEMA" --salida "$FICHERO" || exit $?
fi
if [ -n "$RSS" ]; then
  ARGS+=(--rss "$RSS" --indice "$INDICE")
elif [ -n "$FICHERO" ]; then
  ARGS+=(--fichero "$FICHERO")
elif [ -n "$TITULAR" ]; then
  ARGS+=(--titular "$TITULAR")
  [ -n "$TEXTO" ] && ARGS+=(--texto "$TEXTO")
else
  echo "hace falta --titular, --fichero, --rss o --tema" >&2
  exit 2
fi

echo "═══ reel de noticias · $NOMBRE · ${ANCHO}x${ALTO} · ${FRAMES} f ═══"
python3 "$NOTICIAS" "${ARGS[@]}" || exit $?
[ -f "$GUION" ] || { echo "no se escribio el guion" >&2; exit 1; }
# La fuente viaja junto al guion: el verificador compara TOMA| contra este texto.
if [ -n "$FICHERO" ] && [ -f "$FICHERO" ]; then
  python3 - "$FICHERO" "$GUION" "$NOTICIAS" <<'PY' || exit 1
import json, os, sys
sys.path.insert(0, os.path.dirname(sys.argv[3]))
import noticias
titular, cuerpo, fuente = noticias.leer_fichero(sys.argv[1])
origen = titular + "\n" + cuerpo
sidecar = sys.argv[2] + ".fuente.json"
json.dump(
    {"titular": titular, "cuerpo": cuerpo, "fuente": fuente, "origen": origen,
     "noticia": os.path.abspath(sys.argv[1]), "guion": os.path.abspath(sys.argv[2])},
    open(sidecar, "w", encoding="utf-8"),
    ensure_ascii=False, indent=2,
)
print("  fuente: " + sidecar)
PY
fi

if [ "${SOLO_GUION:-0}" = 1 ]; then
  echo "  solo guion: $GUION"
  exit 0
fi

# ffmpeg solo hace falta a partir de aqui: componer el guion es texto.
exigir_herramientas ffmpeg ffprobe || exit 1

# ── ancla neutral ──────────────────────────────────────────────────────────
# El runner sabe elegir el fotograma de ancla mirando la cara (boca cerrada,
# pose frontal, nitidez), pero es opt-in y NADIE lo encendia: el reel se
# anclaba a un fotograma elegido por reloj, casi siempre en mitad de una
# palabra, y la toma siguiente arrancaba con la boca abierta.
#
# Se enciende aqui, y solo si el selector es utilizable: en una maquina sin
# .venv-calidad ni el modelo YuNet, el runner aborta a proposito antes que
# caer en silencio al ancla temporal, y eso dejaria el reel sin generar.
if [ -z "${ANCLA_NEUTRAL:-}" ]; then
  if [ -x "$MD/.venv-calidad/bin/python" ] \
     && [ -f "$MD/calidad/seleccionar-ancla.py" ] \
     && compgen -G "$MD/modelos/evaluacion/face_detection_yunet*.onnx" >/dev/null
  then
    export ANCLA_NEUTRAL=1
  else
    export ANCLA_NEUTRAL=0
    echo "  aviso: sin selector de ancla neutral (falta .venv-calidad o el modelo"
    echo "         YuNet); el ancla saldra por reloj. Arreglalo con"
    echo "         calidad/preparar-modelos-evaluacion.sh"
  fi
fi

# ── el corte entre tomas ───────────────────────────────────────────────────
# CORTE, no fundido. Se probo el fundido y sale peor: superpone dos caras con
# la boca en posiciones distintas y deja un fantasma de seis fotogramas que
# parece un fallo de codificacion. Bajaba la metrica de salto de imagen de 24x
# la mediana a 6x, pero esa metrica no mide lo que se ve.
#
# El problema de fondo es que ninguna toma tiene cola muda: la presentadora
# habla hasta el ultimo fotograma porque el modelo estira la locucion hasta
# llenar la toma que se le pide. Con la boca abierta a ambos lados, ni el
# corte ni el fundido pueden ser invisibles.
#
# Lo que si funciona es que el corte PAREZCA intencionado: PUNCH_ALTERNO
# cierra el encuadre de las tomas pares un 9% y cada union pasa a ser un
# cambio de tamaño claro, que es el lenguaje normal de un reel.
export TRANSICION=${TRANSICION:-corte}
export PUNCH_ALTERNO=${PUNCH_ALTERNO:-1.09}

# VALIDAR atraviesa el runner real. No se llama a sd-cli.
if [ "${VALIDAR:-0}" = 1 ]; then
  VALIDAR=1 bash "$RUNNER" "$GUION" "$NOMBRE" "$FRAMES" "$ANCHO" "$ALTO" "$PASOS"
  exit $?
fi

bash "$RUNNER" "$GUION" "$NOMBRE" "$FRAMES" "$ANCHO" "$ALTO" "$PASOS" || exit $?
OBRA=$MD/produccion/obra/$NOMBRE
if [ -d "$OBRA" ]; then
  cp -n "$GUION" "$OBRA/entrada.guion" 2>/dev/null || cp "$GUION" "$OBRA/entrada.guion"
  if [ -f "$GUION.fuente.json" ]; then
    cp "$GUION.fuente.json" "$OBRA/fuente.json"
  fi
fi

ESTADO=$MD/produccion/obra/$NOMBRE/estado.json
[ -f "$ESTADO" ] || { echo "no hay estado de obra en $ESTADO" >&2; exit 1; }
VIDEO=$(python3 - "$ESTADO" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(d.get("final") or "")
PY
)
[ -n "$VIDEO" ] && [ -f "$VIDEO" ] || {
  echo "la obra no publico un final revisable" >&2
  exit 1
}

REELOUT=${VIDEO%.mp4}-reel-1080x1920.mp4
# Subtitulos y escalado en UNA pasada. Antes se quemaban a 416x736 y despues
# se ampliaban 2,6x: el rotulo salia borroso por construccion, y costaba una
# generacion entera de x264 de mas.
CUES=$(mktemp -d "${TMPDIR:-/tmp}/reel-cues-XXXXXX") || exit 1
trap 'rm -rf "$CUES"' EXIT
# --alto 1920: la caja y el interlineado van en pixeles y el rotulo se pinta
# ya escalado. Sin decirlo, la caja quedaba pegada a las letras.
VF_SUBS=$(python3 "$SUBS" "$VIDEO" --guion "$GUION" --salida /dev/null \
            --solo-filtro --dir-textos "$CUES" --alto 1920) || exit $?
SUBS_VF="$VF_SUBS" bash "$EXPORT" "$VIDEO" "$REELOUT" || exit $?
rm -rf "$CUES"
trap - EXIT
echo "═══ REEL LISTO ═══"
echo "    montaje interno: $VIDEO"
echo "    reel 1080x1920 subtitulado: $REELOUT"
