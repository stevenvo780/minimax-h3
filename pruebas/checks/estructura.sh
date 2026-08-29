#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
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
for d in lib produccion calidad herramientas pruebas videos modelos; do
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

# 5. La raiz no puede volver a crecer sin querer
n=$(ls -1 "$RAIZ" | wc -l)
[ "$n" -le 16 ] || { echo "FALLA $nombre: la raiz tiene $n entradas (tope 16). Algo nuevo se dejo suelto."; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre (raiz con $n entradas)"
exit $fallos
