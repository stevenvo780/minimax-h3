#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  TANDA DEL DIA — las noticias de produccion/noticias/dia/ convertidas en
#  reels, en serie, con un solo cerrojo de GPU.
#
#  Antes esto llamaba a producir-anclado.sh DIRECTAMENTE, saltandose los dos
#  ultimos pasos del reel: subtitular.py y exportar-reel.sh. Lo que se entrego
#  el 7 de septiembre fueron cinco MP4 de 416x736 a -19 LUFS, sin subtitulos y
#  sin 1080x1920 — el montaje interno, no el producto. Y sondear-dia.sh los
#  daba por buenos porque solo miraba los dia-*.mp4 en bruto.
#
#  Ahora pasa por reel-noticias.sh, que es el unico camino completo. Tambien
#  desaparece la lista de nombres a mano: la tanda es lo que haya en el
#  catalogo del dia, ni mas ni menos.
#
#  Uso:  produccion/tanda-noticias-dia.sh [nombre-corto ...]
#  Entorno: SEG_OBJETIVO=32   duracion pedida a cada reel
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe python3 || exit 1

DIA=$MD/produccion/noticias/dia
SEG_OBJETIVO=${SEG_OBJETIVO:-32}

if [ $# -gt 0 ]; then
  IDS=("$@")
else
  mapfile -t IDS < <(cd "$DIA" 2>/dev/null && ls -1 *.txt 2>/dev/null | sed 's/\.txt$//')
fi
[ ${#IDS[@]} -gt 0 ] || { echo "FALLO: no hay noticias en $DIA" >&2; exit 1; }

LOG=$MD/produccion/logs/tanda-dia-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$MD/produccion/logs" "$DEST" || exit 1

# El log va por 'exec' y no por '{ ... } | tee': con el pipe, el bloque corre
# en un subshell, el fail=1 de dentro no sale de ahi y 'exit $fail' leia
# siempre el 0 del padre. Comprobado: cinco FALLO por pantalla y rc=0.
exec > >(tee -a "$LOG") 2>&1

fail=0
{
  echo "tanda start $(date -u --iso-8601=seconds) · ${#IDS[@]} noticias · objetivo ${SEG_OBJETIVO}s"
  for id in "${IDS[@]}"; do
    fuente=$DIA/$id.txt
    if [ ! -f "$fuente" ]; then
      echo "FALLO: falta $fuente"
      fail=1
      continue
    fi
    nombre=dia-$id
    echo "═══ $nombre $(date -u +%H:%M:%S) ═══"
    bash "$MD/produccion/reel-noticias.sh" \
      --fichero "$fuente" --nombre "$nombre" --seg-objetivo "$SEG_OBJETIVO"
    rc=$?
    echo "═══ $nombre rc=$rc $(date -u +%H:%M:%S) ═══"
    if [ "$rc" -ne 0 ]; then
      fail=1
    fi
  done
  echo "tanda end fail=$fail $(date -u --iso-8601=seconds)"
}
exit "$fail"
