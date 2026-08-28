#!/bin/bash
# Ensambla los 14 planos: cortes duros de video (intencionales en un montaje),
# fundidos de audio por plano para suavizar el cambio de fondo musical,
# y frases sobreimpresas. NO regenera nada: solo monta.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
P=$MD/proyecto-minuto
FUENTE=/usr/share/fonts/noto/NotoSerif-Regular.ttf
TMP=$P/montaje; mkdir -p $TMP; rm -f $TMP/*.mp4 $TMP/lista.txt 2>/dev/null

# Verificar que la fuente existe, si no abortar inmediatamente
if [ ! -f "$FUENTE" ]; then
  echo "ERROR: fuente de texto no encontrada: $FUENTE"
  echo "  buscando alternativas..."
  for alt in /usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf /usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf; do
    if [ -f "$alt" ]; then
      echo "  usando alternativa: $alt"
      FUENTE="$alt"
      break
    fi
  done
  [ ! -f "$FUENTE" ] && { echo "  no hay fuente disponible, abortando"; exit 1; }
fi

# Derivar DUR de FRAMES y FPS en lugar de constante mágica
DUR=$(awk "BEGIN{printf \"%.6f\", $FRAMES / $FPS}")
echo "duración por plano: $DUR s (de $FRAMES frames a $FPS fps)"

N=$(ls -1 $P/shots/s*.avi 2>/dev/null | wc -l)
echo "planos disponibles: $N"
[ "$N" -eq 0 ] && { echo "no hay planos"; exit 1; }

# 1) normalizar cada plano con fundido de audio en los extremos
for f in $P/shots/s*.avi; do
  b=$(basename "$f" .avi)
  ff -y -v error -i "$f" \
    -af "afade=t=in:st=0:d=0.30,afade=t=out:st=$(awk "BEGIN{print $DUR-0.30}"):d=0.30" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k \
    "$TMP/$b.mp4"
  echo "file '$TMP/$b.mp4'" >> $TMP/lista.txt
done

# 2) concatenar
ff -y -v error -f concat -safe 0 -i $TMP/lista.txt -c copy $TMP/bruto.mp4

# 3) frases sobreimpresas (plano -> texto), 3s centradas en cada plano
txt() {  # $1=n_plano  $2=texto
  local ini=$(awk "BEGIN{printf \"%.2f\", ($1-1)*$DUR+0.7}")
  local fin=$(awk "BEGIN{printf \"%.2f\", ($1-1)*$DUR+3.9}")
  printf "drawtext=fontfile=%s:text='%s':fontcolor=white@0.92:fontsize=38:x=(w-text_w)/2:y=h-h/6:box=1:boxcolor=black@0.35:boxborderw=18:enable='between(t\\,%s\\,%s)'" \
    "$FUENTE" "$2" "$ini" "$fin"
}

# Génerar rótulos solo para los planos que existen
declare -a ROTULOS
ROTULOS[1]="La existencia precede a la esencia"
ROTULOS[3]="Estamos condenados a ser libres"
ROTULOS[5]="El infierno son los otros"
ROTULOS[7]="La lucha misma basta para llenar un corazón"
ROTULOS[8]="Buscamos sentido, y el mundo calla"
ROTULOS[12]="Somos lo que hacemos con lo que hicieron de nosotros"
ROTULOS[14]="Hay que imaginar a Sísifo dichoso"

FILTROS_ARR=()
for plano in "${!ROTULOS[@]}"; do
  if [ "$plano" -le "$N" ]; then
    FILTROS_ARR+=("$(txt "$plano" "${ROTULOS[$plano]}")")
  else
    echo "  omitiendo rótulo del plano $plano (no existe)"
  fi
done
FILTROS=$(IFS=','; echo "${FILTROS_ARR[*]}")

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST"
FINAL="$DEST/existencialismo-1min-${W}x${H}-$STAMP.mp4"
if [ ${#FILTROS_ARR[@]} -eq 0 ]; then
  echo "  ningun rotulo aplicable: se entrega el montaje sin sobreimpresion"
  cp "$TMP/bruto.mp4" "$FINAL"
else
  ff -y -v error -i $TMP/bruto.mp4 -vf "$FILTROS" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a copy "$FINAL"
fi
[ ! -f "$FINAL" ] && { echo "FALLO al sobreimprimir"; exit 1; }
echo "LISTO: $FINAL"
ffp -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
     -of default=noprint_wrappers=1 "$FINAL"
