#!/usr/bin/env python3
"""Detalle fino en la ZONA DE LA BARBA, para comparar dos brazos de un A/B.

Steven: "se siente la barba como un poco acartonada". Acartonado = falta de
textura fina: pelo suelto, poro, microcontraste. La medida global no sirve
porque el fondo negro del retrato ocupa media imagen y aplana cualquier
diferencia; hay que mirar SOLO donde esta la barba.

Con el encuadre de estos guiones (primer plano cerrado, la cara llena el cuadro
de la frente al menton) la barba cae en la mitad inferior central. Se recorta
esa banda y se mide la energia de alta frecuencia dentro.

Se usa la MEDIANA de muchos fotogramas: en el brazo hablado la boca se mueve, y
un fotograma suelto con la boca abierta no puede decidir el resultado.

Uso: medir-barba.py <video> [<video2> ...]
"""
import subprocess, sys, os, tempfile, shutil, statistics, re

def energia_alta(video, muestras=24):
    dur = float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
        "-of","csv=p=0",video],capture_output=True,text=True).stdout.strip() or 0)
    if dur <= 0: return None
    T = tempfile.mkdtemp(prefix="barba-")
    vals = []
    try:
        for i in range(muestras):
            t = dur*(i+0.5)/muestras
            f = os.path.join(T,"f.png")
            # recorte: mitad inferior central, donde cae la barba en este encuadre
            subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-ss",str(t),"-i",video,
                "-frames:v","1","-vf","crop=iw*0.40:ih*0.32:iw*0.30:ih*0.56",
                "-update","1",f],capture_output=True)
            if not os.path.exists(f): continue
            # energia de alta frecuencia = diferencia entre la imagen y su version
            # suavizada. Es exactamente lo que se pierde cuando algo se "acartona".
            r = subprocess.run(["ffmpeg","-v","info","-i",f,"-vf",
                "format=gray,split[a][b];[b]gblur=sigma=1.6[c];[a][c]blend=all_mode=difference,"
                "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
                "-f","null","-"],capture_output=True,text=True).stderr
            m = re.search(r"YAVG=([0-9.]+)", r)
            if m: vals.append(float(m.group(1)))
    finally:
        shutil.rmtree(T, ignore_errors=True)
    return (statistics.median(vals), len(vals)) if vals else None

if __name__ == "__main__":
    if len(sys.argv) < 2: print(__doc__); sys.exit(2)
    res = []
    for v in sys.argv[1:]:
        r = energia_alta(v)
        if r is None:
            print(f"  {os.path.basename(v):45s}  no pude medir"); continue
        res.append((os.path.basename(v), r[0]))
        print(f"  {os.path.basename(v):45s}  detalle fino {r[0]:6.3f}  ({r[1]} muestras)")
    if len(res) == 2:
        (n1,a),(n2,b) = res
        print(f"\n  {n2} tiene un {100*(b-a)/a:+.1f}% de detalle fino respecto a {n1}")
