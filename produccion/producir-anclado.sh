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
exigir_herramientas ffmpeg ffprobe || exit 1
. "$(dirname "${BASH_SOURCE[0]}")/../lib/compat.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vram.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/prompt.sh"
PROD=$MD/produccion
CAL=$MD/calidad   # las herramientas de medida viven aparte

GUION=${1:?falta el guion}; NOMBRE=${2:?falta el nombre}
FRAMES=${3:-685}; W=${4:-736}; H=${5:-416}; PASOS=${6:-20}
# ── Cuanta RAM hace falta ANTES de arrancar una toma ──────────────────────
# Estaba a ojo: 8000 MiB para arrancar y 10000 para reintentar. MEDIDO el
# 2026-08-29 muestreando memory.current cada 5 s durante una generacion, sd-cli
# llega a 14.2 GB de RSS. Los dos umbrales se quedaban MUY cortos, asi que el
# script daba luz verde con 13.4 GB libres —lo dijo su propio log: "toma 3: 13408
# MiB libres, reintento"— y el OOM killer lo mataba en el paso 7 de 20. Tres
# veces seguidas en la misma toma.
#
# Descartado por el camino, midiendo: NO era el presupuesto de VRAM (se bajo de
# cuda0=7 a 4 y murio igual) ni la cache de pagina (el desglose del cgroup dio
# anon 17.6 GB contra file 3.5 GB). Era arrancar sin sitio, sin mas.
#
# CORREGIDO otra vez: 14.2 GB era un muestreo cada 5 s que se perdia el pico.
# Muestreando a 1 Hz y guardando el maximo, sd-cli llega a 19.3 GB y el cgroup
# toca su techo de 24576 MB exacto. Con ~5 GB de otros procesos, NO CABE: el
# margen real es cero. Por eso 19500, que es casi todo el contenedor.
RAM_NECESARIA=${RAM_NECESARIA:-19500}

MODELO=${MODELO:-$MD/modelos/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf}

OBRA=$PROD/obra/$NOMBRE; mkdir -p "$OBRA/anclas" "$PROD/logs"
[ -f "$GUION" ] || { echo "no existe el guion: $GUION"; exit 1; }
SD=$(compat_sdcli) || { echo "sd-cli no es ejecutable aqui"; exit 1; }

ESCENA=$(grep -m1 '^@ESCENA '   "$GUION" | sed 's/^@ESCENA //')
AMBIENTE=$(grep -m1 '^@AMBIENTE ' "$GUION" | sed 's/^@AMBIENTE //')
MUSICA=$(grep -m1 '^@MUSICA '   "$GUION" | sed 's/^@MUSICA //')
# Tipo de plano por defecto para toda la pieza; cada toma puede anularlo.
TIPO_DEF=$(grep -m1 '^@TIPO ' "$GUION" | sed 's/^@TIPO //' | tr -d ' ')
TIPO_DEF=${TIPO_DEF:-habla}
tipo_valido "$TIPO_DEF" || { echo "@TIPO desconocido: $TIPO_DEF (validos: $PROMPT_TIPOS)"; exit 1; }

# HABLA| se mantiene por compatibilidad; TOMA| es la forma general.
#   TOMA|<contenido>|<modo>|<tipo opcional>
mapfile -t CONTENIDOS < <(grep -E '^(HABLA|TOMA)\|' "$GUION" | cut -d'|' -f2)
mapfile -t TIPOS      < <(grep -E '^(HABLA|TOMA)\|' "$GUION" | awk -F'|' -v d="$TIPO_DEF" '{t=$4; gsub(/ /,"",t); print (t==""?d:t)}')
N=${#CONTENIDOS[@]}
[ "$N" -gt 0 ] || { echo "el guion no tiene lineas HABLA| ni TOMA|"; exit 1; }
for t in "${TIPOS[@]}"; do
  tipo_valido "$t" || { echo "tipo de plano desconocido en el guion: '$t' (validos: $PROMPT_TIPOS)"; exit 1; }
done

# ── VALIDAR=1: comprobar el guion sin gastar un segundo de GPU ─────────────
# Antes no habia forma de revisar un guion sin producirlo. Comprobar "¿parsea
# bien esto?" arrancaba una generacion de verdad, que ademas competia por el
# cerrojo con la tanda en curso. Con VALIDAR=1 se hace todo el trabajo previo
# —cabecera, tipos, prompts— se imprimen los prompts y se sale antes de tocar
# la GPU. Sirve tambien para LEER el prompt exacto que recibira el modelo, que
# es lo que de verdad hay que revisar cuando un plano sale raro.
if [ "${VALIDAR:-0}" = 1 ]; then
  echo "═══ VALIDACION de $GUION (no se genera nada) ═══"
  echo "    tomas: $N · tipos: $(printf '%s ' "${TIPOS[@]}")"
  for i in "${!CONTENIDOS[@]}"; do
    n=$((i+1))
    echo "───── toma $n [${TIPOS[$i]}] ─────"
    construir_prompt "${TIPOS[$i]}" "$ESCENA" "${CONTENIDOS[$i]}" "$AMBIENTE" "$MUSICA" \
      || { echo "  FALLO construyendo el prompt de la toma $n"; exit 1; }
    echo
  done
  echo "═══ guion valido ═══"
  exit 0
fi

SEG=$(awk "BEGIN{printf \"%.1f\", $FRAMES/24}")
echo "═══ ANCLADO: $NOMBRE · $N tomas de ${SEG}s = $(awk "BEGIN{printf \"%.0f\", $N*$FRAMES/24}")s ═══"
echo "    ${W}x${H} · ${FRAMES}f · ${PASOS} pasos · $(basename "$MODELO")"
echo "    tipos: $(printf '%s ' "${TIPOS[@]}")"

generar() {  # $1=indice  $2=contenido  $3=ancla(o vacio)  $4=tipo
  local i=$1 cont=$2 ancla=${3:-} tipo=${4:-habla}
  local out=$OBRA/t$(printf %02d "$i")
  [ -f "$out.avi" ] && { echo "  toma $i ya existe, salto"; return 0; }
  local prompt; prompt=$(construir_prompt "$tipo" "$ESCENA" "$cont" "$AMBIENTE" "$MUSICA") || return 1
  local extra=(); [ -n "$ancla" ] && extra+=(--init-img "$ancla")
  # Consciente del tamaño del trabajo: el buffer de computo crece con
  # frames x pixeles, y pedir MAS modelo residente hace que NO quepa.
  # La ruta anclada engorda el buffer ~1.7 GB: hay que decirselo al presupuesto
  # o autoriza mas modelo del que cabe y el guardian corta la toma a medias.
  local maxv; maxv=$(vram_arg_trabajo 0 "$FRAMES" "$W" "$H" "$([ -n "$ancla" ] && echo 1 || echo 0)")
  vram_esperar 0 5000 900 || echo "  aviso: margen de VRAM justo, arranco igual"
  # Esperar tambien a la RAM: una generacion usa casi los 24 GB del contenedor y
  # arrancar sin sitio la mata el OOM killer a mitad. Paso de verdad: la toma 3
  # murio en el paso 16/20 tras 18 min de GPU porque habia mediciones en paralelo.
  local t=0
  while [ "$(ram_libre_mb)" -lt "$RAM_NECESARIA" ] && [ $t -lt 900 ]; do
    [ $t = 0 ] && echo "  esperando RAM: solo $(ram_libre_mb) MiB libres de los $RAM_NECESARIA que hacen falta"
    sleep 20; t=$((t+20))
  done
  echo "  toma $i [$tipo] · $maxv ${ancla:+· anclada a $(basename "$ancla")}"
  # Reintento ante OOM, como ya hacia producir.sh y yo no habia copiado.
  # El pico de memoria NO esta en la difusion sino en el decodificado de video,
  # que convierte los latentes en los 345 fotogramas de golpe. Medido: la toma 4
  # completo los 20 pasos (1261 s) y el audio VAE, y murio justo ahi. Las tomas
  # 1-3 pasaron ese punto por poco. Reintentar cuesta tiempo pero no calidad.
  local intento=1
  while [ $intento -le 3 ]; do
  if [ $intento -gt 1 ]; then
    echo "  toma $i: reintento $intento/3 tras OOM · esperando a que se asiente la memoria"
    sleep 120
    local w=0
    while [ "$(ram_libre_mb)" -lt "$RAM_NECESARIA" ] && [ $w -lt 900 ]; do sleep 20; w=$((w+20)); done
    echo "  toma $i: $(ram_libre_mb) MiB libres, reintento"
  fi
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
  if [ -f "$real" ]; then
    mv "$real" "$out.avi"; echo "  toma $i OK en $((SECONDS-t0))s${ancla:+ (anclada)}"
    return 0
  fi
  echo "  toma $i intento $intento fallo tras $((SECONDS-t0))s"
  tr '\r' '\n' < "$PROD/logs/$NOMBRE-t$i.log" | tail -3 | sed 's/^/      /'
  intento=$((intento+1))
  done
  echo "  toma $i FALLO DEFINITIVO tras 3 intentos"
  return 1
}

# ── toma 1: limpia, y de ella salen las anclas ─────────────────────────────
generar 1 "${CONTENIDOS[0]}" "" "${TIPOS[0]}" || exit 1
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
    generar "$k" "${CONTENIDOS[$((k-1))]}" "$OBRA/anclas/a$(printf %02d "$k").png" "${TIPOS[$((k-1))]}" || exit 1
  done
fi

# ── montaje: fundido entre tomas, que son cortes de verdad ─────────────────
echo "═══ montando $N tomas ═══"
MONT=$OBRA/montaje; mkdir -p "$MONT"; rm -f "$MONT"/*.mp4 "$MONT/lista.txt"
# La toma 1 es la referencia de luminancia: es la unica generada limpia, sin
# ancla, asi que es el aspecto "verdadero" de la escena. Las demas se igualan a
# ella. Ver luminancia_mediana() en comun.sh para el porque.
REF=$(ls "$OBRA"/t[0-9][0-9].avi 2>/dev/null | head -1)
i=0
for f in "$OBRA"/t[0-9][0-9].avi; do
  i=$((i+1)); n=$(printf %02d $i)
  D=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$f")
  VF=""
  if [ "$i" -gt 1 ] && [ -n "$REF" ]; then
    G=$(ganancia_nivel "$f" "$REF")
    # Por debajo del 2% no se toca: corregir ruido de medida solo añade una
    # pasada de filtro y no arregla nada que se vea.
    if awk -v g="$G" 'BEGIN{exit !(g<0.98 || g>1.02)}'; then
      VF="-vf lutyuv=y=val*$G"
      echo "  toma $n: nivelada a la toma 1 (ganancia $G)"
    fi
  fi
  ff -y -v error -i "$f" $VF \
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
python3 "$CAL/auditar.py" contacto "$DEST_F" "$OBRA/contacto.jpg" >/dev/null && echo "    contactos: $OBRA/contacto.jpg"
# La cobertura de voz SOLO significa algo si la pieza tiene dialogo. En un
# plano de manos o un paisaje no hay nadie hablando: el detector lee el cello y
# el ambiente como voz continua, saca "voz 100.0%" y dictamina ATROPELLADO. Es
# una falsa alarma del mismo tipo que el recorte central de evaluar2 — la medida
# da por hecho el formato de retrato hablado.
if printf '%s\n' "${TIPOS[@]}" | grep -qx 'habla'; then
  python3 "$CAL/auditar.py" habla "$DEST_F"
else
  echo "  (sin tomas habladas: me salto la cobertura de voz, no aplica)"
fi
python3 "$CAL/auditar.py" audio "$DEST_F"
