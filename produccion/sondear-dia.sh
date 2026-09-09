#!/bin/bash
# Lista los MP4 dia-* publicados: ruta, bytes, duracion, WxH, codecs.
# Falla si no hay 5, si falta audio/video, o si duracion <= 0.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"
exigir_herramientas ffprobe python3 || exit 1

OUT=${1:-}
DEST_DIR=${DEST:-$MD/videos/entregas}
mapfile -t FILES < <(ls -1 "$DEST_DIR"/dia-*.mp4 2>/dev/null | sort)
n=${#FILES[@]}
[ "$n" -ge 5 ] || { echo "FALLO: hay $n MP4 dia-* en $DEST_DIR, se esperaban 5" >&2; exit 1; }

python3 - "$OUT" "${FILES[@]}" <<'PY'
import json, os, subprocess, sys

out = sys.argv[1] if sys.argv[1] else ""
files = sys.argv[2:]
rows = []
seen = set()
for path in files:
    name = os.path.basename(path)
    if name in seen:
        sys.exit(f"FALLO: nombre duplicado {name}")
    seen.add(name)
    r = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height",
            "-of", "json", path,
        ],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit(f"FALLO: ffprobe {path}: {r.stderr[-200:]}")
    data = json.loads(r.stdout)
    fmt = data.get("format") or {}
    streams = data.get("streams") or []
    types = {s.get("codec_type") for s in streams if isinstance(s, dict)}
    if "video" not in types or "audio" not in types:
        sys.exit(f"FALLO: {path} sin video+audio ({types})")
    try:
        dur = float(fmt.get("duration") or 0)
    except (TypeError, ValueError):
        dur = 0.0
    if dur <= 0:
        sys.exit(f"FALLO: {path} duracion {dur}")
    size = int(fmt.get("size") or os.path.getsize(path))
    if size < 10000:
        sys.exit(f"FALLO: {path} demasiado pequeño ({size} B)")
    vid = next(s for s in streams if s.get("codec_type") == "video")
    aud = next(s for s in streams if s.get("codec_type") == "audio")
    w, h = int(vid.get("width") or 0), int(vid.get("height") or 0)
    rows.append({
        "path": path,
        "name": name,
        "bytes": size,
        "duration_s": round(dur, 3),
        "width": w,
        "height": h,
        "video_codec": vid.get("codec_name"),
        "audio_codec": aud.get("codec_name"),
        "codecs": ",".join(
            f"{s.get('codec_type')}:{s.get('codec_name')}" for s in streams
        ),
    })

# Distinct stories: filename stem before first resolution token.
stems = []
for row in rows:
    stem = row["name"].split("-416x")[0].split("-736x")[0].split("-1376x")[0]
    stems.append(stem)
if len(set(stems)) < 5:
    sys.exit(f"FALLO: historias no distintas: {stems}")
banned = ("existencialismo", "formato-", "estoicismo", "cinismo", "absurdo", "fenomenologia", "dialectica")
for row in rows:
    low = row["name"].lower()
    if any(b in low for b in banned):
        sys.exit(f"FALLO: no es una noticia del dia: {row['name']}")

lines = [
    "path\tbytes\tduration_s\twidth\theight\tcodecs",
]
for row in rows:
    lines.append(
        f"{row['path']}\t{row['bytes']}\t{row['duration_s']}\t"
        f"{row['width']}\t{row['height']}\t{row['codecs']}"
    )
text = "\n".join(lines) + "\n"
if out:
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
    open(out, "w", encoding="utf-8").write(text)
sys.stdout.write(text)

# Cada TOMA hablada tiene que ser substring de la fuente investigada.
md = os.path.dirname(os.path.dirname(os.path.abspath(files[0])))
# files live in videos/entregas; project root is parent of videos/
root = os.path.dirname(os.path.dirname(files[0])) if os.path.basename(os.path.dirname(files[0])) == "entregas" else None
if root and os.path.basename(root) == "videos":
    root = os.path.dirname(root)
if not root:
    root = os.environ.get("MD") or os.getcwd()
obras = os.path.join(root, "produccion", "obra")
for row in rows:
    name = row["name"].split("-416x")[0].split("-736x")[0].split("-1376x")[0]
    src_path = os.path.join(obras, name, "fuente.json")
    guion_path = os.path.join(obras, name, "entrada.guion")
    if not os.path.isfile(src_path) or not os.path.isfile(guion_path):
        sys.exit(f"FALLO: falta fuente o guion junto a la obra {name}")
    src = json.load(open(src_path, encoding="utf-8"))
    origen = (src.get("titular", "") + " " + src.get("cuerpo", "")).lower()
    for line in open(guion_path, encoding="utf-8"):
        if not line.startswith("TOMA|"):
            continue
        campos = line.split("|")
        tipo = campos[3].strip() if len(campos) > 3 else ""
        if tipo and tipo not in {"habla", "informativo"}:
            continue
        nucleo = campos[1].strip().lower().rstrip(".!?…")
        if nucleo not in origen:
            sys.exit(f"FALLO: TOMA inventada en {name}: {campos[1][:80]}")
print(f"ok sondear-dia ({len(rows)} mp4, tomas ⊆ fuente)", file=sys.stderr)
PY
