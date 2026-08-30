#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  SONDA DE RESOLUCION — averigua a que tamaño se puede generar de verdad.
#
#  Todo lo entregado hasta ahora sale a 736x416, y Steven dijo lo que hay que
#  decir: "la calidad aun es muy pobre". Escalar despues (RealESRGAN) no
#  inventa detalle que no se genero; lo unico que sube la calidad de verdad es
#  GENERAR mas grande.
#
#  Lo que lo impedia era doble y solo quedaba una mitad:
#    - RAM: los pesos (11.4 + 17 GB) no cabian en un cgroup de 24 GB. YA NO:
#      el cgroup son 125 GB. Los 73 oom_kill de memory.events son historicos.
#    - VRAM: el buffer de computo crece con frames x ancho x alto y vive en la
#      tarjeta pase lo que pase. Esta sigue mandando, y es lo que mide esto.
#
#  El intercambio real no es "mas calidad o menos", es RESOLUCION contra
#  DURACION DE PLANO: las dos comen el mismo buffer. Esta sonda da la curva
#  para poder elegir con datos en vez de a ojo.
#
#  No infiere: GENERA. Una toma corta por combinacion, y apunta si entro, con
#  cuanta VRAM y en cuanto tiempo. Lo que sale es una tabla, no una opinion.
#
#  Uso:  sonda-resolucion.sh [frames]        (por defecto 107, ~4.5 s)
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
exigir_herramientas ffmpeg ffprobe || exit 1

FRAMES=${1:-107}
PASOS=${PASOS:-8}          # pocos pasos: aqui se mide si CABE, no si es bonito
GPU0_MINIMO=${GPU0_MINIMO:-1500}
SALIDA=${SALIDA:-$MD/medidas/resolucion-$(date +%Y%m%d-%H%M%S).tsv}
# De menos a mas. En cuanto una no entra, las mayores tampoco: se corta.
ESCALAS=${ESCALAS:-"736x416 896x504 1024x576 1152x648 1280x720 1376x768"}

mkdir -p "$(dirname "$SALIDA")"
T=$(mktemp -d "${TMPDIR:-/tmp}/sonda-XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

PROMPT_ESC="A man of about fifty-five with short grey-flecked dark hair and a full salt-and-pepper beard, wearing a charcoal grey wool sweater. Tight close-up against a plain matte black studio backdrop. Soft diffused warm key light from the left. Static locked-off camera, fine film grain."
PROMPT=$(construir_prompt habla "$PROMPT_ESC" "Esto es una prueba de resolucion, nada mas." \
  "A very quiet neutral room tone, and the clear calm male dialogue spoken by the man." \
  "A single sustained low cello note held quietly.") || exit 1

libre0() { nvidia-smi -i 0 --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }

echo "═══ SONDA DE RESOLUCION · $FRAMES fotogramas · $PASOS pasos ═══"
echo "    RAM del cgroup: $(awk '{printf "%.0f GB", $1/1073741824}' /sys/fs/cgroup/memory.max 2>/dev/null)"
echo "    VRAM libre en la 5070 Ti: $(libre0) MiB"
printf 'ancho\talto\tframes\tpasos\tcabe\tvram_pico_mib\tsegundos\tmotivo\n' > "$SALIDA"

for esc in $ESCALAS; do
  w=${esc%x*}; h=${esc#*x}
  l=$(libre0)
  if [ "${l:-0}" -lt $((GPU0_MINIMO + 4000)) ]; then
    echo "  $esc: la GPU tiene $l MiB libres, no arranco (margen del usuario)"
    printf '%s\t%s\t%s\t%s\tno\t\t\tgpu-ocupada\n' "$w" "$h" "$FRAMES" "$PASOS" >> "$SALIDA"
    continue
  fi
  maxv=$(vram_arg_trabajo 0 "$FRAMES" "$w" "$h" 0)
  printf "  %-10s %s ... " "$esc" "$maxv"
  # Vigilar el pico de VRAM mientras corre. Muestrear cada 2 s no basta —el
  # pico esta en el decodificado de video y dura poco—, asi que se muestrea
  # rapido y se paga el coste en CPU, que aqui sobra.
  ( while :; do libre0; sleep 0.3; done ) > "$T/libre.txt" 2>/dev/null &
  VIG=$!
  t0=$SECONDS
  # La invocacion tiene que ser LA MISMA que la de produccion, bandera por
  # bandera. Medir sin --stream-layers, --diffusion-fa o --rng cpu daria una
  # curva de otro programa: lo que cabe depende de esas banderas tanto como de
  # la resolucion, y la tabla se usaria para decidir la produccion de verdad.
  con_cerrojo 3600 "$SDCLI" -M vid_gen \
    --diffusion-model "$MODELO_DIFF" --vae "$MODELO_VAE" \
    --audio-vae "$MODELO_AVAE" --llm "$MODELO_LLM" \
    -p "$PROMPT" -s "${SEED:-100}" \
    --cfg-scale 1.0 -W "$w" -H "$h" --fps 24 \
    --video-frames "$FRAMES" --steps "$PASOS" \
    --diffusion-fa --rng cpu \
    --backend "diffusion=CUDA0,te=cpu,vae=CUDA0" --params-backend "${PARAMS_BK:-diffusion=cpu,te=disk}" \
    --max-vram "$maxv" --stream-layers \
    -o "$T/p.mp4" </dev/null > "$T/g.log" 2>&1
  rc=$?
  dur=$((SECONDS-t0))
  kill $VIG 2>/dev/null; wait $VIG 2>/dev/null
  # pico = el minimo de libre observado, restado del total
  tot=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
  min=$(sort -n "$T/libre.txt" 2>/dev/null | head -1)
  pico=$([ -n "${min:-}" ] && echo $((tot - min)) || echo "")
  real=$(sd_salida "$T/p.mp4")
  if [ $rc -eq 0 ] && [ -f "$real" ]; then
    res=$(ffp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$real" 2>/dev/null)
    echo "CABE · pico ${pico:-?} MiB · ${dur}s · sale $res"
    printf '%s\t%s\t%s\t%s\tsi\t%s\t%s\t%s\n' "$w" "$h" "$FRAMES" "$PASOS" "${pico:-}" "$dur" "$res" >> "$SALIDA"
    rm -f "$real" "$T/p.mp4"
  else
    # Distinguir los dos fallos: no es lo mismo faltar VRAM que faltar RAM.
    motivo=otro
    grep -qi 'cudaMalloc\|out of memory\|resource allocation' "$T/g.log" && motivo=vram
    grep -qi 'Killed' "$T/g.log" && motivo=ram
    echo "NO CABE ($motivo) · pico ${pico:-?} MiB · ${dur}s"
    tail -3 "$T/g.log" | sed 's/^/      /'
    printf '%s\t%s\t%s\t%s\tno\t%s\t%s\t%s\n' "$w" "$h" "$FRAMES" "$PASOS" "${pico:-}" "$dur" "$motivo" >> "$SALIDA"
    echo "  a partir de aqui todo es mas grande: corto."
    break
  fi
done
echo "═══ tabla: $SALIDA ═══"
column -t "$SALIDA"
