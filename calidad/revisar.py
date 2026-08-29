#!/usr/bin/env python3
"""Prepara el material para REVISAR una pieza con los ojos (o con un modelo que vea).

Por que existe: los defectos que de verdad estropean estos videos no los ve
ninguna metrica de señal de este proyecto. Comprobado el 2026-08-29 sobre
'formato-detalle', que puntuaba 0 manchas, ESTABLE y -4.2% de deriva —perfecto—
mientras tenia una mano derecha malformada, con los dedos fundidos, durante los
56 segundos enteros. Y sobre 'formato-accion', que con las mismas notas cambia de
lampara, de libros y de CARA entre la toma 1 y la 4.

Se intento detectar la incoherencia entre tomas por señal, comparando la mediana
temporal de cada toma. NO FUNCIONA, y queda escrito para que nadie lo reintente:
la pieza mala dio 1.81% de diferencia y la buena 3.87%, o sea al reves. Estas
diferencias son SEMANTICAS (otra lampara, otra cara), no fotometricas: dos
imagenes pueden diferir poquisimo en pixeles y muchisimo en significado.

Asi que esto no puntua nada. Genera las laminas que hacen falta para mirar, y
quien mira tiene que ser algo que VEA. En este montaje eso es Claude: los modelos
delegados (gemini, codex, minimax) solo reciben texto — delegar_a_cloud no acepta
imagenes— asi que no pueden revisar un fotograma.

Genera:
  <salida>-tira.jpg    12 momentos repartidos por la pieza, con su segundo
  <salida>-zoom.jpg    la MISMA region ampliada en cada toma: sirve para ver si
                       la identidad o el decorado cambian en los cortes
Uso:
  revisar.py <video> [--obra <dir_tomas>] [--zona manos|cara|centro] [--salida pre]
"""
import subprocess, sys, os, glob, argparse

ZONAS = {  # x, y, ancho, alto en fraccion del cuadro
    "cara":   (0.28, 0.06, 0.44, 0.52),
    "manos":  (0.10, 0.45, 0.80, 0.50),
    "centro": (0.25, 0.25, 0.50, 0.50),
    "todo":   (0.00, 0.00, 1.00, 1.00),
}

def _ff(a): subprocess.run(["ffmpeg","-nostdin","-y","-v","error"]+a, capture_output=True)

def dur(v):
    r = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                        "-of","csv=p=0",v], capture_output=True, text=True).stdout.strip()
    try: return float(r)
    except ValueError: return 0.0

def _montar(pngs, salida, por_fila):
    if not pngs: return False
    ins = []
    for p in pngs: ins += ["-i", p]
    filas, n = [], len(pngs)
    for i in range(0, n, por_fila):
        grupo = list(range(i, min(i+por_fila, n)))
        if len(grupo) < por_fila: break
        filas.append("".join(f"[{j}]" for j in grupo) + f"hstack=inputs={por_fila}[f{len(filas)}]")
    if not filas: return False
    fc = ";".join(filas)
    if len(filas) > 1:
        fc += ";" + "".join(f"[f{i}]" for i in range(len(filas))) + f"vstack=inputs={len(filas)}"
    else:
        fc = fc.replace("[f0]", "")
    _ff(ins + ["-filter_complex", fc, "-frames:v","1","-update","1", salida])
    return os.path.exists(salida)

def tira(video, salida, n=12, ancho=460):
    d = dur(video)
    if d <= 0: return False
    T = os.path.dirname(salida) or "."
    pngs = []
    for i in range(n):
        t = d*(i+0.5)/n
        f = os.path.join(T, f".rev-t{i:02d}.png")
        _ff(["-ss",str(t),"-i",video,"-frames:v","1","-update","1","-vf",
             f"scale={ancho}:-1,drawtext=text='{t:.1f}s':x=8:y=8:fontsize=22:fontcolor=yellow"
             ":box=1:boxcolor=black@0.5", f])
        if os.path.exists(f): pngs.append(f)
    ok = _montar(pngs, salida, 4)
    for p in pngs: os.remove(p)
    return ok

def zoom_por_toma(obra, salida, zona="cara", ancho=520):
    """La MISMA region de cada toma, lado a lado: para ver si cambia la identidad."""
    tomas = sorted(glob.glob(os.path.join(obra,"t[0-9][0-9].avi")) or
                   glob.glob(os.path.join(obra,"p[0-9][0-9].avi")))
    if len(tomas) < 2: return False
    x,y,w,h = ZONAS.get(zona, ZONAS["cara"])
    T = os.path.dirname(salida) or "."
    pngs = []
    for i,t in enumerate(tomas):
        d = dur(t)
        if d <= 0: continue
        f = os.path.join(T, f".rev-z{i:02d}.png")
        _ff(["-ss",str(d/2),"-i",t,"-frames:v","1","-update","1","-vf",
             f"crop=iw*{w}:ih*{h}:iw*{x}:ih*{y},scale={ancho}:-1,"
             f"drawtext=text='toma {i+1}':x=8:y=8:fontsize=24:fontcolor=yellow"
             ":box=1:boxcolor=black@0.5", f])
        if os.path.exists(f): pngs.append(f)
    ok = _montar(pngs, salida, len(pngs)) if pngs else False
    for p in pngs: os.remove(p)
    return ok

if __name__ == "__main__":
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("video"); ap.add_argument("--obra"); ap.add_argument("--zona", default="cara")
    ap.add_argument("--salida"); ap.add_argument("-h","--help", action="store_true")
    a = ap.parse_args()
    if a.help: print(__doc__); sys.exit(0)
    pre = a.salida or os.path.splitext(os.path.basename(a.video))[0]
    if tira(a.video, f"{pre}-tira.jpg"): print(f"  {pre}-tira.jpg   12 momentos de la pieza")
    else: print("  no pude generar la tira"); sys.exit(1)
    if a.obra:
        if zoom_por_toma(a.obra, f"{pre}-zoom.jpg", a.zona):
            print(f"  {pre}-zoom.jpg   la zona '{a.zona}' en cada toma, para comparar")
        else: print("  no pude generar el zoom por tomas")
    print("\n  MIRALAS. Esto no puntua: los defectos que importan aqui —manos")
    print("  malformadas, identidad que cambia, decorado que se mueve— no los ve")
    print("  ninguna metrica de señal, y ya se comprobo que intentarlo da el")
    print("  resultado AL REVES (ver la cabecera de este fichero).")
