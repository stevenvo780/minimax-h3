#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  EXPORTAR REEL — deja un MP4 9:16 listo para TikTok e Instagram.
#
#  La generacion nativa es 416x736 (mismo numero de pixeles que 736x416, que
#  es lo medido). Aqui se escala a 1080x1920, yuv420p, +faststart y loudnorm
#  a -14 LUFS (movil; el montaje interno sigue a -19).
#
#  No genera. No toca la GPU. No sobrescribe.
#
#  Uso:  exportar-reel.sh <entrada.mp4> [salida.mp4]
#  Entorno: ANCHO=1080 ALTO=1920 CRF=18
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1

IN=${1:?falta el video de entrada}
[ -f "$IN" ] || { echo "no existe: $IN" >&2; exit 1; }
[ -L "$IN" ] && { echo "no acepto un symlink como entrada: $IN" >&2; exit 1; }

ANCHO=${ANCHO:-1080}
ALTO=${ALTO:-1920}
CRF=${CRF:-18}
case "$ANCHO$ALTO$CRF" in
  *[!0-9]*) echo "ANCHO, ALTO y CRF deben ser enteros" >&2; exit 2 ;;
esac
[ "$ANCHO" -ge 320 ] && [ "$ALTO" -ge 320 ] || {
  echo "resolucion de export demasiado pequeña: ${ANCHO}x${ALTO}" >&2
  exit 2
}
# 9:16 con un margen de un pixel por redondeo (416x736 no es 9:16 exacto).
awk -v w="$ANCHO" -v h="$ALTO" 'BEGIN{
  r=w/h; t=9/16;
  if (r<t-0.02 || r>t+0.02) { exit 1 }
}' || {
  echo "el export tiene que ser 9:16 (recibido ${ANCHO}x${ALTO})" >&2
  exit 2
}

BASE=$(basename "$IN" .mp4)
OUT=${2:-$DEST/${BASE}-reel-${ANCHO}x${ALTO}.mp4}
case "$OUT" in
  *.mp4) : ;;
  *) echo "la salida tiene que terminar en .mp4" >&2; exit 2 ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  echo "la salida ya existe y no se sobrescribe: $OUT" >&2
  exit 1
fi

W=$(ffp -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$IN")
H=$(ffp -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")
[ -n "$W" ] && [ -n "$H" ] || { echo "ffprobe no pudo leer ${IN}" >&2; exit 1; }

DIR=$(dirname "$OUT")
mkdir -p "$DIR" || exit 1
TMP="$DIR/.exportando-reel-$$.mp4"
trap 'rm -f "$TMP"' EXIT

# Encaja en 9:16: escala cubriendo y recorta centro. Un plano de presentadora
# generado a 416x736 casi no recorta; un landscape heredado pierde laterales
# (mejor eso que franjas negras que delatan el 16:9 en el feed).
FILTRO="scale=${ANCHO}:${ALTO}:force_original_aspect_ratio=increase,crop=${ANCHO}:${ALTO},setsar=1"

echo "═══ export reel ${W}x${H} -> ${ANCHO}x${ALTO} ═══"
if ! ff -v error -i "$IN" \
    -vf "$FILTRO" \
    -c:v libx264 -preset medium -crf "$CRF" -pix_fmt yuv420p \
    -c:a aac -b:a 192k -ac 2 \
    -af "loudnorm=I=-14:TP=-1.5:LRA=11" \
    -movflags +faststart \
    -y "$TMP"
then
  echo "FALLO: ffmpeg no pudo exportar el reel" >&2
  exit 1
fi
[ -s "$TMP" ] || { echo "FALLO: el export quedo vacio" >&2; exit 1; }

RW=$(ffp -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$TMP")
RH=$(ffp -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$TMP")
[ "$RW" = "$ANCHO" ] && [ "$RH" = "$ALTO" ] || {
  echo "FALLO: el export salio ${RW}x${RH}, se pedia ${ANCHO}x${ALTO}" >&2
  exit 1
}

if ! mv -n -- "$TMP" "$OUT" || [ -e "$TMP" ] || [ ! -s "$OUT" ]; then
  echo "FALLO: no pude publicar $OUT" >&2
  exit 1
fi
trap - EXIT
echo "  $OUT"
