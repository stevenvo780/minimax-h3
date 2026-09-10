#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  SD-SALIDA — sd-cli NO escribe donde se le pide.
#
#  Si se le pasa "-o pieza.mp4", el fichero que aparece es "pieza.mp4.avi".
#  Quien se olvide de eso construye una ruta que no existe, y en un runner eso
#  significa dar por fallada una toma que salio bien, o publicar una pieza
#  vacia. lib/comun.sh::sd_salida() es la unica traduccion valida.
#
#  Este check probaba esa propiedad a traves de produccion/producir.sh, el
#  runner anterior, que ya no existe: era una prueba sobre codigo muerto. Ahora
#  comprueba el contrato en lib/comun.sh y que TODOS los que llaman a sd-cli
#  pasen por el, incluido el runner vivo.
# ═══════════════════════════════════════════════════════════════════════════
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="sd-salida"
exec 0</dev/null
fallos=0

# 1. El contrato: sd_salida añade .avi y nada mas.
REAL=$(bash -c '. "$1"/lib/comun.sh >/dev/null 2>&1; sd_salida "/tmp/pieza.mp4"' _ "$RAIZ")
[ "$REAL" = "/tmp/pieza.mp4.avi" ] \
  || { echo "FALLA $nombre: sd_salida dio '$REAL', se esperaba /tmp/pieza.mp4.avi"; fallos=1; }

# 2. Todo el que invoca vid_gen tiene que resolver su salida con sd_salida.
#    Un runner que construya la ruta a mano vuelve a caer en el mismo agujero.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -q "sd_salida" "$f" \
    || { echo "FALLA $nombre: $f llama a vid_gen y no usa sd_salida"; fallos=1; }
done < <(grep -rl -- "-M vid_gen" "$RAIZ"/produccion/*.sh "$RAIZ"/herramientas/*.sh \
           "$RAIZ"/lib/*.sh 2>/dev/null)

# 3. El runner vivo, explicito: si alguien lo reescribe sin sd_salida, salta.
grep -q 'sd_salida "\$temporal"' "$RAIZ/produccion/producir-anclado.sh" \
  || { echo "FALLA $nombre: producir-anclado.sh dejo de resolver su salida con sd_salida"; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre (contrato .avi y todos los llamantes lo usan)"
exit $fallos
