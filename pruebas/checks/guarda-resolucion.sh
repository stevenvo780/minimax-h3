#!/bin/bash
CHECK="guarda-resolucion"
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
WORK=""
fallar() {
  echo "FALLA $CHECK: $1"
  [ -n "$WORK" ] && echo "  (material de la prueba conservado en $WORK)"
  exit 1
}

PRODUCIR="$RAIZ/produccion/producir.sh"
[ -f "$PRODUCIR" ] || fallar "no existe $PRODUCIR"

WORK=$(mktemp -d /tmp/guarda-resolucion.XXXXXX) || fallar "no se pudo crear directorio temporal"

# No hay ffmpeg/ffprobe reales en esta maquina -> stubs minimos en PATH.
# ffmpeg: "copia" el contenido del origen (tras -i) al destino (ultimo arg),
#         igual que el ffmpeg real preserva WxH cuando no hay -vf scale.
# ffprobe: si le piden width,height, lee esa "resolucion" del contenido del
#          fichero (que este check escribio ahi mismo); si piden duration,
#          devuelve un numero fijo. Asi el guarda de producir.sh, que llama
#          a ffprobe de verdad, opera sobre datos que controlamos.
STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/ffmpeg" <<'STUB'
#!/bin/bash
src=""; prev=""; dst=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; dst="$a"
done
mkdir -p "$(dirname "$dst")" 2>/dev/null
if [ -n "$src" ] && [ -f "$src" ]; then
  cp "$src" "$dst" 2>/dev/null || : > "$dst"
else
  : > "$dst"
fi
exit 0
STUB
cat > "$STUBBIN/ffprobe" <<'STUB'
#!/bin/bash
f="${@: -1}"
case "$*" in
  *width,height*) cat "$f" 2>/dev/null || echo "0,0" ;;
  *) echo "4.4583" ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/ffmpeg" "$STUBBIN/ffprobe" \
  || fallar "no se pudieron crear los stubs de ffmpeg/ffprobe"
[ -x "$STUBBIN/ffmpeg" ] && [ -x "$STUBBIN/ffprobe" ] \
  || fallar "los stubs de ffmpeg/ffprobe no quedaron ejecutables"

export PATH="$STUBBIN:$PATH"

# Simula una "produccion": 1 plano HABLA ya generado (se salta sd-cli) + 1
# BROLL externo, cada uno con una "resolucion" (contenido "W,H") elegida por
# el caso. MD/DEST se sobrescriben via entorno para que producir.sh escriba
# TODO bajo /tmp.
correr_caso() {
  local caso=$1 dim_h=$2 dim_b=$3
  MDFAKE=$WORK/raiz-$caso
  MONTAJE=$MDFAKE/produccion/obra/$caso/montaje
  local OBRA=$MDFAKE/produccion/obra/$caso
  mkdir -p "$OBRA"
  printf '%s' "$dim_h" > "$OBRA/p01.avi"
  local BROLL=$WORK/broll-$caso.avi
  printf '%s' "$dim_b" > "$BROLL"
  local GUION=$WORK/$caso.guion
  {
    echo "@ESCENA escena de prueba"
    echo "@AMBIENTE silencio"
    echo "@MUSICA ninguna"
    echo "HABLA|hola|"
    echo "BROLL|$BROLL|"
  } > "$GUION"
  SALIDA=$(MD="$MDFAKE" DEST="$WORK/dest-$caso" bash "$PRODUCIR" "$GUION" "$caso" 2>&1)
  CODIGO=$?
}

# Autocomprobacion del montaje: si el escenario ni siquiera llego a producir
# los 2 clips que van al concat, cualquier veredicto sobre el guarda seria
# una atribucion falsa. Se diagnostica aparte, con su propio mensaje.
exigir_montaje() {   # $1=caso  $2=dim clip1 esperada  $3=dim clip2 esperada
  local caso=$1 esp1=$2 esp2=$3
  local n; n=$(find "$MONTAJE" -maxdepth 1 -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "2" ] || fallar "el escenario '$caso' no llego al concat: se esperaban 2 clips en $MONTAJE y hay $n. NO se ha podido evaluar el guarda de resolucion (cola de salida: $(printf '%s\n' "$SALIDA" | tail -6))"
  local d1 d2
  d1=$(cat "$MONTAJE/01.mp4" 2>/dev/null); d2=$(cat "$MONTAJE/02.mp4" 2>/dev/null)
  [ "$d1" = "$esp1" ] && [ "$d2" = "$esp2" ] \
    || fallar "el montaje del caso '$caso' no tiene las resoluciones que este check monto (esperado '$esp1'/'$esp2', obtenido '$d1'/'$d2'): el escenario no es valido"
}

hay_mp4_final() {   # $1=caso
  [ -d "$WORK/dest-$1" ] && [ -n "$(find "$WORK/dest-$1" -name '*.mp4' 2>/dev/null)" ]
}

# -- Caso 1: plano (1376x768) y BROLL (640x360) con resoluciones distintas
#    -> debe abortar SIN generar el .mp4 final, con exit 1 y el mensaje.
correr_caso "mismatch" "1376,768" "640,360"
exigir_montaje "mismatch" "1376,768" "640,360"

if hay_mp4_final "mismatch"; then
  fallar "con 1376x768 y 640x360 mezclados se genero igualmente el .mp4 final ($(find "$WORK/dest-mismatch" -name '*.mp4')): es EXACTAMENTE el fichero corrupto sin error que el guarda debia impedir"
fi
[ "$CODIGO" -eq 1 ] \
  || fallar "con resoluciones mezcladas el codigo de salida fue $CODIGO, se esperaba 1 (cola de salida: $(printf '%s\n' "$SALIDA" | tail -6))"
printf '%s\n' "$SALIDA" | grep -q "los clips NO comparten resolucion" \
  || fallar "aborto con codigo 1 pero SIN el mensaje del guarda de resolucion: el abort puede venir de otra causa (cola de salida: $(printf '%s\n' "$SALIDA" | tail -6))"

# -- Caso 2 (control): plano y BROLL a la MISMA resolucion (1376x768)
#    -> el guarda NO debe dispararse y el montaje debe completarse.
correr_caso "match" "1376,768" "1376,768"
exigir_montaje "match" "1376,768" "1376,768"

if printf '%s\n' "$SALIDA" | grep -q "los clips NO comparten resolucion"; then
  fallar "con resoluciones iguales el guarda disparo un falso positivo"
fi
[ "$CODIGO" -eq 0 ] \
  || fallar "con resoluciones iguales producir.sh no debio fallar (codigo $CODIGO, cola de salida: $(printf '%s\n' "$SALIDA" | tail -8))"
hay_mp4_final "match" \
  || fallar "con resoluciones iguales no se genero el .mp4 final esperado en $WORK/dest-match"

rm -rf "$WORK"
echo "PASA $CHECK"
exit 0