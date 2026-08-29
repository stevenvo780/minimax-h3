#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="nivel-luminancia"
exec 0</dev/null

# ── Por que existe ────────────────────────────────────────────────────────
# El modelo, al re-anclar en una escena oscura, devuelve una toma mas CLARA que
# la de partida: en 'paisaje' la toma 2 salio un 50% mas clara que la 1 y se veia
# como si alguien subiera las luces a mitad de pieza.
#
# Lo que lo hacia dificil de ver: ese escalon se DISFRAZA de perdida de calidad.
# La pieza medida sin corregir daba +38% de energia de bordes entre tomas, que
# parece realce acumulado; igualando solo la luminancia cae a -7.1%. No habia
# nada mas nitido, solo mas claro.
#
# Contrato: la ganancia esta acotada (una medicion loca no puede arrasar una toma
# buena), vale 1 cuando no se puede medir, y corrige en el sentido correcto.

. "$RAIZ/lib/comun.sh" 2>/dev/null || { echo "FALLA $nombre: no pude cargar comun.sh"; exit 1; }
for fn in luminancia_mediana ganancia_nivel; do
  declare -F "$fn" >/dev/null || { echo "FALLA $nombre: falta $fn()"; exit 1; }
done
command -v ffmpeg >/dev/null || { echo "SALTA $nombre (sin ffmpeg)"; exit 0; }

T=$(mktemp -d /tmp/chk-nivel.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
fallos=0

# Dos clips identicos salvo por el brillo: uno al 100% y otro al 50%.
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=320x240:rate=24:duration=2" \
  -c:v mjpeg -q:v 2 "$T/claro.avi" 2>/dev/null
ffmpeg -nostdin -y -v error -i "$T/claro.avi" -vf "lutyuv=y=val*0.5" \
  -c:v mjpeg -q:v 2 "$T/oscuro.avi" 2>/dev/null
[ -s "$T/claro.avi" ] && [ -s "$T/oscuro.avi" ] || { echo "SALTA $nombre (no pude crear los clips)"; exit 0; }

yc=$(luminancia_mediana "$T/claro.avi"); yo=$(luminancia_mediana "$T/oscuro.avi")
if [ -z "$yc" ] || [ -z "$yo" ]; then
  echo "FALLA $nombre: luminancia_mediana no midio ($yc / $yo)"; fallos=1
elif ! awk -v a="$yo" -v b="$yc" 'BEGIN{exit !(a < b)}'; then
  echo "FALLA $nombre: el clip oscuro ($yo) no midio menos que el claro ($yc)"; fallos=1
fi

# Corregir el oscuro hacia el claro pide ganancia > 1; al reves, < 1.
gsube=$(ganancia_nivel "$T/oscuro.avi" "$T/claro.avi")
gbaja=$(ganancia_nivel "$T/claro.avi" "$T/oscuro.avi")
awk -v g="$gsube" 'BEGIN{exit !(g>1.05)}' || { echo "FALLA $nombre: subir el oscuro dio ganancia $gsube (esperaba >1)"; fallos=1; }
awk -v g="$gbaja" 'BEGIN{exit !(g<0.95)}' || { echo "FALLA $nombre: bajar el claro dio ganancia $gbaja (esperaba <1)"; fallos=1; }

# Proporcionalidad, con una diferencia que NO toca los topes: un clip al 75%
# de brillo debe pedir una ganancia de ~1.333 para volver al original.
ffmpeg -nostdin -y -v error -i "$T/claro.avi" -vf "lutyuv=y=val*0.75" \
  -c:v mjpeg -q:v 2 "$T/medio.avi" 2>/dev/null
if [ -s "$T/medio.avi" ]; then
  gm=$(ganancia_nivel "$T/medio.avi" "$T/claro.avi")
  awk -v g="$gm" 'BEGIN{exit !(g>1.15 && g<1.55)}' || {
    echo "FALLA $nombre: un clip al 75% pidio ganancia $gm, esperaba ~1.33"; fallos=1; }
fi

# Acotada a [0.5, 2.0]: ni un caso extremo puede arrasar una toma.
ffmpeg -nostdin -y -v error -i "$T/claro.avi" -vf "lutyuv=y=val*0.05" \
  -c:v mjpeg -q:v 2 "$T/negro.avi" 2>/dev/null
if [ -s "$T/negro.avi" ]; then
  gx=$(ganancia_nivel "$T/negro.avi" "$T/claro.avi")
  awk -v g="$gx" 'BEGIN{exit !(g<=2.0 && g>=0.5)}' || {
    echo "FALLA $nombre: ganancia $gx fuera de [0.5, 2.0] en un caso extremo"; fallos=1; }
fi

# Si no se puede medir, vale 1 (no tocar) en vez de romper el montaje.
gnada=$(ganancia_nivel "$T/no-existe.avi" "$T/claro.avi" 2>/dev/null)
[ "$gnada" = "1" ] || { echo "FALLA $nombre: con un fichero inexistente dio '$gnada', esperaba 1"; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre (sube=$gsube baja=$gbaja medio=${gm:-n/a})"
exit $fallos
