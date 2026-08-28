#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRODUCIR ANCLADO — varias tomas largas, ninguna encadenada.
#
#  Uso: producir-anclado.sh <guion> <nombre> [frames] [W] [H] [pasos]
#
#  El guion lleva UNA linea HABLA por toma. La primera se genera limpia; de ella
#  se extraen frames PRISTINOS que sirven de ancla para las demas. Ninguna toma
#  usa como ancla el final de otra: asi no hay acumulacion.
#
#  POR QUE, medido:
#    - una toma sola no se degrada por larga que sea (25/25 y 20/20 hasta 685f)
#    - encadenar si: 1 plano 95.0 · 2 89.0 · 3 87.7 · 4 68.7
#    - pero el ANCLA borra la deriva: en obra/existencialismo el salto de bordes
#      es -3% en un enlace normal y -16.2 / -15.5 / -17.3 % en cada ancla.
#    Luego: tomas lo mas largas que quepan (685 frames = 28.5 s) y ancladas.
#
#  Las anclas se toman REPARTIDAS por la primera toma, no todas del mismo sitio:
#  anclas distintas dan poses distintas y el corte no parece un salto atras.
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
PROD=$MD/produccion

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}
FRAMES=${3:-685}; W=${4:-736}; H=${5:-416}; PASOS=${6:-20}
MODELO=${MODELO:-$MD/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf}

OBRA=$PROD/obra/$NOMBRE; mkdir -p "$OBRA/anclas" "$PROD/logs"
[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }
SD=$(compat_sdcli) || { echo "sd-cli no es ejecutable aqui"; exit 1; }

ESCENA=$(grep -m1 '^@ESCENA '   "$GUION" | sed 's/^@ESCENA //')
AMBIENTE=$(grep -m1 '^@AMBIENTE ' "$GUION" | sed 's/^@AMBIENTE //')
MUSICA=$(grep -m1 '^@MUSICA '   "$GUION" | sed 's/^@MUSICA //')
mapfile -t DIALOGOS < <(grep '^HABLA|' "$GUION" | cut -d'|' -f2)
N=${#DIALOGOS[@]}
[ "$N" -gt 0 ] || { echo "el guion no tiene lineas HABLA"; exit 1; }

SEG=$(awk "BEGIN{printf \"%.1f\", $FRAMES/24}")
echo "═══ ANCLADO: $NOMBRE · $N tomas de ${SEG}s = $(awk "BEGIN{printf \"%.0f\", $N*$FRAMES/24}")s ═══"
echo "    ${W}x${H} · ${FRAMES}f · ${PASOS} pasos · $(basename "$MODELO")"

generar() {  # $1=indice  $2=dialogo  $3=ancla(o vacio)
  local i=$1 dia=$2 ancla=${3:-}
  local out=$OBRA/t$(printf %02d "$i")
  [ -f "$out.avi" ] && { echo "  toma $i ya existe, salto"; return 0; }
  local prompt="detailed_description:
The target video is in realistic photographic style. [Shot 1] $ESCENA He speaks with calm deliberation, unhurried, pausing naturally between sentences. Subject 1 (S1) says, <d>[Spanish] $dia</d> When his voice stops, his lips settle closed and he holds the gaze, breathing slowly.

overall_soundscape:
$AMBIENTE

non_diegetic_music:
$MUSICA"
  local extra=(); [ -n "$ancla" ] && extra+=(--init-img "$ancla")
  local maxv; maxv=$(vram_arg 0)
  vram_esperar 0 5000 900 || echo "  aviso: margen de VRAM justo, arranco igual"
  echo "  toma $i · $maxv ${ancla:+· anclada a $(basename "$ancla")}"
  local t0=$SECONDS
  con_cerrojo 10800 "$SD" -M vid_gen \
    --diffusion-model "$MODELO" --vae "$MODELO_VAE" \
    --audio-vae "$MODELO_AVAE" --llm "$MODELO_LLM" \
    -p "$prompt" -s $(( ${SEED:-100} + i )) \
    --cfg-scale "${CFG:-1.0}" -W "$W" -H "$H" --fps 24 \
    --video-frames "$FRAMES" --steps "$PASOS" \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "diffusion=cpu" \
    --max-vram "$maxv" --stream-layers \
    -o "$out.mp4" "${extra[@]}" > "$PROD/logs/$NOMBRE-t$i.log" 2>&1
  local real; real=$(sd_salida "$out.mp4")
  [ -f "$real" ] || { echo "  toma $i FALLO tras $((SECONDS-t0))s"
                      tr '\r' '\n' < "$PROD/logs/$NOMBRE-t$i.log" | tail -5 | sed 's/^/      /'; return 1; }
  mv "$real" "$out.avi"; echo "  toma $i OK en $((SECONDS-t0))s"
}

# ── toma 1: limpia, y de ella salen las anclas ─────────────────────────────
generar 1 "${DIALOGOS[0]}" "" || exit 1
T1=$OBRA/t01.avi

if [ "$N" -gt 1 ]; then
  echo "═══ extrayendo $((N-1)) anclas pristinas, repartidas por la toma 1 ═══"
  DUR1=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$T1")
  for k in $(seq 2 "$N"); do
    # repartidas, evitando los extremos: el ultimo frame es justo el que
    # arrastra mas realce, y es lo que NO queremos como ancla.
    POS=$(awk -v k="$k" -v n="$N" -v d="$DUR1" 'BEGIN{printf "%.2f", d*(k-1)/(n+1)}')
    A=$OBRA/anclas/a$(printf %02d "$k").png
    ff -y -v error -ss "$POS" -i "$T1" -frames:v 1 -update 1 "$A"
    echo "  ancla $k: segundo $POS -> $(basename "$A")"
  done
  for k in $(seq 2 "$N"); do
    generar "$k" "${DIALOGOS[$((k-1))]}" "$OBRA/anclas/a$(printf %02d "$k").png" || exit 1
  done
fi

# ── montaje: fundido entre tomas, que son cortes de verdad ─────────────────
echo "═══ montando $N tomas ═══"
MONT=$OBRA/montaje; mkdir -p "$MONT"; rm -f "$MONT"/*.mp4 "$MONT/lista.txt"
i=0
for f in "$OBRA"/t[0-9][0-9].avi; do
  i=$((i+1)); n=$(printf %02d $i)
  D=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$f")
  ff -y -v error -i "$f" \
    -af "loudnorm=I=-19:TP=-2:LRA=7,afade=t=in:st=0:d=0.25,afade=t=out:st=$(awk "BEGIN{print $D-0.25}"):d=0.25" \
    -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k "$MONT/$n.mp4" \
    && echo "file '$MONT/$n.mp4'" >> "$MONT/lista.txt" || echo "  clip $n fallo, omitido"
  printf '%s\n' "$n" >> "$MONT/tramos.txt"   # cada toma es un tramo: fundido entre todas
done
sed -i '1d' "$MONT/tramos.txt" 2>/dev/null   # el primero no lleva fundido de entrada
STAMP=$(date +%Y%m%d-%H%M%S)
FINAL="$OBRA/.montando-$STAMP.mp4"
python3 "$PROD/fundir.py" "$MONT" "$FINAL" \
  || ff -y -v error -f concat -safe 0 -i "$MONT/lista.txt" -c copy "$FINAL"
[ -f "$FINAL" ] || { echo "FALLO al montar"; exit 1; }
RWH=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$FINAL")
RS=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$FINAL")
DEST_F="$DEST/$NOMBRE-${RWH%,*}x${RWH#*,}-$(awk "BEGIN{printf \"%.0f\",$RS}")s-$STAMP.mp4"
mkdir -p "$DEST"; mv "$FINAL" "$DEST_F"
echo "═══ LISTO: $DEST_F ═══"
python3 "$PROD/auditar.py" contacto "$DEST_F" "$OBRA/contacto.jpg" >/dev/null && echo "    contactos: $OBRA/contacto.jpg"
python3 "$PROD/auditar.py" habla "$DEST_F"
python3 "$PROD/auditar.py" audio "$DEST_F"
