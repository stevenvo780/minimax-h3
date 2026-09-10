#!/bin/bash
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="estructura"
exec 0</dev/null

# El arbol se desordeno hasta tener 29 entradas en la raiz, con 12 videos
# sueltos mezclados con scripts, documentacion y los 51 GB de pesos. Este check
# fija la forma para que no vuelva a pasar sin que nadie se entere.

fallos=0

# 1. Ningun video suelto en la raiz: van a videos/
n=$(ls -1 "$RAIZ"/*.mp4 2>/dev/null | wc -l)
[ "$n" -eq 0 ] || { echo "FALLA $nombre: $n video(s) sueltos en la raiz, van a videos/"; fallos=1; }

# 2. Cada cosa en su carpeta
for d in lib produccion calidad herramientas pruebas videos modelos imagenes noticias; do
  [ -d "$RAIZ/$d" ] || { echo "FALLA $nombre: falta $d/"; fallos=1; }
done

# 3. Las herramientas de MEDIDA viven juntas en calidad/, no repartidas
for f in auditar.py evaluar2.py comparar-formatos.sh; do
  [ -f "$RAIZ/calidad/$f" ] || { echo "FALLA $nombre: calidad/$f no esta donde debe"; fallos=1; }
  [ -f "$RAIZ/produccion/$f" ] && { echo "FALLA $nombre: produccion/$f duplicado; la medida vive en calidad/"; fallos=1; }
done

# 4. Los pesos agrupados, no cuatro carpetas gigantes en la raiz
for d in diffusion_models text_encoders vae upscalers; do
  [ -d "$RAIZ/$d" ] && { echo "FALLA $nombre: $d/ suelto en la raiz, va en modelos/"; fallos=1; }
done

# 5. La raiz no puede volver a crecer sin querer. Las dos entradas nuevas
# autorizadas son AGENTS.md (guia universal) e imagenes/ (modulo de imagenes).
n=$(ls -1 "$RAIZ" | wc -l)
# El tope existe para que la raiz no vuelva a desmadrarse (llego a 29 entradas
# con 12 videos sueltos). Subirlo es legitimo cuando se añade una carpeta a
# proposito, no cuando se cuela algo: 19 desde que la noticia en crudo vive en
# noticias/, que es la entrada COMPARTIDA por el reel y el carrusel.
# Dos de las 19 son restos en disco de pipelines retirados que no se versionan
# (archivo/ y proyecto-minuto/): al borrarlos, esto vuelve a 17.
[ "$n" -le 19 ] || { echo "FALLA $nombre: la raiz tiene $n entradas (tope 19). Algo nuevo se dejo suelto."; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre (raiz con $n entradas)"
exit $fallos
