#!/bin/bash
set -u
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre=calidad-v2
exec 0</dev/null
fallos=0
T=$(mktemp -d /tmp/chk-calidad-v2.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT

E="$RAIZ/calidad/v2/evaluar.sh"
P="$RAIZ/calidad/perfiles/estricto-v2.json"
PY="$RAIZ/.venv-calidad/bin/python"
[ -x "$PY" ] || PY=python3
[ -x "$E" ] || { echo "FALLA $nombre: falta evaluador ejecutable"; exit 1; }

# El wrapper debe rechazar de forma acotada una segunda instancia; así un
# limite de threads no aparece como fallo espurio dentro de OpenCV/ffmpeg.
exec 7>"$T/evaluador.lock" || exit 1
flock 7 || exit 1
set +e
CALIDAD_V2_CERROJO="$T/evaluador.lock" CALIDAD_V2_ESPERA=0 \
  "$E" "$T/no-debe-arrancar" >"$T/lock.out" 2>"$T/lock.err"
lock_rc=$?
set -e
flock -u 7 || exit 1
if [ "$lock_rc" -ne 2 ] || ! grep -q 'turno sigue ocupado' "$T/lock.err"; then
  echo "FALLA $nombre: el cerrojo no serializo una segunda evaluacion"
  fallos=1
fi

printf 'contenido-intacto\n' > "$T/victima"
ln -s "$T/victima" "$T/evaluador-symlink.lock"
set +e
CALIDAD_V2_CERROJO="$T/evaluador-symlink.lock" CALIDAD_V2_ESPERA=0 \
  "$E" "$T/no-debe-arrancar" >"$T/symlink.out" 2>"$T/symlink.err"
symlink_rc=$?
set -e
if [ "$symlink_rc" -ne 2 ] || ! grep -q 'no puede ser un symlink' "$T/symlink.err" \
   || [ "$(cat "$T/victima")" != contenido-intacto ]; then
  echo "FALLA $nombre: el lock symlink modifico o no rechazo la victima"
  fallos=1
fi

make_plan() {
  local dir=$1; shift
  mkdir -p "$dir"
  python3 - "$dir/plan.json" "$@" <<'PY'
import json,sys
path,*types=sys.argv[1:]
takes=[]
for i,t in enumerate(types,1):
    takes.append({
        "indice":i,"tipo":t,"contenido":("Frase de prueba claramente hablada." if t=="habla" else "Plano sin voces."),
        "width":160,"height":90,"fps":24,"frames":24,"duracion_estimada_s":1.0,
    })
json.dump({"schema":"minimax-h3.plan-obra/v1","cabecera":{"tipo":types[0]},"tomas":takes},open(path,"w"))
PY
}

make_video() {
  local visual=$1 out=$2 frequency=${3:-1000}
  ffmpeg -nostdin -y -v error \
    -f lavfi -i "$visual" \
    -f lavfi -i "sine=frequency=$frequency:sample_rate=48000:duration=1" \
    -t 1 -shortest -c:v ffv1 -c:a pcm_s16le "$out"
}

expect_rc() {
  local expected=$1; shift
  set +e
  "$@" >/dev/null 2>"$T/stderr"
  local got=$?
  set -e
  if [ "$got" -ne "$expected" ]; then
    echo "FALLA $nombre: rc=$got, se esperaba $expected: $*"
    sed -n '1,4p' "$T/stderr" | sed 's/^/    /'
    fallos=1
  fi
}

set -e

# 1. Sin YuNet/SFace ni Whisper, todos los controles semanticos necesarios
# quedan UNKNOWN. El evaluador debe pedir REVIEW (3), omitir total y nunca
# convertir el modo degradado en PASS.
make_plan "$T/review" habla detalle
make_video "testsrc2=size=160x90:rate=24:duration=1" "$T/review/t01.avi"
make_video "smptebars=size=160x90:rate=24:duration=1" "$T/review/t02.avi"
expect_rc 3 "$E" "$T/review" --profile "$P" --no-face-backend --no-asr-backend --transition-style cut --output "$T/review.json"
python3 - "$T/review.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="REVIEW",d["status"]
assert d["semantic_complete"] is False
assert "total" not in d["scores"] and "TOTAL" not in d["scores"]
assert d["capabilities"]["face_detection"]["status"]=="unavailable"
assert any(g["status"]=="UNKNOWN" for t in d["takes"] for g in t["gates"])
assert [t["type"] for t in d["takes"]]==["habla","detalle"]
PY

# 2. Las metricas temporales de t02 deben ser byte-a-byte iguales aunque t01
# cambie radicalmente. Esto fija que no hay comparacion de bordes entre tomas.
make_plan "$T/isla-a" habla detalle
make_plan "$T/isla-b" habla detalle
make_video "color=c=white:size=160x90:rate=24:duration=1" "$T/isla-a/t01.avi"
make_video "testsrc2=size=160x90:rate=24:duration=1" "$T/isla-b/t01.avi"
cp "$T/review/t02.avi" "$T/isla-a/t02.avi"
cp "$T/review/t02.avi" "$T/isla-b/t02.avi"
expect_rc 3 "$E" "$T/isla-a" --profile "$P" --no-face-backend --no-asr-backend --transition-style cut --output "$T/isla-a.json"
expect_rc 3 "$E" "$T/isla-b" --profile "$P" --no-face-backend --no-asr-backend --transition-style cut --output "$T/isla-b.json"
python3 - "$T/isla-a.json" "$T/isla-b.json" <<'PY' || fallos=1
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert a["takes"][1]["temporal"]==b["takes"][1]["temporal"]
assert a["takes"][1]["temporal"]["scope"]=="intra-take-only"
for report in (a,b):
    encoded=json.dumps(report["takes"][1]["temporal"])
    assert "previous" not in encoded and "edge_reference" not in encoded
PY

# 3. Negro + camara inmovil da FAIL (1), incluso aunque ademas falte semantica.
make_plan "$T/fail" camara
make_video "color=c=black:size=160x90:rate=24:duration=1" "$T/fail/t01.avi"
expect_rc 1 "$E" "$T/fail" --profile "$P" --no-face-backend --no-asr-backend --output "$T/fail.json"
python3 - "$T/fail.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); gs={g["id"]:g["status"] for g in d["takes"][0]["gates"]}
assert d["status"]=="FAIL"
assert gs["temporal.black"]=="FAIL" and gs["temporal.motion"]=="FAIL"
assert d["takes"][0]["evidence"],"el fallo temporal debe producir evidencia"
PY

# 4. Un xfade entre habla y detalle es doble exposicion de roles incompatibles
# y tiene poder de veto propio.
expect_rc 1 "$E" "$T/review" --profile "$P" --no-face-backend --no-asr-backend \
  --transition-style xfade --transition-seconds 0.5 --output "$T/xfade.json"
python3 - "$T/xfade.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); tr=d["transitions"][0]
assert tr["status"]=="FAIL" and tr["double_exposure_risk"] is True
assert tr["gate"]["status"]=="FAIL"
PY

# 5. El contrato de codigos tambien incluye PASS=0 y ERROR=2. Para aislar el
# camino PASS se usa un perfil de fixture que declara que no hay comprobaciones
# semanticas aplicables; no hay UNKNOWN escondidos.
python3 - "$P" "$T/pass-profile.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
s=d["semantica"]
for k in ("requiere_asr_tipos","prohibe_habla_tipos","requiere_rostro_tipos","prohibe_rostro_tipos"):
    s[k]=[]
d["temporal"]["congelacion_s_review"]=5.0
json.dump(d,open(sys.argv[2],"w"))
PY
make_plan "$T/pass" detalle
make_video "color=c=white:size=160x90:rate=24:duration=1" "$T/pass/t01.avi"
expect_rc 0 "$E" "$T/pass" --profile "$T/pass-profile.json" --no-face-backend --no-asr-backend --output "$T/pass.json"
python3 - "$T/pass.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="PASS" and d["semantic_complete"] is True
assert "total" in d["scores"]
PY
expect_rc 2 "$E" "$T/no-existe" --profile "$P" --output "$T/error.json"
python3 - "$T/error.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); assert d["status"]=="ERROR"
PY

# 6. Si hay montaje, su audio es la autoridad de entrega. Una fuente caliente
# sigue visible como SOURCE/advisory, pero no tumba un montaje normalizado.
make_plan "$T/delivery" detalle
ffmpeg -nostdin -y -v error \
  -f lavfi -i "color=c=white:size=160x90:rate=24:duration=1" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=1" \
  -filter_complex "[1:a]volume=7.9[a]" -map 0:v -map '[a]' \
  -t 1 -shortest -c:v ffv1 -c:a pcm_s16le "$T/delivery/t01.avi"
# Sin entrega ensamblada no hay otra autoridad: la fuente caliente falla.
expect_rc 1 "$E" "$T/delivery" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --output "$T/source-only.json"
python3 - "$T/source-only.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); gates={g["id"]:g for g in d["takes"][0]["gates"]}
assert d["status"]=="FAIL" and d["montage_audio"] is None
assert gates["audio.true_peak"]["status"]=="FAIL"
assert gates["audio.true_peak"].get("advisory") is not True
PY
make_video "color=c=white:size=160x90:rate=24:duration=1" "$T/delivery-normal.avi"
expect_rc 0 "$E" "$T/delivery" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/delivery-normal.avi" \
  --output "$T/delivery-normal.json"
python3 - "$T/delivery-normal.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); t=d["takes"][0]
assert d["status"]=="PASS",d["reasons"]
assert d["montage_audio"]["scope"]=="DELIVERY" and d["montage_audio"]["authoritative"] is True
assert d["montage_audio"]["status"]=="PASS"
source=[g for g in t["gates"] if g["id"]=="source.audio.true_peak"]
assert source and source[0]["status"]=="FAIL" and source[0]["advisory"] is True
assert t["audio"]["scope"]=="SOURCE" and t["audio"]["authoritative"] is False
assert any(g["id"]=="delivery.audio.true_peak" and g["status"]=="PASS" for g in d["montage_audio"]["gates"])
assert all("source.audio" not in reason for reason in d["reasons"])
PY

# El caso inverso sí debe vetar: el montaje final llega recortado y con el pico
# pegado a 0, aunque las fuentes sean sólo diagnóstico.
ffmpeg -nostdin -y -v error \
  -f lavfi -i "color=c=white:size=160x90:rate=24:duration=1" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=1" \
  -filter_complex "[1:a]volume=10[a]" -map 0:v -map '[a]' \
  -t 1 -shortest -c:v ffv1 -c:a pcm_s16le "$T/delivery-clipped.avi"
expect_rc 1 "$E" "$T/delivery" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/delivery-clipped.avi" \
  --output "$T/delivery-clipped.json"
python3 - "$T/delivery-clipped.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); gates={g["id"]:g for g in d["montage_audio"]["gates"]}
assert d["status"]=="FAIL"
assert gates["delivery.audio.true_peak"]["status"]=="FAIL"
assert gates["delivery.audio.clipping"]["status"]=="FAIL"
assert d["montage_audio"]["status"]=="FAIL"
PY

# 7. La declaracion cut no autentica el contenido. El evaluador compara el
# montaje con todas las fuentes y detecta una permutacion con la misma
# geometria, FPS, duracion y codecs.
make_plan "$T/order" detalle detalle
make_video "color=c=white:size=160x90:rate=24:duration=1" "$T/order/t01.avi" 700
make_video "testsrc2=size=160x90:rate=24:duration=1" "$T/order/t02.avi" 1200
ffmpeg -nostdin -y -v error -i "$T/order/t01.avi" -i "$T/order/t02.avi" \
  -filter_complex '[0:v:0][0:a:0][1:v:0][1:a:0]concat=n=2:v=1:a=1[v][a]' \
  -map '[v]' -map '[a]' -c:v ffv1 -c:a pcm_s16le "$T/order/correct.avi"
expect_rc 0 "$E" "$T/order" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/order/correct.avi" \
  --transition-style cut --output "$T/order-correct.json"
ffmpeg -nostdin -y -v error -i "$T/order/t02.avi" -i "$T/order/t01.avi" \
  -filter_complex '[0:v:0][0:a:0][1:v:0][1:a:0]concat=n=2:v=1:a=1[v][a]' \
  -map '[v]' -map '[a]' -c:v ffv1 -c:a pcm_s16le "$T/order/reversed.avi"
expect_rc 1 "$E" "$T/order" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/order/reversed.avi" \
  --transition-style cut --output "$T/order-reversed.json"
python3 - "$T/order-correct.json" "$T/order-reversed.json" <<'PY' || fallos=1
import json,sys
good=json.load(open(sys.argv[1])); bad=json.load(open(sys.argv[2]))
gg={g["id"]:g for g in good["montage_video"]["gates"]}
bg={g["id"]:g for g in bad["montage_video"]["gates"]}
assert gg["technical.montage.visual_correspondence"]["status"]=="PASS",gg
assert bg["technical.montage.visual_correspondence"]["status"]=="FAIL",bg
assert bad["montage_video"]["correspondence"]["per_take"]
PY

# Un montaje negro/ajeno con 64x64 a 10 FPS falla por el archivo real aunque
# se declare cut. No se confia en el argumento de linea de comandos.
make_plan "$T/foreign" detalle
make_video "color=c=white:size=160x90:rate=24:duration=1" "$T/foreign/t01.avi"
make_video "color=c=black:size=64x64:rate=10:duration=1" "$T/foreign.avi"
expect_rc 1 "$E" "$T/foreign" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/foreign.avi" \
  --transition-style cut --output "$T/foreign.json"
python3 - "$T/foreign.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); g={x["id"]:x["status"] for x in d["montage_video"]["gates"]}
assert d["status"]=="FAIL",d["reasons"]
assert g["technical.montage.geometry"]=="FAIL"
assert g["technical.montage.fps"]=="FAIL"
assert g["technical.montage.visual_correspondence"]=="FAIL"
assert g["technical.montage.decode"]=="PASS"
PY

# 8. Una entrega con stream de audio pero silencio digital tambien se veta.
ffmpeg -nostdin -y -v error \
  -f lavfi -i "color=c=white:size=160x90:rate=24:duration=1" \
  -f lavfi -i "anullsrc=r=48000:cl=mono" -t 1 -shortest \
  -c:v ffv1 -c:a pcm_s16le "$T/silent.avi"
expect_rc 1 "$E" "$T/foreign" --profile "$T/pass-profile.json" \
  --no-face-backend --no-asr-backend --montage "$T/silent.avi" \
  --transition-style cut --output "$T/silent.json"
python3 - "$T/silent.json" <<'PY' || fallos=1
import json,sys
d=json.load(open(sys.argv[1])); g={x["id"]:x for x in d["montage_audio"]["gates"]}
assert d["status"]=="FAIL",d["reasons"]
assert g["delivery.audio.silence"]["status"]=="FAIL"
assert d["montage_video"]["status"]=="PASS"
PY

# 9. La logica ASR de entrega usa todos los dialogos y comprueba su orden. Se
# inyecta la transcripcion para que el fixture no dependa de descargar modelos.
"$PY" - "$RAIZ/calidad/v2/evaluar.py" "$P" <<'PY' || fallos=1
import importlib.util,json,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("evaluar_v2",sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
profile=json.load(open(sys.argv[2]))
plan={"tomas":[
    {"indice":1,"tipo":"habla","contenido":"uno dos tres"},
    {"indice":2,"tipo":"detalle","contenido":"sin voz"},
    {"indice":3,"tipo":"habla","contenido":"cuatro cinco seis"},
]}
model=Path("/fixture/modelo.bin"); vad=Path("/fixture/vad.bin")
results=[{"technical":{"duration_s":2.0}} for _ in plan["tomas"]]
mod.transcribe_segments=lambda *_,**__: (
    "cuatro cinco seis uno dos tres",
    [{"start_s":0.1,"end_s":0.8,"text":"cuatro cinco seis"},
     {"start_s":4.1,"end_s":4.8,"text":"uno dos tres"}],None)
metrics,gates=mod.montage_asr_analysis(Path("/fixture/final.avi"),plan,results,"cut",profile,model,vad,None)
statuses={g["id"]:g["status"] for g in gates}
assert statuses["semantic.delivery.asr_fidelity"]=="FAIL",statuses
assert statuses["semantic.delivery.dialogue_order"]=="FAIL",statuses
mod.transcribe_segments=lambda *_,**__: (
    "uno dos tres cuatro cinco seis",
    [{"start_s":0.1,"end_s":0.8,"text":"uno dos tres"},
     {"start_s":4.1,"end_s":4.8,"text":"cuatro cinco seis"}],None)
metrics,gates=mod.montage_asr_analysis(Path("/fixture/final.avi"),plan,results,"cut",profile,model,vad,None)
assert all(g["status"]=="PASS" for g in gates),gates
mod.transcribe_segments=lambda *_,**__: (
    "uno dos tres cuatro cinco seis",
    [{"start_s":0.1,"end_s":0.8,"text":"uno dos tres"},
     {"start_s":2.1,"end_s":2.8,"text":"cuatro cinco seis"}],None)
metrics,gates=mod.montage_asr_analysis(Path("/fixture/final.avi"),plan,results,"cut",profile,model,vad,None)
statuses={g["id"]:g["status"] for g in gates}
assert statuses["semantic.delivery.asr_fidelity"]=="PASS",statuses
assert statuses["semantic.delivery.dialogue_order"]=="PASS",statuses
assert statuses["semantic.delivery.speech_timeline"]=="FAIL",statuses
mod.transcribe_segments=lambda *_,**__: ("",[],None)
metrics,gates=mod.montage_asr_analysis(Path("/fixture/final.avi"),plan,results,"cut",profile,model,vad,None)
assert any(g["status"]=="FAIL" for g in gates),gates

# Una entrega con texto y orden exactos NO pasa si desplaza la voz al borde de
# la ventana, aunque las fuentes originales tuvieran cola limpia.
mod.transcribe_segments=lambda *_,**__: (
    "uno dos tres cuatro cinco seis",
    [{"start_s":1.85,"end_s":1.99,"text":"uno dos tres"},
     {"start_s":4.1,"end_s":4.8,"text":"cuatro cinco seis"}],None)
metrics,gates=mod.montage_asr_analysis(Path("/fixture/final.avi"),plan,results,"cut",profile,model,vad,None)
statuses={g["id"]:g["status"] for g in gates}
assert statuses["semantic.delivery.asr_fidelity"]=="PASS",statuses
assert statuses["semantic.delivery.dialogue_order"]=="PASS",statuses
assert statuses["semantic.delivery.speech_timeline"]=="PASS",statuses
assert statuses["semantic.delivery.speech_tail"]=="FAIL",statuses
PY

# 10. Si VideoCapture abandona antes del ultimo frame, cero detecciones no se
# interpreta como ausencia de rostro: la cobertura queda ERROR.
"$PY" - "$RAIZ/calidad/v2/evaluar.py" "$P" <<'PY' || fallos=1
import importlib.util,json,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("evaluar_v2",sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
profile=json.load(open(sys.argv[2]))
class Frame:
    shape=(90,160,3)
class Capture:
    def __init__(self): self.n=0
    def isOpened(self): return True
    def get(self,key): return 24.0 if key==1 else 24
    def read(self):
        self.n+=1
        return (True,Frame()) if self.n<=4 else (False,None)
    def release(self): pass
class CV:
    CAP_PROP_FPS=1; CAP_PROP_FRAME_COUNT=2
    @staticmethod
    def VideoCapture(_): return Capture()
class Detector:
    def setInputSize(self,_): pass
    def detect(self,_): return None,None
backend=object.__new__(mod.FaceBackend)
backend.error=None; backend.cv2=CV; backend.detector=Detector(); backend.recognizer=None
metrics,features,anomalies=backend.analyze(Path("/fixture/truncado.avi"),8.0)
assert metrics["capture_complete"] is False,metrics
assert metrics["decoded_frames"]==4 and metrics["source_frames"]==24,metrics
assert features==[] and anomalies
gates=mod.face_gates(metrics,"detalle",profile,backend)
assert gates[0]["id"]=="semantic.face_capture" and gates[0]["status"]=="ERROR",gates
PY

# 11. La cola vocal usa segmentos cortos, ignora etiquetas no verbales y tiene
# tres zonas deliberadas: PASS, REVIEW y FAIL. No certifica cierre labial.
"$PY" - "$RAIZ/calidad/v2/evaluar.py" "$P" <<'PY' || fallos=1
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location("evaluar_v2",sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
profile=json.load(open(sys.argv[2]))

def check(end,expected):
    metrics,gates=mod.speech_tail_from_segments(8.0,[
        {"start_s":0.0,"end_s":end,"text":"frase hablada"},
        {"start_s":end,"end_s":9.0,"text":"[Música]"},
    ],profile)
    assert gates[0]["status"]==expected,(metrics,gates)
    assert metrics["certifies_lip_closure"] is False

check(6.7,"PASS")
check(7.1,"REVIEW")
check(7.5,"FAIL")
metrics,gates=mod.speech_tail_from_segments(8.0,[
    {"start_s":0.0,"end_s":9.0,"text":"[Música]"},
],profile)
assert gates[0]["status"]=="FAIL" and metrics["clean_tail_s"] is None
assert mod.spoken_words("[BLANK_AUDIO] (Música) <silence> [inaudible]")==[]
assert mod.spoken_words("(en serio)")==["en","serio"]
assert mod.timed_transcript_error(
    "frase inicial frase final",
    [{"start_s":0.0,"end_s":6.5,"text":"frase inicial"}],duration_s=8.0,
) is not None
assert mod.timed_transcript_error(
    "frase final",
    [{"start_s":7.0,"end_s":9.0,"text":"frase final"}],duration_s=8.0,
) is not None
metrics,gates=mod.speech_tail_analysis(
    __import__('pathlib').Path('/fixture/video.avi'),
    {"tipo":"habla"},8.0,profile,__import__('pathlib').Path('/fixture/model.bin'),None,None,
)
assert gates[0]["status"]=="UNKNOWN",gates
PY

# 12. La version publicada y la exigida por el schema no pueden divergir.
"$PY" - "$RAIZ/calidad/v2/evaluar.py" "$RAIZ/calidad/esquemas/informe-v2.schema.json" "$T/pass.json" <<'PY' || fallos=1
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location("evaluar_v2",sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
schema=json.load(open(sys.argv[2])); report=json.load(open(sys.argv[3]))
assert schema["properties"]["evaluator"]["properties"]["version"]["const"]==mod.VERSION
assert report["evaluator"]["version"]==mod.VERSION
for key in schema["required"]:
    assert key in report,key
assert report["status"] in schema["properties"]["status"]["enum"]
PY

if [ "$fallos" -eq 0 ]; then
  echo "ok $nombre (fail-closed, montaje real, orden/ASR, cola vocal y cobertura facial)"
fi
exit "$fallos"
