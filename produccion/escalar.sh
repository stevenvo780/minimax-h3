#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ESCALAR — sube una pieza de 736x416 a 1080p con RealESRGAN x4.
#
#  Por que hacia falta: TODO se entregaba a 736x416, que en cualquier pantalla
#  se ve pobre. Steven lo dijo con esas palabras —"la calidad aun es muy
#  pobre"— y llevaba razon: la resolucion de generacion esta limitada por la
#  VRAM (el buffer crece con frames x pixeles), pero ESCALAR despues no compite
#  con la generacion.
#
#  Corre en la RTX 2060 (CUDA1), que estuvo parada toda la sesion mientras se
#  peleaba por memoria en la 5070 Ti. No toca la GPU donde se genera.
#
#  Uso:  escalar.sh <video.mp4> [salida.mp4]
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1
. "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh"
SDCLI=$(compat_sdcli) || { echo "no pude preparar sd-cli"; exit 1; }

IN=${1:?falta el video}
[ -f "$IN" ] || { echo "no existe: $IN"; exit 1; }
BASE=$(basename "$IN" .mp4)
OUT=${2:-$MD/videos/entregas/${BASE%%-[0-9]*x[0-9]*-*}-1080p.mp4}
W=$(ffp -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$IN")
H=$(ffp -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")
N=$(ffp -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$IN" 2>/dev/null)
echo "═══ escalando $BASE · ${W}x${H} · ${N:-?} fotogramas ═══"

T=$(mktemp -d "${TMPDIR:-/tmp}/escala-XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/in" "$T/out"
ff -v error -i "$IN" "$T/in/%05d.png" || { echo "FALLO extrayendo fotogramas"; exit 1; }
TOT=$(ls -1 "$T/in" | wc -l)
echo "  $TOT fotogramas extraidos, escalando en la RTX 2060..."

i=0; fallos=0
for f in "$T/in"/*.png; do
  i=$((i+1))
  sd_upscale "$f" "$T/out/$(basename "$f")" CUDA1 512 >/dev/null 2>&1 || fallos=$((fallos+1))
  [ $((i % 100)) = 0 ] && echo "    $i/$TOT"
done
HECHOS=$(ls -1 "$T/out" 2>/dev/null | wc -l)
echo "  escalados $HECHOS de $TOT (fallos: $fallos)"
[ "$HECHOS" -lt "$TOT" ] && { echo "FALLO: faltan fotogramas, no monto un video incompleto"; exit 1; }

FPS=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$IN" | head -1)
# a 1080p de altura, manteniendo la proporcion y con ancho par
ff -y -v error -framerate "${FPS:-24}" -i "$T/out/%05d.png" -i "$IN" \
   -map 0:v -map 1:a? -vf "scale=-2:1080:flags=lanczos" \
   -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -c:a copy -shortest "$OUT" \
  || { echo "FALLO montando"; exit 1; }
RES=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT")
echo "═══ LISTO: $OUT ($RES) ═══"
