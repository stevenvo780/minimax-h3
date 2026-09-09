#!/bin/bash
# Regresion del banco content-addressed. Usa un sd-cli falso: cero GPU.
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
NOMBRE=candidatos
exec 0</dev/null

fallar() { echo "FALLA $NOMBRE: $1"; exit 1; }
REAL_FFMPEG=$(command -v ffmpeg) || fallar "falta ffmpeg"
command -v ffprobe >/dev/null 2>&1 || fallar "falta ffprobe"

T=$(mktemp -d "${TMPDIR:-/tmp}/chk-candidatos.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
P=$T/proyecto
mkdir -p "$P/bin" "$P/lib" "$P/harness" "$P/produccion" \
  "$P/modelos/diffusion_models" "$P/modelos/vae" "$P/modelos/text_encoders" \
  "$T/compat/cuda" "$T/banco" "$T/salidas"

for archivo in comun.sh compat.sh prompt.sh vram.sh estado_obra.py; do
  cp "$RAIZ/lib/$archivo" "$P/lib/$archivo" || exit 1
done
cp "$RAIZ/harness/candidatos.py" "$P/harness/" || exit 1
cp "$RAIZ/produccion/generar-candidato.sh" "$P/produccion/" || exit 1
chmod +x "$P/produccion/generar-candidato.sh" "$P/harness/candidatos.py"

: > "$T/compat/cuda/libcudart.so.13"
printf '%s\n' "$T/compat/cuda" > "$T/compat/cuda.path"
printf 'modelo A\n' > "$P/modelos/diffusion_models/modelo-a.gguf"
printf 'modelo B\n' > "$P/modelos/diffusion_models/modelo-b.gguf"
printf 'video vae\n' > "$P/modelos/vae/minimax_h3_video_vae_fp16.safetensors"
printf 'audio vae\n' > "$P/modelos/vae/minimax_h3_audio_vae_fp32.safetensors"
printf 'llm\n' > "$P/modelos/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf"

cat > "$P/bin/sd-cli" <<'SH'
#!/bin/bash
[ "${1:-}" = --help ] && exit 0
out=""; width=""; height=""; frames=""; fps=""; anchor=""
printf '%q ' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -W) width=$2; shift 2 ;;
    -H) height=$2; shift 2 ;;
    --video-frames) frames=$2; shift 2 ;;
    --fps) fps=$2; shift 2 ;;
    --init-img) anchor=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ -n "$width" ] && [ -n "$height" ] \
  && [ -n "$frames" ] && [ -n "$fps" ] || exit 71
if [ "${EXPECT_STAGED_ANCHOR:-0}" = 1 ]; then
  [ -n "$anchor" ] && [ -f "$anchor" ] && [ ! -L "$anchor" ] || exit 72
  [ "$anchor" != "${ANCHOR_SOURCE_FOR_TEST:-}" ] || exit 73
  case "$anchor" in */.*.tmp.*/anchor-input.png) ;; *) exit 78 ;; esac
  [ -z "${EXPECTED_ANCHOR_SHA:-}" ] || \
    [ "$(sha256sum "$anchor" | awk '{print $1}')" = "$EXPECTED_ANCHOR_SHA" ] || exit 74
  [ $((8#$(stat -c '%a' "$anchor") & 8#222)) -eq 0 ] || exit 75
fi
case "${MUTATE_DURING_SD:-}" in
  source) printf 'fuente mutada durante sd-cli\n' > "$ANCHOR_SOURCE_FOR_TEST" ;;
  staged)
    chmod u+w "$anchor" || exit 76
    printf 'staging mutado durante sd-cli\n' > "$anchor" || exit 77 ;;
esac
duration=$(awk -v n="$frames" -v f="$fps" 'BEGIN{printf "%.9f",n/f}')
"$REAL_FFMPEG" -nostdin -y -v error \
  -f lavfi -i "color=c=black:s=${width}x${height}:r=$fps" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$duration" \
  -frames:v "$frames" -shortest -c:v ffv1 -c:a pcm_s16le "$out.avi"
SH
chmod +x "$P/bin/sd-cli"

cat > "$P/bin/hook-ancla" <<'SH'
#!/bin/bash
set -eu
fase=$1
fuente=$2
staged=$3
case "${HOOK_ANCHOR_ACTION:-}:$fase" in
  sustituir-fuente:despues-identificar)
    reemplazo=${fuente}.reemplazo
    printf 'ancla sustituta\n' > "$reemplazo"
    mv -- "$reemplazo" "$fuente"
    ;;
  mutar-staged:antes-gpu)
    [ -n "$staged" ] || exit 81
    chmod u+w "$staged"
    printf 'ancla staged mutada\n' > "$staged"
    ;;
esac
SH
chmod +x "$P/bin/hook-ancla"

PLAN=$T/plan.json
cat > "$PLAN" <<'JSON'
{
  "schema": "minimax-h3.plan-obra/v1",
  "run_fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "parametros": {
    "nombre": "obra-prueba", "width": 64, "height": 48,
    "frames": 22, "fps": 24, "steps": 1, "seed": 100
  },
  "tomas": [
    {
      "indice": 1, "nombre": "obra-prueba", "registro": "TOMA",
      "tipo": "habla", "modo": "inicio", "anchor_source": null,
      "escena": "Un retrato fijo.",
      "contenido": "Esta es una prueba breve.",
      "ambiente": "Una sala silenciosa.", "musica": "Una nota grave.",
      "width": 64, "height": 48, "frames": 22, "fps": 24,
      "steps": 1, "semilla": 101, "duracion_estimada_s": 0.916667,
      "model_id": "modelo-del-plan",
      "fingerprint": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
JSON
MODELO_A=$P/modelos/diffusion_models/modelo-a.gguf
MODELO_B=$P/modelos/diffusion_models/modelo-b.gguf
CALLS=$T/calls.txt
: > "$CALLS"
export CALLS REAL_FFMPEG

correr() {
  MD="$P" COMPAT_DIR="$T/compat" CERROJO="$T/gpu.lock" \
    CANDIDATE_SKIP_RESOURCE_WAIT=1 \
    bash "$P/produccion/generar-candidato.sh" \
      --plan "$PLAN" --toma 1 --modelo "$1" --bank "$T/banco" \
      --max-vram cuda0=1 "${@:2}"
}

# Dry-run: identidad completa y determinista, sin llamada al modelo ni obra.
PLAN_SHA=$(sha256sum "$PLAN" | awk '{print $1}')
correr "$MODELO_A" --dry-run > "$T/dry-a.json" || fallar "dry-run base"
correr "$MODELO_A" --dry-run > "$T/dry-a2.json" || fallar "segundo dry-run"
[ ! -s "$CALLS" ] || fallar "dry-run llamo a sd-cli"
python3 - "$T/dry-a.json" "$T/dry-a2.json" <<'PY' || fallar "dry-run no fue determinista"
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert a["dry_run"] is True
assert a["fingerprint"] == b["fingerprint"]
assert a["effective_take"]["steps"] == 1
assert len(a["inputs"]["model_sha256"]) == 64
assert a["candidate_dir"].endswith(a["fingerprint"])
PY

# Cada entrada relevante debe abrir otra direccion del banco.
correr "$MODELO_A" --steps 2 --dry-run > "$T/dry-steps.json" || exit 1
correr "$MODELO_B" --dry-run > "$T/dry-model.json" || exit 1
printf 'ancla uno\n' > "$T/ancla.png"
correr "$MODELO_A" --anchor "$T/ancla.png" --dry-run > "$T/dry-anchor-a.json" || exit 1
printf 'ancla dos\n' > "$T/ancla.png"
correr "$MODELO_A" --anchor "$T/ancla.png" --dry-run > "$T/dry-anchor-b.json" || exit 1
CANDIDATE_ARTIFACT_VERSION=h3-candidate-video/v2 \
  correr "$MODELO_A" --dry-run > "$T/dry-version.json" || exit 1
python3 - "$T" <<'PY' || fallar "una entrada no invalido la huella"
import json, pathlib, sys
d=pathlib.Path(sys.argv[1])
files=["dry-a.json","dry-steps.json","dry-model.json","dry-anchor-a.json",
       "dry-anchor-b.json","dry-version.json"]
fps=[json.load(open(d/f))["fingerprint"] for f in files]
assert len(set(fps)) == len(fps), fps
PY

# Publica dos recetas en hojas distintas; la segunda ejecucion identica reutiliza.
correr "$MODELO_A" > "$T/gen-a.log" || fallar "generacion base: $(tail -5 "$T/gen-a.log")"
CAND_A=$(sed -n 's/^candidato publicado: //p' "$T/gen-a.log")
[ -n "$CAND_A" ] && [ -s "$CAND_A/video.avi" ] && [ -s "$CAND_A/manifest.json" ] \
  || fallar "faltan artefactos del candidato"
[ "$(wc -l < "$CALLS")" -eq 1 ] || fallar "sd-cli no se llamo exactamente una vez"
correr "$MODELO_A" > "$T/reuse.log" || fallar "reutilizacion valida"
grep -q '^candidato verificado, se reutiliza:' "$T/reuse.log" \
  || fallar "no anuncio reutilizacion"
[ "$(wc -l < "$CALLS")" -eq 1 ] || fallar "reutilizar volvio a generar"

correr "$MODELO_A" --steps 2 > "$T/gen-b.log" || fallar "segunda receta"
CAND_B=$(sed -n 's/^candidato publicado: //p' "$T/gen-b.log")
[ "$CAND_A" != "$CAND_B" ] || fallar "dos recetas colisionaron"
[ -s "$CAND_A/video.avi" ] && [ -s "$CAND_B/video.avi" ] \
  || fallar "una receta reemplazo a la otra"
[ "$(wc -l < "$CALLS")" -eq 2 ] || fallar "conteo de generaciones inesperado"

python3 "$P/harness/candidatos.py" verificar "$CAND_A" --technical >/dev/null \
  || fallar "verificacion tecnica del candidato"
python3 "$P/harness/candidatos.py" comparar "$CAND_A" "$CAND_B" --json > "$T/compara.json" \
  || fallar "comparacion"
python3 "$P/harness/candidatos.py" listar "$T/banco" --json > "$T/lista.json" \
  || fallar "listado"
python3 - "$T/compara.json" "$T/lista.json" <<'PY' || fallar "inventario incompleto"
import json,sys
assert len(json.load(open(sys.argv[1]))) == 2
assert len(json.load(open(sys.argv[2]))["candidates"]) == 2
PY

# Un candidato existente pero alterado bloquea; nunca se pisa ni se regenera.
cp "$CAND_A/manifest.json" "$T/manifest-bueno.json"
printf '{"schema":"roto"}\n' > "$CAND_A/manifest.json"
if correr "$MODELO_A" > "$T/corrupto.log" 2>&1; then
  fallar "reemplazo un candidato corrupto"
fi
[ "$(wc -l < "$CALLS")" -eq 2 ] || fallar "candidato corrupto gasto GPU"
grep -q 'no se reemplaza' "$T/corrupto.log" || fallar "fallo corrupto poco claro"
mv "$T/manifest-bueno.json" "$CAND_A/manifest.json"

# La seleccion liga manifiesto y video por SHA; staging no sigue symlinks ni pisa.
SELECCION=$T/seleccion.json
python3 "$P/harness/candidatos.py" seleccionar "$CAND_A" --output "$SELECCION" \
  --note "ganador de prueba" >/dev/null || fallar "seleccion"
SALIDA=$T/salidas/toma-elegida.avi
python3 "$P/harness/candidatos.py" preparar "$SELECCION" --output "$SALIDA" >/dev/null \
  || fallar "staging"
[ "$(sha256sum "$SALIDA" | awk '{print $1}')" = \
  "$(sha256sum "$CAND_A/video.avi" | awk '{print $1}')" ] || fallar "staging altero bytes"
[ -s "$SALIDA.candidate.json" ] || fallar "staging sin manifiesto"
if python3 "$P/harness/candidatos.py" preparar "$SELECCION" --output "$SALIDA" >/dev/null 2>&1; then
  fallar "staging piso una salida existente"
fi

mv "$CAND_A/video.avi" "$T/video-real.avi"
ln -s "$T/video-real.avi" "$CAND_A/video.avi"
if python3 "$P/harness/candidatos.py" verificar "$CAND_A" >/dev/null 2>&1; then
  fallar "verificar siguio un symlink de video"
fi
rm "$CAND_A/video.avi"
mv "$T/video-real.avi" "$CAND_A/video.avi"

# El ancla usada por sd-cli es siempre una copia privada, de solo lectura y
# ligada al SHA/metadata observados al identificar. Sustituciones y mutaciones
# fallan cerradas, no publican y limpian su staging.
HOOK_ANCLA=$P/bin/hook-ancla
ANCLA_SEGURA=$T/ancla-segura.png
printf 'ancla original para TOCTOU\n' > "$ANCLA_SEGURA"

FP_REEMPLAZO=$(
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 301 --dry-run |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_dir"])'
) || fallar "identificacion previa para sustitucion"
CALLS_ANTES=$(wc -l < "$CALLS")
if CANDIDATE_TEST_MODE=1 CANDIDATE_TEST_HOOK="$HOOK_ANCLA" \
  HOOK_ANCHOR_ACTION=sustituir-fuente \
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 301 > "$T/toctou-fuente.log" 2>&1; then
  fallar "acepto un ancla sustituida despues de identificar"
fi
[ "$(wc -l < "$CALLS")" -eq "$CALLS_ANTES" ] || fallar "sustitucion de ancla gasto GPU"
[ ! -e "$FP_REEMPLAZO" ] || fallar "publico el candidato con ancla sustituida"
grep -Eq 'ancla.*cambio|cambio.*ancla' "$T/toctou-fuente.log" \
  || fallar "fallo TOCTOU de fuente poco claro"

printf 'ancla original para TOCTOU\n' > "$ANCLA_SEGURA"
FP_STAGED=$(
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 302 --dry-run |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_dir"])'
) || fallar "identificacion previa para mutacion staged"
if CANDIDATE_TEST_MODE=1 CANDIDATE_TEST_HOOK="$HOOK_ANCLA" \
  HOOK_ANCHOR_ACTION=mutar-staged \
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 302 > "$T/toctou-staged.log" 2>&1; then
  fallar "acepto una copia staged mutada antes de GPU"
fi
[ "$(wc -l < "$CALLS")" -eq "$CALLS_ANTES" ] || fallar "mutacion staged gasto GPU"
[ ! -e "$FP_STAGED" ] || fallar "publico el candidato con staging mutado"
grep -q 'copia staged cambio' "$T/toctou-staged.log" \
  || fallar "fallo staged poco claro"

printf 'ancla estable para generacion\n' > "$ANCLA_SEGURA"
ANCLA_SHA=$(sha256sum "$ANCLA_SEGURA" | awk '{print $1}')
EXPECT_STAGED_ANCHOR=1 ANCHOR_SOURCE_FOR_TEST="$ANCLA_SEGURA" \
  EXPECTED_ANCHOR_SHA="$ANCLA_SHA" \
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 303 > "$T/anclado-ok.log" \
  || fallar "generacion anclada normal: $(tail -8 "$T/anclado-ok.log")"
CAND_ANCLADO=$(sed -n 's/^candidato publicado: //p' "$T/anclado-ok.log")
[ -n "$CAND_ANCLADO" ] && [ -s "$CAND_ANCLADO/video.avi" ] \
  || fallar "no publico el candidato anclado normal"
[ ! -e "$CAND_ANCLADO/anchor-input.png" ] \
  || fallar "publico por error la copia temporal del ancla"
tail -1 "$CALLS" | grep -F -- "$ANCLA_SEGURA" >/dev/null \
  && fallar "sd-cli recibio la ruta mutable del ancla fuente"
python3 - "$CAND_ANCLADO/manifest.json" "$ANCLA_SHA" <<'PY' \
  || fallar "manifiesto anclado incompleto"
import json,sys
m=json.load(open(sys.argv[1]))
assert m["inputs"]["anchor_sha256"] == sys.argv[2]
assert isinstance(m["inputs"]["anchor_source_metadata"], dict)
PY

printf 'ancla estable durante GPU\n' > "$ANCLA_SEGURA"
FP_DURANTE=$(
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 304 --dry-run |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_dir"])'
) || fallar "identificacion previa para mutacion durante GPU"
ANCLA_SHA=$(sha256sum "$ANCLA_SEGURA" | awk '{print $1}')
CALLS_ANTES=$(wc -l < "$CALLS")
if EXPECT_STAGED_ANCHOR=1 ANCHOR_SOURCE_FOR_TEST="$ANCLA_SEGURA" \
  EXPECTED_ANCHOR_SHA="$ANCLA_SHA" MUTATE_DURING_SD=source \
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 304 > "$T/toctou-durante.log" 2>&1; then
  fallar "publico aunque la fuente cambio durante la generacion"
fi
[ "$(wc -l < "$CALLS")" -eq $((CALLS_ANTES + 1)) ] \
  || fallar "la sonda durante GPU no ejecuto exactamente una vez"
[ ! -e "$FP_DURANTE" ] || fallar "publico tras mutacion de fuente durante GPU"
grep -q 'cambio durante la generacion' "$T/toctou-durante.log" \
  || fallar "fallo post-GPU poco claro"

printf 'ancla estable para staging post-GPU\n' > "$ANCLA_SEGURA"
FP_DURANTE_STAGED=$(
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 305 --dry-run |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_dir"])'
) || fallar "identificacion previa para mutacion de copia durante GPU"
ANCLA_SHA=$(sha256sum "$ANCLA_SEGURA" | awk '{print $1}')
CALLS_ANTES=$(wc -l < "$CALLS")
if EXPECT_STAGED_ANCHOR=1 ANCHOR_SOURCE_FOR_TEST="$ANCLA_SEGURA" \
  EXPECTED_ANCHOR_SHA="$ANCLA_SHA" MUTATE_DURING_SD=staged \
  correr "$MODELO_A" --anchor "$ANCLA_SEGURA" --seed 305 > "$T/toctou-durante-staged.log" 2>&1; then
  fallar "publico aunque la copia staged cambio durante la generacion"
fi
[ "$(wc -l < "$CALLS")" -eq $((CALLS_ANTES + 1)) ] \
  || fallar "la sonda de copia durante GPU no ejecuto exactamente una vez"
[ ! -e "$FP_DURANTE_STAGED" ] || fallar "publico tras mutar el staging durante GPU"
grep -q 'cambio durante la generacion' "$T/toctou-durante-staged.log" \
  || fallar "fallo post-GPU de copia poco claro"

if find "$T/banco" -type d -name '.*.tmp.*' -print -quit | grep -q .; then
  fallar "quedo un staging temporal tras los fallos TOCTOU"
fi

[ "$(sha256sum "$PLAN" | awk '{print $1}')" = "$PLAN_SHA" ] \
  || fallar "el runner modifico plan.json"
[ ! -e "$P/produccion/obra" ] || fallar "el runner toco la obra base"
echo "PASA $NOMBRE (huellas, no-overwrite, staging inmutable, TOCTOU y seleccion)"
