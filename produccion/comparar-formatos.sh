#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  COMPARAR FORMATOS — mide las piezas de formato y las pone en una tabla.
#
#  El punto no es sacar UNA nota: es que la nota de evaluar2 NO es comparable
#  entre formatos. evaluar2 recorta siempre el centro (donde esta la cara en un
#  retrato) y compara la primera muestra contra la ultima. Un paisaje impecable
#  saco 44.6 con esa vara. Por eso aqui manda 'estabilidad', que mide el
#  fotograma entero y compara medianas de tercios, y 'manchas', que escanea
#  TODOS los fotogramas buscando picos de saturacion.
#
#  Uso:  comparar-formatos.sh [patron]     (por defecto formato-*.mp4)
# ═══════════════════════════════════════════════════════════════════════════
set -u
MD=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$MD/lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1
A="$MD/produccion/auditar.py"
PAT=${1:-formato-*.mp4}

# No medir con una generacion en curso: escanear todos los fotogramas de un
# clip mientras el modelo decodifica el VAE ya mato una toma en el paso 16/20.
if hay_generacion_en_curso 2>/dev/null; then
  echo "HAY UNA GENERACION EN CURSO. Medir ahora puede matarla por OOM." >&2
  echo "Espera a que termine, o forza con MEDIR_IGUAL=1." >&2
  [ "${MEDIR_IGUAL:-0}" = 1 ] || exit 1
fi

printf '%-14s %8s %7s %9s %9s %-12s %s\n' FORMATO DUR MANCHAS d-TONO d-BORDES VEREDICTO RUIDO
printf '%.0s─' {1..78}; echo
for f in $MD/$PAT; do
  [ -f "$f" ] || { echo "  (no hay ficheros que casen con $PAT)"; break; }
  n=$(basename "$f" .mp4); n=${n%%-*[0-9]}; n=$(basename "$f" | sed 's/^formato-//; s/-[0-9]\{8\}-[0-9]\{6\}\.mp4$//; s/-[0-9]*x[0-9]*.*$//')
  dur=$(ffp -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
  man=$(python3 "$A" manchas "$f" --json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("manchas",d.get("n","?")))' 2>/dev/null || echo "?")
  est=$(python3 "$A" estabilidad "$f" --json 2>/dev/null)
  dt=$(printf '%s' "$est" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("%+.1f%%"%d["deriva_tono_%"])' 2>/dev/null || echo "?")
  db=$(printf '%s' "$est" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("%+.1f%%"%d["deriva_bordes_%"])' 2>/dev/null || echo "?")
  vd=$(printf '%s' "$est" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["veredicto"])' 2>/dev/null || echo "?")
  ru=$(python3 "$A" audio "$f" 2>/dev/null | grep -o 'ruido>6kHz [-0-9.]*' | awk '{printf "%.1fdB",$2}' || echo "?")
  printf '%-14s %7ss %7s %9s %9s %-12s %s\n' "$n" "${dur:-?}" "$man" "$dt" "$db" "$vd" "${ru:-?}"
done
