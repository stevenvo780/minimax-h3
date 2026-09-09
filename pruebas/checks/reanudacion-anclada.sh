#!/bin/bash
# Regresion vertical del runner actual: plan, cache content-addressed, salida
# atomica y montaje fail-closed. Todo corre con sd-cli falso y videos diminutos.
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
NOMBRE=reanudacion-anclada
exec 0</dev/null

fallar() { echo "FALLA $NOMBRE: $1"; exit 1; }
REAL_FFMPEG=$(command -v ffmpeg) || fallar "ffmpeg no esta disponible"
REAL_PYTHON=$(command -v python3) || fallar "python3 no esta disponible"
command -v ffprobe >/dev/null 2>&1 || fallar "ffprobe no esta disponible"

T=$(mktemp -d "${TMPDIR:-/tmp}/chk-anclada.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
P=$T/proyecto
mkdir -p "$P/lib" "$P/harness" "$P/produccion" "$P/calidad" "$P/bin" \
  "$P/.venv-calidad/bin" "$P/modelos/evaluacion" \
  "$P/modelos/diffusion_models" "$P/modelos/vae" "$P/modelos/text_encoders" \
  "$T/stubs" "$T/salida" "$T/compat/cuda"

for f in compat.sh comun.sh prompt.sh vram.sh estado_obra.py; do
  cp "$RAIZ/lib/$f" "$P/lib/$f" || fallar "no pude copiar lib/$f"
done
cp "$RAIZ/harness/planificar.py" "$P/harness/" || exit 1
cp "$RAIZ/produccion/producir-anclado.sh" "$RAIZ/produccion/fundir.py" "$P/produccion/" || exit 1

# Las metricas posteriores son asesoras y no forman parte de este check.
cat > "$P/calidad/auditar.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
chmod +x "$P/calidad/auditar.py"

# Backend y selector falsos, exclusivos de esta regresion. El wrapper permite
# probar por separado ausencia de OpenCV y fallo semantico (p.ej. sin rostro),
# y el selector deja un PNG/JSON con el mismo contrato trazable del real.
cat > "$P/.venv-calidad/bin/python" <<'SH'
#!/bin/bash
if [ "${1:-}" = -c ] && [[ "${2:-}" == *FaceDetectorYN* ]]; then
  [ "${ANCHOR_BACKEND_FAIL:-0}" = 1 ] && exit 19
  exit 0
fi
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$P/.venv-calidad/bin/python"

cat > "$P/calidad/seleccionar-ancla.py" <<'PY'
#!/usr/bin/env python3
import argparse, hashlib, json, os, subprocess, sys

def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""):
            h.update(block)
    return h.hexdigest()

p=argparse.ArgumentParser()
p.add_argument("video"); p.add_argument("--salida",required=True)
p.add_argument("--json",required=True); p.add_argument("--modelo",required=True)
a=p.parse_args()
with open(os.environ["ANCHOR_CALLS"],"a",encoding="utf-8") as f:
    f.write(" ".join(sys.argv[1:])+"\n")
if os.environ.get("ANCHOR_FAIL","0") == "1":
    with open(a.json,"w",encoding="utf-8") as f:
        json.dump({"schema":"seleccionar-ancla/v1","estado":"rechazado_gate_rostro"},f)
    print("ERROR: la toma no contiene exactamente un rostro persistente",file=sys.stderr)
    raise SystemExit(3)
subprocess.run([
    os.environ["REAL_FFMPEG"],"-nostdin","-y","-v","error","-i",a.video,
    "-frames:v","1","-update","1",a.salida
],check=True)
data={
    "schema":"seleccionar-ancla/v1", "estado":"seleccionado",
    "video":{"sha256":sha(a.video)},
    "modelo":{"sha256":sha(a.modelo),"backend":"stub-yunet"},
    "seleccion":{"sha256_png":sha(a.salida),"frame_index":0,"timestamp_s":0.0},
    "top_candidatos":[]
}
with open(a.json,"w",encoding="utf-8") as f:
    json.dump(data,f,sort_keys=True)
PY
chmod +x "$P/calidad/seleccionar-ancla.py"
printf 'yunet de prueba\n' > "$P/modelos/evaluacion/face_detection_yunet_2023mar.onnx"

# Hace que compat_cuda no recorra el workspace. sd-cli falso ya arranca tal cual.
: > "$T/compat/cuda/libcudart.so.13"
printf '%s\n' "$T/compat/cuda" > "$T/compat/cuda.path"

cat > "$P/bin/sd-cli" <<'SH'
#!/bin/bash
# recipe A
[ "${1:-}" = --help ] && exit 0
out=""; w=64; h=48; frames=24
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -W) w=$2; shift 2 ;;
    -H) h=$2; shift 2 ;;
    --video-frames) frames=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 2
printf '%s\n' "$out" >> "$CALLS"
[ "${SD_SLEEP:-0}" = 0 ] || sleep "$SD_SLEEP"
if [ "${SHORT_OUTPUT:-0}" = 1 ]; then frames=6; fi
duration=$(awk -v n="$frames" 'BEGIN{printf "%.9f", n/24}')
"$REAL_FFMPEG" -nostdin -y -v error \
  -f lavfi -i "color=c=black:s=${w}x${h}:r=24" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$duration" \
  -frames:v "$frames" -shortest \
  -c:v ffv1 -c:a pcm_s16le "$out.avi" || exit 3
[ -z "${SD_ERROR_TEXT:-}" ] || printf '%s\n' "$SD_ERROR_TEXT" >&2
exit "${SD_FAIL:-0}"
SH
chmod +x "$P/bin/sd-cli"
printf 'diffusion de prueba\n' > "$P/modelos/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf"
printf 'video vae de prueba\n' > "$P/modelos/vae/minimax_h3_video_vae_fp16.safetensors"
printf 'audio vae de prueba\n' > "$P/modelos/vae/minimax_h3_audio_vae_fp32.safetensors"
printf 'llm de prueba\n' > "$P/modelos/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf"

cat > "$T/stubs/nvidia-smi" <<'SH'
#!/bin/bash
echo 20000
SH
chmod +x "$T/stubs/nvidia-smi"

# Puede fallar solo el postproceso de una toma; sd-cli usa REAL_FFMPEG y no pasa
# por este wrapper. El resto se delega al ffmpeg autentico.
cat > "$T/stubs/ffmpeg" <<'SH'
#!/bin/bash
ultimo=""
for arg in "$@"; do ultimo=$arg; done
if [ "${FAIL_POST:-0}" = 1 ]; then
  case "$ultimo" in */montaje/[0-9][0-9].mp4) exit 42 ;; esac
fi
exec "$REAL_FFMPEG" "$@"
SH
chmod +x "$T/stubs/ffmpeg"

G=$T/obra.guion
cat > "$G" <<'EOF'
@TIPO habla
@ESCENA Un retrato fijo.
@AMBIENTE Una sala silenciosa.
@MUSICA Una nota grave.
TOMA|Primera version del texto.|inicio|habla|
EOF

CALLS=$T/llamadas.txt
: > "$CALLS"
ANCHOR_CALLS=$T/llamadas-selector.txt
: > "$ANCHOR_CALLS"
export CALLS ANCHOR_CALLS REAL_FFMPEG REAL_PYTHON

correr() {  # <guion> <obra>; variables FAIL_POST/SD_FAIL se heredan si existen
  PATH="$T/stubs:$PATH" MD="$P" DEST="$T/salida" CERROJO="$T/generacion.lock" \
    COMPAT_DIR="$T/compat" RAM_NECESARIA=0 \
    ANCLA_NEUTRAL="${ANCLA_NEUTRAL_PRUEBA:-0}" \
    ANCHOR_FAIL="${ANCHOR_FAIL_PRUEBA:-0}" \
    ANCHOR_BACKEND_FAIL="${ANCHOR_BACKEND_FAIL_PRUEBA:-0}" \
    REINTENTOS="${REINTENTOS_PRUEBA:-1}" REINTENTO_REPOSO=0 \
    bash "$P/produccion/producir-anclado.sh" "$1" "$2" 22 64 48 1
}

# 1. Primera corrida: plan, toma, sidecar, estado y entrega completa.
correr "$G" cache > "$T/primera.log" 2>&1 || fallar "primera corrida: $(tail -4 "$T/primera.log")"
OBRA=$P/produccion/obra/cache
[ -s "$OBRA/plan.json" ] || fallar "no se guardo plan.json"
[ -s "$OBRA/t01.avi" ] || fallar "no se genero t01.avi"
[ -s "$OBRA/t01.fingerprint" ] || fallar "no se guardo la huella de t01"
[ -s "$OBRA/recipe.json" ] || fallar "no se guardo el manifiesto de receta"
python3 - "$OBRA/estado.json" <<'PY' || fallar "estado final incorrecto"
import json,sys
e=json.load(open(sys.argv[1],encoding="utf-8"))
assert e["phase"] == "review_pending" and e["completed"] == e["total"] == 1
assert e.get("final")
PY
[ "$(wc -l < "$CALLS")" -eq 1 ] || fallar "la primera corrida no llamo una vez a sd-cli"
ENTREGA=$(find "$T/salida" -maxdepth 1 -type f -name 'cache-*.mp4' -print -quit)
[ -n "$ENTREGA" ] || fallar "no se publico la primera entrega"
python3 "$P/lib/estado_obra.py" verify-artifact \
  "$ENTREGA.minimax-h3.json" "$ENTREGA" \
  || fallar "la entrega no tiene procedencia verificable"

# El manifiesto ata la identidad del inode, no sólo size/mtime. Sustituir un
# componente por otro byte-a-byte igual se detecta antes de volver a generar.
MODELO_TEST=$P/modelos/vae/minimax_h3_audio_vae_fp32.safetensors
cp -p "$MODELO_TEST" "$T/modelo-mismo-contenido"
mv "$T/modelo-mismo-contenido" "$MODELO_TEST"
if python3 "$P/lib/estado_obra.py" verify-recipe "$OBRA/recipe.json" >/dev/null 2>&1; then
  fallar "verify-recipe acepto un componente sustituido con iguales bytes y mtime"
fi

# También se ata el nombre original: retargetear un MODELO= que sea symlink no
# puede verificar el inode viejo mientras sd-cli abriría silenciosamente otro.
printf 'mismo-peso\n' > "$T/peso-a"
cp -p "$T/peso-a" "$T/peso-b"
ln -s "$T/peso-a" "$T/peso-activo"
python3 "$P/lib/estado_obra.py" recipe-fingerprint \
  --cache "$T/cache-symlink.json" --manifest "$T/recipe-symlink.json" \
  --component "diffusion=$T/peso-activo" --setting recipe=prueba >/dev/null \
  || fallar "no pude crear receta mediante symlink"
ln -sfn "$T/peso-b" "$T/peso-activo"
if python3 "$P/lib/estado_obra.py" verify-recipe "$T/recipe-symlink.json" >/dev/null 2>&1; then
  fallar "verify-recipe acepto un symlink retargeteado"
fi

# Empezar otra corrida limpia el `final` y el mensaje de la anterior.
python3 "$P/lib/estado_obra.py" state "$OBRA/estado.json" --phase planned \
  --name cache --run-fingerprint prueba --completed 0 --total 1 || exit 1
python3 - "$OBRA/estado.json" <<'PY' || fallar "planned heredo el final anterior"
import json,sys
state=json.load(open(sys.argv[1],encoding="utf-8"))
assert "final" not in state and "message" not in state
PY

# Un resto de una version mas larga no puede colarse en el montaje actual.
cp "$OBRA/t01.avi" "$OBRA/t02.avi"
correr "$G" cache > "$T/segunda.log" 2>&1 || fallar "reanudar el mismo plan fallo"
[ "$(wc -l < "$CALLS")" -eq 1 ] || fallar "la misma huella regenero una toma valida"
[ "$(wc -l < "$OBRA/montaje/lista.txt")" -eq 1 ] \
  || fallar "el montaje incluyo la toma sobrante t02"
grep -q 'verificada (huella' "$T/segunda.log" || fallar "no anuncio reutilizacion verificada"

# Un AVI sustituido por otro estructuralmente valido no puede pasar sólo por
# conservar el fingerprint de solicitud: el sidecar liga tambien sus bytes.
duration=$(awk 'BEGIN{printf "%.9f", 22/24}')
"$REAL_FFMPEG" -nostdin -y -v error \
  -f lavfi -i "color=c=red:s=64x48:r=24" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$duration" \
  -frames:v 22 -shortest -c:v ffv1 -c:a pcm_s16le "$OBRA/t01-sustituta.avi"
mv "$OBRA/t01-sustituta.avi" "$OBRA/t01.avi"
correr "$G" cache > "$T/artefacto.log" 2>&1 || fallar "corrida tras sustituir el AVI fallo"
[ "$(wc -l < "$CALLS")" -eq 2 ] \
  || fallar "un AVI sustituido con sidecar viejo se reutilizo"

# El estado mas peligroso de un crash es AVI publicado sin sidecar. Ahora se
# trata como legacy no demostrable y se regenera salvo opt-in inseguro.
rm "$OBRA/t01.fingerprint"
correr "$G" cache > "$T/legacy.log" 2>&1 || fallar "regeneracion legacy segura fallo"
[ "$(wc -l < "$CALLS")" -eq 3 ] \
  || fallar "un AVI legacy sin huella se reutilizo por defecto"

# Cambiar bytes del ejecutable conservando tamano y mtime debe invalidar la
# receta. El antiguo stat(size,mtime) colisionaba exactamente en este caso.
cp -p "$P/bin/sd-cli" "$T/sd-cli-anterior"
sed -i 's/recipe A/recipe B/' "$P/bin/sd-cli"
touch -r "$T/sd-cli-anterior" "$P/bin/sd-cli"
correr "$G" cache > "$T/receta.log" 2>&1 || fallar "corrida con receta cambiada fallo"
[ "$(wc -l < "$CALLS")" -eq 4 ] \
  || fallar "bytes distintos con mismo tamano/mtime reutilizaron una toma obsoleta"

# Cambiar el contenido bajo el mismo nombre invalida solo lo que cambio y
# preserva el artefacto caro anterior en historial.
sed -i 's/Primera version/Segunda version/' "$G"
correr "$G" cache > "$T/tercera.log" 2>&1 || fallar "corrida con guion cambiado fallo"
[ "$(wc -l < "$CALLS")" -eq 5 ] || fallar "el guion cambiado reutilizo t01 obsoleta"
find "$OBRA/historial" -type f -name 't01.avi' -print -quit | grep -q . \
  || fallar "la toma reemplazada no se preservo en historial"

# Dependencias reales de ancla: el PNG queda ligado a sus bytes y al SHA del
# AVI fuente. Se prueban dos corrupciones que antes conservaban sidecars viejos.
G_ANCLA=$T/ancla.guion
cat > "$G_ANCLA" <<'EOF'
@TIPO habla
@ESCENA Un retrato fijo.
@AMBIENTE Una sala silenciosa.
@MUSICA Una nota grave.
TOMA|Primera toma.|inicio|habla|
TOMA|Segunda toma.|ancla:1|habla|
EOF
antes=$(wc -l < "$CALLS")
correr "$G_ANCLA" cadena-ancla > "$T/ancla-1.log" 2>&1 \
  || fallar "primera corrida anclada fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes+2)) ] \
  || fallar "la corrida anclada no genero exactamente dos tomas"
OBRA_ANCLA=$P/produccion/obra/cadena-ancla
"$REAL_FFMPEG" -nostdin -y -v error -f lavfi -i "color=c=red:s=64x48" \
  -frames:v 1 -update 1 "$OBRA_ANCLA/anclas/a02.png"
correr "$G_ANCLA" cadena-ancla > "$T/ancla-2.log" 2>&1 \
  || fallar "reparar un PNG de ancla sustituido fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes+2)) ] \
  || fallar "reextraer el mismo ancla regenero una toma innecesariamente"
find "$OBRA_ANCLA/historial" -type f -name a02.png -print -quit | grep -q . \
  || fallar "el PNG de ancla sustituido no se preservo"

req=$(python3 - "$OBRA_ANCLA/t01.fingerprint" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["fingerprint"])
PY
)
duration=$(awk 'BEGIN{printf "%.9f", 22/24}')
"$REAL_FFMPEG" -nostdin -y -v error \
  -f lavfi -i "color=c=blue:s=64x48:r=24" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=$duration" \
  -frames:v 22 -shortest -c:v ffv1 -c:a pcm_s16le "$OBRA_ANCLA/t01.avi"
python3 "$P/lib/estado_obra.py" write-fingerprint "$OBRA_ANCLA/t01.fingerprint" \
  "$req" --artifact "$OBRA_ANCLA/t01.avi" || exit 1
correr "$G_ANCLA" cadena-ancla > "$T/ancla-3.log" 2>&1 \
  || fallar "invalidar el ancla al cambiar los bytes fuente fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes+3)) ] \
  || fallar "cambiar el AVI fuente no regenero exactamente la toma dependiente"

# Un rc no-cero no se vuelve exito aunque sd-cli haya dejado un AVI aparente.
antes=$(wc -l < "$CALLS")
set +e
SD_FAIL=9 REINTENTOS_PRUEBA=3 correr "$G" salida-rc > "$T/rc.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "sd-cli rc=9 fue aceptado como exito"
[ "$(wc -l < "$CALLS")" -eq $((antes+1)) ] \
  || fallar "un fallo determinista rc=9 gasto mas de un intento"
[ ! -f "$P/produccion/obra/salida-rc/t01.avi" ] \
  || fallar "una salida con rc=9 se publico como toma valida"
compgen -G "$T/salida/salida-rc-*.mp4" >/dev/null \
  && fallar "una generacion rc=9 produjo entrega"

# SIGABRT/SIGSEGV no implican OOM por sí solos. Sin firma se corta en uno; con
# cudaMalloc/out of memory se consumen los reintentos configurados.
antes=$(wc -l < "$CALLS")
set +e
SD_FAIL=134 REINTENTOS_PRUEBA=3 correr "$G" abort-determinista > "$T/abort.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "SIGABRT determinista termino con exito"
[ "$(wc -l < "$CALLS")" -eq $((antes+1)) ] \
  || fallar "SIGABRT sin OOM se reintento"

antes=$(wc -l < "$CALLS")
set +e
SD_FAIL=134 SD_ERROR_TEXT='cudaMalloc failed: out of memory' \
  REINTENTOS_PRUEBA=3 correr "$G" abort-oom > "$T/abort-oom.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "SIGABRT/OOM falso termino con exito"
[ "$(wc -l < "$CALLS")" -eq $((antes+3)) ] \
  || fallar "SIGABRT con firma OOM no uso exactamente tres intentos"

# rc=0 tampoco basta: un clip corto con audio y resolucion correctos debe
# fallar por conteo de frames/duracion y nunca adquirir una huella oficial.
set +e
SHORT_OUTPUT=1 correr "$G" salida-corta > "$T/corta.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "una salida de 6/22 frames termino con exito"
[ ! -f "$P/produccion/obra/salida-corta/t01.avi" ] \
  || fallar "una toma truncada se publico como valida"
compgen -G "$T/salida/salida-corta-*.mp4" >/dev/null \
  && fallar "una toma truncada produjo entrega"

# Si una de las N tomas no se puede postprocesar, no se publica una pieza
# parcial y el estado durable queda en failed.
set +e
FAIL_POST=1 correr "$G" parcial > "$T/parcial.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "el postproceso fallido termino con exito"
compgen -G "$T/salida/parcial-*.mp4" >/dev/null \
  && fallar "se publico una pieza parcial"
python3 - "$P/produccion/obra/parcial/estado.json" <<'PY' \
  || fallar "el fallo no quedo durable"
import json,sys
assert json.load(open(sys.argv[1],encoding="utf-8"))["phase"] == "failed"
PY

# ANCLA_NEUTRAL es opt-in estricto. Su cache liga no solo los pixeles, sino
# tambien selector, modelo, sidecar y metodo; el fixture negro hace que el PNG
# temporal y el neutral sean identicos y prueba justo la colision peligrosa.
G_NEUTRAL=$T/ancla-neutral.guion
cat > "$G_NEUTRAL" <<'EOF'
@TIPO habla
@ESCENA Un retrato fijo.
@AMBIENTE Una sala silenciosa.
@MUSICA Una nota grave.
TOMA|Primera toma.|inicio|habla|
TOMA|Segunda toma.|ancla:1|habla|
EOF

antes_sd=$(wc -l < "$CALLS"); antes_selector=$(wc -l < "$ANCHOR_CALLS")
ANCLA_NEUTRAL_PRUEBA=2 correr "$G_NEUTRAL" neutral-env-invalido \
  > "$T/neutral-env.log" 2>&1 && fallar "ANCLA_NEUTRAL=2 fue aceptado"
[ "$(wc -l < "$CALLS")" -eq "$antes_sd" ] \
  || fallar "ANCLA_NEUTRAL invalido alcanzo sd-cli"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq "$antes_selector" ] \
  || fallar "ANCLA_NEUTRAL invalido alcanzo el selector"
grep -q 'ANCLA_NEUTRAL debe ser 0 o 1' "$T/neutral-env.log" \
  || fallar "ANCLA_NEUTRAL invalido no dio un error claro"

ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/neutral-1.log" 2>&1 || fallar "primera corrida neutral fallo: $(tail -5 "$T/neutral-1.log")"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+2)) ] \
  || fallar "la primera corrida neutral no genero exactamente dos tomas"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+1)) ] \
  || fallar "la primera corrida neutral no llamo exactamente una vez al selector"
OBRA_NEUTRAL=$P/produccion/obra/neutral-cache
A_NEUTRAL=$OBRA_NEUTRAL/anclas/a02.png
[ -s "$A_NEUTRAL" ] && [ -s "$A_NEUTRAL.json" ] && [ -s "$A_NEUTRAL.fingerprint" ] \
  || fallar "el modo neutral no publico PNG, sidecar y huella"
grep -q "$OBRA_NEUTRAL/t01.avi --salida $A_NEUTRAL --json $A_NEUTRAL.json --modelo $P/modelos/evaluacion/face_detection_yunet_2023mar.onnx" \
  "$ANCHOR_CALLS" || fallar "la llamada al selector no recibio fuente/salidas/modelo exactos"
python3 "$P/lib/estado_obra.py" match-fingerprint "$A_NEUTRAL.fingerprint" \
  "$(python3 - "$A_NEUTRAL.fingerprint" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"])
PY
)" --artifact "$A_NEUTRAL" || fallar "la huella del ancla neutral no liga su PNG"
FP_NEUTRAL_1=$(python3 - "$A_NEUTRAL.fingerprint" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"])
PY
)
PNG_NEUTRAL=$(sha256sum "$A_NEUTRAL" | awk '{print $1}')
RUN_NEUTRAL_1=$(python3 - "$OBRA_NEUTRAL/plan.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["run_fingerprint"])
PY
)
RECETA_NEUTRAL_1=$(python3 - "$OBRA_NEUTRAL/recipe.json" \
  "$P/calidad/seleccionar-ancla.py" \
  "$P/modelos/evaluacion/face_detection_yunet_2023mar.onnx" <<'PY'
import hashlib,json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["settings"]["ancla_neutral"] == "neutral-yunet-v1"
components=manifest["components"]
assert set(("selector_ancla","modelo_yunet")) <= set(components)
for key,path in (("selector_ancla",sys.argv[2]),("modelo_yunet",sys.argv[3])):
    assert components[key]["source_path"] == path
    assert components[key]["sha256"] == hashlib.sha256(open(path,"rb").read()).hexdigest()
print(manifest["fingerprint"])
PY
) || fallar "la receta global neutral no liga modo, selector y YuNet"
FINAL_NEUTRAL_1=$(python3 - "$OBRA_NEUTRAL/estado.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["final"])
PY
)
python3 - "$FINAL_NEUTRAL_1.minimax-h3.json" "$RUN_NEUTRAL_1" <<'PY' \
  || fallar "la entrega neutral no quedo ligada a su run_fingerprint"
import json,sys
assert json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"] == sys.argv[2]
PY

# Cache hit: se verifica que el backend siga presente, pero no se reejecuta el
# selector ni sd-cli si toda la procedencia coincide.
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/neutral-cache-hit.log" 2>&1 || fallar "reanudar cache neutral fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+2)) ] \
  || fallar "un cache hit neutral regenero una toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+1)) ] \
  || fallar "un cache hit neutral reejecuto el selector"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_fingerprint"])' "$OBRA_NEUTRAL/plan.json")" = "$RUN_NEUTRAL_1" ] \
  || fallar "un cache hit neutral cambio el run_fingerprint"

# Cambiar al metodo temporal produce el mismo PNG negro, pero debe cambiar la
# receta y el run_fingerprint globales. Por eso las huellas por toma invalidan
# las dos tomas, ademas de cambiar la procedencia del ancla dependiente.
correr "$G_NEUTRAL" neutral-cache > "$T/neutral-a-temporal.log" 2>&1 \
  || fallar "cambiar de neutral a temporal fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+4)) ] \
  || fallar "cambiar de neutral a temporal no invalido las huellas por toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+1)) ] \
  || fallar "el metodo temporal llamo al selector"
[ ! -e "$A_NEUTRAL.json" ] || fallar "el metodo temporal dejo activo el sidecar neutral"
FP_TEMPORAL=$(python3 - "$A_NEUTRAL.fingerprint" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"])
PY
)
PNG_TEMPORAL=$(sha256sum "$A_NEUTRAL" | awk '{print $1}')
[ "$PNG_NEUTRAL" = "$PNG_TEMPORAL" ] \
  || fallar "el fixture no produjo la colision de PNG necesaria para probar el metodo"
[ "$FP_NEUTRAL_1" != "$FP_TEMPORAL" ] \
  || fallar "neutral y temporal compartieron huella pese a usar metodos distintos"
RUN_TEMPORAL=$(python3 - "$OBRA_NEUTRAL/plan.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["run_fingerprint"])
PY
)
[ "$RUN_TEMPORAL" != "$RUN_NEUTRAL_1" ] \
  || fallar "neutral y temporal compartieron run_fingerprint"
python3 - "$OBRA_NEUTRAL/recipe.json" <<'PY' \
  || fallar "la receta temporal conservo dependencias faciales"
import json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["settings"]["ancla_neutral"] == "temporal-v1"
assert "selector_ancla" not in manifest["components"]
assert "modelo_yunet" not in manifest["components"]
PY
FINAL_TEMPORAL=$(python3 - "$OBRA_NEUTRAL/estado.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["final"])
PY
)
[ "$FINAL_TEMPORAL" != "$FINAL_NEUTRAL_1" ] \
  || fallar "neutral y temporal reutilizaron la misma publicacion final"
python3 - "$FINAL_TEMPORAL.minimax-h3.json" "$RUN_TEMPORAL" <<'PY' \
  || fallar "la entrega temporal no quedo ligada a su run_fingerprint"
import json,sys
assert json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"] == sys.argv[2]
PY

ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/temporal-a-neutral.log" 2>&1 || fallar "volver de temporal a neutral fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+6)) ] \
  || fallar "volver a neutral no restauro las huellas globales por toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+2)) ] \
  || fallar "volver a neutral no llamo una vez al selector"
FP_NEUTRAL_2=$(python3 - "$A_NEUTRAL.fingerprint" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="ascii"))["fingerprint"])
PY
)
[ "$FP_NEUTRAL_1" = "$FP_NEUTRAL_2" ] \
  || fallar "la misma receta neutral no recupero una huella determinista"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_fingerprint"])' "$OBRA_NEUTRAL/plan.json")" = "$RUN_NEUTRAL_1" ] \
  || fallar "volver a la receta neutral no recupero su run_fingerprint"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$OBRA_NEUTRAL/recipe.json")" = "$RECETA_NEUTRAL_1" ] \
  || fallar "volver a neutral no recupero la huella global de receta"

# Cambiar selector o modelo invalida ancla y toma aunque el selector stub elija
# exactamente los mismos pixeles.
printf '\n# revision B del selector\n' >> "$P/calidad/seleccionar-ancla.py"
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/neutral-selector-cambio.log" 2>&1 || fallar "cambio de selector fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+8)) ] \
  || fallar "cambiar selector no invalido las huellas por toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+3)) ] \
  || fallar "cambiar selector no recalculo el ancla"
RUN_SELECTOR_B=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_fingerprint"])' \
  "$OBRA_NEUTRAL/plan.json")
[ "$RUN_SELECTOR_B" != "$RUN_NEUTRAL_1" ] \
  || fallar "cambiar selector no cambio el run_fingerprint"
python3 - "$OBRA_NEUTRAL/recipe.json" "$P/calidad/seleccionar-ancla.py" <<'PY' \
  || fallar "la receta no registro los nuevos bytes del selector"
import hashlib,json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["components"]["selector_ancla"]["sha256"] == hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()
PY

printf 'revision B del modelo\n' >> "$P/modelos/evaluacion/face_detection_yunet_2023mar.onnx"
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/neutral-modelo-cambio.log" 2>&1 || fallar "cambio de modelo fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+10)) ] \
  || fallar "cambiar modelo no invalido las huellas por toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+4)) ] \
  || fallar "cambiar modelo no recalculo el ancla"
RUN_MODELO_B=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_fingerprint"])' \
  "$OBRA_NEUTRAL/plan.json")
[ "$RUN_MODELO_B" != "$RUN_SELECTOR_B" ] \
  || fallar "cambiar YuNet no cambio el run_fingerprint"
python3 - "$OBRA_NEUTRAL/recipe.json" \
  "$P/modelos/evaluacion/face_detection_yunet_2023mar.onnx" <<'PY' \
  || fallar "la receta no registro los nuevos bytes de YuNet"
import hashlib,json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["components"]["modelo_yunet"]["sha256"] == hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()
PY

# Alterar solo el sidecar obliga a revalidar/reseleccionar. Como el selector
# restaura exactamente la misma evidencia, la toma cara no se regenera.
printf ' \n' >> "$A_NEUTRAL.json"
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-cache \
  > "$T/neutral-sidecar-cambio.log" 2>&1 || fallar "reparar sidecar neutral fallo"
[ "$(wc -l < "$CALLS")" -eq $((antes_sd+10)) ] \
  || fallar "restaurar el mismo sidecar regenero una toma innecesariamente"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_selector+5)) ] \
  || fallar "un sidecar alterado se reutilizo sin llamar al selector"

# Sin rostro es un fallo cerrado tras generar la fuente. Un backend ausente, en
# cambio, se detecta durante la receta global: no se genera ni siquiera t01 y
# nunca existe un plan neutral con dependencias sin verificar.
antes_fallo_sd=$(wc -l < "$CALLS"); antes_fallo_sel=$(wc -l < "$ANCHOR_CALLS")
set +e
ANCLA_NEUTRAL_PRUEBA=1 ANCHOR_FAIL_PRUEBA=1 \
  correr "$G_NEUTRAL" neutral-sin-rostro > "$T/neutral-sin-rostro.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "selector sin rostro termino con exito"
[ "$(wc -l < "$CALLS")" -eq $((antes_fallo_sd+1)) ] \
  || fallar "el fallo sin rostro genero la toma dependiente"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq $((antes_fallo_sel+1)) ] \
  || fallar "el caso sin rostro no llamo exactamente una vez al selector"
[ ! -e "$P/produccion/obra/neutral-sin-rostro/t02.avi" ] \
  || fallar "el caso sin rostro publico la toma dependiente"
grep -q 'no uso fallback temporal' "$T/neutral-sin-rostro.log" \
  || fallar "el fallo sin rostro no declaro el cierre sin fallback"
compgen -G "$T/salida/neutral-sin-rostro-*.mp4" >/dev/null \
  && fallar "el fallo sin rostro publico una entrega"

antes_fallo_sd=$(wc -l < "$CALLS"); antes_fallo_sel=$(wc -l < "$ANCHOR_CALLS")
set +e
ANCLA_NEUTRAL_PRUEBA=1 ANCHOR_BACKEND_FAIL_PRUEBA=1 \
  correr "$G_NEUTRAL" neutral-sin-backend > "$T/neutral-sin-backend.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "modo neutral sin backend termino con exito"
[ "$(wc -l < "$CALLS")" -eq "$antes_fallo_sd" ] \
  || fallar "la ausencia de backend alcanzo sd-cli antes del fingerprint"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq "$antes_fallo_sel" ] \
  || fallar "la ausencia de backend llego al selector"
grep -q 'no uso un instante temporal como fallback' "$T/neutral-sin-backend.log" \
  || fallar "la ausencia de backend no produjo un error fail-closed claro"

MODELO_YUNET=$P/modelos/evaluacion/face_detection_yunet_2023mar.onnx
mv "$MODELO_YUNET" "$T/yunet-ausente.onnx"

# Modo 0 conserva la ruta temporal y no exige ni importa backend, selector o
# YuNet. Se retiran las dos dependencias para demostrarlo, no solo para confiar
# en que una rama no fue ejecutada.
SELECTOR_TEST=$P/calidad/seleccionar-ancla.py
mv "$SELECTOR_TEST" "$T/selector-ausente.py"
antes_temporal_sd=$(wc -l < "$CALLS"); antes_temporal_sel=$(wc -l < "$ANCHOR_CALLS")
ANCLA_NEUTRAL_PRUEBA=0 ANCHOR_BACKEND_FAIL_PRUEBA=1 \
  correr "$G" temporal-sin-evaluador > "$T/temporal-sin-evaluador.log" 2>&1 \
  || fallar "modo temporal exigio backend, selector o YuNet"
[ "$(wc -l < "$CALLS")" -eq $((antes_temporal_sd+1)) ] \
  || fallar "modo temporal sin evaluador no produjo su toma"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq "$antes_temporal_sel" ] \
  || fallar "modo temporal sin evaluador llamo al selector"
python3 - "$P/produccion/obra/temporal-sin-evaluador/recipe.json" <<'PY' \
  || fallar "modo temporal registro dependencias faciales ausentes"
import json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["settings"]["ancla_neutral"] == "temporal-v1"
assert "selector_ancla" not in manifest["components"]
assert "modelo_yunet" not in manifest["components"]
PY
mv "$T/selector-ausente.py" "$SELECTOR_TEST"

antes_fallo_sd=$(wc -l < "$CALLS"); antes_fallo_sel=$(wc -l < "$ANCHOR_CALLS")
set +e
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_NEUTRAL" neutral-sin-modelo \
  > "$T/neutral-sin-modelo.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fallar "modo neutral sin modelo termino con exito"
[ "$(wc -l < "$CALLS")" -eq "$antes_fallo_sd" ] \
  || fallar "la ausencia de modelo alcanzo sd-cli antes del fingerprint"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq "$antes_fallo_sel" ] \
  || fallar "la ausencia de modelo llego al selector"
grep -q 'falta el modelo YuNet' "$T/neutral-sin-modelo.log" \
  || fallar "la ausencia de modelo no produjo un error claro"
mv "$T/yunet-ausente.onnx" "$MODELO_YUNET"

# Un destino B-roll conserva el metodo temporal aunque el opt-in global este
# activo: la receta valida sus dependencias globales, pero la toma no se envia
# al selector facial ni genera evidencia facial.
G_BROLL=$T/ancla-broll.guion
cat > "$G_BROLL" <<'EOF'
@TIPO habla
@ESCENA Un retrato fijo.
@AMBIENTE Una sala silenciosa.
@MUSICA Una nota grave.
TOMA|Primera toma.|inicio|habla|
TOMA|Detalle de una pieza de madera inmovil.|ancla:1|detalle|
EOF
antes_broll_sd=$(wc -l < "$CALLS"); antes_broll_sel=$(wc -l < "$ANCHOR_CALLS")
ANCLA_NEUTRAL_PRUEBA=1 correr "$G_BROLL" neutral-broll \
  > "$T/neutral-broll.log" 2>&1 \
  || fallar "la corrida B-roll neutral fallo: $(tail -5 "$T/neutral-broll.log")"
[ "$(wc -l < "$CALLS")" -eq $((antes_broll_sd+2)) ] \
  || fallar "la prueba B-roll no genero sus dos tomas"
[ "$(wc -l < "$ANCHOR_CALLS")" -eq "$antes_broll_sel" ] \
  || fallar "un destino B-roll fue analizado por el selector facial"
[ ! -e "$P/produccion/obra/neutral-broll/anclas/a02.png.json" ] \
  || fallar "un destino B-roll dejo sidecar de evaluacion facial"
python3 - "$P/produccion/obra/neutral-broll/recipe.json" <<'PY' \
  || fallar "la corrida B-roll perdio la identidad global neutral"
import json,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
assert manifest["settings"]["ancla_neutral"] == "neutral-yunet-v1"
assert "selector_ancla" in manifest["components"]
assert "modelo_yunet" in manifest["components"]
PY

# Dos runners, incluso con nombres distintos, no pueden superponer la obra
# completa. El segundo falla sin llegar a sd-cli; no queda en cola a ciegas.
antes=$(wc -l < "$CALLS")
SD_SLEEP=2 correr "$G" concurrente-a > "$T/concurrente-a.log" 2>&1 &
pid_a=$!
for _ in $(seq 1 50); do
  [ "$(wc -l < "$CALLS")" -gt "$antes" ] && break
  sleep 0.1
done
[ "$(wc -l < "$CALLS")" -eq $((antes+1)) ] \
  || fallar "la primera obra concurrente no alcanzo sd-cli"
# El mismo lock base bloquea a un consumidor legacy, no sólo a otra obra.
if MD="$P" COMPAT_DIR="$T/compat" CERROJO="$T/generacion.lock" \
    bash -c '. "$1/lib/comun.sh"; con_cerrojo 0 true' _ "$P" \
    > "$T/legacy-lock.log" 2>&1; then
  fallar "un runner legacy entro mientras la obra anclada retenia el recurso global"
fi
set +e
correr "$G" concurrente-b > "$T/concurrente-b.log" 2>&1
rc_b=$?
set -e
[ "$rc_b" -ne 0 ] || fallar "una segunda obra concurrente fue admitida"
[ "$(wc -l < "$CALLS")" -eq $((antes+1)) ] \
  || fallar "la segunda obra concurrente alcanzo sd-cli"
wait "$pid_a" || fallar "la primera obra concurrente fallo"

echo "PASA $NOMBRE (plan, receta neutral global, cache, huellas, rc, montaje exacto y fallo durable)"
exit 0
