#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  FORMATOS — produce en serie los cuatro formatos de guiones/formatos/.
#
#  En serie y no en paralelo a proposito: dos generaciones concurrentes se
#  mataron entre ellas por OOM (medido). El cerrojo de comun.sh ya lo impide,
#  pero encolarlas aqui hace el progreso legible y el fallo aislado.
#
#  Es RESUMIBLE: si un formato ya tiene su mp4, lo salta. Asi puedo alargar
#  una tanda o repetir solo el formato que salga mal sin re-generar el resto.
# ═══════════════════════════════════════════════════════════════════════════
set -u
MD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Steven pidio las piezas EN LA CARPETA DEL PROYECTO, no en ~/Videos: alli no
# las ve. Sin esto, DEST cae en $HOME/Videos y la entrega aparece donde no la
# esta mirando.
export DEST=${DEST:-$(cd "$MD/.." && pwd)/videos/entregas}
FRAMES=${FRAMES:-345} W=${W:-736} H=${H:-416} PASOS=${PASOS:-20}
FORMATOS=${FORMATOS:-detalle camara accion paisaje}

for f in $FORMATOS; do
  g="$MD/guiones/formatos/$f.guion"
  [ -f "$g" ] || { echo "[$(date +%H:%M:%S)] $f: no existe $g, salto"; continue; }
  if compgen -G "$MD/../formato-$f-*.mp4" >/dev/null; then
    echo "[$(date +%H:%M:%S)] $f: ya producido, salto"; continue
  fi
  echo "[$(date +%H:%M:%S)] ═══ $f · ${FRAMES}f a ${W}x${H} · $PASOS pasos ═══"
  "$MD/producir-anclado.sh" "$g" "formato-$f" "$FRAMES" "$W" "$H" "$PASOS"
  echo "[$(date +%H:%M:%S)] $f rc=$?"
done
echo "[$(date +%H:%M:%S)] FORMATOS-FIN"
