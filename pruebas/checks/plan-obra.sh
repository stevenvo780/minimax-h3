#!/bin/bash
# Contrato del plan canonico: cualquier cambio aqui puede invalidar reanudaciones
# caras, asi que se prueba sin GPU y sin depender de jq ni de paquetes Python.
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
PLAN=$RAIZ/harness/planificar.py
nombre=plan-obra
exec 0</dev/null

[ -f "$PLAN" ] || { echo "FALLA $nombre: falta harness/planificar.py"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/chk-plan-obra.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fallos=0

plan_efectivo() {
  python3 "$PLAN" "$1" --nombre "$9" --frames "$2" \
    --width "$3" --height "$4" --steps "$5" --fps "$6" --seed "$7" \
    --model-id "$8"
}

plan() {
  plan_efectivo "$1" "${2:-345}" 736 416 20 24 "${4:-100}" \
    "${3:-minimax-h3-check}" obra-check
}

cat > "$T/base.guion" <<'EOF'
@TIPO habla
@ESCENA Una escena estable.
@AMBIENTE Una sala silenciosa.
@MUSICA Una nota sostenida.
TOMA|Primera frase.|inicio|
HABLA|Segunda frase.|ancla|
TOMA|Un gesto sin voz.|encadena|muda|Otra escena.|Otro ambiente.
TOMA|Regreso al origen.|ancla:1|habla|
EOF

# Misma entrada: mismos bytes, huellas y orden. Tambien fija las claves que
# consume el ejecutor, el incremento de semilla y las referencias normalizadas.
if ! plan "$T/base.guion" > "$T/plan-a.json" 2>"$T/error"; then
  echo "FALLA $nombre: el plan base no se pudo construir"
  sed -n '1,2p' "$T/error" | sed 's/^/    /'
  exit 1
fi
plan "$T/base.guion" > "$T/plan-b.json" 2>"$T/error" || fallos=1
if ! cmp -s "$T/plan-a.json" "$T/plan-b.json"; then
  echo "FALLA $nombre: dos planes identicos producen JSON distinto"
  fallos=1
fi
if ! python3 - "$T/plan-a.json" "$T/base.guion" "$RAIZ/lib/prompt.sh" <<'PY'
import hashlib, json, re, sys
p=json.load(open(sys.argv[1],encoding="utf-8"))
sha=lambda b: hashlib.sha256(b).hexdigest()
canonical=lambda v: json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(",",":"),allow_nan=False).encode()
assert p["schema"] == "minimax-h3.plan-obra/v1"
assert p["guion_sha256"] == sha(open(sys.argv[2],"rb").read())
assert p["prompt_engine_sha256"] == sha(open(sys.argv[3],"rb").read())
run=dict(p); run_fp=run.pop("run_fingerprint")
assert run_fp == sha(canonical(run))
assert p["cabecera"] == {
    "tipo":"habla", "escena":"Una escena estable.",
    "ambiente":"Una sala silenciosa.", "musica":"Una nota sostenida."
}
assert [t["indice"] for t in p["tomas"]] == [1,2,3,4]
assert [t["modo"] for t in p["tomas"]] == ["inicio","ancla:1","ancla:1","ancla:1"]
assert [t["anchor_source"] for t in p["tomas"]] == [None,1,1,1]
assert [t["semilla"] for t in p["tomas"]] == [101,102,103,104]
for take in p["tomas"]:
    effective=dict(take); take_fp=effective.pop("fingerprint")
    material={"schema":"minimax-h3.toma/v1",
              "prompt_engine_sha256":p["prompt_engine_sha256"],
              "toma":effective}
    assert take_fp == sha(canonical(material))
assert any("encadena" in warning and "ancla:1" in warning for warning in p["warnings"])
assert p["tomas"][2]["escena"] == "Otra escena."
assert p["tomas"][2]["ambiente"] == "Otro ambiente."
assert p["duracion_estimada_s"] == 57.5
PY
then
  echo "FALLA $nombre: el JSON base no cumple el contrato"
  fallos=1
fi

# argparse fija semantica decimal aunque la entrada tenga cero inicial. El
# ejecutor debe consumir esta semilla efectiva y no reinterpretarla en Bash.
if ! plan "$T/base.guion" 345 minimax-h3-check 010 > "$T/plan-seed.json" 2>/dev/null \
    || ! python3 - "$T/plan-seed.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding="utf-8"))
assert p["parametros"]["seed"] == 10
assert p["tomas"][0]["semilla"] == 11
PY
then
  echo "FALLA $nombre: una semilla con cero inicial no se normalizo en decimal"
  fallos=1
fi

# Un cambio efectivo de guion invalida la corrida y la toma afectada, pero deja
# reutilizables las tomas cuyo contrato no cambio. Los parametros de generacion
# si afectan a todas.
cp "$T/base.guion" "$T/cambiado.guion"
sed -i 's/Primera frase/Primera frase modificada/' "$T/cambiado.guion"
plan "$T/cambiado.guion" > "$T/plan-guion.json" 2>/dev/null || fallos=1
plan "$T/base.guion" 362 > "$T/plan-param.json" 2>/dev/null || fallos=1
plan "$T/base.guion" 345 otra-pila-y-receta > "$T/plan-modelo.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 737 416 20 24 100 minimax-h3-check obra-check > "$T/plan-width.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 736 417 20 24 100 minimax-h3-check obra-check > "$T/plan-height.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 736 416 21 24 100 minimax-h3-check obra-check > "$T/plan-steps.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 736 416 20 25 100 minimax-h3-check obra-check > "$T/plan-fps.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 736 416 20 24 101 minimax-h3-check obra-check > "$T/plan-seed-cambio.json" 2>/dev/null || fallos=1
plan_efectivo "$T/base.guion" 345 736 416 20 24 100 minimax-h3-check otra-obra > "$T/plan-nombre.json" 2>/dev/null || fallos=1
python3 - "$T/plan-a.json" "$T/plan-guion.json" "$T/plan-param.json" \
  "$T/plan-modelo.json" "$T/plan-width.json" "$T/plan-height.json" \
  "$T/plan-steps.json" "$T/plan-fps.json" "$T/plan-seed-cambio.json" \
  "$T/plan-nombre.json" <<'PY' || {
import json,sys
a,g,p,*variantes=(json.load(open(x,encoding="utf-8")) for x in sys.argv[1:])
assert a["guion_sha256"] != g["guion_sha256"]
assert a["run_fingerprint"] != g["run_fingerprint"]
assert a["tomas"][0]["fingerprint"] != g["tomas"][0]["fingerprint"]
assert a["tomas"][1]["fingerprint"] == g["tomas"][1]["fingerprint"]
assert a["run_fingerprint"] != p["run_fingerprint"]
assert a["tomas"][0]["fingerprint"] != p["tomas"][0]["fingerprint"]
for variante in variantes:
    assert a["run_fingerprint"] != variante["run_fingerprint"]
    assert a["tomas"][0]["fingerprint"] != variante["tomas"][0]["fingerprint"]
PY
  echo "FALLA $nombre: guion o parametros no invalidan las huellas"
  fallos=1
}

error_2_sin_json() {
  local guion=$1 patron=$2 etiqueta=$3
  if plan "$guion" >"$T/salida-error" 2>"$T/error"; then
    echo "FALLA $nombre: $etiqueta salio con codigo 0"
    fallos=1
    return
  else
    local rc=$?
    if [ "$rc" -ne 2 ]; then
      echo "FALLA $nombre: $etiqueta salio con codigo $rc, se esperaba 2"
      fallos=1
    fi
  fi
  if [ -s "$T/salida-error" ]; then
    echo "FALLA $nombre: $etiqueta imprimio JSON parcial en stdout"
    fallos=1
  fi
  if ! grep -qi "$patron" "$T/error"; then
    echo "FALLA $nombre: $etiqueta no dio un error claro sobre '$patron'"
    sed -n '1,2p' "$T/error" | sed 's/^/    /'
    fallos=1
  fi
}

sed 's/|ancla|/|teleporta|/' "$T/base.guion" > "$T/modo-malo.guion"
error_2_sin_json "$T/modo-malo.guion" "modo desconocido" "un modo invalido"
sed 's/|ancla|/|ancla:4|/' "$T/base.guion" > "$T/adelante.guion"
error_2_sin_json "$T/adelante.guion" "hacia adelante" "un ancla hacia adelante"
ancla_gigante=$(python3 -c 'print("9" * 5000)')
sed "s/|ancla|/|ancla:$ancla_gigante|/" "$T/base.guion" > "$T/ancla-gigante.guion"
error_2_sin_json "$T/ancla-gigante.guion" "fuera del rango" "una referencia de ancla gigante"
if plan "$T/base.guion" 346 >"$T/salida-error" 2>"$T/error"; then
  echo "FALLA $nombre: frames fuera de 17k+5 salieron con codigo 0"
  fallos=1
else
  rc=$?
  if [ "$rc" -ne 2 ] || [ -s "$T/salida-error" ] || ! grep -q '17k+5' "$T/error"; then
    echo "FALLA $nombre: frames fuera de 17k+5 no fallaron limpiamente"
    fallos=1
  fi
fi

# Python acepta enteros arbitrariamente grandes, el runner y el JSON de
# duracion no. Debe rebotar como entrada invalida, nunca con OverflowError/rc1.
frames_gigantes=$(python3 -c 'print(17 * 10**4000 + 5)')
if plan "$T/base.guion" "$frames_gigantes" >"$T/salida-error" 2>"$T/error"; then
  echo "FALLA $nombre: frames fuera del rango del runner salieron con codigo 0"
  fallos=1
else
  rc=$?
  if [ "$rc" -ne 2 ] || [ -s "$T/salida-error" ] || ! grep -q 'fuera del rango' "$T/error"; then
    echo "FALLA $nombre: frames gigantes no fallaron limpiamente con codigo 2"
    fallos=1
  fi
fi

# La ruta de ancla antigua no se conserva como dependencia opaca: queda una
# referencia canonica a toma 1 y un aviso auditable.
sed 's/|ancla|/|ancla:anclas\/a180.png|/' "$T/base.guion" > "$T/legacy.guion"
if ! plan "$T/legacy.guion" > "$T/legacy.json" 2>"$T/error"; then
  echo "FALLA $nombre: la sintaxis legacy dejo de planificar"
  fallos=1
else
  python3 - "$T/legacy.json" <<'PY' || {
import json,sys
p=json.load(open(sys.argv[1],encoding="utf-8"))
assert p["tomas"][1]["modo"] == "ancla:1"
assert p["tomas"][1]["anchor_source"] == 1
assert any("legacy" in warning and "ancla:1" in warning for warning in p["warnings"])
PY
    echo "FALLA $nombre: legacy no se normalizo con warning"
    fallos=1
  }
fi

# Incluso una marca historica imposible en la primera toma queda expresada
# como inicio. El warning evita que la correccion silencie la intencion original.
sed '0,/|inicio|/s//|encadena|/' "$T/base.guion" > "$T/primera-encadena.guion"
if ! plan "$T/primera-encadena.guion" > "$T/primera-encadena.json" 2>"$T/error"; then
  echo "FALLA $nombre: encadena en la primera toma no se pudo normalizar"
  fallos=1
else
  python3 - "$T/primera-encadena.json" <<'PY' || {
import json,sys
p=json.load(open(sys.argv[1],encoding="utf-8"))
assert p["tomas"][0]["modo"] == "inicio"
assert p["tomas"][0]["anchor_source"] is None
assert any("encadena" in warning and "inicio" in warning for warning in p["warnings"])
PY
    echo "FALLA $nombre: encadena inicial no quedo como inicio con warning"
    fallos=1
  }
fi

# El contrato nuevo debe aceptar todo el acervo vigente, incluidos HABLA sin
# @TIPO y las anclas por fichero historicas.
actuales=0
while IFS= read -r -d '' guion; do
  actuales=$((actuales+1))
  if ! plan "$guion" > /dev/null 2>"$T/error"; then
    echo "FALLA $nombre: no planifica ${guion#$RAIZ/}"
    sed -n '1,2p' "$T/error" | sed 's/^/    /'
    fallos=1
  fi
done < <(find "$RAIZ/produccion/guiones" -type f -name '*.guion' -print0 | sort -z)
if [ "$actuales" -eq 0 ]; then
  echo "FALLA $nombre: no encontre guiones actuales"
  fallos=1
fi

if [ "$fallos" -eq 0 ]; then
  echo "ok $nombre ($actuales guiones, determinismo, huellas, modos y legacy)"
fi
exit "$fallos"
