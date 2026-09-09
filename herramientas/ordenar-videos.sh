#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ORDENAR VÍDEOS — deja a la vista SOLO la pieza actual y archiva el resto.
#
#  Uso:   ordenar-videos.sh                  -> enseña qué haría, SIN tocar nada
#         ordenar-videos.sh --hazlo          -> lo hace
#         ordenar-videos.sh --hazlo <texto>  -> conserva la salida más reciente
#                                                cuyo nombre contenga <texto>
#
#  DEST cambia la carpeta que se inspecciona (por defecto, videos/entregas del
#  proyecto). ARCHIVO_DEST cambia la carpeta recuperable a la que se mueven las
#  salidas (por defecto, DEST/archivo-minimax).
#  NO BORRA NI SOBRESCRIBE NADA. Sólo considera archivos regulares directos
#  con nombre ASCII y sidecar de procedencia cuyo SHA coincide con el MP4.
# ═══════════════════════════════════════════════════════════════════════════
set -u
shopt -s nullglob

MD=${MD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
V=${DEST:-$MD/videos/entregas}
ARCH=${ARCHIVO_DEST:-$V/archivo-minimax}
ESTADO_OBRA=$MD/lib/estado_obra.py
SUFIJO_MANIFIESTO=.minimax-h3.json
HAZLO=0
[ "${1:-}" = "--hazlo" ] && { HAZLO=1; shift; }
CONSERVAR=${1:-}

[ -d "$V" ] && [ ! -L "$V" ] || {
  echo "no existe una carpeta de vídeos regular: $V"
  exit 1
}
[ -f "$ESTADO_OBRA" ] || {
  echo "no existe el verificador de procedencia: $ESTADO_OBRA"
  exit 1
}

# Formatos publicados por producir.sh, encadenar.sh, generar-1080p.sh,
# proyecto-minuto/ensamblar.sh y el nombre por defecto de h3.sh. Los anclajes
# son deliberados: un sufijo, una extensión doble desconocida o texto donde la
# pipeline escribe números convierte el elemento en no seleccionable.
firma() {
  local nombre=$1
  local prefijo='[A-Za-z0-9][A-Za-z0-9_-]*'
  local fecha='[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])'
  local hora='([01][0-9]|2[0-3])[0-5][0-9][0-5][0-9]'
  local sello="${fecha}-${hora}(-[0-9]{9})?"

  [[ $nombre =~ ^${prefijo}-[1-9][0-9]*x[1-9][0-9]*-[0-9]+([.][0-9]+)?s-${sello}[.]mp4$ ]] ||
  [[ $nombre =~ ^${prefijo}-1080p-[0-9]+([.][0-9]+)?s-${sello}[.]mp4$ ]] ||
  [[ $nombre =~ ^existencialismo-1min-[1-9][0-9]*x[1-9][0-9]*-${sello}[.]mp4$ ]] ||
  [[ $nombre =~ ^h3-${sello}[.]mp4([.]avi)?$ ]]
}

es_salida_regular() {
  local ruta=$1
  local manifiesto=$ruta$SUFIJO_MANIFIESTO
  [ -f "$ruta" ] && [ ! -L "$ruta" ] \
    && firma "${ruta##*/}" \
    && [ -f "$manifiesto" ] && [ ! -L "$manifiesto" ] \
    && python3 "$ESTADO_OBRA" verify-artifact "$manifiesto" "$ruta" >/dev/null 2>&1
}

# Se enumera una sola vez y sin `ls`: así directorios, enlaces y nombres
# personales no pueden convertirse accidentalmente ni en la pieza conservada
# ni en candidatas a mover.
SALIDAS=()
BUENA=""
INTACTOS=0
for f in "$V"/*; do
  [ "$f" = "$ARCH" ] && continue
  if es_salida_regular "$f"; then
    SALIDAS+=("$f")
    b=${f##*/}
    if { [ -z "$CONSERVAR" ] || [[ $b == *"$CONSERVAR"* ]]; } \
        && { [ -z "$BUENA" ] || [ "$f" -nt "$BUENA" ]; }; then
      BUENA=$f
    fi
  else
    INTACTOS=$((INTACTOS+1))
  fi
done

if [ -z "$BUENA" ]; then
  if [ -n "$CONSERVAR" ]; then
    echo "no encuentro ninguna salida válida que contenga '$CONSERVAR' en $V"
  else
    echo "no encuentro ninguna salida válida de la pipeline en $V"
  fi
  if [ ${#SALIDAS[@]} -gt 0 ]; then
    echo "  salidas válidas disponibles:"
    n=0
    for f in "${SALIDAS[@]}"; do
      echo "    ${f##*/}"
      n=$((n+1)); [ $n -eq 8 ] && break
    done
  fi
  exit 1
fi

MOVER=()
for f in "${SALIDAS[@]}"; do
  [ "$f" = "$BUENA" ] || MOVER+=("$f")
done

echo "═══ CARPETA: $V ═══"
echo "  se CONSERVA a la vista: ${BUENA##*/}"
echo

if [ ${#MOVER[@]} -eq 0 ]; then
  echo "  nada que archivar: la carpeta ya está limpia."
else
  echo "  se ARCHIVAN ${#MOVER[@]} archivos en $ARCH/:"
  for f in "${MOVER[@]}"; do
    tam=$(du -sh -- "$f" 2>/dev/null | cut -f1)
    printf "    %-58s %s\n" "${f##*/}" "${tam:-?}"
  done
fi
[ $INTACTOS -gt 0 ] && echo "  se DEJAN QUIETOS $INTACTOS elemento(s) sin una firma válida."

if [ $HAZLO -eq 0 ]; then
  echo
  echo "  (simulación: no se ha movido nada. Repite con --hazlo para aplicarlo)"
  exit 0
fi

ERRORES=0
if [ ${#MOVER[@]} -gt 0 ]; then
  if [ -L "$ARCH" ] || { [ -e "$ARCH" ] && [ ! -d "$ARCH" ]; }; then
    echo "no se puede usar como archivo una ruta que no sea un directorio regular: $ARCH"
    exit 1
  fi
  mkdir -p -- "$ARCH" || { echo "no se pudo crear la carpeta de archivo: $ARCH"; exit 1; }
  [ -d "$ARCH" ] && [ ! -L "$ARCH" ] || {
    echo "la carpeta de archivo dejó de ser un directorio regular: $ARCH"
    exit 1
  }

  for f in "${MOVER[@]}"; do
    # Revalidación justo antes de mover: protege también frente a un cambio
    # del elemento entre la simulación interna y esta fase.
    if ! es_salida_regular "$f"; then
      echo "    no se movió porque ya no es una salida regular válida: $f"
      ERRORES=1
      continue
    fi
    destino=$ARCH/${f##*/}
    manifiesto=$f$SUFIJO_MANIFIESTO
    destino_manifiesto=$destino$SUFIJO_MANIFIESTO
    if [ -e "$destino" ] || [ -L "$destino" ] \
        || [ -e "$destino_manifiesto" ] || [ -L "$destino_manifiesto" ]; then
      echo "    no se sobrescribió el archivo existente: $destino"
      ERRORES=1
      continue
    fi
    mv -n -- "$manifiesto" "$destino_manifiesto" || {
      echo "    no se pudo mover el manifiesto: $manifiesto"
      ERRORES=1
      continue
    }
    if [ -e "$manifiesto" ] || [ -L "$manifiesto" ]; then
      echo "    no se movió el manifiesto: el destino apareció durante la operación"
      ERRORES=1
      continue
    fi
    mv -n -- "$f" "$destino" || {
      echo "    no se pudo mover: $f"
      mv -n -- "$destino_manifiesto" "$manifiesto" || true
      ERRORES=1
      continue
    }
    # GNU mv -n puede devolver 0 cuando omite una colisión aparecida entre la
    # comprobación y el mv. Si el origen sigue ahí, no se anuncia como movido.
    if [ -e "$f" ] || [ -L "$f" ]; then
      echo "    no se movió ni sobrescribió: el destino apareció durante la operación"
      mv -n -- "$destino_manifiesto" "$manifiesto" || true
      ERRORES=1
    fi
  done
fi

echo
echo "═══ RESULTADO ═══"
echo "  se conserva: ${BUENA##*/}"
echo "  archivo recuperable: $ARCH/"
echo
echo "  para verlo: xdg-open \"$BUENA\""
echo "  para deshacer sin sobrescribir: mv -n -- \"$ARCH\"/* \"$V\"/"

[ $ERRORES -eq 0 ]
