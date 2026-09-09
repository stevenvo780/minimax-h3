#!/usr/bin/env bash
set -u

NOMBRE="seleccionar-ancla"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
SCRIPT="$RAIZ/calidad/seleccionar-ancla.py"
FALLOS=0
falla() { echo "FALLA $NOMBRE: $*"; FALLOS=$((FALLOS+1)); }

if [[ ! -f "$SCRIPT" ]]; then
  echo "FALLA $NOMBRE: no se encontro $SCRIPT"
  exit 1
fi

PY="$RAIZ/.venv-calidad/bin/python"
if [[ ! -x "$PY" ]]; then PY=$(command -v python3 || true); fi
if [[ -z "$PY" ]] || ! "$PY" -c 'import cv2, numpy' >/dev/null 2>&1; then
  echo "FALLA $NOMBRE: falta OpenCV; ejecuta calidad/preparar-modelos-evaluacion.sh"
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "FALLA $NOMBRE: falta ffmpeg"
  exit 1
fi

WORK=$(mktemp -d /tmp/chk_seleccionar_ancla.XXXXXX) || exit 1
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

VIDEO="$WORK/cara-estatica.avi"
ffmpeg -nostdin -y -v error -f lavfi \
  -i "color=c=#303030:s=320x240:r=20:d=4" \
  -vf "drawbox=x=80:y=20:w=160:h=200:color=#d69b78:t=fill,\
drawbox=x=116:y=84:w=20:h=8:color=black:t=fill,\
drawbox=x=184:y=84:w=20:h=8:color=black:t=fill,\
drawbox=x=156:y=116:w=8:h=24:color=#8b4c3b:t=fill,\
drawbox=x=130:y=164:w=60:h=3:color=black:t=fill" \
  -frames:v 80 -c:v ffv1 "$VIDEO"
if [[ ! -s "$VIDEO" ]]; then
  echo "FALLA $NOMBRE: no se pudo crear el video fixture"
  exit 1
fi

CARA='{"bbox":[80,20,160,200],"landmarks":[[125,90],[195,90],[160,125],[130,165],[190,165]],"confianza":0.99}'
CARA_2='{"bbox":[10,80,45,60],"landmarks":[[20,100],[35,100],[28,112],[20,125],[35,125]],"confianza":0.98}'
printf '{"default":[%s],"frames":{}}\n' "$CARA" > "$WORK/una-cara.json"
printf '{"default":[%s,%s],"frames":{}}\n' "$CARA" "$CARA_2" > "$WORK/dos-caras.json"
printf '%s\n' \
  '{"default":[{"bbox":[80,20,160,200],"landmarks":[[125,90],[195,90],[160,125],[130,165],[190,165]],"confianza":0.60}],"frames":{}}' \
  > "$WORK/baja-confianza.json"
printf '%s\n' \
  '{"default":[{"bbox":[80,20,160,200],"landmarks":[[125,70],[195,112],[160,125],[130,165],[190,165]],"confianza":0.99}],"frames":{}}' \
  > "$WORK/pose-extrema.json"

# CASO A: recorre los 80 frames, selecciona dentro del margen y deja evidencia.
OUT_A=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO" \
  --salida "$WORK/ancla-a.png" --detecciones-simuladas "$WORK/una-cara.json" 2>&1)
RC_A=$?
if [[ "$RC_A" -ne 0 ]]; then
  falla "CASO A: seleccion valida fallo: rc=$RC_A, salida=$OUT_A"
elif [[ ! -s "$WORK/ancla-a.png" || ! -s "$WORK/ancla-a.png.json" ]]; then
  falla "CASO A: no publico PNG y sidecar"
else
  if ! "$PY" - "$WORK/ancla-a.png" "$WORK/ancla-a.png.json" <<'PY'
import hashlib, json, re, sys
import cv2

png, lateral = sys.argv[1:]
datos = json.load(open(lateral, encoding="utf-8"))
imagen = cv2.imread(png, cv2.IMREAD_UNCHANGED)
assert datos["schema"] == "seleccionar-ancla/v1"
assert datos["estado"] == "seleccionado"
assert datos["muestreo"]["estrategia"] == "todos_los_frames"
assert datos["muestreo"]["frames_analizados"] == 80
assert datos["gate_rostro_persistente"]["aprobado"] is True
assert datos["gate_rostro_persistente"]["frames_con_un_rostro"] == 80
assert 7 <= datos["seleccion"]["frame_index"] <= 72
assert datos["seleccion"]["timestamp_s"] == datos["seleccion"]["frame_index"] / 20
assert imagen.shape == (240, 320, 3)
assert hashlib.sha256(open(png, "rb").read()).hexdigest() == datos["seleccion"]["sha256_png"]
assert re.fullmatch(r"[0-9a-f]{64}", datos["video"]["sha256"])
assert re.fullmatch(r"[0-9a-f]{64}", datos["modelo"]["sha256"])
assert re.fullmatch(r"[0-9a-f]{64}", datos["seleccion"]["sha256_frame_bgr"])
assert len(datos["top_candidatos"]) >= 2
assert "apertura_boca_proxy" in datos["seleccion"]["metricas"]
assert "velocidad_local_proxy" in datos["seleccion"]["metricas"]
PY
  then
    falla "CASO A: contrato o trazabilidad JSON/PNG incorrectos"
  fi
fi

# CASO B: misma entrada produce exactamente el mismo fotograma y decision.
OUT_B=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO" \
  --salida "$WORK/ancla-b.png" --detecciones-simuladas "$WORK/una-cara.json" 2>&1)
RC_B=$?
if [[ "$RC_B" -ne 0 ]]; then
  falla "CASO B: segunda seleccion fallo: rc=$RC_B, salida=$OUT_B"
elif ! cmp -s "$WORK/ancla-a.png" "$WORK/ancla-b.png"; then
  falla "CASO B: el PNG no fue determinista"
elif ! "$PY" - "$WORK/ancla-a.png.json" "$WORK/ancla-b.png.json" <<'PY'
import json, sys
a, b = [json.load(open(r, encoding="utf-8")) for r in sys.argv[1:]]
assert a["seleccion"]["frame_index"] == b["seleccion"]["frame_index"]
assert a["seleccion"]["sha256_frame_bgr"] == b["seleccion"]["sha256_frame_bgr"]
assert a["seleccion"]["score"] == b["seleccion"]["score"]
PY
then
  falla "CASO B: frame, SHA o score cambiaron entre ejecuciones"
fi

# CASO C: dos rostros persistentes invalidan toda la toma y no dejan un PNG.
OUT_C=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO" \
  --salida "$WORK/ancla-c.png" --detecciones-simuladas "$WORK/dos-caras.json" 2>&1)
RC_C=$?
if [[ "$RC_C" -eq 0 ]] || ! printf '%s' "$OUT_C" | grep -q "exactamente un rostro persistente"; then
  falla "CASO C: dos caras persistentes no activaron el gate: rc=$RC_C, salida=$OUT_C"
elif [[ -e "$WORK/ancla-c.png" ]]; then
  falla "CASO C: se publico PNG pese al gate fallido"
elif ! grep -q '"frames_con_varios_rostros": 80' "$WORK/ancla-c.png.json"; then
  falla "CASO C: el diagnostico no contabilizo las dos caras"
fi

# CASO D: detecciones bajo confianza se descartan, no se promocionan.
OUT_D=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO" \
  --salida "$WORK/ancla-d.png" --detecciones-simuladas "$WORK/baja-confianza.json" 2>&1)
RC_D=$?
if [[ "$RC_D" -eq 0 ]] || [[ -e "$WORK/ancla-d.png" ]]; then
  falla "CASO D: se aceptaron detecciones de baja confianza: rc=$RC_D, salida=$OUT_D"
elif ! grep -q '"detecciones_descartadas_confianza": 80' "$WORK/ancla-d.png.json"; then
  falla "CASO D: el descarte por confianza no quedo trazado"
fi

# CASO E: un rostro detectable pero borroso pasa el gate de persistencia y aun
# asi no se convierte en ancla.
VIDEO_BLUR="$WORK/cara-borrosa.avi"
ffmpeg -nostdin -y -v error -f lavfi -i "color=c=#888888:s=320x240:r=20:d=4" \
  -frames:v 80 -c:v ffv1 "$VIDEO_BLUR"
OUT_E=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO_BLUR" \
  --salida "$WORK/ancla-e.png" --detecciones-simuladas "$WORK/una-cara.json" 2>&1)
RC_E=$?
if [[ "$RC_E" -eq 0 ]] || ! printf '%s' "$OUT_E" | grep -q "ningun frame supero"; then
  falla "CASO E: el blur no fue descartado: rc=$RC_E, salida=$OUT_E"
elif [[ -e "$WORK/ancla-e.png" ]] || ! grep -q '"blur"' "$WORK/ancla-e.png.json"; then
  falla "CASO E: salida o diagnostico incorrecto para blur"
fi

# CASO F: una pose extrema no gana por nitidez o confianza altas.
OUT_F=$(SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 "$PY" "$SCRIPT" "$VIDEO" \
  --salida "$WORK/ancla-f.png" --detecciones-simuladas "$WORK/pose-extrema.json" 2>&1)
RC_F=$?
if [[ "$RC_F" -eq 0 ]] || [[ -e "$WORK/ancla-f.png" ]]; then
  falla "CASO F: se publico una pose extrema: rc=$RC_F, salida=$OUT_F"
elif ! grep -q '"pose_ojos_extrema"' "$WORK/ancla-f.png.json"; then
  falla "CASO F: el descarte de pose no quedo trazado"
fi

# CASO G: ni modelo ausente ni backend simulado se convierten en fallback.
OUT_G=$("$PY" "$SCRIPT" "$VIDEO" --salida "$WORK/ancla-g.png" \
  --modelo "$WORK/no-existe.onnx" 2>&1)
RC_G=$?
if [[ "$RC_G" -eq 0 ]] || ! printf '%s' "$OUT_G" | grep -q "modelo YuNet ausente"; then
  falla "CASO G: modelo ausente no produjo error claro: rc=$RC_G, salida=$OUT_G"
fi
OUT_G2=$("$PY" "$SCRIPT" "$VIDEO" --salida "$WORK/ancla-g2.png" \
  --detecciones-simuladas "$WORK/una-cara.json" 2>&1)
RC_G2=$?
if [[ "$RC_G2" -eq 0 ]] || ! printf '%s' "$OUT_G2" | grep -q "solo se permite"; then
  falla "CASO G: se activo simulacion sin autorizacion explicita: rc=$RC_G2, salida=$OUT_G2"
fi

if [[ "$FALLOS" -gt 0 ]]; then
  echo "RESULTADO $NOMBRE: $FALLOS fallo(s)"
  exit 1
fi
echo "OK $NOMBRE: selector denso, determinista y con gates verificados"
