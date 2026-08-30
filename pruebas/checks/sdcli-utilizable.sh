#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="sdcli-utilizable"
exec 0</dev/null

# ── Por que existe este check ─────────────────────────────────────────────
# Dos defectos de la libreria compartida dejaban INUTILIZABLE a todo script que
# no fuera producir-anclado.sh. Los dos se pagaban en GPU o en horas:
#
# 1. lib/comun.sh definia SDCLI=$MD/bin/sd-cli a secas. Ese binario NO arranca
#    en este contenedor: le falta libcudart.so.13 y se compilo contra una glibc
#    mas nueva. Quien lo arreglaba era lib/compat.sh, que SEIS scripts que usan
#    sd-cli no sourceaban (encadenar, generar-1080p, h3, producir,
#    escalar-pipeline, generar). Morian con
#    "libcudart.so.13: cannot open shared object file" nada mas tocar la GPU.
#    Paso de verdad: sd_upscale devolvia 127.
#
# 2. MODELO_DIFF apuntaba al modelo ENTERO (18.8 GB). Con el codificador de
#    texto (17 GB) son 35.8 GB en un cgroup de 24 GB: el OOM killer se lleva la
#    generacion con un "Killed" seco despues de minutos de carga. El que cabe
#    es el PODADO (11.4 GB). producir-anclado.sh lo sabia y lo pisaba en local;
#    los demas heredaban el default roto.
#
# El contrato: sourcear SOLO lib/comun.sh basta para tener un sd-cli que
# arranca y un modelo que cabe en memoria.

fallos=0

# 1. sourcear comun.sh a secas deja un sd-cli ejecutable
out=$(cd "$RAIZ" && bash -c '. lib/comun.sh; "$SDCLI" --help' 2>&1)
if [ $? -ne 0 ]; then
  echo "FALLA $nombre: sourceando solo lib/comun.sh, \$SDCLI no arranca."
  echo "  $(printf '%s' "$out" | head -2)"
  fallos=1
fi

# 2. el modelo por defecto es el que cabe, y existe
mod=$(cd "$RAIZ" && bash -c '. lib/comun.sh; echo "$MODELO_DIFF"' 2>/dev/null)
case "$mod" in
  *pruned*) : ;;
  *) echo "FALLA $nombre: MODELO_DIFF por defecto no es el podado: $mod"
     echo "  el entero (18.8 GB) + el codificador (17 GB) no caben en 24 GB"
     fallos=1 ;;
esac
[ -f "$mod" ] || { echo "FALLA $nombre: MODELO_DIFF no existe: $mod"; fallos=1; }

# 3. ningun script que use sd-cli puede quedarse sin la preparacion de compat.
#    Como ahora la hace comun.sh, basta con que sourceen comun.sh.
for f in $(cd "$RAIZ" && grep -rl 'sd_vid_gen\|sd_upscale\|\$SDCLI\|\${SDCLI}' --include='*.sh' . \
           | grep -v '^./lib/' | grep -v '^./pruebas/'); do
  if ! grep -q 'comun\.sh' "$RAIZ/$f"; then
    echo "FALLA $nombre: $f usa sd-cli pero no sourcea lib/comun.sh"
    fallos=1
  fi
done

# 4. nadie fija el tile del escalador en 512 a pelo: en la RTX 2060 ese tamaño
#    aborta SIEMPRE con "cublasCreate_v2 ... the resource allocation failed",
#    asi que fallan los N fotogramas y no se escala nada. El tile se negocia.
for f in $(cd "$RAIZ" && grep -rln 'upscale-tile-size\|sd_upscale' --include='*.sh' . | grep -v '^./pruebas/'); do
  if grep -vE '^\s*#' "$RAIZ/$f" | grep -qE 'sd_upscale[^|]*CUDA1[^|]*512|upscale-tile-size[" ]*512'; then
    echo "FALLA $nombre: $f fija el tile en 512 (aborta en la 2060). Negocialo."
    fallos=1
  fi
done

[ $fallos -eq 0 ] && echo "ok $nombre"
exit $fallos
