#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  VRAM — presupuesto de VRAM ADAPTATIVO, recalculado en caliente
#
#  Se sourcea desde cualquier script del proyecto:
#      . "$(dirname "${BASH_SOURCE[0]}")/lib/vram.sh"        # desde la raiz
#      . "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"     # desde produccion/
#
#  POR QUE sobre lo LIBRE y no sobre el TOTAL
#  ------------------------------------------
#  El escritorio de esta maquina ya ocupa ~3.7 GB de la 5070 Ti (15872 MiB
#  totales) en reposo, ANTES de que ningun proceso de la pipeline arranque.
#  La 2060 (5747 MiB) el escritorio no la toca. Un techo calculado sobre
#  memory.total (p.ej. 80% de 15872 = 12697 MiB) le promete a --max-vram mas
#  memoria de la que en la practica va a quedar libre cuando sd-cli la pida:
#  eso es, medido, lo que produjo los OOM de los planos p05 y p10 (ver
#  README.md y produccion/producir.sh). Calcular sobre memory.free JUSTO
#  ANTES de cada plano es lo unico que refleja lo que el escritorio esta
#  usando EN ESE INSTANTE, no lo que la GPU tiene de fabrica.
#
#  Por eso el presupuesto es ADAPTATIVO: no hay una constante "9 GB para la
#  GPU0" en ningun sitio de este fichero. Cada llamada a vram_libre() vuelve
#  a preguntarle a nvidia-smi, y vram_techo()/vram_arg() recalculan sobre esa
#  respuesta fresca.
#
#  Degradacion (nvidia-smi ausente, roto o con salida ilegible)
#  --------------------------------------------------------------
#  Todas las funciones de aqui degradan a VRAM_TECHO_FALLBACK_MIB (2048 MiB)
#  y avisan por stderr, en vez de dejar una variable vacia que reviente un
#  --max-vram ("cuda0=" sin numero es un argumento invalido para sd-cli).
#  2048 MiB no es un numero arbitrario: es el mismo valor que
#  produccion/producir.sh ya fija a mano hoy (MAXVRAM="cuda0=2"); si no hay
#  forma de medir la VRAM real, este fichero cae al numero que la pipeline
#  ya daba por seguro antes de que existiera.
#
#  Sourceable sin efectos: definir las funciones de abajo no ejecuta
#  nvidia-smi ni nada mas. Nada corre hasta que el llamador invoca una
#  funcion vram_*. Tampoco se toca ninguna opcion de shell (set -e/-u/...):
#  esas son decision del script que sourcea esto, igual que en lib/comun.sh.
# ═══════════════════════════════════════════════════════════════════════════

# Configurables por entorno, igual que W/H/FRAMES/STEPS en lib/comun.sh.
VRAM_TECHO_FALLBACK_MIB=${VRAM_TECHO_FALLBACK_MIB:-2048}
VRAM_COLCHON_MIB=${VRAM_COLCHON_MIB:-1024}
VRAM_FRACCION_DEFECTO=${VRAM_FRACCION_DEFECTO:-0.80}

# ── interno: valida que $1 sea un entero (>=0) y lo imprime; si no, falla ──
_vram_entero() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$1"
}

# vram_libre <idx> -> MiB libres AHORA en esa GPU, via nvidia-smi.
# Nunca imprime nada vacio: en modo degradado imprime VRAM_TECHO_FALLBACK_MIB
# y avisa por stderr.
vram_libre() {
  local idx=${1:-} mib
  if [ -z "$idx" ]; then
    echo "vram_libre: falta <idx>" >&2
    return 2
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "vram_libre: no hay nvidia-smi en el PATH; degradando a $VRAM_TECHO_FALLBACK_MIB MiB libres (GPU $idx)" >&2
    printf '%s\n' "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi
  mib=$(nvidia-smi -i "$idx" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]')
  if ! mib=$(_vram_entero "$mib"); then
    echo "vram_libre: nvidia-smi -i $idx no devolvio un numero valido ('$mib'); degradando a $VRAM_TECHO_FALLBACK_MIB MiB" >&2
    printf '%s\n' "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi
  printf '%s\n' "$mib"
}

# vram_total <idx> -> MiB totales de esa GPU. Misma degradacion que vram_libre.
vram_total() {
  local idx=${1:-} mib
  if [ -z "$idx" ]; then
    echo "vram_total: falta <idx>" >&2
    return 2
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "vram_total: no hay nvidia-smi en el PATH; degradando a $VRAM_TECHO_FALLBACK_MIB MiB (GPU $idx)" >&2
    printf '%s\n' "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi
  mib=$(nvidia-smi -i "$idx" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]')
  if ! mib=$(_vram_entero "$mib"); then
    echo "vram_total: nvidia-smi -i $idx no devolvio un numero valido ('$mib'); degradando a $VRAM_TECHO_FALLBACK_MIB MiB" >&2
    printf '%s\n' "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi
  printf '%s\n' "$mib"
}

# vram_techo <idx> [fraccion=0.80] -> MiB que podemos pedir: fraccion de lo
# LIBRE ahora mismo (nunca del total), redondeado a entero hacia abajo, y
# recortado para que jamas supere (libre - VRAM_COLCHON_MIB). El colchon es
# la ultima linea de defensa: aunque alguien pase una fraccion disparatada
# (1.5, 0, "cosa-invalida"...) el techo nunca se come el margen minimo.
vram_techo() {
  local idx=${1:-} fraccion=${2:-$VRAM_FRACCION_DEFECTO}
  if [ -z "$idx" ]; then
    echo "vram_techo: falta <idx>" >&2
    return 2
  fi
  if ! [[ $fraccion =~ ^[0-9]*\.?[0-9]+$ ]]; then
    echo "vram_techo: fraccion '$fraccion' no es un numero valido; usando $VRAM_FRACCION_DEFECTO" >&2
    fraccion=$VRAM_FRACCION_DEFECTO
  fi

  local libre techo tope
  libre=$(vram_libre "$idx")
  libre=$(_vram_entero "$libre") || libre=$VRAM_TECHO_FALLBACK_MIB   # defensa extra, no deberia dispararse

  techo=$(awk -v l="$libre" -v f="$fraccion" 'BEGIN { t = l * f; if (t < 0) t = 0; printf "%d", t }')

  tope=$(( libre - VRAM_COLCHON_MIB ))
  [ "$tope" -lt 0 ] && tope=0
  [ "$techo" -gt "$tope" ] && techo=$tope
  [ "$techo" -lt 0 ] && techo=0

  printf '%s\n' "$techo"
}

# vram_arg <idx> [fraccion] -> cadena lista para --max-vram, p.ej. "cuda0=9".
# sd-cli espera GIGAS enteros: se convierte MiB/1024 y se redondea A LA BAJA
# (division entera de bash ya trunca hacia 0 para valores no negativos).
# Si el techo redondea a 0 GB (GPU practicamente llena) se usa un piso de
# 1 GB y se avisa: "cuda0=0" es tan invalido para sd-cli como "cuda0=".
vram_arg() {
  local idx=${1:-} fraccion=${2:-}
  if [ -z "$idx" ]; then
    echo "vram_arg: falta <idx>" >&2
    return 2
  fi
  local techo_mib gb
  if [ -n "$fraccion" ]; then
    techo_mib=$(vram_techo "$idx" "$fraccion")
  else
    techo_mib=$(vram_techo "$idx")
  fi
  techo_mib=$(_vram_entero "$techo_mib") || techo_mib=0   # defensa extra

  gb=$(( techo_mib / 1024 ))
  if [ "$gb" -lt 1 ]; then
    echo "vram_arg: techo de ${techo_mib} MiB en GPU $idx redondea a 0 GB; se usa un piso de 1 GB para no pasarle a sd-cli un --max-vram en 0" >&2
    gb=1
  fi
  printf 'cuda%s=%s\n' "$idx" "$gb"
}

# vram_esperar <idx> <MiB> [seg=90] -> espera hasta que haya al menos <MiB>
# libres en esa GPU. Imprime los MiB libres alcanzados y devuelve 0, o
# expira tras [seg] segundos y devuelve 1 (avisando por stderr). Sondea cada
# 2 s. Si no hay nvidia-smi, esperar no sirve de nada (el numero nunca va a
# cambiar): resuelve de una con el valor degradado en vez de dormir [seg] s
# sin sentido.
vram_esperar() {
  local idx=${1:-} minimo=${2:-} seg=${3:-90}
  if [ -z "$idx" ] || [ -z "$minimo" ]; then
    echo "vram_esperar: uso: vram_esperar <idx> <MiB> [seg]" >&2
    return 2
  fi
  if ! [[ $minimo =~ ^[0-9]+$ ]]; then
    echo "vram_esperar: <MiB> debe ser un entero, dio '$minimo'" >&2
    return 2
  fi
  if ! [[ $seg =~ ^[0-9]+$ ]]; then
    echo "vram_esperar: [seg] '$seg' invalido; usando 90" >&2
    seg=90
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "vram_esperar: no hay nvidia-smi en el PATH; no tiene sentido esperar, degradando de una a $VRAM_TECHO_FALLBACK_MIB MiB" >&2
    if [ "$VRAM_TECHO_FALLBACK_MIB" -ge "$minimo" ]; then
      printf '%s\n' "$VRAM_TECHO_FALLBACK_MIB"
      return 0
    fi
    return 1
  fi

  local t0=$SECONDS libre
  while :; do
    libre=$(vram_libre "$idx")
    if [ "$libre" -ge "$minimo" ]; then
      printf '%s\n' "$libre"
      return 0
    fi
    if [ $(( SECONDS - t0 )) -ge "$seg" ]; then
      echo "vram_esperar: expiro tras ${seg}s esperando ${minimo} MiB libres en GPU $idx (quedaron ${libre} MiB)" >&2
      return 1
    fi
    sleep 2
  done
}

# vram_informe -> una linea por GPU detectada: total, libre y techo actuales.
# En modo degradado imprime una unica linea de aviso con GPU "?".
vram_informe() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "vram_informe: no hay nvidia-smi en el PATH; degradando a valores seguros" >&2
    printf 'GPU?: total=%s MiB  libre=%s MiB  techo=%s MiB  (degradado, sin nvidia-smi)\n' \
      "$VRAM_TECHO_FALLBACK_MIB" "$VRAM_TECHO_FALLBACK_MIB" "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi

  local idxs
  idxs=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null)
  if [ -z "$idxs" ]; then
    echo "vram_informe: nvidia-smi no listo ninguna GPU; degradando a valores seguros" >&2
    printf 'GPU?: total=%s MiB  libre=%s MiB  techo=%s MiB  (degradado, sin GPUs)\n' \
      "$VRAM_TECHO_FALLBACK_MIB" "$VRAM_TECHO_FALLBACK_MIB" "$VRAM_TECHO_FALLBACK_MIB"
    return 0
  fi

  local idx tot lib tec
  while IFS= read -r idx; do
    idx=$(printf '%s' "$idx" | tr -d '[:space:]')
    [ -n "$idx" ] || continue
    tot=$(vram_total "$idx")
    lib=$(vram_libre "$idx")
    tec=$(vram_techo "$idx")
    printf 'GPU%s: total=%s MiB  libre=%s MiB  techo=%s MiB\n' "$idx" "$tot" "$lib" "$tec"
  done <<EOF_IDXS
$idxs
EOF_IDXS
}
