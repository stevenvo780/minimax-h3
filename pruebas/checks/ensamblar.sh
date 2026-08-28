#!/bin/bash
set -u
NOMBRE="ensamblar"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"

FALLAR() { echo "FALLA $NOMBRE: $1"; exit 1; }

SCRIPT="$RAIZ/proyecto-minuto/ensamblar.sh"
[ -f "$SCRIPT" ] || FALLAR "no encuentro $SCRIPT"

WORK=$(mktemp -d /tmp/chk-ensamblar.XXXXXX) || FALLAR "no pude crear directorio temporal"
trap 'rm -rf "$WORK"' EXIT

# ─────────────────────────────────────────────────────────────────────────
# PARTE A: ejecucion real del script (sin tocar el repo) con:
#   - N=8 planos "existentes" -> solo deben generarse rotulos para
#     los planos <= 8 (1,3,5,7,8) y omitirse los de 12 y 14.
#   - FRAMES/FPS propios -> DUR debe derivarse de ellos, no ser
#     la constante magica vieja (4.458333).
#   - fuente primaria ausente en esta maquina -> debe caer a una
#     alternativa existente.
# ffmpeg/ffprobe se stubean: no hay ffmpeg real en esta maquina.
# ─────────────────────────────────────────────────────────────────────────

MDROOT="$WORK/proyecto"
mkdir -p "$MDROOT/proyecto-minuto/shots"
DESTDIR="$WORK/dest"
mkdir -p "$DESTDIR"

for i in 1 2 3 4 5 6 7 8; do
  printf 'AVI-FALSO-%d' "$i" > "$MDROOT/proyecto-minuto/shots/s$(printf '%02d' "$i").avi"
done

BIN="$WORK/bin"; mkdir -p "$BIN"
FFDIR="$WORK/ffcalls"; mkdir -p "$FFDIR"

# stub de ffmpeg: registra CADA invocacion en un fichero propio, un argumento
# por linea (asi el valor de -vf se puede leer exacto, sin re-parsear nada)
cat > "$BIN/ffmpeg" <<'EOSTUB'
#!/bin/bash
REG=$(mktemp "$FFDIR/call.XXXXXX")
printf '%s\n' "$@" > "$REG"
SALIDA=""; for a in "$@"; do SALIDA="$a"; done
if grep -qxF -- '-vf' "$REG"; then
  printf 'FINAL-CON-OVERLAY' > "$SALIDA"
elif grep -qxF -- 'concat' "$REG"; then
  printf 'BRUTO-CONCAT' > "$SALIDA"
else
  printf 'NORM' > "$SALIDA"
fi
exit 0
EOSTUB
chmod +x "$BIN/ffmpeg"

cat > "$BIN/ffprobe" <<'EOSTUB'
#!/bin/bash
echo "duration=1.000000"
echo "size=100"
exit 0
EOSTUB
chmod +x "$BIN/ffprobe"

# fuente esperada segun el mismo orden que usa el script (calculada en vivo,
# no asumida, para que el check no dependa de la maquina donde corra)
PRIMARIA=/usr/share/fonts/noto/NotoSerif-Regular.ttf
ALT1=/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf
ALT2=/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf
if [ -f "$PRIMARIA" ]; then ESPERADA="$PRIMARIA"; ESPERA_FALLBACK=0
elif [ -f "$ALT1" ]; then ESPERADA="$ALT1"; ESPERA_FALLBACK=1
elif [ -f "$ALT2" ]; then ESPERADA="$ALT2"; ESPERA_FALLBACK=1
else ESPERADA=""; ESPERA_FALLBACK=-1
fi
[ "$ESPERA_FALLBACK" -eq -1 ] && FALLAR "entorno inesperado: ni la fuente primaria ni ninguna alternativa existen, no puedo validar el fallback de fuente"

DUR_ESPERADA=$(awk 'BEGIN{printf "%.6f", 100/24}')

OUT=$(MD="$MDROOT" DEST="$DESTDIR" FRAMES=100 FPS=24 W=640 H=360 \
      PATH="$BIN:$PATH" FFDIR="$FFDIR" \
      bash "$SCRIPT" 2>&1)
RC=$?

[ "$RC" -eq 0 ] || FALLAR "el script salio con codigo $RC. Salida:
$OUT"

echo "$OUT" | grep -qF "planos disponibles: 8" \
  || FALLAR "no reporto los 8 planos disponibles. Salida:
$OUT"

echo "$OUT" | grep -qF "duración por plano: $DUR_ESPERADA s (de 100 frames a 24 fps)" \
  || FALLAR "DUR no se derivo de FRAMES/FPS (100/24 -> $DUR_ESPERADA). Salida:
$OUT"
# si siguiera hardcodeado en 4.458333 (107/24, la constante vieja) esto lo detecta:
echo "$OUT" | grep -qF "4.458333" \
  && FALLAR "aparece la constante magica vieja 4.458333 en la salida"

# guard estructural: en una maquina donde la fuente PRIMARIA si exista, la
# comprobacion dinamica de abajo no se dispara, asi que el fallback se
# verifica ademas sobre el propio fichero.
grep -qF 'usando alternativa' "$SCRIPT" \
  || FALLAR "no cayo a la fuente alternativa esperada: el script ya no busca fuentes alternativas"
if [ "$ESPERA_FALLBACK" -eq 1 ]; then
  echo "$OUT" | grep -qF "usando alternativa: $ESPERADA" \
    || FALLAR "no cayo a la fuente alternativa esperada ($ESPERADA). Salida:
$OUT"
fi

for p in 12 14; do
  echo "$OUT" | grep -qF "omitiendo rótulo del plano $p (no existe)" \
    || FALLAR "no omitio el rotulo del plano $p, que no deberia existir con N=8. Salida:
$OUT"
done
for p in 1 3 5 7 8; do
  echo "$OUT" | grep -qF "omitiendo rótulo del plano $p " \
    && FALLAR "omitio el rotulo del plano $p, que SI deberia existir con N=8"
done

# localizar la invocacion de ffmpeg que lleva -vf y extraer el argumento
# EXACTO que se le paso como cadena de filtros (la linea siguiente a "-vf")
VF=""
VF_HALLADO=0
for reg in "$FFDIR"/call.*; do
  [ -f "$reg" ] || continue
  grep -qxF -- '-vf' "$reg" || continue
  VF_HALLADO=1
  VF=$(awk 'encontrado{print; exit} /^-vf$/{encontrado=1}' "$reg")
  break
done
[ "$VF_HALLADO" -eq 1 ] || FALLAR "no se registro ninguna llamada a ffmpeg con -vf"
[ -n "$VF" ] || FALLAR "se invoco ffmpeg con -vf VACIO (era justo lo que habia que evitar)"

case "$VF" in
  ,*|*,) FALLAR "la cadena de filtros empieza o acaba en coma (rotulos omitidos dejaron huecos): [$VF]" ;;
  *,,*)  FALLAR "la cadena de filtros tiene una coma doble (rotulo omitido dejo un hueco): [$VF]" ;;
esac

N_DRAWTEXT=$(printf '%s' "$VF" | grep -oF 'drawtext=' | wc -l)
[ "$N_DRAWTEXT" -eq 5 ] \
  || FALLAR "esperaba 5 drawtext (planos 1,3,5,7,8) y hay $N_DRAWTEXT: [$VF]"

for txt in "La existencia precede a la esencia" "Estamos condenados a ser libres" \
           "El infierno son los otros" "La lucha misma basta para llenar un corazón" \
           "Buscamos sentido, y el mundo calla"; do
  printf '%s' "$VF" | grep -qF "$txt" \
    || FALLAR "falta el rotulo esperado '$txt' en el filtro -vf (plano deberia existir con N=8)"
done
for txt in "Somos lo que hacemos con lo que hicieron de nosotros" "Hay que imaginar a Sísifo dichoso"; do
  printf '%s' "$VF" | grep -qF "$txt" \
    && FALLAR "aparece el rotulo '$txt' en -vf pese a que su plano (12/14) no existe con N=8"
done

printf '%s' "$VF" | grep -qF "fontfile=$ESPERADA" \
  || FALLAR "el filtro -vf no usa la fuente esperada ($ESPERADA)"

FINAL_A=$(find "$DESTDIR" -name 'existencialismo-1min-640x360-*.mp4' 2>/dev/null | head -n1)
[ -n "$FINAL_A" ] || FALLAR "no se genero el fichero final esperado en $DESTDIR"
[ "$(cat "$FINAL_A")" = "FINAL-CON-OVERLAY" ] \
  || FALLAR "el final con rotulos presentes debio pasar por ffmpeg -vf, no coincide el contenido"

# ─────────────────────────────────────────────────────────────────────────
# PARTE B: si ningun rotulo aplicara (FILTROS_ARR vacio), el script debe
# copiar el bruto en vez de invocar ffmpeg con -vf "". Se extrae el bloque
# if/else/fi TAL CUAL esta en el fichero real (no se reescribe la logica)
# y se ejecuta dos veces: con FILTROS_ARR vacio y con FILTROS_ARR lleno.
# ─────────────────────────────────────────────────────────────────────────

# se incluye desde "STAMP=" (donde nace $FINAL) hasta el "fi" del bloque,
# para que $FINAL quede definido exactamente como en el fichero real
BLOQUE=$(sed -n '/^STAMP=/,/^fi$/p' "$SCRIPT")
[ -n "$BLOQUE" ] || FALLAR "no encontre el bloque de fallback (cp bruto) en $SCRIPT: ¿cambio el codigo?"
printf '%s' "$BLOQUE" | grep -qF 'cp "$TMP/bruto.mp4"' \
  || FALLAR "no encontre el bloque de fallback (cp bruto) en $SCRIPT: el sed no capturo un cp de bruto.mp4"
printf '%s' "$BLOQUE" | grep -qF 'ff -y' \
  || FALLAR "el bloque extraido no contiene la llamada ff -y esperada; el sed no capturo lo correcto"
printf '%s' "$BLOQUE" | grep -qF 'FILTROS_ARR[@]' \
  || FALLAR "el bloque de salida no decide segun el numero de rotulos (FILTROS_ARR): se pasaria -vf aunque no haya ninguno"

# --- B1: FILTROS_ARR vacio -> debe copiar el bruto y NO llamar a ff ---
WORK2="$WORK/parteB1"; mkdir -p "$WORK2/dest2"
printf 'BRUTO-MARCA' > "$WORK2/bruto.mp4"
{
  echo 'set -u'
  echo 'FILTROS_ARR=()'
  printf 'ff() { echo "FF_LLAMADO:$*" >> %q; SAL=""; for a in "$@"; do SAL="$a"; done; printf "FF-HIZO-EL-FINAL" > "$SAL"; }\n' "$WORK2/ff_called.marker"
  printf '%s\n' "$BLOQUE"
} > "$WORK2/parteB.sh"

OUT_B=$(TMP="$WORK2" DEST="$WORK2/dest2" W=1 H=1 FILTROS="no-deberia-usarse-nunca" \
        bash "$WORK2/parteB.sh" 2>&1)
RC_B=$?

[ "$RC_B" -eq 0 ] || FALLAR "la rama de fallback (bloque real) fallo con codigo $RC_B. Salida:
$OUT_B"

[ -f "$WORK2/ff_called.marker" ] \
  && FALLAR "con FILTROS_ARR vacio igual se invoco ff (se habria pasado -vf \"\" a ffmpeg)"

echo "$OUT_B" | grep -qF "ningun rotulo aplicable" \
  || FALLAR "la rama de fallback no imprimio el aviso de 'ningun rotulo aplicable'. Salida:
$OUT_B"

FINAL_B=$(find "$WORK2/dest2" -name 'existencialismo-1min-1x1-*.mp4' 2>/dev/null | head -n1)
[ -n "$FINAL_B" ] || FALLAR "la rama de fallback no genero ningun fichero final en $WORK2/dest2"
[ "$(cat "$FINAL_B")" = "BRUTO-MARCA" ] \
  || FALLAR "el fichero final de la rama de fallback no es una copia exacta del bruto"

# --- B2: FILTROS_ARR con rotulos -> SI debe llamar a ff (no copiar el bruto) ---
WORK3="$WORK/parteB2"; mkdir -p "$WORK3/dest2"
printf 'BRUTO-MARCA' > "$WORK3/bruto.mp4"
{
  echo 'set -u'
  echo 'FILTROS_ARR=("drawtext=uno" "drawtext=dos")'
  printf 'ff() { echo "FF_LLAMADO:$*" >> %q; SAL=""; for a in "$@"; do SAL="$a"; done; printf "FF-HIZO-EL-FINAL" > "$SAL"; }\n' "$WORK3/ff_called.marker"
  printf '%s\n' "$BLOQUE"
} > "$WORK3/parteB.sh"

OUT_B2=$(TMP="$WORK3" DEST="$WORK3/dest2" W=1 H=1 FILTROS="drawtext=uno,drawtext=dos" \
         bash "$WORK3/parteB.sh" 2>&1)
RC_B2=$?

[ "$RC_B2" -eq 0 ] || FALLAR "con rotulos presentes el bloque real fallo con codigo $RC_B2. Salida:
$OUT_B2"
[ -f "$WORK3/ff_called.marker" ] \
  || FALLAR "con FILTROS_ARR NO vacio no se invoco ff: el 'arreglo' copia el bruto siempre y nunca sobreimprime"
grep -qF -- '-vf drawtext=uno,drawtext=dos' "$WORK3/ff_called.marker" \
  || FALLAR "la llamada a ff no recibio la cadena de filtros esperada. Registro:
$(cat "$WORK3/ff_called.marker")"

FINAL_B2=$(find "$WORK3/dest2" -name 'existencialismo-1min-1x1-*.mp4' 2>/dev/null | head -n1)
[ -n "$FINAL_B2" ] || FALLAR "con rotulos presentes no se genero ningun fichero final en $WORK3/dest2"
[ "$(cat "$FINAL_B2")" = "FF-HIZO-EL-FINAL" ] \
  || FALLAR "con rotulos presentes el final no lo produjo ff (contenido inesperado)"

echo "PASA $NOMBRE"
exit 0