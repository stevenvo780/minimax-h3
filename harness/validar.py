#!/usr/bin/env python3
"""Bateria de validacion de una pieza: calidad, estabilidad, audio y VARIEDAD.

Reune en un solo veredicto lo que estaba repartido en calidad/auditar.py, y añade
la medida que faltaba: si la pieza es VARIADA o si todas sus tomas son el mismo
plano repetido.

Lo que este harness NO puede decidir, y hay que decirlo claro: si la pieza se
siente NATURAL. Esta sesion dejo cuatro casos medidos en los que la nota y el ojo
apuntaron en direcciones opuestas —una mano deformada con nota perfecta, unos
labios fruncidos contados como aberracion, una barba de cepillo puntuando mejor
que una barba real, un paisaje impecable hundido por el recorte central—. La
naturalidad y las alucinaciones anatomicas necesitan MIRAR: calidad/revisar.py
genera las laminas, y quien mira tiene que ser algo que vea.

Uso:  validar.py <video.mp4> [<video2.mp4> ...] [--json]
"""
import json, os, re, subprocess, sys, statistics, tempfile, shutil

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUD = os.path.join(RAIZ, "calidad", "auditar.py")

def _aud(modo, video):
    try:
        r = subprocess.run(["python3", AUD, modo, video, "--json"],
                           capture_output=True, text=True, timeout=1800)
        return json.loads(r.stdout) if r.stdout.strip() else None
    except Exception:
        return None

def variedad(video, muestras=12):
    """Cuanto se diferencian entre si los momentos de la pieza.

    Una pieza donde todas las tomas son el mismo plano repetido puede sacar
    sobresaliente en estabilidad y no valer nada: la estabilidad premia justo lo
    contrario de la variedad, asi que hacen falta las dos.
    """
    d = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                        "-of","csv=p=0",video], capture_output=True, text=True).stdout.strip()
    try: d = float(d)
    except ValueError: return None
    if d <= 0: return None
    T = tempfile.mkdtemp(prefix="var-")
    try:
        fs = []
        for i in range(muestras):
            t = d*(i+0.5)/muestras
            f = os.path.join(T, f"{i:02d}.png")
            subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-ss",str(t),"-i",video,
                            "-frames:v","1","-update","1","-vf","scale=160:-1",f],
                           capture_output=True)
            if os.path.exists(f): fs.append(f)
        if len(fs) < 4: return None
        difs = []
        for a, b in zip(fs, fs[1:]):
            r = subprocess.run(["ffmpeg","-nostdin","-v","info","-i",a,"-i",b,"-filter_complex",
                 "[0][1]blend=all_mode=difference,format=gray,signalstats,"
                 "metadata=print:key=lavfi.signalstats.YAVG","-f","null","-"],
                 capture_output=True, text=True).stderr
            m = re.search(r"YAVG=([0-9.]+)", r)
            if m: difs.append(float(m.group(1)))
        if not difs: return None
        return {"media": round(statistics.mean(difs),2), "maxima": round(max(difs),2)}
    finally:
        shutil.rmtree(T, ignore_errors=True)

def validar(video):
    n = os.path.basename(video)
    res = {"pieza": n, "problemas": [], "avisos": []}
    dur = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                          "-of","csv=p=0",video], capture_output=True, text=True).stdout.strip()
    res["duracion_s"] = round(float(dur),1) if dur else None
    wh = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries",
                         "stream=width,height","-of","csv=p=0",video],
                        capture_output=True, text=True).stdout.strip()
    res["resolucion"] = wh

    m = _aud("manchas", video)
    if m and "manchas" in m:
        res["manchas"] = m["manchas"]
        if m["manchas"] > 0:
            res["avisos"].append(f"{m['manchas']} pico(s) de saturacion — MIRALOS antes de "
                                 "creerlos: unos labios fruncidos disparan este detector")
    e = _aud("estabilidad", video)
    if e and "veredicto" in e:
        res["deriva_tono_%"]  = e.get("deriva_tono_%")
        res["deriva_bordes_%"] = e.get("deriva_bordes_%")
        res["estabilidad"] = e["veredicto"]
        if e["veredicto"] == "DERIVA":
            res["problemas"].append("la pieza deriva de principio a fin")
    a = _aud("audio", video)
    if a:
        res["ruido_dB"] = a.get("ruido_alta_dB")
        if a.get("limpio") is False:
            res["problemas"].append("siseo audible por encima de 6 kHz")
    v = variedad(video)
    if v:
        res["variedad"] = v["media"]
        if v["media"] < 3:
            res["avisos"].append(f"variedad baja ({v['media']}): los planos se parecen "
                                 "demasiado entre si")
    if res.get("resolucion","").startswith("512"):
        res["avisos"].append("512 de ancho: esa resolucion produjo 12 aberraciones de color medidas")

    res["veredicto"] = ("REVISAR" if res["problemas"] else
                        "OK CON AVISOS" if res["avisos"] else "OK")
    res["pendiente_de_mirar"] = ("anatomia, identidad entre tomas y continuidad: "
                                 "ninguna metrica los ve. Usa calidad/revisar.py")
    return res

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args: print(__doc__); sys.exit(2)
    salida = [validar(v) for v in args]
    if "--json" in sys.argv:
        print(json.dumps(salida, indent=1, ensure_ascii=False)); sys.exit(0)
    for r in salida:
        print(f"\n  ── {r['pieza']}")
        print(f"     {r.get('resolucion','?')} · {r.get('duracion_s','?')} s · "
              f"manchas {r.get('manchas','?')} · {r.get('estabilidad','?')} · "
              f"variedad {r.get('variedad','?')} · ruido {r.get('ruido_dB','?')} dB")
        for p in r["problemas"]: print(f"     PROBLEMA: {p}")
        for x in r["avisos"]:    print(f"     aviso: {x}")
        print(f"     -> {r['veredicto']}")
    print(f"\n  Falta por MIRAR en todas: {salida[0]['pendiente_de_mirar']}")
