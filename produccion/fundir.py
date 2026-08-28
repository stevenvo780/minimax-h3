#!/usr/bin/env python3
"""Une los clips de MONT: duro dentro del tramo, fundido de 0.5s entre tramos."""
import sys, os, subprocess, glob
MONT, FINAL = sys.argv[1], sys.argv[2]
TR = 0.5
clips = sorted(glob.glob(os.path.join(MONT, "[0-9][0-9].mp4")))
if not clips: sys.exit(1)
bounds = set()
tf = os.path.join(MONT, "tramos.txt")
if os.path.exists(tf):
    bounds = {l.strip() for l in open(tf) if l.strip()}

# agrupar clips en tramos
grupos, actual = [], []
for c in clips:
    n = os.path.basename(c)[:2]
    if n in bounds and actual:
        grupos.append(actual); actual = []
    actual.append(c)
if actual: grupos.append(actual)

def dur(f):
    r = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                        "-of","default=noprint_wrappers=1:nokey=1",f],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: ffprobe fallo en '{f}' (returncode {r.returncode})\n")
        sys.exit(1)
    s = r.stdout.strip()
    if not s:
        sys.stderr.write(f"ERROR: ffprobe no devolvio duracion para '{f}'\n")
        sys.exit(1)
    try:
        d = float(s)
    except ValueError:
        sys.stderr.write(f"ERROR: no se puede parsear duracion '{s}' para '{f}'\n")
        sys.exit(1)
    if not (0 < d < float('inf')):
        sys.stderr.write(f"ERROR: duracion invalida {d} para '{f}'\n")
        sys.exit(1)
    return d

def get_video_metadata(f):
    """Extrae WxH, pix_fmt, r_frame_rate de un archivo."""
    r = subprocess.run(["ffprobe","-v","error","-select_streams","v","-show_entries",
                        "stream=width,height,pix_fmt,r_frame_rate","-of","csv=p=0",f],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: ffprobe metadatos fallo en '{f}'\n")
        sys.exit(1)
    parts = r.stdout.strip().split(",")
    if len(parts) < 4:
        sys.stderr.write(f"ERROR: metadatos incompletos en '{f}'\n")
        sys.exit(1)
    return {"width": int(parts[0]), "height": int(parts[1]), "pix_fmt": parts[2], "r_frame_rate": parts[3]}

# Limpiar ejecuciones anteriores
for f in glob.glob(os.path.join(MONT, "l[0-9]*.txt")) + glob.glob(os.path.join(MONT, "tramo[0-9]*.mp4")):
    try: os.remove(f)
    except: pass

# 1) concat duro dentro de cada tramo
tramos = []
metadatos = []
for gi, g in enumerate(grupos):
    out = os.path.join(MONT, f"tramo{gi}.mp4")
    lst = os.path.join(MONT, f"l{gi}.txt")
    with open(lst,"w") as fh:
        for c in g: fh.write(f"file '{c}'\n")
    subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-f","concat","-safe","0",
                    "-i",lst,"-c","copy",out], check=True)
    tramos.append(out)
    meta = get_video_metadata(out)
    metadatos.append(meta)

# Validar que todos los tramos tienen la misma resolucion y formato
ref_meta = metadatos[0]
for i, meta in enumerate(metadatos[1:], 1):
    if meta["width"] != ref_meta["width"] or meta["height"] != ref_meta["height"] or \
       meta["pix_fmt"] != ref_meta["pix_fmt"] or meta["r_frame_rate"] != ref_meta["r_frame_rate"]:
        sys.stderr.write(f"ERROR: tramos incompatibles para xfade:\n")
        sys.stderr.write(f"tramo0: {ref_meta['width']}x{ref_meta['height']}, {ref_meta['pix_fmt']}, {ref_meta['r_frame_rate']}\n")
        sys.stderr.write(f"tramo{i}: {meta['width']}x{meta['height']}, {meta['pix_fmt']}, {meta['r_frame_rate']}\n")
        sys.exit(1)

if len(tramos) == 1:
    subprocess.run(["cp", tramos[0], FINAL], check=True); sys.exit(0)

# 2) fundido encadenado entre tramos
ins, parts = [], []
for t in tramos: ins += ["-i", t]
v, a, off = "[0:v]", "[0:a]", 0.0
for i in range(1, len(tramos)):
    off += dur(tramos[i-1]) - TR
    parts.append(f"{v}[{i}:v]xfade=transition=fade:duration={TR}:offset={off:.4f}[v{i}]")
    parts.append(f"{a}[{i}:a]acrossfade=d={TR}[a{i}]")
    v, a = f"[v{i}]", f"[a{i}]"
cmd = ["ffmpeg","-nostdin","-y","-v","error"] + ins + \
      ["-filter_complex",";".join(parts),"-map",v,"-map",a,
       "-c:v","libx264","-preset","slow","-crf","17","-pix_fmt","yuv420p",
       "-c:a","aac","-b:a","192k",FINAL]
subprocess.run(cmd, check=True)
print(f"  fundidos aplicados entre {len(tramos)} tramos")
