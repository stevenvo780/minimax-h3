#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRODUCIR — pipeline estandarizado MiniMax-H3
#  Uso:  producir.sh <guion> [nombre]
#  Ej:   producir.sh guiones/existencialismo.guion existencialismo
#
#  Lee un .guion (ver formato en el propio fichero), genera los planos HABLA
#  encadenando los marcados "encadena", inserta los BROLL ya existentes y
#  ensambla el vídeo final en ~/Vídeos.
#
#  RESUMIBLE: los planos ya generados en obra/<nombre>/ se saltan.
#  NO destructivo: nunca sobrescribe material de entrada.
# ═══════════════════════════════════════════════════════════════════════════
set -u

GUION=${1:?falta el guion}
NOMBRE=${2:-$(basename "$GUION" .guion)}
SEED=${SEED:-100}

. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
params_defecto 1376 768 107 20
PROD=$MD/produccion

# Este script fuerza tambien la VAE a CPU y un techo de VRAM bajo.
PARAMS_BACKEND="diffusion=cpu,vae=cpu"
MAXVRAM="cuda0=2"

OBRA=$PROD/obra/$NOMBRE
mkdir -p "$OBRA" "$PROD/logs"
[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }

# ── parsear cabecera ───────────────────────────────────────────────────────
ESCENA=$(grep -m1 '^@ESCENA '   "$GUION" | sed 's/^@ESCENA //')
AMBIENTE=$(grep -m1 '^@AMBIENTE ' "$GUION" | sed 's/^@AMBIENTE //')
MUSICA=$(grep -m1 '^@MUSICA '   "$GUION" | sed 's/^@MUSICA //')

# ── generar un plano hablado ───────────────────────────────────────────────
generar_habla() {   # $1=idx  $2=dialogo  $3=init_img(o vacio)  $4=encuadre
  local IDX=$1 DIA=$2 INIT=$3 ENC=${4:-}
  local OUT=$OBRA/p$IDX
  [ -f "$OUT.avi" ] && { echo "  p$IDX ya existe, salto"; return 0; }
  local PROMPT="detailed_description:
The target video is in realistic photographic style. [Shot 1] $ESCENA ${ENC:+$ENC. }He pauses, then speaks with calm deliberation. Subject 1 (S1) says, <d>[Spanish] $DIA</d> Exactly as his voice stops, his lips settle closed and he holds the gaze, breathing slowly.

overall_soundscape:
$AMBIENTE

non_diegetic_music:
$MUSICA"
  local EXTRA=(); [ -n "$INIT" ] && EXTRA+=(--init-img "$INIT")
  local T0=$SECONDS
  sd_vid_gen "$PROMPT" "$OUT.mp4" -s $((SEED + 10#$IDX)) "${EXTRA[@]}" > "$PROD/logs/$NOMBRE-p$IDX.log" 2>&1
  if [ -f "$(sd_salida "$OUT.mp4")" ]; then
    mv "$(sd_salida "$OUT.mp4")" "$OUT.avi"
    echo "  p$IDX OK en $((SECONDS-T0))s${INIT:+ (encadenado)}"
    return 0
  fi
  # OOM transitorio (picos de VRAM del escritorio): reintentar hasta 4 veces
  if grep -qa "out of memory" "$PROD/logs/$NOMBRE-p$IDX.log" 2>/dev/null; then
    local try=1
    while [ $try -le 4 ]; do
      echo "  p$IDX OOM, reintento $try/4 en 90s (VRAM libre: $(nvidia-smi -i 0 --query-gpu=memory.free --format=csv,noheader))"
      sleep 90
      T0=$SECONDS
      sd_vid_gen "$PROMPT" "$OUT.mp4" -s $((SEED + 10#$IDX)) "${EXTRA[@]}" > "$PROD/logs/$NOMBRE-p$IDX.log" 2>&1
      if [ -f "$(sd_salida "$OUT.mp4")" ]; then
        mv "$(sd_salida "$OUT.mp4")" "$OUT.avi"
        echo "  p$IDX OK en $((SECONDS-T0))s (reintento $try)${INIT:+ (encadenado)}"
        return 0
      fi
      try=$((try+1))
    done
  fi
  echo "  p$IDX FALLO DEFINITIVO"; grep -aoE "out of memory|allocating [0-9.]+ MiB" "$PROD/logs/$NOMBRE-p$IDX.log" | tail -2
  return 1
}

ultimo_frame() {  # $1=avi  $2=png destino
  ff -y -v error -sseof -0.05 -i "$1" -frames:v 1 -update 1 "$2" 2>/dev/null
  [ -f "$2" ] || ff -y -v error -i "$1" -vf "select=eq(n\,$((FRAMES-1)))" -frames:v 1 -update 1 "$2" 2>/dev/null
}

# ── recorrer el guion ──────────────────────────────────────────────────────
echo "═══ PRODUCIENDO: $NOMBRE ═══  $(date '+%F %H:%M:%S')"
echo "    ${W}x${H}, ${FRAMES}f, ${STEPS} pasos"
IDX=0; PREV=""; ENC_TRAMO=""; : > "$OBRA/orden.txt"
while IFS='|' read -r TIPO CONT MODO ENCU; do
  case "$TIPO" in
    HABLA)
      IDX=$((IDX+1)); N=$(printf "%02d" $IDX)
      case "${MODO:-}" in
        encadena) ENCU="${ENCU:-$ENC_TRAMO}" ;;
        ancla:*)  PREV="$OBRA/${MODO#ancla:}"; ENC_TRAMO="${ENCU:-}"
                  [ -f "$PREV" ] || { echo "  ANCLA NO ENCONTRADA: $PREV"; PREV=""; } ;;
        *)        PREV=""; ENC_TRAMO="${ENCU:-}" ;;
      esac
      if generar_habla "$N" "$CONT" "$PREV" "${ENCU:-}"; then
        case "${MODO:-}" in encadena) MARCA="cont";; *) MARCA="tramo";; esac
        printf "%s\t%s\n" "$OBRA/p$N.avi" "$MARCA" >> "$OBRA/orden.txt"
        PREV=$OBRA/last$N.png; ultimo_frame "$OBRA/p$N.avi" "$PREV"
        [ -f "$PREV" ] || PREV=""
      fi
      ;;
    BROLL)
      SRC="$MD/proyecto-minuto/$CONT"
      [ -f "$SRC" ] || SRC="$CONT"
      if [ -f "$SRC" ]; then
        echo "$SRC" >> "$OBRA/orden.txt"; echo "  broll: $(basename $SRC)"
      else
        echo "  broll NO ENCONTRADO: $CONT"
      fi
      PREV=""    # tras un corte visual no se encadena
      ;;
  esac
done < <(grep -E "^(HABLA|BROLL)\|" "$GUION")

# ── ensamblar ──────────────────────────────────────────────────────────────
echo "═══ ENSAMBLANDO ($(wc -l < "$OBRA/orden.txt") planos) ═══"
MONT=$OBRA/montaje; mkdir -p "$MONT"; rm -f "$MONT"/*.mp4 "$MONT/lista.txt" "$MONT/tramos.txt" 2>/dev/null
DUR=$(awk "BEGIN{printf \"%.4f\", $FRAMES/24}")
i=0
while IFS=$'\t' read -r f marca; do
  i=$((i+1)); n=$(printf "%02d" $i)
  [ "$marca" = "tramo" ] && [ $i -gt 1 ] && echo "$n" >> "$MONT/tramos.txt"
  CLIPDUR=$(ffp -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
  CLIPDUR=${CLIPDUR:-$DUR}
  if ff -y -v error -i "$f" \
    -af "loudnorm=I=-19:TP=-2:LRA=7,afade=t=in:st=0:d=0.25,afade=t=out:st=$(awk "BEGIN{print $CLIPDUR-0.25}"):d=0.25" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k "$MONT/$n.mp4"; then
    echo "file '$MONT/$n.mp4'" >> "$MONT/lista.txt"
  else
    echo "  CLIP $i FALLO al procesar ($f) — OMITIDO del montaje"
  fi
done < "$OBRA/orden.txt"

STAMP=$(date +%Y%m%d-%H%M%S)
SEC=$(awk "BEGIN{printf \"%.0f\", $i*$DUR}")
FINAL="$DEST/$NOMBRE-${W}x${H}-${SEC}s-$STAMP.mp4"

# ── Guarda: sin clips no hay nada que concatenar ───────────────────────────
[ -s "$MONT/lista.txt" ] || { echo "FALLO: ningun clip llego al montaje. Revisa $PROD/logs/"; exit 1; }

# ── Guarda: "concat -c copy" con resoluciones distintas produce un fichero
#    corrupto SIN dar ningun error. Mas vale parar aqui que entregar basura.
declare -A DIMS
while read -r f; do
  d=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null)
  [ -n "$d" ] || { echo "FALLO: no se pudieron leer las dimensiones de $f"; exit 1; }
  DIMS[$d]=$(( ${DIMS[$d]:-0} + 1 ))
done < <(grep "^file " "$MONT/lista.txt" | cut -d"'" -f2)
if [ ${#DIMS[@]} -gt 1 ]; then
  echo "FALLO: los clips NO comparten resolucion, el concat saldria corrupto:"
  for d in "${!DIMS[@]}"; do echo "    ${DIMS[$d]} clip(s) a ${d/,/x}"; done
  echo "    (suele pasar al mezclar BROLL de 1376x768 con planos generados a otra W/H)"
  echo "    los clips ya procesados estan intactos en $MONT/"
  exit 1
fi

# Union DURA dentro de cada tramo (la continuidad es exacta), FUNDIDO entre tramos.
if [ -s "$MONT/tramos.txt" ]; then
  echo "  fundidos entre tramos: $(tr '\n' ' ' < $MONT/tramos.txt)"
  python3 "$PROD/fundir.py" "$MONT" "$FINAL" || \
    ff -y -v error -f concat -safe 0 -i "$MONT/lista.txt" -c copy "$FINAL"
else
  ff -y -v error -f concat -safe 0 -i "$MONT/lista.txt" -c copy "$FINAL"
fi
[ -f "$FINAL" ] || { echo "FALLO al ensamblar"; exit 1; }
echo "═══ LISTO: $FINAL ═══"
ffp -v error -show_entries format=duration,size -show_entries stream=codec_type,width,height,nb_frames \
        -of default=noprint_wrappers=1 "$FINAL"
