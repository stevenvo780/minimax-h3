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
    return float(r.stdout.strip())

# 1) concat duro dentro de cada tramo
tramos = []
for gi, g in enumerate(grupos):
    out = os.path.join(MONT, f"tramo{gi}.mp4")
    lst = os.path.join(MONT, f"l{gi}.txt")
    with open(lst,"w") as fh:
        for c in g: fh.write(f"file '{c}'\n")
    subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-f","concat","-safe","0",
                    "-i",lst,"-c","copy",out], check=True)
    tramos.append(out)

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
