#!/bin/bash
# Vigila la produccion y va publicando cada plano terminado en ~/Videos/<nombre>/
# ademas de un PREVIEW-parcial.mp4 con todo lo que lleva, en orden de guion.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
PROD=$MD/produccion
NOMBRE=${1:-existencialismo}
G=$PROD/guiones/$NOMBRE.guion
OBRA=$PROD/obra/$NOMBRE
V=$DEST/$NOMBRE
mkdir -p "$V"

publicar() {
  local cambio=0
  # planos hablados nuevos
  for f in $OBRA/p*.avi; do
    [ -f "$f" ] || continue
    local b=$(basename "$f" .avi)
    [ -f "$V/$b.mp4" ] && continue
    ff -y -v error -i "$f" -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
           -c:a aac -b:a 192k "$V/$b.mp4" 2>/dev/null && { echo "  publicado: $b.mp4"; cambio=1; }
  done
  [ $cambio -eq 0 ] && return
  # preview en el ORDEN DEL GUION, con lo que exista
  local lista=$V/.lista.txt; : > "$lista"; local idx=0 n=0
  while IFS='|' read -r TIPO CONT MODO; do
    case "$TIPO" in
      HABLA) idx=$((idx+1)); local p=$(printf "p%02d" $idx)
             [ -f "$V/$p.mp4" ] && { echo "file '$V/$p.mp4'" >> "$lista"; n=$((n+1)); } ;;
      BROLL) local src="$MD/proyecto-minuto/$CONT"
             if [ -f "$src" ]; then
               local bb=$(basename "$src" .avi)
               [ -f "$V/broll-$bb.mp4" ] || ff -y -v error -i "$src" -c:v libx264 -preset fast \
                    -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k "$V/broll-$bb.mp4" 2>/dev/null
               [ -f "$V/broll-$bb.mp4" ] && { echo "file '$V/broll-$bb.mp4'" >> "$lista"; n=$((n+1)); }
             fi ;;
    esac
  done < <(grep -E "^(HABLA|BROLL)\|" "$G")
  [ "$n" -gt 0 ] && ff -y -v error -f concat -safe 0 -i "$lista" -c copy \
      "$V/PREVIEW-parcial.mp4" 2>/dev/null && echo "  PREVIEW actualizado ($n planos)"
}

echo "=== vigilante de preview: $NOMBRE -> $V ==="
while :; do
  publicar
  pgrep -f "producir\.sh" >/dev/null 2>&1 || { sleep 60; publicar; break; }
  sleep 60
done
echo "=== vigilante terminado ==="
