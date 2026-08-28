#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ENLACE — limpieza calibrada del frame de enlace
#
#  El último frame de un plano se pasa como --init-img al siguiente (modo
#  `encadena`). Ese frame ya lleva el realce del modelo; el siguiente plano
#  realza ENCIMA -> realimentación positiva que va acartonando la imagen
#  eslabón a eslabón (bordes: 12.34 -> 12.98 -> 13.58 -> 14.48, medido sobre
#  produccion/obra/existencialismo-4p/last0N.png, referencia p01 = 11.96).
#
#  Este fichero calibra y aplica un desenfoque gaussiano (gblur) sobre el
#  frame de enlace para devolverlo a la energía de bordes de la referencia
#  ANTES de pasarlo como --init-img, cortando la realimentación.
#
#  Se sourcea desde cualquier script del proyecto:
#      . "$(dirname "${BASH_SOURCE[0]}")/lib/enlace.sh"        # desde la raíz
#      . "$(dirname "${BASH_SOURCE[0]}")/../lib/enlace.sh"     # desde produccion/
# ═══════════════════════════════════════════════════════════════════════════

. "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

# ── medida ──────────────────────────────────────────────────────────────────
# enlace_bordes <png>
#   Energía de bordes, EXACTAMENTE como la mide produccion/evaluar2.py:
#   bordes_estr() -> gb(png,"format=gray,gblur=sigma=1.3,sobel"); sum(b)/len(b)
#   Mismo filtro, mismo -f rawvideo, misma media de bytes: los números tienen
#   que coincidir dígito a dígito con evaluar2.py o la calibración no vale.
enlace_bordes() {
  local png=$1
  ff -v error -i "$png" -vf "format=gray,gblur=sigma=1.3,sobel" -f rawvideo - 2>/dev/null \
    | python3 -c '
import sys
b = sys.stdin.buffer.read()
print(sum(b) / len(b) if b else "")
'
}

# _enlace_bordes_tras <png> <sigma_previo>
#   Interno: bordes que resultarían de limpiar <png> con gblur=<sigma_previo>
#   ANTES de aplicar la propia cadena de medida (un solo proceso ffmpeg:
#   se encadenan los dos gblur en el mismo -vf). Usado por enlace_sigma para
#   evaluar candidatos durante la búsqueda, sin escribir ficheros intermedios.
_enlace_bordes_tras() {
  local png=$1 sigma=$2
  ff -v error -i "$png" -vf "gblur=sigma=${sigma},format=gray,gblur=sigma=1.3,sobel" -f rawvideo - 2>/dev/null \
    | python3 -c '
import sys
b = sys.stdin.buffer.read()
print(sum(b) / len(b) if b else "")
'
}

# _enlace_dentro <valor> <ref> <tol>  -> exit 0 si |valor-ref| <= ref*tol
_enlace_dentro() {
  python3 -c "
import sys
v, ref, tol = $1, $2, $3
sys.exit(0 if abs(v - ref) <= ref * tol else 1)
"
}

# ── búsqueda ────────────────────────────────────────────────────────────────
# enlace_sigma <png> <ref_bordes> [tolerancia=0.03]
#   Busca por BISECCIÓN (rango sigma 0..3, 8 iteraciones) el sigma de gblur
#   que deja los bordes de <png> dentro de <tolerancia> de <ref_bordes>.
#   Los bordes bajan monótonamente al subir sigma (más desenfoque = menos
#   energía de Sobel), así que la bisección es válida: si el candidato queda
#   POR ENCIMA de la referencia hace falta MÁS sigma (mitad alta); si queda
#   POR DEBAJO, hace falta MENOS (mitad baja).
#   Si <png> ya está dentro de tolerancia sin tocarlo, devuelve 0 y no evalúa
#   ningún candidato (no hay que emborronar lo que ya está limpio).
enlace_sigma() {
  local png=$1 ref=$2 tol=${3:-0.03}
  local actual
  actual=$(enlace_bordes "$png")
  if [ -z "$actual" ]; then
    echo "enlace_sigma: no pude medir '$png'" >&2
    return 1
  fi
  if _enlace_dentro "$actual" "$ref" "$tol"; then
    echo 0
    return 0
  fi
  local lo=0 hi=3 mid val i
  for i in 1 2 3 4 5 6 7 8; do
    mid=$(python3 -c "print(($lo + $hi) / 2)")
    val=$(_enlace_bordes_tras "$png" "$mid")
    if _enlace_dentro "$val" "$ref" "$tol"; then
      break
    fi
    if python3 -c "import sys; sys.exit(0 if $val > $ref else 1)"; then
      lo=$mid   # todavía por encima de la referencia -> hace falta más sigma
    else
      hi=$mid   # ya por debajo -> nos pasamos, hace falta menos sigma
    fi
  done
  echo "$mid"
}

# ── limpieza ────────────────────────────────────────────────────────────────
# enlace_limpiar <png_in> <png_out> <ref_bordes> [tolerancia=0.03]
#   Calcula el sigma con enlace_sigma y escribe <png_out> limpio.
#   Si el sigma encontrado es 0 (ya estaba dentro de tolerancia) NO reescribe
#   con ffmpeg -vf gblur: copia el fichero tal cual, así un frame ya limpio
#   sale idéntico, sin pasar de nuevo por el códec PNG.
#   Informa por stderr: bordes antes, sigma aplicado, bordes después.
enlace_limpiar() {
  local pin=$1 pout=$2 ref=$3 tol=${4:-0.03}
  local antes sigma despues

  antes=$(enlace_bordes "$pin")
  sigma=$(enlace_sigma "$pin" "$ref" "$tol")

  if python3 -c "import sys; sys.exit(0 if float('$sigma') <= 0 else 1)"; then
    cp "$pin" "$pout"
  else
    ff -y -v error -i "$pin" -vf "gblur=sigma=${sigma}" "$pout" 2>/dev/null
  fi

  despues=$(enlace_bordes "$pout")
  echo "enlace_limpiar: $pin -> $pout | bordes antes=$antes sigma=$sigma bordes despues=$despues (ref=$ref tol=$tol)" >&2
}
