#!/bin/bash
# El producto ahora es un reel de noticias 9:16. Si el recorte inventa hechos,
# el compositor deja de tratar 'informativo' como voz, o el export no sale
# 1080x1920, el feed de TikTok/IG recibe basura. Este check no gasta GPU.
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="noticias-reel"
exec 0</dev/null

fallos=0
falla() { echo "FALLA $nombre: $1"; fallos=1; }

for f in harness/noticias.py harness/investigar.py produccion/subtitular.py \
         produccion/exportar-reel.sh produccion/reel-noticias.sh \
         harness/categorias/noticias.json \
         produccion/guiones/noticias/ejemplo-reel.guion; do
  [ -f "$RAIZ/$f" ] || { echo "FALLA $nombre: falta $f"; exit 1; }
done
n_dia=$(ls -1 "$RAIZ"/produccion/noticias/dia/*.txt 2>/dev/null | wc -l)
[ "$n_dia" -ge 5 ] || { echo "FALLA $nombre: hace falta 5 noticias del dia, hay $n_dia"; exit 1; }
python3 -c "import ast; ast.parse(open('$RAIZ/harness/noticias.py').read())" \
  || { echo "FALLA $nombre: noticias.py no parsea"; exit 1; }
python3 -c "import ast; ast.parse(open('$RAIZ/produccion/subtitular.py').read())" \
  || { echo "FALLA $nombre: subtitular.py no parsea"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/chk-noticias-XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# 1. El recorte no inventa: cada frase dicha es un substring del origen.
python3 - "$RAIZ/harness/noticias.py" "$T" <<'PY' || fallos=1
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("noticias", sys.argv[1])
n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)
titular = "El congreso aprueba hoy la ley de vivienda."
cuerpo = (
    "El texto fija un tope al alquiler en zonas tensionadas y entra en vigor el mes que viene. "
    "La oposicion voto en contra y anuncio un recurso. "
    "El gobierno cifra en ciento cincuenta mil los hogares afectados el primer año."
)
r = n.redactar(titular, cuerpo, seg_objetivo=12)
origen = (titular + " " + cuerpo).lower()
for frase in r["frases"]:
    nucleo = frase.lower().rstrip(".!?…")
    if nucleo not in origen.lower():
        print("FALLA noticias-reel: frase inventada:", frase)
        sys.exit(1)
if r["frases"][0].rstrip(".") not in titular:
    print("FALLA noticias-reel: el gancho no es el titular")
    sys.exit(1)
if r["palabras"] > int(12 * n.PALABRAS_POR_SEG) + 2:
    print("FALLA noticias-reel: no recorto al presupuesto", r)
    sys.exit(1)
# EE.UU. no puede partir el titular.
r2 = n.redactar(
    "EE.UU. impulsa conversaciones trilaterales con Rusia.",
    "El enviado de EE.UU. Steve Witkoff viajo a Kyiv.",
    seg_objetivo=20,
)
if not r2["frases"][0].lower().startswith("ee.uu. impulsa"):
    print("FALLA noticias-reel: EE.UU. partio el titular:", r2["frases"])
    sys.exit(1)
# Un titular vacio tiene que rebotar.
try:
    n.redactar("  ", "cuerpo", 20)
except SystemExit:
    pass
else:
    print("FALLA noticias-reel: un titular vacio no rebotó")
    sys.exit(1)
# file:// no es un RSS aceptable.
try:
    n.leer_rss("file:///etc/passwd")
except SystemExit:
    pass
else:
    print("FALLA noticias-reel: file:// no fue rechazado")
    sys.exit(1)
Path(sys.argv[2], "ok").write_text("1")
PY
[ -f "$T/ok" ] || falla "el recorte no paso las aserciones"

# 2. Compone un guion 9:16 que el runner declara valido, tipo informativo.
FIX="$RAIZ/pruebas/fixtures/noticia-demo.txt"
python3 "$RAIZ/harness/noticias.py" \
  --fichero "$FIX" --guion "$T/corte.guion" --seg-objetivo 16 --seg-por-toma 8 \
  >/dev/null || { falla "noticias.py --guion fallo"; }
grep -q '^@TIPO informativo' "$T/corte.guion" \
  || falla "el guion compuesto no es @TIPO informativo"
grep -q '^TOMA|' "$T/corte.guion" || falla "el guion compuesto no tiene TOMA"
# Primera toma inicio, el resto ancla.
modos=$(awk -F'|' '/^TOMA\|/{print $3}' "$T/corte.guion")
echo "$modos" | head -1 | grep -qx inicio || falla "toma 1 no es inicio"
echo "$modos" | awk 'NR>1 && $0!="ancla"{bad=1} END{exit bad}' \
  || falla "alguna toma posterior no es ancla"
# El planificador no necesita ffmpeg: si esto falla, el runner anclado
# tampoco aceptaria el guion, y se descubriria despues de gastar GPU.
if ! python3 "$RAIZ/harness/planificar.py" "$T/corte.guion" \
      --nombre chk-noticias --frames 192 --width 416 --height 736 \
      --steps 20 --fps 24 --seed 100 --model-id chk >"$T/plan.json" 2>"$T/plan.err"
then
  falla "el planificador rechazo el guion de noticias"
  sed -n '1,5p' "$T/plan.err" | sed 's/^/    /'
else
  python3 - "$T/plan.json" <<'PY' || fallos=1
import json,sys
p=json.load(open(sys.argv[1],encoding="utf-8"))
assert p["parametros"]["width"]==416 and p["parametros"]["height"]==736
assert all(t["tipo"]=="informativo" for t in p["tomas"]), [t["tipo"] for t in p["tomas"]]
assert p["tomas"][0]["modo"]=="inicio"
PY
fi
# Prompt de presentador, no el filosofico. Se sourcea el motor real.
p=$(bash -c '. "$1"; construir_prompt informativo "ESCENA-X" "El congreso aprueba." "AMB" "MUS"' \
      _ "$RAIZ/lib/prompt.sh") || falla "construir_prompt informativo fallo"
printf '%s' "$p" | grep -q 'news-anchor delivery' \
  || falla "el prompt de informativo no es el de presentador"
printf '%s' "$p" | grep -q 'calm deliberation' \
  && falla "el reel de noticias sigue usando el prompt filosofico"
printf '%s' "$p" | grep -q '\[Spanish\]' \
  || falla "el prompt de informativo no dispara el dialogo <d>[Spanish]"
printf '%s' "$p" | grep -q 'ESCENA-X' \
  || falla "el prompt de informativo perdio la escena"

# El ejemplo versionado tambien valida (lo cubre guiones.sh; aqui el tipo).
grep -q '@TIPO informativo' "$RAIZ/produccion/guiones/noticias/ejemplo-reel.guion" \
  || falla "el ejemplo no es informativo"

# 3. Categoria: 9:16 nativo, ritmo de voz continua.
python3 - "$RAIZ/harness/categorias/noticias.json" <<'PY' || fallos=1
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
f=c.get("formato") or {}
assert f.get("ancho")==416 and f.get("alto")==736, f
assert f["alto"]>f["ancho"], "el formato nativo no es vertical"
assert c["ritmo"]==["informativo"], c["ritmo"]
assert "9:16" in c["escena"] or "Vertical" in c["escena"]
assert "no readable text" in c["escena"].lower() or "no readable text" in c["escena"]
PY

# 4. Subtitulos: el filtro cae en zona segura y escapa el texto.
python3 "$RAIZ/produccion/subtitular.py" /dev/null \
  --texto "El congreso aprueba la ley. El tope entra en vigor." \
  --salida "$T/no.mp4" --solo-filtro > "$T/vf" || {
  falla "subtitular --solo-filtro fallo"
}
grep -q "drawtext=" "$T/vf" || falla "no hay drawtext"
grep -q "y=h\*0.62" "$T/vf" || falla "los subtitulos no estan en y=h*0.62 (zona segura)"
grep -q "fontfile=" "$T/vf" || falla "drawtext sin fontfile"
# Un apostrofe o dos puntos no pueden romper el filtro.
python3 "$RAIZ/produccion/subtitular.py" /dev/null \
  --texto "Atencion: 'hoy' se vota." --salida "$T/no.mp4" --solo-filtro \
  > "$T/vf2" || falla "subtitular no escapo el texto con : y comillas"
grep -q "text=" "$T/vf2" || falla "el filtro escapado no tiene text="

if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  # Clip minimo 9:16 con audio. Sin GPU.
  ffmpeg -nostdin -y -v error \
    -f lavfi -i "color=c=navy:s=416x736:d=2:r=24" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac "$T/in.mp4" \
    || falla "no pude fabricar el clip de prueba"
  if [ -f "$T/in.mp4" ]; then
    python3 "$RAIZ/produccion/subtitular.py" "$T/in.mp4" \
      --texto "El congreso aprueba la ley." --salida "$T/subs.mp4" \
      || falla "subtitular no quemo el clip de prueba"
    [ -s "$T/subs.mp4" ] || falla "el mp4 subtitulado esta vacio"
    bash "$RAIZ/produccion/exportar-reel.sh" "$T/subs.mp4" "$T/reel.mp4" \
      || falla "exportar-reel.sh fallo"
    WH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
         -of csv=p=0 "$T/reel.mp4" 2>/dev/null)
    [ "$WH" = "1080,1920" ] || falla "el reel no es 1080x1920 (fue '$WH')"
    # No sobrescribe.
    if bash "$RAIZ/produccion/exportar-reel.sh" "$T/subs.mp4" "$T/reel.mp4" \
         >/dev/null 2>&1; then
      falla "exportar-reel sobrescribio una salida existente"
    fi
    # Un export que no sea 9:16 se rechaza.
    if ANCHO=1280 ALTO=720 bash "$RAIZ/produccion/exportar-reel.sh" \
         "$T/subs.mp4" "$T/mal.mp4" >/dev/null 2>&1; then
      falla "exportar-reel acepto 1280x720"
    fi
  fi
else
  echo "  (sin ffmpeg en esta maquina: se salta quemado y export reales)"
fi

# 5. SOLO_GUION del wrapper, sin GPU.
if ! SOLO_GUION=1 bash "$RAIZ/produccion/reel-noticias.sh" \
      --fichero "$FIX" --nombre chkdemo >"$T/wrap.out" 2>&1; then
  falla "reel-noticias.sh SOLO_GUION fallo"
  sed -n '1,8p' "$T/wrap.out" | sed 's/^/    /'
fi
[ -f "$RAIZ/produccion/guiones/noticias/generados/chkdemo.guion" ] \
  || [ -f "$RAIZ/produccion/guiones/noticias/chkdemo.guion" ] \
  || falla "SOLO_GUION no escribio el guion"
rm -f "$RAIZ/produccion/guiones/noticias/generados/chkdemo.guion" \
      "$RAIZ/produccion/guiones/noticias/chkdemo.guion"

# VALIDAR=1 del wrapper atraviesa producir-anclado.sh, que exige ffmpeg
# aunque no genere. Sin ffmpeg no se puede afirmar nada de esa rama.
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  if ! VALIDAR=1 bash "$RAIZ/produccion/reel-noticias.sh" \
        --fichero "$FIX" --nombre chkvalidar >"$T/val.out" 2>&1; then
    falla "reel-noticias.sh VALIDAR=1 fallo"
    sed -n '1,8p' "$T/val.out" | sed 's/^/    /'
  fi
  grep -q "guion valido" "$T/val.out" || falla "VALIDAR=1 no imprimio guion valido"
  if compgen -G "$RAIZ/produccion/obra/chkvalidar/*.avi" >/dev/null; then
    falla "VALIDAR=1 genero video"
  fi
  rm -rf "$RAIZ/produccion/obra/chkvalidar"
  rm -f "$RAIZ/produccion/guiones/noticias/generados/chkvalidar.guion" \
        "$RAIZ/produccion/guiones/noticias/chkvalidar.guion"
fi

# 6. Recorte sobre una noticia INVESTIGADA: cada frase dicha ⊆ fuente.
python3 - "$RAIZ" "$T" <<'PY' || fallos=1
import importlib.util, os, sys
raiz, tmp = sys.argv[1], sys.argv[2]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
inv = load("investigar", os.path.join(raiz, "harness", "investigar.py"))
noti = load("noticias", os.path.join(raiz, "harness", "noticias.py"))
item = inv.elegir("avion amazon miami")
r = noti.redactar(item["titular"], item["cuerpo"], seg_objetivo=16)
origen = (item["titular"] + " " + item["cuerpo"]).lower()
for frase in r["frases"]:
    nucleo = frase.lower().rstrip(".!?…")
    if nucleo not in origen:
        print("FALLA noticias-reel: frase inventada sobre fuente investigada:", frase)
        sys.exit(1)
if not item.get("fuente", "").startswith("http"):
    print("FALLA noticias-reel: la noticia investigada no trae URL de fuente")
    sys.exit(1)
open(os.path.join(tmp, "inv-ok"), "w").write(item["id"])
PY
[ -f "$T/inv-ok" ] || falla "el recorte sobre noticia investigada no paso"

# 7. --tema del wrapper: dos corridas SOLO_GUION identicas.
if ! SOLO_GUION=1 bash "$RAIZ/produccion/reel-noticias.sh" \
      --tema "avion amazon miami" --nombre chktema --seg-objetivo 16 \
      >"$T/tema1.out" 2>&1; then
  falla "reel-noticias.sh --tema SOLO_GUION fallo"
  sed -n '1,8p' "$T/tema1.out" | sed 's/^/    /'
fi
G1="$RAIZ/produccion/guiones/noticias/generados/chktema.guion"
[ -f "$G1" ] || falla "--tema no escribio guion"
[ -f "$G1.fuente.json" ] || falla "--tema no escribio sidecar de fuente"
tomas1=$(awk -F'|' '/^TOMA\|/{print $2}' "$G1")
SOLO_GUION=1 bash "$RAIZ/produccion/reel-noticias.sh" \
      --tema "avion amazon miami" --nombre chktema --seg-objetivo 16 \
      >"$T/tema2.out" 2>&1 || falla "segunda corrida --tema fallo"
tomas2=$(awk -F'|' '/^TOMA\|/{print $2}' "$G1")
[ "$tomas1" = "$tomas2" ] || falla "dos corridas --tema produjeron TOMA distintas"
# las TOMA habladas son substring de la fuente
python3 - "$G1" "$G1.fuente.json" <<'PY' || fallos=1
import json, sys
guion=open(sys.argv[1],encoding="utf-8").read()
src=json.load(open(sys.argv[2],encoding="utf-8"))
origen=(src["titular"]+" "+src["cuerpo"]).lower()
for line in guion.splitlines():
    if not line.startswith("TOMA|"): continue
    campos=line.split("|")
    tipo=campos[3].strip() if len(campos)>3 else ""
    if tipo and tipo not in {"habla","informativo"}: continue
    nucleo=campos[1].strip().lower().rstrip(".!?…")
    if nucleo not in origen:
        print("FALLA noticias-reel: TOMA no esta en la fuente:", campos[1])
        sys.exit(1)
PY
rm -f "$G1" "$G1.fuente.json" \
      "$RAIZ/produccion/guiones/noticias/generados/chktema.noticia.txt" \
      "$RAIZ/produccion/guiones/noticias/generados/chktema.noticia.txt.fuente.json"

# 8. El sondeo de los cinco MP4 falla cerrado si no hay entregas.
if [ -f "$RAIZ/produccion/sondear-dia.sh" ]; then
  DEST="$T/vacio" bash "$RAIZ/produccion/sondear-dia.sh" "$T/cinco.txt" \
    >/dev/null 2>"$T/sondear.err" && falla "sondear-dia.sh paso sin ningun MP4"
  grep -q 'se esperaban 5' "$T/sondear.err" \
    || falla "sondear-dia.sh no dijo que faltan 5 MP4"
else
  falla "falta produccion/sondear-dia.sh"
fi

[ $fallos -eq 0 ] && echo "ok $nombre (recorte, informativo, 9:16, investigacion, export)"
exit $fallos
