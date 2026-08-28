#!/bin/bash
# sd-cli escribe en "<lo que le pasas a -o>.avi". Si un script comprueba una ruta
# distinta a la que le paso, cree que TODOS los planos fallaron.
# Esta regresion existio de verdad durante la revision (se comprobaba
# sd_salida "$OUT" en vez de sd_salida "$OUT.mp4"): todos los planos habrian
# reportado "FALLO DEFINITIVO". No se puede verificar contra el commit inicial
# porque alli el bug no existia; se verifica mutando el codigo actual.
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
set -u
NOMBRE="sd-salida"
W=$(mktemp -d /tmp/chk-sdsalida-XXXXXX); trap 'rm -rf "$W"' EXIT

# ── sd-cli falso: cumple el contrato real (-o X  ->  crea X.avi) ───────────
mkdir -p "$W/bin"
cat > "$W/bin/sd-cli" <<'STUB'
#!/bin/bash
o=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { o=$2; shift; }; shift; done
[ -n "$o" ] || exit 2
head -c 2048 /dev/urandom > "$o.avi"
STUB
chmod +x "$W/bin/sd-cli"

# ── arbol de pruebas con el producir.sh REAL ───────────────────────────────
monta() {  # $1=destino  $2=mutar(si|no)
  local D=$1
  mkdir -p "$D/lib" "$D/produccion/guiones" "$D/bin"
  cp "$RAIZ/lib/comun.sh" "$D/lib/"
  cp "$RAIZ/produccion/producir.sh" "$D/produccion/"
  cp "$W/bin/sd-cli" "$D/bin/"
  # la MUTACION: comprobar una ruta distinta de la que se le paso a sd_vid_gen
  [ "$2" = "si" ] && sed -i 's|sd_salida "$OUT\.mp4"|sd_salida "$OUT"|g' "$D/produccion/producir.sh"
  printf '@ESCENA X\n@AMBIENTE Y\n@MUSICA Z\nHABLA|hola|inicio|\n' > "$D/produccion/guiones/t.guion"
}
corre() {  # $1=arbol -> imprime la linea del plano
  ( cd "$1" && DEST="$1/out" FRAMES=5 STEPS=1 \
      timeout 60 bash produccion/producir.sh produccion/guiones/t.guion t 2>&1 ) \
    | grep -aE '^  p01' | head -1
}

monta "$W/bueno"   no
monta "$W/mutante" si
BUENO=$(corre "$W/bueno")
MUT=$(corre "$W/mutante")

# El bueno tiene que detectar el .avi; el mutante tiene que perderlo.
case "$BUENO" in
  *OK*) : ;;
  *) echo "FALLA $NOMBRE: con el codigo actual el plano NO se detecta -> '$BUENO'"; exit 1;;
esac
case "$MUT" in
  *"FALLO DEFINITIVO"*) : ;;
  *) echo "FALLA $NOMBRE: el check no discrimina; la mutacion tambien dio '$MUT'"; exit 1;;
esac
# Y el fichero final tiene que quedar como pNN.avi, no como pNN.mp4.avi
[ -f "$W/bueno/produccion/obra/t/p01.avi" ] || {
  echo "FALLA $NOMBRE: no quedo obra/t/p01.avi tras el mv"; exit 1; }

echo "PASA $NOMBRE (actual: '$BUENO' · mutado: '$MUT')"
exit 0
