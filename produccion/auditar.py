#!/usr/bin/env python3
"""
Auditor de una obra: convierte "se ve acartonado" en una decision.

Uso:  auditar.py obra     <dir_obra>            [--json] [--rapido]
      auditar.py plano    <fichero.avi>         [--json]
      auditar.py contacto <video> [salida.jpg]  hoja de contactos para MIRARLO
      auditar.py audio    <video>               ruido real, separado del volumen
      auditar.py habla    <video>               cobertura de voz: que no se calle

Reutiliza las medidas de evaluar2.py (criterio anti-trampa del autor, intacto)
y añade lo que faltaba: medir EL ESLABON, no solo el plano.

Por que el eslabon. Medido sobre existencialismo-4p:
  cada plano por separado puntua 88.9-95.4, pero el montaje de los cuatro da 68.8.
  La degradacion no ocurre dentro del plano: ocurre al pasar el ultimo frame de
  uno como --init-img del siguiente. Ese frame ya lleva el realce del modelo y el
  modelo realza encima. Realimentacion positiva sobre los bordes:
      last01 +3.2%   last02 +8.5%   last03 +13.5%   last04 +21.1%
  (exceso de energia de borde sobre el primer frame del primer plano)
"""
import sys, os, json, glob, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evaluar2 as E

FF = "ffmpeg"

def _frame(avi, out, ultimo=False):
    cmd = ["ffmpeg", "-nostdin", "-y", "-v", "error"]
    cmd += ["-sseof", "-0.05"] if ultimo else []
    cmd += ["-i", avi, "-frames:v", "1", "-update", "1", out]
    subprocess.run(cmd, capture_output=True)
    return os.path.exists(out)

def bordes(png):
    """Energia de borde estructural. Misma medida que evaluar2.bordes_estr."""
    return E.bordes_estr(png)

def entropia(png):
    return E.entropia_limpia(png)

# Umbrales del veredicto, de la serie medida (+3.2/+8.5/+13.5/+21.1%).
#
# NO hay veredicto "LIMPIAR". Se probo y se descarto MIRANDO la imagen: para
# bajar el exceso de forma apreciable hace falta un desenfoque de sigma>0.5, y
# a partir de 0.35 desaparecen el pelo de barba y el poro de piel. Con el sigma
# maximo sano el exceso solo baja ~1.6 puntos de 21: despreciable. Igualar la
# energia de borde contra otra imagen no deshace el realce, se lleva el detalle.
# Las palancas que SI funcionan no tocan los pixeles: menos eslabones, y
# reanclar a un frame pristino.
UMBRAL_OK, UMBRAL_REANCLAR = 5.0, 20.0
NOTA_MINIMA_PLANO = 85.0

def veredicto(exceso_pct, nota_plano):
    if nota_plano is not None and nota_plano < NOTA_MINIMA_PLANO: return "REGENERAR"
    if exceso_pct <= UMBRAL_OK:       return "OK"
    if exceso_pct <= UMBRAL_REANCLAR: return "REANCLAR"
    return "REGENERAR"

def auditar_obra(dir_obra, con_notas=True):
    planos = sorted(glob.glob(os.path.join(dir_obra, "p[0-9][0-9].avi")))
    if not planos: return {"error": f"sin planos en {dir_obra}"}
    T = tempfile.mkdtemp(prefix="auditar-")
    try:
        # Referencia: el primer frame del primer plano. Es lo unico que nunca
        # paso por un --init-img, asi que es el unico material sin realce heredado.
        ref_png = os.path.join(T, "ref.png")
        if not _frame(planos[0], ref_png):
            return {"error": "no pude extraer el frame de referencia"}
        ref = bordes(ref_png)
        if not ref: return {"error": "no pude medir la referencia"}

        res = {"obra": os.path.basename(dir_obra.rstrip("/")),
               "referencia_bordes": round(ref, 2), "planos": [], "enlaces": []}

        medidas = []
        for p in planos:
            n = os.path.basename(p)[:3]
            pi = os.path.join(T, f"{n}-i.png"); pu = os.path.join(T, f"{n}-u.png")
            _frame(p, pi); _frame(p, pu, ultimo=True)
            bi = bordes(pi) if os.path.exists(pi) else None
            bu = bordes(pu) if os.path.exists(pu) else None
            ei = entropia(pi) if os.path.exists(pi) else None
            nota = None
            if con_notas:
                r = E.evaluar(p)
                nota = r["TOTAL"] if r else None
            medidas.append(dict(nombre=n, ruta=p, b_ini=bi, b_fin=bu, e_ini=ei, nota=nota))
            res["planos"].append({
                "plano": n, "nota": nota,
                "bordes_ini": round(bi, 2) if bi else None,
                "bordes_fin": round(bu, 2) if bu else None,
                "exceso_fin_%": round(100 * (bu - ref) / ref, 1) if bu else None,
            })

        for a, b in zip(medidas, medidas[1:]):
            # El exceso del frame de enlace es la magnitud que mide la
            # realimentacion: es lo que se le va a inyectar al plano siguiente.
            exc = 100 * (a["b_fin"] - ref) / ref if a["b_fin"] else 0.0
            salto_b = (100 * (b["b_ini"] - a["b_fin"]) / a["b_fin"]) if a["b_fin"] and b["b_ini"] else None
            salto_e = (100 * (b["e_ini"] - a["e_ini"]) / a["e_ini"]) if a["e_ini"] and b["e_ini"] else None
            res["enlaces"].append({
                "de": a["nombre"], "a": b["nombre"],
                "exceso_bordes_%": round(exc, 1),
                "salto_bordes_%": round(salto_b, 1) if salto_b is not None else None,
                "salto_entropia_%": round(salto_e, 1) if salto_e is not None else None,
                "veredicto": veredicto(exc, b["nota"]),
            })

        notas = [m["nota"] for m in medidas if m["nota"] is not None]
        res["nota_media_planos"] = round(sum(notas) / len(notas), 1) if notas else None
        res["nota_peor_plano"] = round(min(notas), 1) if notas else None
        malos = [e for e in res["enlaces"] if e["veredicto"] != "OK"]
        res["peor_enlace"] = max(malos, key=lambda e: e["exceso_bordes_%"]) if malos else None
        res["accion"] = res["peor_enlace"]["veredicto"] if res["peor_enlace"] else "NINGUNA"
        return res
    finally:
        subprocess.run(["rm", "-rf", T])

def audio(video):
    """Suelo de ruido de verdad, no volumen.

    evaluar2.audio_piso() toma el RMS global de la ventana mas silenciosa como
    "suelo de ruido". Eso confunde una grabacion FUERTE con una ruidosa: medido,
    los clips de prueba dan RMS -12/-15 dB (que evaluar2 puntua 0/10, "zumbido
    evidente") y sin embargo su banda alta esta a -34/-38 dB, mas limpia que el
    material de referencia del usuario, que esta a -32/-37.

    Aqui el ruido se mide donde vive: por encima de 6 kHz, que en voz hablada
    es casi todo suelo. Y el volumen se informa aparte, sin mezclarlo."""
    def _rms(filtro):
        r = subprocess.run(["ffmpeg", "-nostdin", "-v", "info", "-i", video, "-vn",
                            "-af", filtro, "-f", "null", "-"],
                           capture_output=True, text=True)
        for l in r.stderr.splitlines():
            if "RMS level dB" in l:
                try: return float(l.split(":")[-1].strip())
                except ValueError: return None
        return None
    global_rms = _rms("astats=metadata=1:reset=0")
    hf         = _rms("highpass=f=6000,astats=metadata=1:reset=0")
    res = {"rms_global_dB": global_rms, "ruido_alta_dB": hf}
    if hf is not None:
        # -32 dB o menos = limpio (es donde esta el material bueno del usuario)
        # -22 dB = siseo audible
        res["limpio"] = hf <= -30
        res["nota_ruido"] = round(max(0.0, min(10.0, (-22 - hf) / 10 * 10)), 1)
    return res

def habla(video, umbral_db=None, min_silencio=0.8):
    """Cobertura de voz: que fraccion del clip tiene habla.

    Es la comprobacion narrativa que ninguna metrica de imagen puede hacer. El
    riesgo de una toma larga es que el modelo se quede sin dialogo a la mitad:
    la imagen seguiria impecable y la pieza estaria rota. Se detectan los
    silencios y se reporta lo que queda.

    Tambien delata el caso contrario: si el habla ocupa el 100% sin una sola
    pausa, el modelo esta atropellando el texto."""
    d = E.dur(video)
    # Umbral RELATIVO al propio clip. Uno absoluto (-40 dB) da falsos positivos
    # en una mezcla mas alta: un clip a -15 dB nunca cruza -40 y sale "100% de
    # voz, cero pausas" aunque tenga silencios perfectamente audibles. Es el
    # mismo fallo que tenia la medida del suelo de ruido.
    if umbral_db is None:
        a = audio(video)
        base = a.get("rms_global_dB")
        umbral_db = round(base - 22, 1) if base is not None else -40
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "info", "-i", video, "-vn",
                        "-af", f"silencedetect=noise={umbral_db}dB:d={min_silencio}",
                        "-f", "null", "-"], capture_output=True, text=True)
    silencios, ini = [], None
    for l in r.stderr.splitlines():
        if "silence_start:" in l:
            try: ini = float(l.split("silence_start:")[1].strip().split()[0])
            except (ValueError, IndexError): ini = None
        elif "silence_end:" in l and ini is not None:
            try:
                fin = float(l.split("silence_end:")[1].strip().split()[0])
                silencios.append((ini, fin)); ini = None
            except (ValueError, IndexError): ini = None
    if ini is not None: silencios.append((ini, d))
    mudo = sum(b - a for a, b in silencios)
    cob = 100 * (d - mudo) / d if d else 0
    # El silencio mas largo importa mas que el total: 20 s callado en mitad de
    # una pieza de 60 es una rotura, aunque la cobertura media salga en 66%.
    peor = max((b - a for a, b in silencios), default=0.0)
    return {"duracion_s": round(d, 2), "umbral_dB": umbral_db,
            "cobertura_voz_%": round(cob, 1),
            "silencio_total_s": round(mudo, 2), "silencio_mayor_s": round(peor, 2),
            "silencios": [(round(a, 2), round(b, 2)) for a, b in silencios[:12]],
            "veredicto": ("MUDO"     if cob < 40 else
                          "CORTADO"  if peor > 3.0 else
                          "ATROPELLADO" if cob > 97 else "OK")}

def contacto(video, salida, n=9):
    """Hoja de contactos: n fotogramas repartidos, en rejilla, con el segundo
    rotulado. Existe porque evaluar2 mide degradacion y no belleza: un video
    puede sacar 90 y estar oscuro, mal encuadrado y con el fondo equivocado.
    La nota no sustituye a mirarlo."""
    d = E.dur(video)
    cols = 3 if n <= 9 else 4
    filas = (n + cols - 1) // cols
    T = tempfile.mkdtemp(prefix="contacto-")
    try:
        trozos = []
        for i in range(n):
            t = d * (i + 0.5) / n
            f = os.path.join(T, f"{i:02d}.png")
            subprocess.run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", str(t),
                            "-i", video, "-frames:v", "1", "-update", "1", f],
                           capture_output=True)
            if os.path.exists(f): trozos.append((f, t))
        if not trozos: return None
        ins, filtros, etiq = [], [], []
        for i, (f, t) in enumerate(trozos):
            ins += ["-i", f]
            filtros.append(f"[{i}:v]scale=320:-1,drawtext=text='{t:.1f}s':fontcolor=yellow:"
                           f"fontsize=20:x=8:y=6:box=1:boxcolor=black@0.5[v{i}]")
            etiq.append(f"[v{i}]")
        layout = "|".join(
            ("0" if c == 0 else "+".join(f"w{k}" for k in range(c))) + "_" +
            ("0" if r == 0 else "+".join(f"h{k*cols}" for k in range(r)))
            for r in range(filas) for c in range(cols))[:None]
        layout = "|".join(layout.split("|")[:len(trozos)])
        cmd = (["ffmpeg", "-nostdin", "-y", "-v", "error"] + ins +
               ["-filter_complex", ";".join(filtros) + ";" + "".join(etiq) +
                f"xstack=inputs={len(trozos)}:layout={layout}:fill=black",
                "-frames:v", "1", "-q:v", "3", salida])
        r = subprocess.run(cmd, capture_output=True, text=True)
        return salida if os.path.exists(salida) else None
    finally:
        subprocess.run(["rm", "-rf", T])

def _imprimir(r):
    if "error" in r: print(f"  {r['error']}"); return 1
    print(f"╔══ obra: {r['obra']}   (referencia de bordes {r['referencia_bordes']})")
    for p in r["planos"]:
        nota = f"{p['nota']:5.1f}" if p["nota"] is not None else "    —"
        print(f"║ {p['plano']}  nota {nota}   bordes {p['bordes_ini']} → {p['bordes_fin']}"
              f"   fin {p['exceso_fin_%']:+.1f}% sobre la referencia")
    print("║")
    for e in r["enlaces"]:
        print(f"║ {e['de']}→{e['a']}  exceso {e['exceso_bordes_%']:+6.1f}%"
              f"  salto bordes {e['salto_bordes_%']}%  →  {e['veredicto']}")
    print(f"╚══ media {r['nota_media_planos']} · peor plano {r['nota_peor_plano']} · ACCION: {r['accion']}")
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    modo, arg = sys.argv[1], sys.argv[2]
    js = "--json" in sys.argv
    if modo == "habla":
        h = habla(arg)
        if js: print(json.dumps(h, indent=1)); sys.exit(0)
        print(f"  {os.path.basename(arg)}  {h['duracion_s']}s · voz {h['cobertura_voz_%']}% · "
              f"silencio mayor {h['silencio_mayor_s']}s · umbral {h['umbral_dB']}dB"
              f"  ->  {h['veredicto']}")
        sys.exit(0 if h["veredicto"] == "OK" else 1)
    if modo == "audio":
        a = audio(arg)
        if js: print(json.dumps(a, indent=1)); sys.exit(0)
        print(f"  {os.path.basename(arg)}  volumen {a['rms_global_dB']} dB · "
              f"ruido>6kHz {a['ruido_alta_dB']} dB · "
              f"{'limpio' if a.get('limpio') else 'con siseo'}"); sys.exit(0)
    if modo == "contacto":
        out = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else "contacto.jpg"
        h = contacto(arg, out)
        print(h if h else "no pude generar la hoja de contactos"); sys.exit(0 if h else 1)
    if modo == "obra":
        r = auditar_obra(arg, con_notas="--rapido" not in sys.argv)
    elif modo == "plano":
        v = E.evaluar(arg); r = v if v else {"error": "no evaluable"}
        if js: print(json.dumps(r, indent=1)); sys.exit(0)
        print(f"  {os.path.basename(arg)}  TOTAL {r.get('TOTAL','—')}"); sys.exit(0)
    else:
        print(__doc__); sys.exit(2)
    if js: print(json.dumps(r, indent=1)); sys.exit(0 if "error" not in r else 1)
    sys.exit(_imprimir(r))
