#!/bin/bash
# Prueba real, CPU-only, del derivado estatico reproducible.
set -u

NOMBRE=estabilizar-plano
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}
SCRIPT=$RAIZ/produccion/estabilizar-plano.sh
FALLOS=0

falla() {
  echo "FALLA $NOMBRE: $*"
  FALLOS=$((FALLOS + 1))
}

for herramienta in ffmpeg ffprobe python3 sha256sum cmp; do
  command -v "$herramienta" >/dev/null 2>&1 || {
    echo "FALLA $NOMBRE: falta $herramienta"
    exit 1
  }
done
[ -x "$SCRIPT" ] || {
  echo "FALLA $NOMBRE: falta ejecutable $SCRIPT"
  exit 1
}

T=$(mktemp -d "${TMPDIR:-/tmp}/chk-estabilizar-plano.XXXXXX") || exit 1
limpiar() {
  case "$T" in "${TMPDIR:-/tmp}"/chk-estabilizar-plano.*) rm -rf -- "$T" ;; esac
}
trap limpiar EXIT

FUENTE=$T/fuente.avi
if ! ffmpeg -nostdin -hide_banner -v error \
  -f lavfi -i 'testsrc2=size=64x48:rate=24:duration=2' \
  -f lavfi -i 'sine=frequency=523:sample_rate=48000:duration=2' \
  -map 0:v:0 -map 1:a:0 -frames:v 48 \
  -c:v mjpeg -q:v 3 -pix_fmt yuvj420p -c:a pcm_s16le -f avi "$FUENTE"; then
  echo "FALLA $NOMBRE: no se pudo crear la fuente sintetica"
  exit 1
fi

SALIDA_A=$T/estatico-a.avi
SALIDA_B=$T/estatico-b.avi
if ! "$SCRIPT" --source "$FUENTE" --at 0.5 --seed 7301 --output "$SALIDA_A" \
  > "$T/crear-a.log" 2>&1; then
  falla "generacion A: $(tail -5 "$T/crear-a.log")"
fi
if ! "$SCRIPT" --source "$FUENTE" --at 0.5 --seed 7301 --output "$SALIDA_B" \
  > "$T/crear-b.log" 2>&1; then
  falla "generacion B: $(tail -5 "$T/crear-b.log")"
fi

# Geometria, FPS, cuadro total y las duraciones racional/PCM son identicos.
if ! python3 - "$FUENTE" "$SALIDA_A" "$SALIDA_A.manifest.json" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys


def probe(path):
    raw = subprocess.check_output([
        "ffprobe", "-v", "error", "-count_frames", "-show_entries",
        "format=duration:stream=codec_type,codec_name,width,height,r_frame_rate,"
        "time_base,duration_ts,nb_read_frames,sample_rate,channels",
        "-of", "json", path,
    ])
    data = json.loads(raw)
    video = next(x for x in data["streams"] if x["codec_type"] == "video")
    audio = next(x for x in data["streams"] if x["codec_type"] == "audio")
    return data["format"], video, audio


source_format, source_video, source_audio = probe(sys.argv[1])
output_format, output_video, output_audio = probe(sys.argv[2])
for field in ("width", "height", "r_frame_rate", "duration_ts", "nb_read_frames"):
    assert source_video[field] == output_video[field], (field, source_video, output_video)
assert source_format["duration"] == output_format["duration"] == "2.000000"
for field in ("sample_rate", "channels"):
    assert source_audio[field] == output_audio[field], (field, source_audio, output_audio)
assert output_video["codec_name"] == "mjpeg"
assert output_audio["codec_name"] == "pcm_s16le"

manifest = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert manifest["schema"] == "minimax-h3.estabilizar-plano/v1"
assert manifest["parameters"]["selected_frame_index_zero_based"] == 12
assert manifest["parameters"]["selected_frame_timestamp"] == "1/2"
assert manifest["parameters"]["seed"] == 7301
assert manifest["render"]["filter"] == (
    "format=yuvj420p,noise=c0_seed=7301:c0_strength=2:c0_flags=t+u"
)
assert manifest["audio"]["voice_analysis"] == "not_performed"
assert manifest["validation"]["full_av_decode"] is True
assert manifest["validation"]["semantic_or_voice_quality_assessed"] is False
assert manifest["source"]["sha256"] == hashlib.sha256(
    pathlib.Path(sys.argv[1]).read_bytes()
).hexdigest()
assert manifest["output"]["sha256"] == hashlib.sha256(
    pathlib.Path(sys.argv[2]).read_bytes()
).hexdigest()
PY
then
  falla "no se conservaron exactamente A/V o el manifiesto quedo incompleto"
fi

# No hay movimiento estructural: todos los cuadros difieren solo por grano
# tenue. A la vez, el grano debe ser realmente temporal, no un freeze bit a bit.
if ! ffmpeg -nostdin -hide_banner -v error -xerror -i "$SALIDA_A" \
  -map 0:v:0 -pix_fmt gray -f rawvideo "$T/cuadros.gray"; then
  falla "no se pudo decodificar el video para medir estabilidad"
elif ! python3 - "$T/cuadros.gray" <<'PY'
import hashlib
import pathlib
import sys

width, height, expected = 64, 48, 48
data = pathlib.Path(sys.argv[1]).read_bytes()
size = width * height
assert len(data) == size * expected, (len(data), size * expected)
frames = [data[x:x + size] for x in range(0, len(data), size)]
assert len({hashlib.sha256(frame).digest() for frame in frames}) >= 40
reference = frames[0]
mad = [sum(abs(a - b) for a, b in zip(reference, frame)) / size for frame in frames[1:]]
assert min(mad) > 0.10, min(mad)
assert max(mad) < 1.50, max(mad)
PY
then
  falla "la estructura se movio o el grano no fue temporal/sutil"
fi

# El PCM decodificado debe ser exactamente el de la fuente.
for video in "$FUENTE" "$SALIDA_A"; do
  nombre=$(basename "$video")
  if ! ffmpeg -nostdin -hide_banner -v error -xerror -i "$video" -map 0:a:0 \
    -c:a pcm_s16le -f hash -hash sha256 "$T/$nombre.audio.sha"; then
    falla "no se pudo hashear el audio de $nombre"
  fi
done
if ! cmp -s "$T/fuente.avi.audio.sha" "$T/estatico-a.avi.audio.sha"; then
  falla "el audio PCM de salida no es identico a la fuente"
fi

# Mismos bytes con misma fuente/receta, aunque cambie la ruta de destino.
if ! cmp -s "$SALIDA_A" "$SALIDA_B"; then
  falla "la salida no fue determinista con seed explicita"
fi
if ! "$SCRIPT" --verify --output "$SALIDA_A" > "$T/verificar.log" 2>&1; then
  falla "la verificacion integra fallo: $(tail -5 "$T/verificar.log")"
fi

# Nunca pisa una salida ya publicada, y tampoco sigue symlinks de entrada o salida.
SHA_VIDEO_ANTES=$(sha256sum "$SALIDA_A" | awk '{print $1}')
SHA_MANIFEST_ANTES=$(sha256sum "$SALIDA_A.manifest.json" | awk '{print $1}')
if "$SCRIPT" --source "$FUENTE" --at 0.5 --seed 7301 --output "$SALIDA_A" \
  > "$T/no-overwrite.log" 2>&1; then
  falla "se permitio sobreescribir una salida existente"
fi
if [ "$SHA_VIDEO_ANTES" != "$(sha256sum "$SALIDA_A" | awk '{print $1}')" ] \
  || [ "$SHA_MANIFEST_ANTES" != "$(sha256sum "$SALIDA_A.manifest.json" | awk '{print $1}')" ]; then
  falla "el intento de sobreescritura altero artefactos existentes"
fi

ln -s "$FUENTE" "$T/fuente-link.avi"
if "$SCRIPT" --source "$T/fuente-link.avi" --at 0.5 --seed 1 \
  --output "$T/desde-link.avi" > "$T/source-link.log" 2>&1; then
  falla "se siguio un symlink como fuente"
fi
[ ! -e "$T/desde-link.avi" ] || falla "el rechazo del symlink fuente publico una salida"

ln -s "$T/no-existe.avi" "$T/salida-link.avi"
if "$SCRIPT" --source "$FUENTE" --at 0.5 --seed 1 \
  --output "$T/salida-link.avi" > "$T/output-link.log" 2>&1; then
  falla "se siguio o reemplazo un symlink como salida"
fi
[ -L "$T/salida-link.avi" ] || falla "el rechazo de salida altero el symlink existente"

# Un cambio en cualquier campo cubierto por la huella invalida el manifiesto.
sed -i 's/"grain_luma_strength":2/"grain_luma_strength":3/' "$SALIDA_A.manifest.json"
if "$SCRIPT" --verify --output "$SALIDA_A" > "$T/tamper.log" 2>&1; then
  falla "--verify acepto un manifiesto alterado"
elif ! grep -q 'manifiesto alterado' "$T/tamper.log"; then
  falla "el tamper fallo sin diagnostico explicito: $(tail -3 "$T/tamper.log")"
fi

if [ "$FALLOS" -gt 0 ]; then
  echo "FALLA $NOMBRE: $FALLOS comprobaciones"
  exit 1
fi
echo "ok $NOMBRE (A/V exacto, estructura estable, grano determinista, no-overwrite, symlinks y tamper)"
