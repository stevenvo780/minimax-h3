#!/bin/bash
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="ordenar-seguro"
SCRIPT=$RAIZ/herramientas/ordenar-videos.sh
exec 0</dev/null

fallar() {
  echo "FALLA $nombre: $*"
  exit 1
}

[ -f "$SCRIPT" ] || fallar "no existe $SCRIPT"

T=$(mktemp -d /tmp/chk-ordenar-seguro.XXXXXX) || fallar "no pude crear tmpdir"
trap 'rm -rf "$T"' EXIT
V=$T/videos
ARCH=$T/archivo-recuperable
mkdir -p "$V" || fallar "no pude preparar la carpeta de prueba"

firmar() {
  python3 "$RAIZ/lib/estado_obra.py" write-fingerprint \
    "$1.minimax-h3.json" \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --artifact "$1" >/dev/null || fallar "no pude firmar $1"
}

# Dos salidas del mismo proyecto: el sello del nombre y el mtime están
# invertidos para demostrar que se conserva la realmente más reciente.
BUENA=existencialismo-4p-736x416-58s-20260829-120000.mp4
ANTERIOR=existencialismo-4p-736x416-58s-20260830-120000.mp4
CADENA=cadena-1376x768-15.5s-20260828-091011.mp4
ESCALADO=h3-1080p-2.3s-20260828-101112.mp4
MINUTO=existencialismo-1min-640x360-20260828-111213.mp4
H3=h3-20260828-121314.mp4.avi

printf 'pieza-conservada\n' > "$V/$BUENA"
printf 'pieza-anterior\n' > "$V/$ANTERIOR"
printf 'cadena\n' > "$V/$CADENA"
printf 'escalado\n' > "$V/$ESCALADO"
printf 'minuto\n' > "$V/$MINUTO"
printf 'h3-real\n' > "$V/$H3"
for salida in "$BUENA" "$ANTERIOR" "$CADENA" "$ESCALADO" "$MINUTO" "$H3"; do
  firmar "$V/$salida"
done
touch -t 202608301500 "$V/$BUENA"
touch -t 202608291500 "$V/$ANTERIOR"

# Elementos que el archivador antiguo confundía con salidas: un directorio,
# un enlace con nombre válido y sufijos capturados por globs demasiado amplios.
PERSONAL=vacaciones-familia.mp4
PERSONAL_1MIN=vacaciones-1min-familia.mp4
PERSONAL_UNICODE=José-736x416-14s-20260830-123456.mp4
SUFIJO=h3-20260828-131415.mp4-recuerdo
DIR=existencialismo-4p-640x360-9s-20260830-150001.mp4
LINK=existencialismo-4p-640x360-8s-20260830-150002.mp4
printf 'video-personal\n' > "$V/$PERSONAL"
printf 'otro-video-personal\n' > "$V/$PERSONAL_1MIN"
printf 'video-personal-unicode\n' > "$V/$PERSONAL_UNICODE"
printf 'no-es-salida\n' > "$V/$SUFIJO"
mkdir "$V/$DIR"
ln -s "$V/$PERSONAL" "$V/$LINK"

# La simulación no crea el archivo, no mueve nada y tampoco presenta los
# elementos peligrosos como seleccionados.
SIM=$T/simulacion.log
if ! DEST="$V" ARCHIVO_DEST="$ARCH" bash "$SCRIPT" existencialismo-4p > "$SIM" 2>&1; then
  fallar "la simulación falló: $(tail -1 "$SIM")"
fi
[ ! -e "$ARCH" ] || fallar "la simulación creó la carpeta de archivo"
[ -f "$V/$ANTERIOR" ] || fallar "la simulación movió una salida"
[ -d "$V/$DIR" ] || fallar "la simulación movió el directorio personal"
[ -L "$V/$LINK" ] || fallar "la simulación movió el enlace simbólico"
grep -qF "se CONSERVA a la vista: $BUENA" "$SIM" \
  || fallar "la simulación no preservó la salida regular más reciente"
for peligro in "$PERSONAL" "$PERSONAL_1MIN" "$PERSONAL_UNICODE" "$SUFIJO" "$DIR" "$LINK"; do
  grep -qF "$peligro" "$SIM" \
    && fallar "la simulación seleccionó el elemento no válido '$peligro'"
done

# La ejecución mueve exclusivamente las salidas válidas a la ubicación
# configurable y deja la pieza reciente y todos los elementos personales.
EJEC=$T/ejecucion.log
if ! DEST="$V" ARCHIVO_DEST="$ARCH" bash "$SCRIPT" --hazlo existencialismo-4p > "$EJEC" 2>&1; then
  fallar "la ejecución falló: $(tail -1 "$EJEC")"
fi
[ -f "$V/$BUENA" ] || fallar "no conservó la salida más reciente"
[ ! -e "$ARCH/$BUENA" ] || fallar "archivó la salida que debía conservar"
for salida in "$ANTERIOR" "$CADENA" "$ESCALADO" "$MINUTO" "$H3"; do
  [ ! -e "$V/$salida" ] || fallar "no movió la salida válida '$salida'"
  [ -f "$ARCH/$salida" ] || fallar "la salida '$salida' no quedó recuperable"
  [ -f "$ARCH/$salida.minimax-h3.json" ] \
    || fallar "el manifiesto de '$salida' no se archivó junto al vídeo"
done
[ "$(cat "$ARCH/$ANTERIOR")" = pieza-anterior ] \
  || fallar "el archivo no preservó el contenido de la salida movida"
[ -f "$V/$PERSONAL" ] || fallar "movió o borró el vídeo personal"
[ -f "$V/$PERSONAL_1MIN" ] || fallar "confundió un nombre personal con la salida de un minuto"
[ -f "$V/$PERSONAL_UNICODE" ] || fallar "aceptó un prefijo Unicode como salida de pipeline"
[ -f "$V/$SUFIJO" ] || fallar "aceptó una extensión con sufijo desconocido"
[ -d "$V/$DIR" ] || fallar "movió el directorio con nombre de salida"
[ -L "$V/$LINK" ] || fallar "movió el enlace con nombre de salida"
[ "$(readlink "$V/$LINK")" = "$V/$PERSONAL" ] || fallar "alteró el enlace simbólico"
[ "$(cat "$V/$PERSONAL")" = video-personal ] || fallar "alteró el vídeo personal"

# Una colisión en la carpeta recuperable nunca sobrescribe ni elimina: se
# informa como error y ambos ejemplares permanecen donde estaban.
V2=$T/videos-colision
ARCH2=$T/archivo-colision
mkdir -p "$V2" "$ARCH2"
KEEP2=existencialismo-4p-640x360-10s-20260828-141516.mp4
OLD2=otra-640x360-10s-20260828-141515.mp4
printf 'conservar\n' > "$V2/$KEEP2"
printf 'origen\n' > "$V2/$OLD2"
printf 'archivo-previo\n' > "$ARCH2/$OLD2"
firmar "$V2/$KEEP2"
firmar "$V2/$OLD2"
if DEST="$V2" ARCHIVO_DEST="$ARCH2" bash "$SCRIPT" --hazlo existencialismo-4p > "$T/colision.log" 2>&1; then
  fallar "una colisión en el archivo terminó con código de éxito"
fi
[ "$(cat "$V2/$OLD2")" = origen ] || fallar "la colisión eliminó el fichero de origen"
[ "$(cat "$ARCH2/$OLD2")" = archivo-previo ] || fallar "la colisión sobrescribió el archivo previo"

# Sin filtro no hay un proyecto histórico implícito: se conserva la salida más
# reciente de todo el directorio.
V3=$T/videos-sin-filtro
mkdir -p "$V3"
NUEVA=nueva-736x416-10s-20260830-160000.mp4
VIEJA=vieja-736x416-10s-20260830-150000.mp4
printf 'nueva\n' > "$V3/$NUEVA"
printf 'vieja\n' > "$V3/$VIEJA"
firmar "$V3/$NUEVA"
firmar "$V3/$VIEJA"
touch -t 202608301600 "$V3/$NUEVA"
touch -t 202608301500 "$V3/$VIEJA"
DEST="$V3" ARCHIVO_DEST="$T/archivo-sin-filtro" bash "$SCRIPT" > "$T/sin-filtro.log" \
  || fallar "la simulación sin filtro falló"
grep -qF "se CONSERVA a la vista: $NUEVA" "$T/sin-filtro.log" \
  || fallar "sin filtro no conservó la salida global más reciente"

echo "ok $nombre (simulación y ejecución aisladas; sólo archivos regulares firmados)"
