#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ORDENAR VÍDEOS — deja a la vista SOLO la pieza actual y archiva el resto.
#
#  Uso:   ordenar-videos.sh                  -> enseña qué haría, SIN tocar nada
#         ordenar-videos.sh --hazlo          -> lo hace
#         ordenar-videos.sh --hazlo <patrón> -> conserva otra pieza distinta
#
#  NO BORRA NADA: mueve a ~/Vídeos/archivo-minimax/. Se deshace con un mv.
#  Solo toca ficheros con la firma de nombre de esta pipeline
#  (…-<W>x<H>-<seg>s-<AAAAMMDD>-<HHMMSS>.mp4 y similares), así que tus
#  vídeos personales que estén en la misma carpeta no se mueven.
# ═══════════════════════════════════════════════════════════════════════════
set -u
V=${DEST:-${HOME:-/home/$(id -un)}/Vídeos}
ARCH=$V/archivo-minimax
HAZLO=0; [ "${1:-}" = "--hazlo" ] && { HAZLO=1; shift; }
CONSERVAR=${1:-existencialismo-4p}

[ -d "$V" ] || { echo "no existe la carpeta de vídeos: $V"; exit 1; }

# Firma de nombre de los ficheros que produce esta pipeline.
firma() {
  case "$1" in
    *-[0-9]*x[0-9]*-[0-9]*s-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].mp4) return 0 ;;
    *-1080p-*s-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].mp4) return 0 ;;
    h3-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].mp4*) return 0 ;;
    *-1min-*.mp4) return 0 ;;
  esac
  return 1
}

# La pieza que se conserva: la MÁS RECIENTE que case con el patrón.
BUENA=$(ls -1t "$V"/*"$CONSERVAR"*.mp4 2>/dev/null | head -1)
[ -n "$BUENA" ] || { echo "no encuentro ninguna pieza que case con '$CONSERVAR' en $V"; ls -1t "$V"/*.mp4 2>/dev/null | head -8 | sed 's/^/    hay: /'; exit 1; }

echo "═══ CARPETA: $V ═══"
echo "  se CONSERVA a la vista: $(basename "$BUENA")"
echo

MOVER=(); INTACTOS=0
for f in "$V"/*; do
  [ -f "$f" ] || { [ -d "$f" ] && [ "$f" != "$ARCH" ] && MOVER+=("$f"); continue; }
  [ "$f" = "$BUENA" ] && continue
  b=$(basename "$f")
  if firma "$b"; then MOVER+=("$f"); else INTACTOS=$((INTACTOS+1)); fi
done

if [ ${#MOVER[@]} -eq 0 ]; then
  echo "  nada que archivar: la carpeta ya está limpia."
else
  echo "  se ARCHIVAN ${#MOVER[@]} elementos en $ARCH/:"
  for f in "${MOVER[@]}"; do printf "    %-58s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"; done
fi
[ $INTACTOS -gt 0 ] && echo "  se DEJAN QUIETOS $INTACTOS fichero(s) que no son de esta pipeline."

if [ $HAZLO -eq 0 ]; then
  echo
  echo "  (simulación: no se ha movido nada. Repite con --hazlo para aplicarlo)"
  exit 0
fi

mkdir -p "$ARCH"
for f in "${MOVER[@]}"; do mv -n "$f" "$ARCH/" || echo "    no se pudo mover: $f"; done
echo
echo "═══ CÓMO QUEDA ═══"
ls -1 "$V" | sed 's/^/  /'
echo
echo "  para verlo:  xdg-open \"$BUENA\""
echo "  para deshacer: mv \"$ARCH\"/* \"$V\"/"
