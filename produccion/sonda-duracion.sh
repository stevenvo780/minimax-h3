#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  SONDA DE DURACION — a una resolucion dada, ¿cuanto puede durar un plano?
#
#  Complemento de sonda-resolucion.sh. Aquella fija los fotogramas y sube el
#  tamaño; esta fija el tamaño y sube los fotogramas. Hacen falta las dos
#  porque el buffer de computo crece con el PRODUCTO frames x ancho x alto: no
#  hay una "resolucion maxima" ni una "duracion maxima", hay una curva, y en
#  ella se elige.
#
#  Y la eleccion es de forma, no tecnica: 10 planos de 8 s a 736x416 son 80 s
#  de pieza; 10 planos de 4.5 s a 1152x648 son 45 s con el doble de detalle.
#  Ninguna de las dos es "mejor" en abstracto. Esto da los numeros para elegir.
#
#  Solo cuenta con fotogramas VALIDOS: sd-cli exige 17k+5 y con cualquier otro
#  numero falla despues de cargar el modelo, que son minutos tirados.
#
#  Uso:  sonda-duracion.sh <ancho> <alto> [lista de frames]
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffmpeg ffprobe || exit 1

W=${1:?falta el ancho}; H=${2:?falta el alto}; shift 2
PASOS=${PASOS:-8}
GPU0_MINIMO=${GPU0_MINIMO:-1500}
SALIDA=${SALIDA:-$MD/medidas/duracion-${W}x${H}-$(date +%Y%m%d-%H%M%S).tsv}
FRAMES_LISTA=${*:-"107 141 175 192 209 243 277 345"}

# 17k+5: cualquier otro numero falla DESPUES de cargar el modelo.
for f in $FRAMES_LISTA; do
  if [ $(( (f - 5) % 17 )) -ne 0 ]; then
    echo "FALLO: $f no es de la forma 17k+5. Validos cercanos: $(( (f-5)/17*17+5 )) y $(( ((f-5)/17+1)*17+5 ))"
    exit 1
  fi
done

mkdir -p "$(dirname "$SALIDA")"
T=$(mktemp -d "${TMPDIR:-/tmp}/sondad-XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

PROMPT_ESC="A man of about fifty-five with short grey-flecked dark hair and a full salt-and-pepper beard, wearing a charcoal grey wool sweater. Tight close-up against a plain matte black studio backdrop. Soft diffused warm key light from the left. Static locked-off camera, fine film grain."
PROMPT=$(construir_prompt habla "$PROMPT_ESC" "Esto es una prueba de duracion de plano." \
  "A very quiet neutral room tone, and the clear calm male dialogue spoken by the man." \
  "A single sustained low cello note held quietly.") || exit 1

libre0() { nvidia-smi -i 0 --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }
# La linea base: lo que ya ocupaba OTRO antes de que empezaramos. Sin restarla,
# la columna del pico suma la memoria de quien ya estaba y no es comparable
# entre corridas ni entre maquinas.
TOTAL=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
BASE=$(( TOTAL - $(libre0) ))

echo "═══ SONDA DE DURACION · ${W}x${H} · $PASOS pasos ═══"
echo "    ya ocupados por otros: $BASE MiB · libres para nosotros: $(libre0) MiB"
printf 'ancho\talto\tframes\tsegundos_video\tcabe\tvram_propia_mib\tsegundos_gen\tmotivo\n' > "$SALIDA"

for f in $FRAMES_LISTA; do
  l=$(libre0)
  if [ "${l:-0}" -lt $((GPU0_MINIMO + 4000)) ]; then
    echo "  ${f}f: solo $l MiB libres, no arranco (margen del usuario)"
    printf '%s\t%s\t%s\t%.1f\tno\t\t\tgpu-ocupada\n' "$W" "$H" "$f" "$(awk "BEGIN{print $f/24}")" >> "$SALIDA"
    continue
  fi
  maxv=$(vram_arg_trabajo 0 "$f" "$W" "$H" 0)
  printf "  %-5sf (%4.1fs) %-9s ... " "$f" "$(awk "BEGIN{printf \"%.1f\", $f/24}")" "$maxv"
  ( while :; do libre0; sleep 0.3; done ) > "$T/libre.txt" 2>/dev/null &
  VIG=$!
  t0=$SECONDS
  con_cerrojo 3600 "$SDCLI" -M vid_gen \
    --diffusion-model "$MODELO_DIFF" --vae "$MODELO_VAE" \
    --audio-vae "$MODELO_AVAE" --llm "$MODELO_LLM" \
    -p "$PROMPT" -s "${SEED:-100}" \
    --cfg-scale 1.0 -W "$W" -H "$H" --fps 24 \
    --video-frames "$f" --steps "$PASOS" \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "${PARAMS_BK:-diffusion=cpu,te=disk}" \
    --max-vram "$maxv" --stream-layers \
    -o "$T/p.mp4" </dev/null > "$T/g.log" 2>&1
  rc=$?; dur=$((SECONDS-t0))
  kill $VIG 2>/dev/null; wait $VIG 2>/dev/null
  min=$(sort -n "$T/libre.txt" 2>/dev/null | head -1)
  pico=$([ -n "${min:-}" ] && echo $(( TOTAL - min - BASE )) || echo "")
  real=$(sd_salida "$T/p.mp4")
  seg=$(awk "BEGIN{printf \"%.1f\", $f/24}")
  if [ $rc -eq 0 ] && [ -f "$real" ]; then
    echo "CABE · ${pico:-?} MiB propios · ${dur}s de generacion"
    printf '%s\t%s\t%s\t%s\tsi\t%s\t%s\t\n' "$W" "$H" "$f" "$seg" "${pico:-}" "$dur" >> "$SALIDA"
    rm -f "$real" "$T/p.mp4"
  else
    motivo=otro
    grep -qi 'cudaMalloc\|out of memory\|resource allocation' "$T/g.log" && motivo=vram
    grep -qi 'Killed' "$T/g.log" && motivo=ram
    echo "NO CABE ($motivo) · ${pico:-?} MiB propios · ${dur}s"
    tail -3 "$T/g.log" | sed 's/^/      /'
    printf '%s\t%s\t%s\t%s\tno\t%s\t%s\t%s\n' "$W" "$H" "$f" "$seg" "${pico:-}" "$dur" "$motivo" >> "$SALIDA"
    echo "  a partir de aqui todo es mas largo: corto."
    break
  fi
done
echo "═══ tabla: $SALIDA ═══"
column -t "$SALIDA"
