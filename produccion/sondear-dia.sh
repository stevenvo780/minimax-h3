#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  SONDEAR EL DIA — comprueba que lo entregado es un REEL publicable.
#
#  Antes esto miraba los dia-*.mp4 en bruto: el montaje interno a 416x736,
#  sin subtitulos y a -19 LUFS. Es decir, la prueba de aceptacion certificaba
#  el artefacto equivocado, y por eso cinco piezas a media cocer pasaron por
#  buenas. Ahora el sujeto es el reel: 1080x1920 y sonoridad de movil.
#
#  Tambien desaparece de aqui la lista negra de palabras de filosofia
#  ("existencialismo", "estoicismo", "cinismo"...): lo que hace que una pieza
#  sea del dia no es no llamarse como una pieza vieja, es tener detras una
#  noticia con fuente. Eso ya se comprueba, y se comprueba en positivo.
#
#  Uso:  produccion/sondear-dia.sh [salida.tsv]
#  Entorno: DEST=<dir de entregas>  MINIMO=5  LUFS=-14
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffprobe ffmpeg python3 || exit 1

OUT=${1:-}
DEST_DIR=${DEST:-$MD/videos/entregas}
MINIMO=${MINIMO:-5}
mapfile -t FILES < <(ls -1 "$DEST_DIR"/dia-*-reel-*.mp4 2>/dev/null | sort)
n=${#FILES[@]}
if [ "$n" -lt "$MINIMO" ]; then
  echo "FALLO: hay $n reels dia-*-reel-*.mp4 en $DEST_DIR, se esperaban $MINIMO" >&2
  echo "       (un dia-*.mp4 sin '-reel-' es el montaje interno, no el producto:" >&2
  echo "        lo publica reel-noticias.sh tras subtitular y exportar a 1080x1920)" >&2
  exit 1
fi

python3 - "$MD" "$OUT" "${FILES[@]}" <<'PY'
import json, os, subprocess, sys

raiz, out = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
sys.path.insert(0, os.path.join(raiz, "harness"))
import redaccion  # noqa: E402

LUFS_OBJETIVO = float(os.environ.get("LUFS", "-14"))
LUFS_TOLERANCIA = 2.0


def falla(mensaje):
    sys.exit(f"FALLO: {mensaje}")


def historia(nombre):
    """dia-miami-amazon-416x736-32s-...-reel-1080x1920.mp4 -> dia-miami-amazon"""
    for token in ("-416x", "-736x", "-1080x", "-1376x"):
        if token in nombre:
            return nombre.split(token)[0]
    return nombre


def sonoridad(path):
    proc = subprocess.run(
        ["ffmpeg", "-nostdin", "-i", path, "-af", "ebur128", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    marca = "I:"
    for linea in reversed(proc.stderr.splitlines()):
        if marca in linea and "LUFS" in linea:
            try:
                return float(linea.split(marca)[1].split("LUFS")[0])
            except (IndexError, ValueError):
                return None
    return None


rows, vistos = [], set()
for path in files:
    nombre = os.path.basename(path)
    if nombre in vistos:
        falla(f"nombre duplicado {nombre}")
    vistos.add(nombre)
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "format=duration,size:stream=codec_type,codec_name,width,height",
         "-of", "json", path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        falla(f"ffprobe {path}: {proc.stderr[-200:]}")
    data = json.loads(proc.stdout)
    fmt = data.get("format") or {}
    streams = [s for s in (data.get("streams") or []) if isinstance(s, dict)]
    tipos = {s.get("codec_type") for s in streams}
    if "video" not in tipos or "audio" not in tipos:
        falla(f"{nombre} sin video+audio ({tipos})")
    try:
        dur = float(fmt.get("duration") or 0)
    except (TypeError, ValueError):
        dur = 0.0
    if dur <= 0:
        falla(f"{nombre} duracion {dur}")
    size = int(fmt.get("size") or os.path.getsize(path))
    if size < 10000:
        falla(f"{nombre} demasiado pequeño ({size} B)")
    vid = next(s for s in streams if s.get("codec_type") == "video")
    w, h = int(vid.get("width") or 0), int(vid.get("height") or 0)
    if (w, h) != (1080, 1920):
        falla(f"{nombre} es {w}x{h}; un reel se publica en 1080x1920")
    lufs = sonoridad(path)
    if lufs is None:
        falla(f"{nombre}: no pude medir la sonoridad")
    if abs(lufs - LUFS_OBJETIVO) > LUFS_TOLERANCIA:
        falla(
            f"{nombre} a {lufs:.1f} LUFS; el movil pide {LUFS_OBJETIVO:.0f} "
            f"(±{LUFS_TOLERANCIA:.0f}). ¿Se publico el montaje interno?"
        )
    rows.append({
        "path": path, "name": nombre, "historia": historia(nombre),
        "bytes": size, "duration_s": round(dur, 3), "width": w, "height": h,
        "lufs": round(lufs, 1),
        "codecs": ",".join(f"{s.get('codec_type')}:{s.get('codec_name')}" for s in streams),
    })

historias = [r["historia"] for r in rows]
if len(set(historias)) < len(rows):
    falla(f"historias no distintas: {historias}")

lineas = ["path\tbytes\tduration_s\twidth\theight\tlufs\tcodecs"]
for r in rows:
    lineas.append(
        f"{r['path']}\t{r['bytes']}\t{r['duration_s']}\t{r['width']}\t"
        f"{r['height']}\t{r['lufs']}\t{r['codecs']}"
    )
texto = "\n".join(lineas) + "\n"
if out:
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
    open(out, "w", encoding="utf-8").write(texto)
sys.stdout.write(texto)

# Cada TOMA hablada tiene que estar en la noticia investigada. Se comprueba
# FRASE A FRASE: al saltarse lo ya dicho, una toma puede juntar dos frases que
# en el teletipo original no eran contiguas.
obras = os.path.join(raiz, "produccion", "obra")
for r in rows:
    nombre = r["historia"]
    fuente = os.path.join(obras, nombre, "fuente.json")
    guion = os.path.join(obras, nombre, "entrada.guion")
    if not os.path.isfile(fuente) or not os.path.isfile(guion):
        falla(f"falta fuente o guion junto a la obra {nombre}")
    src = json.load(open(fuente, encoding="utf-8"))
    origen = src.get("titular", "") + " " + src.get("cuerpo", "")
    for linea in open(guion, encoding="utf-8"):
        if not linea.startswith("TOMA|"):
            continue
        campos = linea.split("|")
        tipo = campos[3].strip() if len(campos) > 3 else ""
        if tipo and tipo not in redaccion.TIPOS_VOZ:
            continue
        toma = campos[1].strip()
        if not redaccion.en_fuente(toma, origen):
            falla(f"TOMA inventada en {nombre}: {toma[:80]}")

print(f"ok sondear-dia ({len(rows)} reels 1080x1920, tomas ⊆ fuente)", file=sys.stderr)
PY
