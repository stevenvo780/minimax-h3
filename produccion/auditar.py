#!/usr/bin/env python3
"""
Auditor de una obra: convierte "se ve acartonado" en una decision.

Uso:  auditar.py obra   <dir_obra>          [--json]
      auditar.py plano  <fichero.avi>       [--json]
      auditar.py enlace <avi_A> <avi_B>     [--json]

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

# Umbrales del veredicto. Salen de la serie medida arriba (+3.2/+8.5/+13.5/+21.1%)
# y son el PRIMER sitio a recalibrar cuando haya mas datos.
UMBRAL_OK, UMBRAL_LIMPIAR, UMBRAL_REANCLAR = 5.0, 15.0, 25.0
NOTA_MINIMA_PLANO = 85.0

def veredicto(exceso_pct, nota_plano):
    if nota_plano is not None and nota_plano < NOTA_MINIMA_PLANO: return "REGENERAR"
    if exceso_pct <= UMBRAL_OK:        return "OK"
    if exceso_pct <= UMBRAL_LIMPIAR:   return "LIMPIAR"
    if exceso_pct <= UMBRAL_REANCLAR:  return "REANCLAR"
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
