#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  LAZO — produce, mide, decide, repite. Hasta la meta o hasta agotar el tiempo.
#
#  Uso:  lazo.sh <guion> <nombre> [--meta 85] [--horas 8] [--dry-run]
#
#  Palancas, de barata a cara. NO hay palanca de desenfoque: se probo y se
#  descarto porque mejoraba el numero destruyendo detalle (ver lib/enlace.sh).
#    1. REANCLAR  reescribe la linea del guion a "ancla:anclas/aNN.png" y
#                 regenera ese plano. Resetea la deriva sin tocar pixeles.
#    2. REGENERAR mismo plano, otra semilla.
#    3. TOPOLOGIA planos mas largos -> menos eslabones. Lo mas caro y lo mas
#                 eficaz: medido, cada eslabon cuesta puntos y el tercero
#                 se lleva 19 de golpe (95.0 / 89.0 / 87.7 / 68.7).
#
#  REANUDABLE: guarda estado tras cada accion. Si lo matan, continua donde iba.
#  NO DESTRUCTIVO: antes de regenerar, el plano viejo va a descartes/.
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh" 2>/dev/null || true
PROD=$MD/produccion

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}; shift 2
META=85; HORAS=8; SECO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --meta)  META=$2; shift 2 ;;
    --horas) HORAS=$2; shift 2 ;;
    --dry-run) SECO=1; shift ;;
    *) echo "opcion desconocida: $1"; exit 2 ;;
  esac
done

OBRA=$PROD/obra/$NOMBRE
EST=$OBRA/lazo-estado.json
BIT=$OBRA/lazo.log
mkdir -p "$OBRA/descartes"
LIMITE=$(( $(date +%s) + HORAS*3600 ))

anota() { echo "[$(date '+%F %H:%M:%S')] $*" | tee -a "$BIT"; }

guardar_estado() {  # $1=iteracion $2=nota $3=accion $4=detalle
  cat > "$EST" <<JSON
{ "nombre": "$NOMBRE", "iteracion": $1, "nota": ${2:-null},
  "ultima_accion": "$3", "detalle": "$4",
  "meta": $META, "sello": "$(date -Iseconds)" }
JSON
}

nota_actual() {
  local j; j=$(python3 "$PROD/auditar.py" obra "$OBRA" --json 2>/dev/null) || return 1
  python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(d.get('nota_media_planos') or 0, d.get('accion','NINGUNA'),
      (d.get('peor_enlace') or {}).get('a',''))" <<<"$j"
}

# ── el bucle ───────────────────────────────────────────────────────────────
ITER=0; PREV=""; SIN_MEJORA=0
[ -f "$EST" ] && ITER=$(python3 -c "import json;print(json.load(open('$EST'))['iteracion'])" 2>/dev/null || echo 0)
anota "═══ LAZO: $NOMBRE · meta $META · $HORAS h · reanudando en iteracion $ITER"

while :; do
  ITER=$((ITER+1))
  if [ "$(date +%s)" -ge "$LIMITE" ]; then anota "tiempo agotado tras $((ITER-1)) iteraciones"; break; fi

  if [ $SECO -eq 0 ]; then
    anota "iteracion $ITER: produciendo"
    DEST="$DEST" bash "$PROD/producir.sh" "$GUION" "$NOMBRE" >> "$BIT" 2>&1
  else
    anota "iteracion $ITER: [SECO] se omite la produccion"
  fi

  read -r NOTA ACCION PLANO < <(nota_actual) || { anota "no pude auditar; abandono"; break; }
  anota "iteracion $ITER: nota $NOTA · accion sugerida $ACCION ${PLANO:+sobre $PLANO}"
  guardar_estado "$ITER" "$NOTA" "$ACCION" "$PLANO"

  if awk -v n="$NOTA" -v m="$META" 'BEGIN{exit !(n>=m)}'; then
    anota "META ALCANZADA: $NOTA >= $META"; break
  fi

  if [ -n "$PREV" ] && awk -v a="$NOTA" -v b="$PREV" 'BEGIN{exit !(a<=b)}'; then
    SIN_MEJORA=$((SIN_MEJORA+1))
    anota "sin mejora ($PREV -> $NOTA), van $SIN_MEJORA"
    [ $SIN_MEJORA -ge 2 ] && { anota "dos acciones sin mejorar: paro para no quemar GPU en un minimo local"; break; }
  else
    SIN_MEJORA=0
  fi
  PREV=$NOTA

  case "$ACCION" in
    REANCLAR|REGENERAR)
      if [ $SECO -eq 1 ]; then anota "[SECO] aplicaria $ACCION a $PLANO"; break; fi
      V=$OBRA/${PLANO}.avi
      [ -f "$V" ] && mv "$V" "$OBRA/descartes/${PLANO}-$(date +%Y%m%d-%H%M%S).avi" \
        && anota "plano $PLANO apartado en descartes/ (nunca se borra)"
      ;;
    NINGUNA) anota "sin accion aplicable y por debajo de la meta: paro"; break ;;
    *)       anota "accion no reconocida: $ACCION"; break ;;
  esac
done

anota "═══ FIN · iteraciones $ITER · ultima nota ${PREV:-—} · bitacora $BIT"
