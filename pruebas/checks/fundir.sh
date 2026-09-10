#!/bin/bash
set -u

NOMBRE="fundir"
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
FALLOS=0
falla() { echo "FALLA $NOMBRE: $*"; FALLOS=$((FALLOS+1)); }

SCRIPT="$RAIZ/produccion/fundir.py"
if [ ! -f "$SCRIPT" ]; then
  echo "FALLA $NOMBRE: no se encontro $SCRIPT"
  exit 1
fi

PATH_REAL="$PATH"
FFMPEG_REAL=$(command -v ffmpeg || true)
FFPROBE_REAL=$(command -v ffprobe || true)
WORK=$(mktemp -d /tmp/chk_fundir.XXXXXX) || exit 1
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"

# Los stubs registran comandos y producen MP4 vacios. ffprobe devuelve un JSON
# completo y calcula la duracion de tramoN a partir de su lista lN.txt.
cat > "$BIN/ffmpeg" <<'EOS'
#!/usr/bin/env bash
echo "ffmpeg $*" >> "${CHK_LOG:-/dev/null}"
entrada=""
anterior=""
for argumento in "$@"; do
  if [ "$anterior" = "-i" ]; then entrada="$argumento"; fi
  anterior="$argumento"
done

if [[ "$*" == *"loudnorm="* ]] && [[ "$*" == *"-f null -"* ]]; then
  cat >&2 <<'JSON'
{
  "input_i" : "-17.80",
  "input_tp" : "0.80",
  "input_lra" : "4.00",
  "input_thresh" : "-28.00",
  "target_offset" : "0.00"
}
JSON
  exit 0
fi

if [[ "$*" == *"ebur128=peak=sample+true"* ]]; then
  base_entrada=$(basename "$entrada")
  lufs="${CHK_AUDIO_LUFS:--19.0}"
  pico_muestra="${CHK_AUDIO_SAMPLE_PEAK:--2.0}"
  pico_real="${CHK_AUDIO_TRUE_PEAK:--1.8}"
  if [ "${CHK_AUDIO_ALWAYS_BAD:-0}" = 1 ] \
      || { [ "${CHK_AUDIO_RETRY:-0}" = 1 ] && [[ "$base_entrada" == *audio-1-* ]]; }; then
    pico_muestra="0.1"
    pico_real="0.4"
  fi
  cat >&2 <<EOF
[stub_ebur128] Summary:

  Integrated loudness:
    I:         $lufs LUFS

  Sample peak:
    Peak:      $pico_muestra dBFS

  True peak:
    Peak:      $pico_real dBFS
EOF
  exit 0
fi

salida="${@: -1}"
if [ "$salida" = "-" ]; then exit 0; fi
mkdir -p "$(dirname "$salida")"
: > "$salida"
exit 0
EOS
chmod +x "$BIN/ffmpeg"

cat > "$BIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
echo "ffprobe $*" >> "${CHK_LOG:-/dev/null}"
archivo="${@: -1}"
base=$(basename "$archivo")
duracion="${CHK_CLIP_DURATION:-2.0}"
if [[ "$base" =~ ^tramo([0-9]+)\.mp4$ ]]; then
  lista="$(dirname "$archivo")/l${BASH_REMATCH[1]}.txt"
  cantidad=$(wc -l < "$lista")
  duracion=$(awk -v d="${CHK_CLIP_DURATION:-2.0}" -v n="$cantidad" 'BEGIN{printf "%.6f",d*n}')
elif [[ "$base" == .*fundiendo-*.mp4 ]] || [[ "$base" == .*audio-*.mp4 ]]; then
  duracion="${CHK_FINAL_DURATION:-2.0}"
fi
ancho=1920
if [ -n "${CHK_BAD_FILE:-}" ] && [ "$base" = "$CHK_BAD_FILE" ]; then ancho=1280; fi

if [ -n "${CHK_NO_AUDIO_FILE:-}" ] && [ "$base" = "$CHK_NO_AUDIO_FILE" ]; then
  streams='[{"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"pix_fmt":"yuv420p","r_frame_rate":"30/1","time_base":"1/15360"}]'
else
  streams="[{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"h264\",\"width\":$ancho,\"height\":1080,\"pix_fmt\":\"yuv420p\",\"r_frame_rate\":\"30/1\",\"time_base\":\"1/15360\"},{\"index\":1,\"codec_type\":\"audio\",\"codec_name\":\"aac\",\"sample_fmt\":\"fltp\",\"sample_rate\":\"48000\",\"channels\":2,\"channel_layout\":\"stereo\",\"time_base\":\"1/48000\"}]"
fi
printf '{"streams":%s,"format":{"duration":"%s"}}\n' "$streams" "$duracion"
exit 0
EOS
chmod +x "$BIN/ffprobe"

nuevo_montaje() {
  local nombre=$1 cantidad=$2
  local montaje="$WORK/$nombre"
  mkdir -p "$montaje"
  local i
  for ((i=0; i<cantidad; i++)); do
    : > "$montaje/$(printf '%02d' "$i").mp4"
  done
  printf '%s\n' "$montaje"
}

# ---------- CASO A: configuracion invalida falla pronto y con mensaje claro ----------
MONT_A=$(nuevo_montaje montA 1)
LOG_A="$WORK/log_A.txt"; : > "$LOG_A"
OUT_A=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_A" TRANSICION=barrido \
  python3 "$SCRIPT" "$MONT_A" "$MONT_A/final.mp4" 2>&1)
RC_A=$?
if [ "$RC_A" -eq 0 ] || ! printf '%s' "$OUT_A" | grep -q "TRANSICION invalida"; then
  falla "CASO A: TRANSICION desconocida no produjo un error claro: rc=$RC_A, salida=$OUT_A"
fi
if [ -s "$LOG_A" ]; then
  falla "CASO A: se invoco ffmpeg/ffprobe pese a que TRANSICION ya era invalida"
fi

OUT_A2=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_A" TRANSICION=fundido \
  DURACION_TRANSICION=nan python3 "$SCRIPT" "$MONT_A" "$MONT_A/final.mp4" 2>&1)
RC_A2=$?
if [ "$RC_A2" -eq 0 ] || ! printf '%s' "$OUT_A2" | grep -q "finito y mayor que cero"; then
  falla "CASO A: DURACION_TRANSICION=nan no fue rechazada con claridad: rc=$RC_A2, salida=$OUT_A2"
fi

# ---------- CASO B: el default es corte, conserva duracion y nunca usa xfade ----------
MONT_B=$(nuevo_montaje montB 3)
LOG_B="$WORK/log_B.txt"; : > "$LOG_B"
printf '01\n02\n' > "$MONT_B/tramos.txt"
touch "$MONT_B/tramo7.mp4" "$MONT_B/tramo99.mp4" "$MONT_B/l7.txt" "$MONT_B/l8.txt"
OUT_B=$(env -u TRANSICION -u DURACION_TRANSICION PATH="$BIN:$PATH_REAL" \
  CHK_LOG="$LOG_B" CHK_FINAL_DURATION=6.0 python3 "$SCRIPT" \
  "$MONT_B" "$MONT_B/final.mp4" 2>&1)
RC_B=$?
if [ "$RC_B" -ne 0 ]; then
  falla "CASO B: el corte predeterminado fallo: rc=$RC_B, salida=$OUT_B"
fi
if ! printf '%s' "$OUT_B" | grep -q "corte directo.*sin solapamiento"; then
  falla "CASO B: la salida no declara que el default sea un corte sin solapamiento: $OUT_B"
fi
if grep -Eq 'xfade|acrossfade|-filter_complex|fade=t=' "$LOG_B"; then
  falla "CASO B: el default invoco un filtro de solapamiento: $(grep '^ffmpeg ' "$LOG_B")"
fi
if ! grep '^ffmpeg ' "$LOG_B" | grep -q -- '-c copy'; then
  falla "CASO B: el corte predeterminado no copio los streams"
fi
if ! grep '^ffmpeg ' "$LOG_B" | grep -q -- '-c:v copy .* -c:a aac'; then
  falla "CASO B: el master final no conservo video por copia y recodifico solo el audio"
fi
if ! grep -q 'ebur128=peak=sample+true' "$LOG_B" \
    || ! printf '%s' "$OUT_B" | grep -q 'audio final: I=-19.0 LUFS.*TP=-1.8 dBTP.*clipping=0'; then
  falla "CASO B: no se midio o no se reporto el audio AAC post-encode: $OUT_B"
fi
if [ ! -f "$MONT_B/final.mp4" ]; then
  falla "CASO B: no se publico el fichero final"
fi
for huerfano in tramo7.mp4 tramo99.mp4 l7.txt l8.txt; do
  if [ -e "$MONT_B/$huerfano" ]; then
    falla "CASO B: no se limpio el intermedio obsoleto '$huerfano'"
  fi
done

# ---------- CASO C: streams incompatibles se rechazan antes de montar ----------
MONT_C=$(nuevo_montaje montC 2)
LOG_C="$WORK/log_C.txt"; : > "$LOG_C"
OUT_C=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_C" CHK_BAD_FILE=01.mp4 \
  python3 "$SCRIPT" "$MONT_C" "$MONT_C/final.mp4" 2>&1)
RC_C=$?
if [ "$RC_C" -eq 0 ] || ! printf '%s' "$OUT_C" | grep -q "clips incompatibles"; then
  falla "CASO C: resoluciones incompatibles no se rechazaron: rc=$RC_C, salida=$OUT_C"
fi
if grep -q '^ffmpeg ' "$LOG_C"; then
  falla "CASO C: se invoco ffmpeg pese a la incompatibilidad ya detectable"
fi

MONT_C2=$(nuevo_montaje montC2 2)
LOG_C2="$WORK/log_C2.txt"; : > "$LOG_C2"
OUT_C2=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_C2" CHK_NO_AUDIO_FILE=01.mp4 \
  python3 "$SCRIPT" "$MONT_C2" "$MONT_C2/final.mp4" 2>&1)
RC_C2=$?
if [ "$RC_C2" -eq 0 ] || ! printf '%s' "$OUT_C2" | grep -q "video=1, audio=0"; then
  falla "CASO C: un clip sin audio no se rechazo con detalle de streams: rc=$RC_C2, salida=$OUT_C2"
fi

# ---------- CASO D: el fundido heredado es opt-in y conserva sus offsets ----------
MONT_D=$(nuevo_montaje montD 3)
LOG_D="$WORK/log_D.txt"; : > "$LOG_D"
printf '01\n02\n' > "$MONT_D/tramos.txt"
OUT_D=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_D" CHK_FINAL_DURATION=5.0 \
  TRANSICION=fundido DURACION_TRANSICION=0.5 python3 "$SCRIPT" \
  "$MONT_D" "$MONT_D/final.mp4" 2>&1)
RC_D=$?
if [ "$RC_D" -ne 0 ]; then
  falla "CASO D: el fundido opt-in fallo: rc=$RC_D, salida=$OUT_D"
fi
if ! grep -q 'xfade=transition=fade:duration=0.500000:offset=1.500000' "$LOG_D" \
    || ! grep -q 'offset=3.000000' "$LOG_D" \
    || ! grep -q 'acrossfade=d=0.500000' "$LOG_D"; then
  falla "CASO D: filtros u offsets del fundido incorrectos: $(grep '^-\?ffmpeg\|^ffmpeg' "$LOG_D" | tail -1)"
fi
if ! printf '%s' "$OUT_D" | grep -q "fundido opt-in de 0.5s"; then
  falla "CASO D: no se identifica el fundido como opt-in: $OUT_D"
fi

# La duracion debe caber en ambos lados; el error sucede antes del xfade final.
MONT_D2=$(nuevo_montaje montD2 2)
LOG_D2="$WORK/log_D2.txt"; : > "$LOG_D2"
printf '01\n' > "$MONT_D2/tramos.txt"
OUT_D2=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_D2" TRANSICION=fundido \
  DURACION_TRANSICION=2.0 python3 "$SCRIPT" "$MONT_D2" "$MONT_D2/final.mp4" 2>&1)
RC_D2=$?
if [ "$RC_D2" -eq 0 ] || ! printf '%s' "$OUT_D2" | grep -q "debe ser menor que ambos tramos"; then
  falla "CASO D: un fundido tan largo como el tramo no se rechazo: rc=$RC_D2, salida=$OUT_D2"
fi
if grep -q 'xfade=' "$LOG_D2"; then
  falla "CASO D: se lanzo xfade despues de detectar una duracion imposible"
fi

# ---------- CASO E: negro hace dos fades separados y no acorta el montaje ----------
MONT_E=$(nuevo_montaje montE 3)
LOG_E="$WORK/log_E.txt"; : > "$LOG_E"
printf '01\n02\n' > "$MONT_E/tramos.txt"
OUT_E=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_E" CHK_FINAL_DURATION=6.0 \
  TRANSICION=negro DURACION_TRANSICION=0.6 python3 "$SCRIPT" \
  "$MONT_E" "$MONT_E/final.mp4" 2>&1)
RC_E=$?
if [ "$RC_E" -ne 0 ]; then
  falla "CASO E: el paso por negro fallo: rc=$RC_E, salida=$OUT_E"
fi
if grep -Eq 'xfade|acrossfade' "$LOG_E"; then
  falla "CASO E: negro solapo dos planos mediante xfade/acrossfade"
fi
if ! grep -q 'fade=t=out' "$LOG_E" || ! grep -q 'fade=t=in' "$LOG_E" \
    || ! grep -q 'concat=n=3:v=1:a=1' "$LOG_E"; then
  falla "CASO E: negro no construyo fades separados seguidos por concat: $(grep '^ffmpeg ' "$LOG_E" | tail -1)"
fi
if ! printf '%s' "$OUT_E" | grep -q "corte sin doble exposicion"; then
  falla "CASO E: no se declara la garantia de corte sin doble exposicion: $OUT_E"
fi

# ---------- CASO F: retry acotado y fallo cerrado del audio post-encode ----------
MONT_F=$(nuevo_montaje montF 2)
LOG_F="$WORK/log_F.txt"; : > "$LOG_F"
OUT_F=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_F" CHK_FINAL_DURATION=4.0 \
  CHK_AUDIO_RETRY=1 python3 "$SCRIPT" "$MONT_F" "$MONT_F/final.mp4" 2>&1)
RC_F=$?
if [ "$RC_F" -ne 0 ] || ! printf '%s' "$OUT_F" | grep -q 'intento=2/3'; then
  falla "CASO F: no recupero un overshoot AAC mediante retry acotado: rc=$RC_F, salida=$OUT_F"
fi
CODIFICACIONES_F=$(grep -c -- '-c:v copy .* -c:a aac' "$LOG_F" || true)
if [ "$CODIFICACIONES_F" -ne 2 ]; then
  falla "CASO F: se esperaban exactamente 2 codificaciones de audio, hubo $CODIFICACIONES_F"
fi

MONT_F2=$(nuevo_montaje montF2 2)
LOG_F2="$WORK/log_F2.txt"; : > "$LOG_F2"
printf 'master-previo-intacto' > "$MONT_F2/final.mp4"
OUT_F2=$(PATH="$BIN:$PATH_REAL" CHK_LOG="$LOG_F2" CHK_FINAL_DURATION=4.0 \
  CHK_AUDIO_ALWAYS_BAD=1 python3 "$SCRIPT" "$MONT_F2" "$MONT_F2/final.mp4" 2>&1)
RC_F2=$?
if [ "$RC_F2" -eq 0 ] || ! printf '%s' "$OUT_F2" | grep -q 'audio final fuera de especificacion tras 3 intentos'; then
  falla "CASO F: audio persistentemente fuera de norma no fallo cerrado: rc=$RC_F2, salida=$OUT_F2"
fi
if [ "$(cat "$MONT_F2/final.mp4")" != 'master-previo-intacto' ]; then
  falla "CASO F: un audio rechazado sobrescribio el master previo"
fi
MEDICIONES_F2=$(grep -c 'ebur128=peak=sample+true' "$LOG_F2" || true)
if [ "$MEDICIONES_F2" -ne 3 ]; then
  falla "CASO F: el fallo persistente no respeto el limite de 3 mediciones: $MEDICIONES_F2"
fi
if compgen -G "$MONT_F2/.*audio-*.mp4" >/dev/null \
    || compgen -G "$MONT_F2/.*fundiendo-*.mp4" >/dev/null; then
  falla "CASO F: quedaron temporales de un master de audio rechazado"
fi

# ---------- CASO G: fixture real con pico alto, duracion y corte intactos ----------
if [ -n "$FFMPEG_REAL" ] && [ -n "$FFPROBE_REAL" ]; then
  MONT_G="$WORK/montG"; mkdir -p "$MONT_G"
  "$FFMPEG_REAL" -nostdin -y -v error \
    -f lavfi -i 'color=c=red:s=160x90:r=24:d=1' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
    -map 0:v:0 -map 1:a:0 -shortest -af 'volume=7.9' \
    -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 96k "$MONT_G/00.mp4"
  RC_G0=$?
  "$FFMPEG_REAL" -nostdin -y -v error \
    -f lavfi -i 'color=c=blue:s=160x90:r=24:d=1' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=1' \
    -map 0:v:0 -map 1:a:0 -shortest -af 'volume=7.9' \
    -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 96k "$MONT_G/01.mp4"
  RC_G1=$?
  printf '01\n' > "$MONT_G/tramos.txt"

  REALBIN="$WORK/realbin"; mkdir -p "$REALBIN"
  cat > "$REALBIN/ffmpeg" <<'EOS'
#!/usr/bin/env bash
echo "ffmpeg $*" >> "$CHK_REAL_LOG"
exec "$CHK_FFMPEG_REAL" "$@"
EOS
  cat > "$REALBIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
exec "$CHK_FFPROBE_REAL" "$@"
EOS
  chmod +x "$REALBIN/ffmpeg" "$REALBIN/ffprobe"
  LOG_G="$WORK/log_G.txt"; : > "$LOG_G"
  OUT_G=$(env -u TRANSICION -u DURACION_TRANSICION PATH="$REALBIN:$PATH_REAL" \
    CHK_REAL_LOG="$LOG_G" CHK_FFMPEG_REAL="$FFMPEG_REAL" CHK_FFPROBE_REAL="$FFPROBE_REAL" \
    python3 "$SCRIPT" "$MONT_G" "$MONT_G/final.mp4" 2>&1)
  RC_G=$?
  if [ "$RC_G0" -ne 0 ] || [ "$RC_G1" -ne 0 ] || [ "$RC_G" -ne 0 ]; then
    falla "CASO G: el fixture FFmpeg real fallo: entradas=$RC_G0/$RC_G1, montaje=$RC_G, salida=$OUT_G"
  else
    D0=$($FFPROBE_REAL -v error -show_entries format=duration -of csv=p=0 "$MONT_G/00.mp4")
    D1=$($FFPROBE_REAL -v error -show_entries format=duration -of csv=p=0 "$MONT_G/01.mp4")
    DF=$($FFPROBE_REAL -v error -show_entries format=duration -of csv=p=0 "$MONT_G/final.mp4")
    if ! awk -v a="$D0" -v b="$D1" -v f="$DF" 'BEGIN{d=f-(a+b); if(d<0)d=-d; exit !(d<=0.13)}'; then
      falla "CASO G: el corte real no conservo la suma de duraciones: $D0 + $D1 != $DF"
    fi
    if grep -Eq 'xfade|acrossfade|-filter_complex' "$LOG_G"; then
      falla "CASO G: el corte real uso un filtro de solapamiento: $(cat "$LOG_G")"
    fi
    if ! grep -q -- '-c:v copy .* -c:a aac' "$LOG_G"; then
      falla "CASO G: el master real no preservo el video por stream copy"
    fi
    if ! printf '%s' "$OUT_G" | grep -Eq 'audio final: .*clipping=0'; then
      falla "CASO G: el audio real no reporto cumplimiento post-encode: $OUT_G"
    fi
    if ! python3 - "$FFMPEG_REAL" "$MONT_G/00.mp4" "$MONT_G/final.mp4" <<'PY'
import subprocess
import sys
import re

ffmpeg, entrada, video = sys.argv[1:]

def medir(ruta):
    r = subprocess.run(
        [ffmpeg, "-nostdin", "-hide_banner", "-nostats", "-v", "info", "-i", ruta,
         "-map", "0:a:0", "-af", "ebur128=peak=sample+true:framelog=quiet",
         "-f", "null", "-"],
        check=True, capture_output=True, text=True,
    )
    resumen = r.stderr.rsplit("Summary:", 1)[-1]
    i = float(re.search(r"Integrated loudness:\s*I:\s*([-0-9.]+)", resumen).group(1))
    tp = float(re.search(r"True peak:\s*Peak:\s*([-0-9.]+)", resumen).group(1))
    sp = float(re.search(r"Sample peak:\s*Peak:\s*([-0-9.]+)", resumen).group(1))
    return i, tp, sp

def pixel(tiempo):
    r = subprocess.run(
        [ffmpeg, "-nostdin", "-v", "error", "-ss", str(tiempo), "-i", video,
         "-frames:v", "1", "-vf", "scale=1:1", "-pix_fmt", "rgb24",
         "-f", "rawvideo", "-"],
        check=True, capture_output=True,
    )
    if len(r.stdout) != 3:
        raise SystemExit(2)
    return tuple(r.stdout)

_, tp_entrada, _ = medir(entrada)
i_final, tp_final, sp_final = medir(video)
if tp_entrada <= -1.0:
    raise SystemExit(f"fixture no era exigente: TP entrada={tp_entrada}")
if not (-19.5 <= i_final <= -18.5 and tp_final <= -1.5 and sp_final < 0.0):
    raise SystemExit(
        f"master fuera de norma: I={i_final}, TP={tp_final}, sample_peak={sp_final}"
    )

antes = pixel(0.75)
despues = pixel(1.25)
if not (antes[0] > 180 and antes[0] > antes[2] * 4):
    raise SystemExit(f"antes del corte no domina rojo: {antes}")
if not (despues[2] > 180 and despues[2] > despues[0] * 4):
    raise SystemExit(f"despues del corte no domina azul: {despues}")
PY
    then
      falla "CASO G: fallo pico/loudness o aparecio mezcla de colores en el corte real"
    fi
  fi
else
  echo "AVISO $NOMBRE: ffmpeg/ffprobe reales no disponibles; fixture real omitido"
fi

if [ "$FALLOS" -ne 0 ]; then
  echo "FALLA $NOMBRE: $FALLOS comprobacion(es) fallida(s)"
  exit 1
fi

# ── PUNCH_ALTERNO: el encuadre alterno que hace legible el corte ───────────
# Dos tomas seguidas del mismo plano con la boca abierta a ambos lados no se
# pueden unir bien: el corte duro salta y el fundido superpone dos bocas. Lo
# que funciona es que el corte parezca intencionado, y para eso las tomas
# pares se cierran un poco. Aqui se comprueba que el punch NO cambia las
# dimensiones (si lo hiciera, validar_compatibilidad rechazaria el montaje) y
# que solo toca las tomas pares.
T_PUNCH=$(mktemp -d "${TMPDIR:-/tmp}/chk-punch-XXXXXX") || exit 1
trap 'rm -rf "$T_PUNCH"' EXIT
for n in 01 02 03; do
  ffmpeg -nostdin -y -v error \
    -f lavfi -i "testsrc2=s=416x736:d=1:r=24" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 \
    "$T_PUNCH/$n.mp4" 2>/dev/null || { echo "FALLA fundir: no pude fabricar clips"; exit 1; }
done
printf '02\n03\n' > "$T_PUNCH/tramos.txt"
if ! PUNCH_ALTERNO=1.09 TRANSICION=corte python3 "$RAIZ/produccion/fundir.py" \
      "$T_PUNCH" "$T_PUNCH/salida.mp4" > "$T_PUNCH/log" 2>&1; then
  echo "FALLA fundir: el punch alterno fallo"; sed -n '1,5p' "$T_PUNCH/log"; exit 1
fi
grep -q "punch alterno" "$T_PUNCH/log" || { echo "FALLA fundir: no anuncio el punch"; exit 1; }
[ -f "$T_PUNCH/02-punch.mp4" ] || { echo "FALLA fundir: no puncho la toma par"; exit 1; }
[ -f "$T_PUNCH/01-punch.mp4" ] && { echo "FALLA fundir: puncho una toma impar"; exit 1; }
WH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T_PUNCH/02-punch.mp4")
[ "$WH" = "416,736" ] || { echo "FALLA fundir: el punch cambio las dimensiones a $WH"; exit 1; }
WH2=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T_PUNCH/salida.mp4")
[ "$WH2" = "416,736" ] || { echo "FALLA fundir: el montaje con punch salio $WH2"; exit 1; }
# Fuera de rango se rechaza en vez de aceptarse en silencio.
if PUNCH_ALTERNO=2.0 TRANSICION=corte python3 "$RAIZ/produccion/fundir.py" \
     "$T_PUNCH" "$T_PUNCH/no.mp4" >/dev/null 2>&1; then
  echo "FALLA fundir: acepto PUNCH_ALTERNO=2.0"; exit 1
fi



echo "PASA $NOMBRE"
exit 0
