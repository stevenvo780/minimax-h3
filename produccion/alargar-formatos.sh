#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ALARGAR FORMATOS — lleva las piezas de 2 tomas (29s) a 4 tomas (~58s).
#
#  NO regenera nada de lo ya hecho: producir-anclado.sh salta toda toma cuyo
#  .avi exista, asi que de las cuatro solo se generan la 3 y la 4. Las dos
#  primeras y sus anclas se reutilizan tal cual.
#
#  Lo unico que hay que apartar es el mp4 de 29s, porque formatos.sh salta el
#  formato que ya tenga uno. Se APARTA a old/, no se borra: es material bueno.
# ═══════════════════════════════════════════════════════════════════════════
set -u
MD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RAIZ=$(cd "$MD/.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1

if hay_generacion_en_curso 2>/dev/null; then
  echo "Hay una generacion en curso. Espera a que termine." >&2; exit 1
fi

mkdir -p "$RAIZ/old/formatos-29s"
for f in detalle camara accion paisaje; do
  g="$MD/guiones/formatos/$f.guion"
  [ -f "$g" ] || continue
  n=$(grep -cE '^TOMA\|' "$g")
  if [ "$n" -ge 4 ]; then echo "  $f: ya tiene $n tomas"; else
    # Las tomas 3 y 4 se anclan igual que la 2: a un fotograma pristino de la 1.
    case $f in
      detalle) a="Both hands rest still on the page, then one lifts slowly away."
               b="A single finger settles on the page and stays there." ;;
      camara)  a="continues its slow forward drift, the lamp now filling much of the frame."
               b="holds its slow advance, steady, never turning." ;;
      accion)  a="stands still beside the table, looking down at the open book."
               b="turns his head slowly toward the window, then looks down again." ;;
      paisaje) a="Dust motes keep drifting through the beam, unhurried."
               b="The light holds steady. Nothing enters the frame." ;;
    esac
    printf 'TOMA|%s|ancla|\nTOMA|%s|ancla|\n' "$a" "$b" >> "$g"
    echo "  $f: 2 -> $(grep -cE '^TOMA\|' "$g") tomas"
  fi
  # apartar el mp4 de 29s para que formatos.sh no salte el formato
  for v in "$RAIZ"/formato-$f-*.mp4; do
    [ -f "$v" ] && mv "$v" "$RAIZ/old/formatos-29s/" && echo "      apartado $(basename "$v")"
  done
done
echo
echo "Ahora: produccion/formatos.sh   (solo generara las tomas 3 y 4 de cada uno)"
