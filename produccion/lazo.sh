#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  LAZO — produce, mide, mira, decide, repite. Hasta la meta o hasta el tiempo.
#
#  Uso: lazo.sh <guion> <nombre> [--meta 85] [--horas 8] [--frames 345]
#                                [--w 736] [--h 416] [--pasos 20] [--dry-run]
#
#  ESTRATEGIA, derivada de lo medido y no de la intuicion:
#
#    El modelo NO se degrada con la duracion. Un plano solo mantiene gradacion
#    25/25 y estructura 20/20 desde 56 hasta 517 frames. Lo unico que degrada es
#    el ESLABON: encadenar cuatro planos hunde el montaje de 95.0 a 68.7, con un
#    acantilado en el tercer enlace. Por eso este lazo NO encadena: produce UNA
#    TOMA lo mas larga que quepa, y lo que varia entre intentos son la semilla,
#    los pasos y el enfasis del prompt.
#
#    Palancas, de barata a cara:
#      1. SEMILLA   otra tirada, mismo coste, resultados muy distintos
#      2. PASOS     mas pasos = mejor adherencia al prompt (medido: a 4 pasos
#                   el encuadre se va y el fondo deja de ser negro)
#      3. FRAMES    acortar si no cupo; alargar si sobra margen
#
#    NO hay palanca de desenfoque: mejoraba la nota destruyendo la imagen.
#
#  Cada intento se mide Y se deja una hoja de contactos, porque evaluar2 mide
#  degradacion y no belleza: un video puede sacar 90 y estar mal encuadrado.
#
#  REANUDABLE y NO DESTRUCTIVO: cada intento se guarda con su nota; el mejor
#  se enlaza como mejor.avi. Nunca se borra nada.
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
PROD=$MD/produccion
CAL=$MD/calidad   # las herramientas de medida viven aparte

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}; shift 2
META=85; HORAS=8; FRAMES=345; W=736; H=416; PASOS=20; SECO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --meta) META=$2; shift 2 ;;  --horas) HORAS=$2; shift 2 ;;
    --frames) FRAMES=$2; shift 2 ;; --w) W=$2; shift 2 ;; --h) H=$2; shift 2 ;;
    --pasos) PASOS=$2; shift 2 ;;  --dry-run) SECO=1; shift ;;
    *) echo "opcion desconocida: $1"; exit 2 ;;
  esac
done

OBRA=$PROD/obra/$NOMBRE; mkdir -p "$OBRA/intentos"
BIT=$OBRA/lazo.log; EST=$OBRA/lazo-estado.json
LIMITE=$(( $(date +%s) + HORAS*3600 ))
anota() { echo "[$(date '+%F %H:%M:%S')] $*" | tee -a "$BIT"; }

# Semillas ya probadas, para reanudar sin repetir trabajo caro.
PROBADAS=""; MEJOR_NOTA=0; MEJOR=""
if [ -f "$EST" ]; then
  PROBADAS=$(python3 -c "import json;print(' '.join(str(s) for s in json.load(open('$EST')).get('semillas',[])))" 2>/dev/null || echo "")
  MEJOR_NOTA=$(python3 -c "import json;print(json.load(open('$EST')).get('mejor_nota',0))" 2>/dev/null || echo 0)
  MEJOR=$(python3 -c "import json;print(json.load(open('$EST')).get('mejor','') )" 2>/dev/null || echo "")
fi

guardar() {
  python3 - "$EST" "$MEJOR_NOTA" "$MEJOR" "$PROBADAS" <<'PY'
import json,sys
est,mn,mj,pr = sys.argv[1:5]
json.dump({"mejor_nota": float(mn), "mejor": mj,
           "semillas": [int(x) for x in pr.split()] if pr.strip() else []},
          open(est,"w"), indent=1)
PY
}

anota "═══ LAZO $NOMBRE · meta $META · ${HORAS}h · ${W}x${H} ${FRAMES}f ${PASOS} pasos"
[ -n "$PROBADAS" ] && anota "reanudando: semillas ya probadas [$PROBADAS], mejor hasta ahora $MEJOR_NOTA"

INTENTO=0
for SEMILLA in 100 200 300 400 500 600 700 800; do
  case " $PROBADAS " in *" $SEMILLA "*) anota "semilla $SEMILLA ya probada, salto"; continue ;; esac
  INTENTO=$((INTENTO+1))
  if [ "$(date +%s)" -ge "$LIMITE" ]; then anota "tiempo agotado"; break; fi

  anota "intento $INTENTO · semilla $SEMILLA"
  if [ $SECO -eq 1 ]; then
    anota "[SECO] generaria ${FRAMES}f a ${W}x${H}, ${PASOS} pasos, semilla $SEMILLA"
    NOTA=$(awk -v i=$INTENTO 'BEGIN{print 70+i*6}')   # simulacion creciente
  else
    SEED=$SEMILLA bash "$PROD/producir-toma-unica.sh" "$GUION" "$NOMBRE" \
         "$FRAMES" "$W" "$H" "$PASOS" >> "$BIT" 2>&1
    V=$OBRA/p01.avi
    [ -f "$V" ] || { anota "intento $INTENTO fallo la generacion"; PROBADAS="$PROBADAS $SEMILLA"; guardar; continue; }
    mv "$V" "$OBRA/intentos/s$SEMILLA.avi"; V=$OBRA/intentos/s$SEMILLA.avi
    NOTA=$(python3 "$CAL/evaluar2.py" "$V" 2>/dev/null | sed -n 's/.*TOTAL \([0-9.]*\).*/\1/p')
    python3 "$CAL/auditar.py" contacto "$V" "$OBRA/intentos/s$SEMILLA.jpg" >/dev/null 2>&1
    python3 "$CAL/auditar.py" audio "$V" 2>/dev/null | tee -a "$BIT"
  fi
  PROBADAS="$PROBADAS $SEMILLA"
  anota "intento $INTENTO · semilla $SEMILLA · nota ${NOTA:-0}"

  if awk -v n="${NOTA:-0}" -v m="$MEJOR_NOTA" 'BEGIN{exit !(n>m)}'; then
    MEJOR_NOTA=$NOTA; MEJOR=${V:-simulado}
    [ $SECO -eq 0 ] && ln -sf "$(basename "$V")" "$OBRA/intentos/mejor.avi"
    anota "nuevo mejor: $MEJOR_NOTA"
  fi
  guardar

  if awk -v n="$MEJOR_NOTA" -v m="$META" 'BEGIN{exit !(n>=m)}'; then
    anota "META ALCANZADA: $MEJOR_NOTA >= $META  ->  $MEJOR"
    anota "MIRA la hoja de contactos antes de darlo por bueno: la nota mide"
    anota "degradacion, no belleza."
    break
  fi
done

anota "═══ FIN · $INTENTO intentos · mejor $MEJOR_NOTA · $MEJOR"
