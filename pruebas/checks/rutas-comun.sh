#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
set -u
NOMBRE="rutas-comun"
VIEJO_MD="/home/stev/Modelos-IA/minimax-h3"
VIEJO_DEST_PRE="/home/stev/V"      # prefijo ASCII: no depende de como se codifique la tilde

[ -d "$RAIZ" ] || { echo "FALLA $NOMBRE: RAIZ='$RAIZ' no es un directorio"; exit 1; }

WORK=$(mktemp -d /tmp/rutas-comun-XXXXXX) || { echo "FALLA $NOMBRE: no pude crear directorio temporal"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ── Inventario de scripts del proyecto (sin old/ ni .git/) ─────────────────
LISTA="$WORK/lista.txt"
# pruebas/ se excluye a proposito: los checks llevan la ruta vieja como DATO
# de prueba, y si no se podan se delatan a si mismos como si fuera una regresion.
( cd "$RAIZ" && find . -path ./old -prune -o -path ./.git -prune -o -path ./pruebas -prune -o \
    -type f \( -name '*.sh' -o -name '*.py' \) -print ) | sed 's|^\./||' | sort > "$LISTA"
[ -s "$LISTA" ] || { echo "FALLA $NOMBRE: no encontre ningun script bajo '$RAIZ'"; exit 1; }

clavadas_en() {  # clavadas_en <excluir-comun|todo>
  while IFS= read -r f; do
    [ "$1" = "todo" ] || [ "$f" != "lib/comun.sh" ] || continue
    grep -Hn -e "$VIEJO_MD" -e "$VIEJO_DEST_PRE" "$RAIZ/$f" 2>/dev/null
  done < "$LISTA"
}

# ── 1) Sin lib/comun.sh no hay nada que deduzca MD ─────────────────────────
if [ ! -f "$RAIZ/lib/comun.sh" ]; then
  echo "FALLA $NOMBRE: no existe '$RAIZ/lib/comun.sh': nadie deduce MD de su propia ubicacion."
  C=$(clavadas_en todo | head -6)
  [ -z "$C" ] || { echo "  rutas de un solo puesto clavadas en los scripts:"; printf '%s\n' "$C" | sed 's/^/    /'; }
  exit 1
fi

# ── 2) Ningun script (fuera de comun.sh) puede llevar la ruta clavada ──────
C=$(clavadas_en excluir-comun)
if [ -n "$C" ]; then
  echo "FALLA $NOMBRE: rutas de un solo puesto de trabajo clavadas otra vez en los scripts:"
  printf '%s\n' "$C" | head -10 | sed 's/^/    /'
  exit 1
fi

# ── 3) Quien sourcee comun.sh debe hacerlo desde su propia ubicacion ───────
while IFS= read -r f; do
  case "$f" in lib/*) continue;; *.sh) : ;; *) continue;; esac
  L=$(grep -m1 -E '^[[:space:]]*(\.|source)[[:space:]].*comun\.sh' "$RAIZ/$f") || continue
  case "$L" in
    *BASH_SOURCE*) : ;;
    *) echo "FALLA $NOMBRE: $f sourcea comun.sh con una ruta que no sale de BASH_SOURCE:"
       echo "    $L"; exit 1;;
  esac
done < "$LISTA"

# ── Simula "otra maquina": los scripts, copiados a otro punto de montaje ───
PROY="$WORK/mnt/otro-punto-de-montaje/minimax-h3"
HOME_FALSO="$WORK/home-falso"
mkdir -p "$PROY/produccion" "$HOME_FALSO" || { echo "FALLA $NOMBRE: no pude preparar el arbol simulado"; exit 1; }
while IFS= read -r f; do
  mkdir -p "$PROY/$(dirname "$f")" && cp "$RAIZ/$f" "$PROY/$f" || {
    echo "FALLA $NOMBRE: no pude copiar '$f' al arbol simulado"; exit 1; }
done < "$LISTA"

crear_sonda() {  # <ruta-sonda> <linea-de-source>
  { echo '#!/bin/bash'; echo 'set -u'; echo "$2"
    echo 'echo "MD=$MD"'; echo 'echo "DEST=$DEST"'; } > "$1"
}
probar_sonda() { # <ruta-sonda> <etiqueta>
  local s=$1 et=$2 out md dest
  if ! out=$(env -i HOME="$HOME_FALSO" PATH="${PATH:-/usr/bin:/bin}" bash "$s" 2>&1); then
    echo "FALLA $NOMBRE: la sonda de $et termino con error: $out"; return 1
  fi
  md=$(printf  '%s\n' "$out" | sed -n 's/^MD=//p'   | tail -1)
  dest=$(printf '%s\n' "$out" | sed -n 's/^DEST=//p' | tail -1)
  ULTIMO_DEST=$dest
  [ "$md" != "$VIEJO_MD" ] || {
    echo "FALLA $NOMBRE: $et dedujo MD='$md' (ruta de un solo puesto clavada) en lugar de '$PROY'"; return 1; }
  [ "$md" = "$PROY" ] || {
    echo "FALLA $NOMBRE: $et dedujo MD='$md', esperaba '$PROY'"; return 1; }
  case "$dest" in
    # CONTRATO ACTUALIZADO 2026-08-29. Antes DEST colgaba de $HOME (~/Vídeos) y
    # este check lo exigia. Pero las piezas acababan donde el autor no las veia
    # —lo dijo con estas palabras: "no sigas dejando en la torre que no las veo"—
    # asi que ahora DEST cuelga del PROYECTO, en videos/entregas.
    #
    # Lo que este check sigue defendiendo, que es lo que importa, es que DEST se
    # DEDUZCA y no este clavado: el arbol simulado esta en otro punto de montaje,
    # asi que un DEST correcto tiene que caer dentro de $PROY y no en la ruta de
    # la maquina donde se escribio el codigo.
    "$VIEJO_DEST_PRE"*) echo "FALLA $NOMBRE: $et dio DEST='$dest' (ruta clavada de un solo puesto)"; return 1;;
    "$PROY"/*) : ;;
    *) echo "FALLA $NOMBRE: $et dio DEST='$dest', que no cuelga del proyecto '$PROY'"; return 1;;
  esac
  [ "$dest" = "$PROY/videos/entregas" ] || {
    echo "FALLA $NOMBRE: $et dio DEST='$dest', esperaba '$PROY/videos/entregas'"; return 1; }
  return 0
}

# ── 4) Una sonda por cada script REAL, en su mismo directorio y con SU MISMA
#      linea de source: comprueba la deduccion tal y como la usa cada script,
#      sin arrancar sd-cli (aqui no hay GPU) ni tocar el repo.
N=0
while IFS= read -r f; do
  case "$f" in lib/*) continue;; *.sh) : ;; *) continue;; esac
  L=$(grep -m1 -E '^[[:space:]]*(\.|source)[[:space:]].*comun\.sh' "$PROY/$f") || continue
  N=$((N + 1))
  S="$PROY/$(dirname "$f")/.sonda-$N.sh"
  crear_sonda "$S" "$L"
  probar_sonda "$S" "$f" || exit 1
done < "$LISTA"

# Sondas sinteticas: las dos formas documentadas en la cabecera de comun.sh.
crear_sonda  "$PROY/.sonda-raiz.sh"            '. "$(dirname "${BASH_SOURCE[0]}")/lib/comun.sh"'
probar_sonda "$PROY/.sonda-raiz.sh"            "sonda a un nivel (raiz)"      || exit 1
crear_sonda  "$PROY/produccion/.sonda-prod.sh" '. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"'
probar_sonda "$PROY/produccion/.sonda-prod.sh" "sonda a dos niveles (produccion/)" || exit 1

# ── 5) Si casi ningun script sourcease comun.sh, la prueba seria vacia ─────
if [ "$N" -lt 5 ]; then
  echo "FALLA $NOMBRE: solo $N script(s) sourcean lib/comun.sh; el resto no usa la deduccion de MD"
  exit 1
fi

# ── 6) Tampoco en comun.sh puede reaparecer la ruta clavada ────────────────
C=$(clavadas_en todo)
if [ -n "$C" ]; then
  echo "FALLA $NOMBRE: rutas de un solo puesto de trabajo clavadas otra vez:"
  printf '%s\n' "$C" | head -10 | sed 's/^/    /'
  exit 1
fi

# El mensaje imprime el DEST que se MIDIO, no uno de ejemplo: durante el reorden
# de 2026-08-29 esta linea seguia anunciando el valor viejo aunque el check ya
# comprobaba el nuevo, y eso hizo dudar de un cambio que estaba bien.
echo "PASA $NOMBRE ($N scripts sourcean lib/comun.sh; MD='$PROY' y DEST='${ULTIMO_DEST:-?}' deducidos)"
exit 0