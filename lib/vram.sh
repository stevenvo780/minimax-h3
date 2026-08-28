#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  VRAM — presupuesto ADAPTATIVO, recalculado en caliente.
#
#  Por que sobre lo LIBRE y no sobre el total: el escritorio del usuario ocupa
#  ~3.4 GB de la 5070 Ti. Un techo calculado sobre los 16 GB totales se come su
#  margen y provoca OOM — es exactamente lo que tumbo p05 y p10 en produccion.
#  Y la sobrecorreccion tampoco vale: los scripts quedaron en --max-vram cuda0=2,
#  usando 2 GB de 16.
#
#  Uso:  . lib/vram.sh
#        vram_arg 0          -> "cuda0=9"   para --max-vram
#        vram_esperar 0 6000 -> espera a que haya 6 GB libres
# ═══════════════════════════════════════════════════════════════════════════

VRAM_FRACCION=${VRAM_FRACCION:-0.80}   # del hueco libre, no del total
VRAM_COLCHON=${VRAM_COLCHON:-1024}     # MiB que nunca se piden, pase lo que pase

_vram_q() {  # $1=idx  $2=campo
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local v; v=$(nvidia-smi -i "$1" --query-gpu="$2" --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  echo "$v"
}

vram_libre() { _vram_q "$1" memory.free  || { echo "vram: no puedo leer la GPU $1" >&2; return 1; }; }
vram_total() { _vram_q "$1" memory.total || { echo "vram: no puedo leer la GPU $1" >&2; return 1; }; }

# MiB que podemos pedir sin comernos el margen del usuario.
vram_techo() {
  local idx=$1 frac=${2:-$VRAM_FRACCION} libre techo
  libre=$(vram_libre "$idx") || return 1
  techo=$(awk -v l="$libre" -v f="$frac" -v c="$VRAM_COLCHON" '
    BEGIN{ t=int(l*f); if (t > l-c) t=l-c; if (t<0) t=0; print t }')
  echo "$techo"
}

# Cadena para --max-vram. sd-cli espera GIGAS: se redondea A LA BAJA.
# Si algo falla devuelve un valor conservador en vez de una cadena vacia, que
# le llegaria a sd-cli como "--max-vram cuda0=" y reventaria de forma opaca.
vram_arg() {
  local idx=$1 techo g
  techo=$(vram_techo "$idx" "${2:-$VRAM_FRACCION}") || { echo "cuda${idx}=2"; return 0; }
  g=$(( techo / 1024 ))
  [ "$g" -lt 1 ] && g=1
  echo "cuda${idx}=${g}"
}

# Espera a que se libere sitio en vez de reventar con OOM.
vram_esperar() {
  local idx=$1 need=$2 max=${3:-900} t=0 libre
  while [ "$t" -lt "$max" ]; do
    libre=$(vram_libre "$idx") || return 1
    [ "$libre" -ge "$need" ] && return 0
    sleep 15; t=$((t+15))
  done
  echo "vram: tras ${max}s la GPU $idx sigue sin $need MiB libres" >&2
  return 1
}

vram_informe() {
  local i
  for i in 0 1; do
    local t l h
    t=$(vram_total "$i" 2>/dev/null) || continue
    l=$(vram_libre "$i"); h=$(vram_techo "$i")
    printf "  GPU%d  total %5d  libre %5d  techo %5d MiB  (--max-vram %s)\n" \
      "$i" "$t" "$l" "$h" "$(vram_arg "$i")"
  done
}
