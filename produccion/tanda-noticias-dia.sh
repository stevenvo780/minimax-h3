#!/bin/bash
# Genera las cinco noticias del dia, en serie, con el runner anclado.
# Un solo cerrojo de GPU: no lanza la siguiente hasta que la anterior termina.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe python3 || exit 1

NAMES=(
  dia-miami-amazon
  dia-afd-sajonia
  dia-kyiv-conversaciones
  dia-ceuta-audiencia
  dia-venezuela-petroleo
)
# Despues de sourcear comun.sh, W/H/FRAMES ya tienen valor (1376x768x107).
# ${VAR:-} no se dispara. Estos son los del reel 9:16, no los globales.
FRAMES=192
W=416
H=736
PASOS=20
LOG=$MD/produccion/logs/tanda-dia-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$MD/produccion/logs" "$DEST"

fail=0
{
  echo "tanda start $(date -u --iso-8601=seconds) frames=$FRAMES ${W}x${H} pasos=$PASOS"
  for name in "${NAMES[@]}"; do
    g=$MD/produccion/guiones/noticias/generados/${name}.guion
    if [ ! -f "$g" ]; then
      echo "FALLO: falta $g"
      fail=1
      continue
    fi
    mkdir -p "$MD/produccion/obra/$name"
    cp "$g" "$MD/produccion/obra/$name/entrada.guion"
    if [ -f "$g.fuente.json" ]; then
      cp "$g.fuente.json" "$MD/produccion/obra/$name/fuente.json"
    fi
    echo "═══ $name $(date -u +%H:%M:%S) ═══"
    bash "$MD/produccion/producir-anclado.sh" "$g" "$name" "$FRAMES" "$W" "$H" "$PASOS"
    rc=$?
    echo "═══ $name rc=$rc $(date -u +%H:%M:%S) ═══"
    if [ "$rc" -ne 0 ]; then
      fail=1
    fi
  done
  echo "tanda end fail=$fail $(date -u --iso-8601=seconds)"
} 2>&1 | tee -a "$LOG"
exit "$fail"
