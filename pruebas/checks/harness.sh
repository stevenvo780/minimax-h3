#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="harness"
exec 0</dev/null

# El harness convierte un TEXTO y una CATEGORIA en un .guion valido. Si eso se
# rompe, se rompe en silencio: el guion sale mal formado y no se descubre hasta
# gastar GPU. Este check lo fija sin generar nada.

fallos=0
for f in harness/componer.py harness/validar.py; do
  [ -f "$RAIZ/$f" ] || { echo "FALLA $nombre: falta $f"; exit 1; }
  python3 -c "import ast;ast.parse(open('$RAIZ/$f').read())" 2>/dev/null || {
    echo "FALLA $nombre: $f no parsea"; fallos=1; }
done
n=$(ls -1 "$RAIZ"/harness/categorias/*.json 2>/dev/null | wc -l)
[ "$n" -ge 3 ] || { echo "FALLA $nombre: solo $n categorias, se esperaban 3 o mas"; fallos=1; }

# Cada categoria tiene que traer todos sus campos y un ritmo no vacio.
for c in "$RAIZ"/harness/categorias/*.json; do
  python3 - "$c" <<'PY' || fallos=1
import json,sys
f=sys.argv[1]
try: d=json.load(open(f,encoding="utf-8"))
except Exception as e: print(f"FALLA harness: {f} no es JSON valido: {e}"); sys.exit(1)
for k in ("nombre","descripcion","escena","ambiente","musica","ritmo"):
    if not d.get(k): print(f"FALLA harness: {f} sin campo '{k}'"); sys.exit(1)
if not isinstance(d["ritmo"],list) or not d["ritmo"]:
    print(f"FALLA harness: {f} con ritmo vacio"); sys.exit(1)
# Un ritmo que pida planos de apoyo sin definirlos deja huecos silenciosos.
if any(t!="habla" for t in d["ritmo"]) and not d.get("apoyos"):
    print(f"FALLA harness: {f} pide planos que no son habla pero no define 'apoyos'"); sys.exit(1)
PY
done

T=$(mktemp -d /tmp/chk-harness.XXXXXX); trap 'rm -rf "$T"' EXIT
TXT="Primera frase de prueba. Segunda frase que alarga el texto lo suficiente. Tercera frase para forzar mas de una toma. Cuarta frase que cierra el conjunto."
for cat in $(ls -1 "$RAIZ"/harness/categorias/*.json | xargs -n1 basename | sed 's/\.json$//'); do
  python3 "$RAIZ/harness/componer.py" "$cat" "$T/$cat.guion" --texto "$TXT" >/dev/null 2>&1 || {
    echo "FALLA $nombre: componer fallo con la categoria $cat"; fallos=1; continue; }
  # el guion compuesto tiene que ser VALIDO para el pipeline, sin gastar GPU
  o=$(cd "$RAIZ" && VALIDAR=1 timeout 60 bash produccion/producir-anclado.sh "$T/$cat.guion" chk 2>&1)
  printf '%s' "$o" | grep -q 'guion valido' || {
    echo "FALLA $nombre: el guion compuesto de '$cat' no valida"
    printf '%s' "$o" | head -3 | sed 's/^/    /'; fallos=1; }
  # la primera toma siempre 'inicio', las demas 'ancla'
  m=$(awk -F'|' '/^TOMA\|/{print $3}' "$T/$cat.guion" | head -1)
  [ "$m" = inicio ] || { echo "FALLA $nombre: en '$cat' la toma 1 es '$m', deberia ser 'inicio'"; fallos=1; }
done

# Una categoria inexistente tiene que rebotar, no producir un guion vacio.
if python3 "$RAIZ/harness/componer.py" noexiste "$T/x.guion" --texto "Hola." >/dev/null 2>&1; then
  echo "FALLA $nombre: una categoria inexistente salio con 0"; fallos=1
fi

[ $fallos -eq 0 ] && echo "ok $nombre ($n categorias, todas componen y validan)"
exit $fallos
