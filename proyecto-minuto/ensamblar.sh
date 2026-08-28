#!/bin/bash
# Ensambla los 14 planos: cortes duros de video (intencionales en un montaje),
# fundidos de audio por plano para suavizar el cambio de fondo musical,
# y frases sobreimpresas. NO regenera nada: solo monta.
set -u
P=/home/stev/Modelos-IA/minimax-h3/proyecto-minuto
DEST=/home/stev/Vídeos
FUENTE=/usr/share/fonts/noto/NotoSerif-Regular.ttf
TMP=$P/montaje; mkdir -p $TMP; rm -f $TMP/*.mp4 $TMP/lista.txt 2>/dev/null
DUR=4.458333   # 107 frames / 24 fps

N=$(ls -1 $P/shots/s*.avi 2>/dev/null | wc -l)
echo "planos disponibles: $N"
[ "$N" -eq 0 ] && { echo "no hay planos"; exit 1; }

# 1) normalizar cada plano con fundido de audio en los extremos
for f in $P/shots/s*.avi; do
  b=$(basename "$f" .avi)
  ffmpeg -y -v error -i "$f" \
    -af "afade=t=in:st=0:d=0.30,afade=t=out:st=$(awk "BEGIN{print $DUR-0.30}"):d=0.30" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k \
    "$TMP/$b.mp4"
  echo "file '$TMP/$b.mp4'" >> $TMP/lista.txt
done

# 2) concatenar
ffmpeg -y -v error -f concat -safe 0 -i $TMP/lista.txt -c copy $TMP/bruto.mp4

# 3) frases sobreimpresas (plano -> texto), 3s centradas en cada plano
txt() {  # $1=n_plano  $2=texto
  local ini=$(awk "BEGIN{printf \"%.2f\", ($1-1)*$DUR+0.7}")
  local fin=$(awk "BEGIN{printf \"%.2f\", ($1-1)*$DUR+3.9}")
  printf "drawtext=fontfile=%s:text='%s':fontcolor=white@0.92:fontsize=38:x=(w-text_w)/2:y=h-h/6:box=1:boxcolor=black@0.35:boxborderw=18:enable='between(t\\,%s\\,%s)'" \
    "$FUENTE" "$2" "$ini" "$fin"
}
FILTROS=$(cat <<EOF
$(txt 1  "La existencia precede a la esencia"),
$(txt 3  "Estamos condenados a ser libres"),
$(txt 5  "El infierno son los otros"),
$(txt 7  "La lucha misma basta para llenar un corazón"),
$(txt 8  "Buscamos sentido, y el mundo calla"),
$(txt 12 "Somos lo que hacemos con lo que hicieron de nosotros"),
$(txt 14 "Hay que imaginar a Sísifo dichoso")
EOF
)
FILTROS=$(echo "$FILTROS" | tr -d '\n')

STAMP=$(date +%Y%m%d-%H%M%S)
FINAL="$DEST/existencialismo-1min-1376x768-$STAMP.mp4"
ffmpeg -y -v error -i $TMP/bruto.mp4 -vf "$FILTROS" \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a copy "$FINAL"
[ ! -f "$FINAL" ] && { echo "FALLO al sobreimprimir"; exit 1; }
echo "LISTO: $FINAL"
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
