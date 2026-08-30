#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ESCALAR — sube una pieza de 736x416 con RealESRGAN x4 y la remonta a 1080p.
#
#  Por que hacia falta: TODO se entregaba a 736x416, que en cualquier pantalla
#  se ve pobre. Steven lo dijo con esas palabras —"la calidad aun es muy
#  pobre"—. La resolucion de GENERACION esta limitada por la VRAM (el buffer
#  crece con frames x pixeles), pero escalar despues no compite con generar.
#
#  Tres cosas que la version anterior hacia mal y costaban la tarea entera:
#
#  1. TILE FIJO EN 512. En la RTX 2060 eso aborta SIEMPRE con
#     "cublasCreate_v2 ... the resource allocation failed", asi que fallaban
#     los N fotogramas y el script terminaba negandose a montar un video
#     incompleto — correcto, pero nunca escalo nada. Ahora el tile se NEGOCIA
#     contra la GPU real: se prueba una escalera descendente con el primer
#     fotograma y se usa el primero que sobreviva.
#
#  2. UN SOLO PROCESO. A ~20 s/fotograma en la 2060, una pieza de 46 s (1104
#     fotogramas) son 6 horas. Ahora reparte entre las GPU que tengan hueco.
#
#  3. NO REANUDABLE. Si se cortaba a las 5 horas se perdia todo. Ahora los
#     fotogramas ya escalados se saltan, asi que volver a lanzarlo continua.
#
#  Reserva de hardware: la 5070 Ti solo se usa si le sobran GPU0_MINIMO MiB
#  DESPUES de nuestro trabajo. Si el usuario la esta usando, se escala entero
#  en la 2060 — mas lento, pero sin quitarle la maquina a nadie.
#
#  Uso:  escalar.sh <video.mp4> [salida.mp4]
#  Entorno: ALTURA=1080  TILE=  GPU0_MINIMO=3000  TRABAJO=<dir reanudable>
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1

IN=${1:?falta el video}
[ -f "$IN" ] || { echo "no existe: $IN"; exit 1; }
BASE=$(basename "$IN" .mp4)
ALTURA=${ALTURA:-1080}
GPU0_MINIMO=${GPU0_MINIMO:-3000}     # MiB que le dejamos libres al usuario
OUT=${2:-$MD/videos/entregas/${BASE%%-[0-9]*x[0-9]*-*}-${ALTURA}p.mp4}

ANCHO=$(ffp -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$IN")
ALTO=$(ffp  -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")
FPS=$(ffp   -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$IN" | head -1)
echo "═══ escalando $BASE · ${ANCHO}x${ALTO} -> ${ALTURA}p ═══"

# ── directorio de trabajo: reanudable a proposito ──────────────────────────
T=${TRABAJO:-$MD/produccion/obra/_escala/$BASE}
mkdir -p "$T/in" "$T/out" || exit 1
if [ "$(ls -1 "$T/in" 2>/dev/null | wc -l)" -eq 0 ]; then
  ff -v error -i "$IN" "$T/in/%05d.png" || { echo "FALLO extrayendo fotogramas"; exit 1; }
fi
TOT=$(ls -1 "$T/in" | wc -l)
YA=$(ls -1 "$T/out" 2>/dev/null | wc -l)
[ "$TOT" -gt 0 ] || { echo "FALLO: 0 fotogramas"; exit 1; }
echo "  $TOT fotogramas · $YA ya escalados de una corrida anterior"

# ── que GPU podemos usar sin quitarle la maquina al usuario ────────────────
libre_mib() { nvidia-smi -i "$1" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }
GPUS=()
L1=$(libre_mib 1); [ "${L1:-0}" -gt 2000 ] && GPUS+=(1)
L0=$(libre_mib 0); [ "${L0:-0}" -gt $((GPU0_MINIMO + 2000)) ] && GPUS+=(0)
if [ ${#GPUS[@]} -eq 0 ]; then
  echo "FALLO: ninguna GPU con hueco (0: ${L0:-?} MiB, 1: ${L1:-?} MiB libres)."
  echo "       No arranco: prefiero no pelear por la memoria que estas usando."
  exit 1
fi
echo "  GPU utilizables: ${GPUS[*]}  (0: ${L0:-?} MiB libres, 1: ${L1:-?} MiB)"

# ── negociar el tile contra la GPU real ────────────────────────────────────
# La escalera baja: 512 va bien en la 5070 Ti y aborta en la 2060.
negociar_tile() {   # $1 = indice de GPU  -> imprime el tile que funciona
  local g=$1 t
  local muestra; muestra=$(ls -1 "$T/in"/*.png | head -1)
  for t in ${TILE:-512 384 256 192 128}; do
    if CUDA_VISIBLE_DEVICES=$g "$SDCLI" -M upscale -i "$muestra" \
         --upscale-model "$UPSCALER" --upscale-tile-size "$t" --backend CUDA0 \
         -o "$T/.sonda-$g.png" </dev/null >"$T/.sonda-$g.log" 2>&1; then
      rm -f "$T/.sonda-$g.png"; echo "$t"; return 0
    fi
  done
  return 1
}
declare -A TILE_DE
for g in "${GPUS[@]}"; do
  if t=$(negociar_tile "$g"); then
    TILE_DE[$g]=$t; echo "  GPU $g: tile $t"
  else
    echo "  GPU $g: ningun tile funciona, la descarto"; tail -3 "$T/.sonda-$g.log" | sed 's/^/      /'
  fi
done
USABLES=(); for g in "${GPUS[@]}"; do [ -n "${TILE_DE[$g]:-}" ] && USABLES+=("$g"); done
[ ${#USABLES[@]} -gt 0 ] || { echo "FALLO: ninguna GPU escala"; exit 1; }

# ── repartir: un worker por GPU utilizable ─────────────────────────────────
ls -1 "$T/in"/*.png > "$T/todos.txt"
rm -f "$T"/parte-* "$T"/worker-*.log
split -n "r/${#USABLES[@]}" -d "$T/todos.txt" "$T/parte-"
trabajar() {   # $1 = GPU  $2 = fichero con la lista
  local g=$1 lista=$2 t=${TILE_DE[$1]}
  while read -r f; do
    local o="$T/out/$(basename "$f")"
    [ -s "$o" ] && continue                       # reanudable
    CUDA_VISIBLE_DEVICES=$g "$SDCLI" -M upscale -i "$f" \
      --upscale-model "$UPSCALER" --upscale-tile-size "$t" --backend CUDA0 \
      -o "$o" </dev/null >>"$T/worker-$g.log" 2>&1 || echo "fallo $(basename "$f")" >>"$T/worker-$g.log"
  done < "$lista"
}
T0=$SECONDS
PIDS=(); i=0
for g in "${USABLES[@]}"; do
  trabajar "$g" "$(printf '%s/parte-%02d' "$T" "$i")" &
  PIDS+=($!); i=$((i+1))
done
# ── barra de progreso con ETA real ─────────────────────────────────────────
# `jobs %%` NO sirve para esto: imprime un error cuando no hay trabajos en vez
# de devolver un codigo util. Se comprueba cada PID con kill -0.
vivos() { local p; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
while vivos; do
  hechos=$(ls -1 "$T/out" 2>/dev/null | wc -l)
  tr=$((SECONDS-T0)); nuevos=$((hechos-YA))
  if [ "$nuevos" -gt 0 ]; then
    eta=$(( tr * (TOT-hechos) / nuevos ))
    printf "\r    %d/%d  ·  %ds transcurridos  ·  faltan ~%dm   " "$hechos" "$TOT" "$tr" "$((eta/60))"
  fi
  sleep 20
done
for p in "${PIDS[@]}"; do wait "$p"; done
echo
HECHOS=$(ls -1 "$T/out" 2>/dev/null | wc -l)
echo "  escalados $HECHOS de $TOT en $((SECONDS-T0))s"
if [ "$HECHOS" -lt "$TOT" ]; then
  echo "FALLO: faltan fotogramas, no monto un video incompleto."
  echo "       El trabajo queda en $T — vuelve a lanzarlo y continua donde iba."
  grep -c fallo "$T"/worker-*.log 2>/dev/null | sed 's/^/       /'
  exit 1
fi

ff -y -v error -framerate "${FPS:-24}" -i "$T/out/%05d.png" -i "$IN" \
   -map 0:v -map 1:a? -vf "scale=-2:${ALTURA}:flags=lanczos" \
   -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -c:a copy -shortest "$OUT" \
  || { echo "FALLO montando"; exit 1; }
RES=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT")
echo "═══ LISTO: $OUT ($RES) ═══"
rm -rf "$T"
