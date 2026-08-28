#!/usr/bin/env python3
"""
Evaluador de calidad de vídeo generado. Puntúa 0-100 con criterio ESTRICTO.
Uso: evaluar.py <video.mp4> [--json]

Mide lo que el ojo percibe como "se degrada" y "no es congruente":
  1. GRADACIÓN   (35 pts) entropía tonal de la cara: su caída = aspecto de cartón
  2. TEXTURA     (25 pts) energía de bordes: su crecimiento = sobre-realce
  3. CROMA       (15 pts) dispersión entre canales = aberración cromática
  4. AUDIO       (15 pts) homogeneidad tonal a lo largo de la pieza
  5. ESTABILIDAD (10 pts) ausencia de saltos bruscos entre muestras contiguas
Cada bloque se puntúa por la DERIVA entre el principio y el final, no por el
valor absoluto: un vídeo uniformemente mediocre no debe puntuar como uno que
empieza bien y acaba mal, pero tampoco se premia la uniformidad de lo malo.
"""
import subprocess, sys, math, collections, json, os, tempfile

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=False)

def dur(v):
    r = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                        "-of","default=noprint_wrappers=1:nokey=1",v],
                       capture_output=True, text=True)
    return float(r.stdout.strip())

def frame(v, t, out, crop=None):
    vf = f"crop={crop}," if crop else ""
    subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-ss",str(t),"-i",v,
                    "-vf",vf.rstrip(",") if vf else "null","-frames:v","1","-update","1",out],
                   capture_output=True)

def gray_bytes(png, extra=""):
    vf = "format=gray" + (","+extra if extra else "")
    r = run(["ffmpeg","-v","error","-i",png,"-vf",vf,"-f","rawvideo","-"])
    return r.stdout

def entropia(png):
    b = gray_bytes(png)
    if not b: return None
    c = collections.Counter(b); n = len(b)
    return -sum((k/n)*math.log2(k/n) for k in c.values())

def bordes(png):
    # sigma 1.1 antes del sobel: el grano fino no cuenta como borde estructural
    b = gray_bytes(png, "gblur=sigma=1.1,sobel")
    return sum(b)/len(b) if b else None

def croma_disp(png):
    vals = []
    for ch in "rgb":
        r = run(["ffmpeg","-v","error","-i",png,"-vf",
                 f"gblur=sigma=1.1,format=rgb24,extractplanes={ch},sobel","-f","rawvideo","-"])
        if not r.stdout: return None
        vals.append(sum(r.stdout)/len(r.stdout))
    return max(vals)-min(vals)

def audio_banda(v, t, f_lo, f_hi):
    filt = f"highpass=f={f_lo},lowpass=f={f_hi},astats=metadata=1:reset=0"
    r = subprocess.run(["ffmpeg","-v","info","-ss",str(t),"-t","3","-i",v,"-vn",
                        "-af",filt,"-f","null","-"], capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if "RMS level dB" in line:
            try: return float(line.split(":")[-1].strip())
            except: return None
    return None

def deriva_pts(ini, fin, tol_buena, tol_mala, max_pts, invertir=False):
    """Puntúa la deriva relativa. tol_buena = deriva sin penalización."""
    if ini is None or fin is None or ini == 0: return 0.0, 0.0
    d = (fin-ini)/abs(ini)
    if invertir: d = -d          # para métricas donde bajar es malo
    d = max(0.0, d)              # solo penaliza la deriva en la dirección mala
    if d <= tol_buena: p = max_pts
    elif d >= tol_mala: p = 0.0
    else: p = max_pts * (1 - (d-tol_buena)/(tol_mala-tol_buena))
    return p, d*100

def mad(a,b):
    r = run(["ffmpeg","-v","error","-i",a,"-i",b,"-filter_complex",
             "[0:v][1:v]blend=all_mode=difference,format=gray","-f","rawvideo","-"])
    return sum(r.stdout)/len(r.stdout) if r.stdout else None

def transiciones(v, D, seg, T):
    """Compara el salto en cada unión con el movimiento natural del propio plano.
    Una transición rígida (anclada) salta MUCHO más que el movimiento normal."""
    if not seg or seg<=0 or seg>=D: return None
    fps=24.0; ratios=[]
    n=int(round(D/seg))
    for k in range(1,n):
        t=k*seg
        a=os.path.join(T,f"ja{k}.png"); b=os.path.join(T,f"jb{k}.png")
        c=os.path.join(T,f"jc{k}.png"); d=os.path.join(T,f"jd{k}.png")
        frame(v,t-1/fps,a); frame(v,t+1/fps,b)          # a través de la unión
        frame(v,t+0.6,c);   frame(v,t+0.6+2/fps,d)      # movimiento natural cercano
        if not all(os.path.exists(x) for x in (a,b,c,d)): continue
        salto=mad(a,b); nat=mad(c,d)
        if salto and nat and nat>0: ratios.append(salto/nat)
    return ratios or None

def evaluar(v, seg=None):
    D = dur(v)
    T = tempfile.mkdtemp()
    # 7 muestras a lo largo de la pieza; recorte central = la cara
    ts = [D*x for x in (0.04,0.20,0.36,0.52,0.68,0.84,0.96)]
    W = subprocess.run(["ffprobe","-v","error","-select_streams","v","-show_entries",
                        "stream=width,height","-of","csv=p=0",v],capture_output=True,text=True).stdout.strip()
    w,h = [int(x) for x in W.split(",")[:2]]
    cw,ch = int(w*0.45), int(h*0.6); cx,cy = int(w*0.28), int(h*0.22)
    crop = f"{cw}:{ch}:{cx}:{cy}"
    ent, bor, cro = [], [], []
    for i,t in enumerate(ts):
        p = os.path.join(T,f"f{i}.png")
        frame(v,t,p,crop)
        if os.path.exists(p):
            ent.append(entropia(p)); bor.append(bordes(p)); cro.append(croma_disp(p))
    ent=[x for x in ent if x]; bor=[x for x in bor if x]; cro=[x for x in cro if x]
    if len(ent)<4: return None

    res = {}
    # 1 GRADACIÓN: que la entropía NO caiga (caída = cartón). 35 pts
    p1,d1 = deriva_pts(ent[0], ent[-1], 0.02, 0.18, 30.0, invertir=True)
    res["gradacion"] = {"pts":round(p1,1),"max":30,"deriva_%":round(-d1,1),
                        "ini":round(ent[0],3),"fin":round(ent[-1],3)}
    # 2 TEXTURA: que los bordes NO crezcan (crecimiento = sobre-realce). 25 pts
    p2,d2 = deriva_pts(bor[0], bor[-1], 0.05, 0.45, 20.0)
    res["textura"] = {"pts":round(p2,1),"max":20,"deriva_%":round(d2,1),
                      "ini":round(bor[0],2),"fin":round(bor[-1],2)}
    # 3 CROMA: que la dispersión NO crezca. 15 pts
    p3,d3 = deriva_pts(cro[0], cro[-1], 0.08, 0.55, 12.0)
    res["croma"] = {"pts":round(p3,1),"max":12,"deriva_%":round(d3,1),
                    "ini":round(cro[0],2),"fin":round(cro[-1],2)}
    # 4 AUDIO: homogeneidad de graves y agudos. 15 pts
    lo=[audio_banda(v,t,40,250) for t in ts]; hi=[audio_banda(v,t,3000,12000) for t in ts]
    lo=[x for x in lo if x is not None]; hi=[x for x in hi if x is not None]
    if len(lo)>=4 and len(hi)>=4:
        disp = ((max(lo)-min(lo)) + (max(hi)-min(hi)))/2
        p4 = 12.0 if disp<=2.5 else (0.0 if disp>=11.0 else 12.0*(1-(disp-2.5)/8.5))
        res["audio"]={"pts":round(p4,1),"max":12,"dispersion_dB":round(disp,2)}
    else:
        p4=0.0; res["audio"]={"pts":0,"max":12,"dispersion_dB":None}
    # 5 ESTABILIDAD: sin saltos bruscos de entropía entre muestras. 10 pts
    saltos=[abs(ent[i+1]-ent[i])/ent[i] for i in range(len(ent)-1)]
    peor=max(saltos)
    p5 = 8.0 if peor<=0.03 else (0.0 if peor>=0.15 else 8.0*(1-(peor-0.03)/0.12))
    res["estabilidad"]={"pts":round(p5,1),"max":8,"peor_salto_%":round(peor*100,1)}

    # 6 TRANSICIONES: el salto en la unión no debe superar el movimiento natural
    rt = transiciones(v, D, seg, T)
    if rt:
        peor=max(rt)
        p6 = 18.0 if peor<=1.2 else (0.0 if peor>=4.0 else 18.0*(1-(peor-1.2)/2.8))
        res["transiciones"]={"pts":round(p6,1),"max":18,"peor_ratio":round(peor,2),
                             "ratios":[round(x,2) for x in rt]}
    else:
        p6=18.0; res["transiciones"]={"pts":18.0,"max":18,"peor_ratio":None,"nota":"sin uniones"}
    total = p1+p2+p3+p4+p5+p6
    res["TOTAL"]=round(total,1)
    res["serie_entropia"]=[round(x,3) for x in ent]
    res["serie_bordes"]=[round(x,2) for x in bor]
    subprocess.run(["rm","-rf",T])
    return res

if __name__=="__main__":
    v=sys.argv[1]
    seg=None
    for i,a in enumerate(sys.argv):
        if a=="--seg" and i+1<len(sys.argv): seg=float(sys.argv[i+1])
    r=evaluar(v, seg)
    if r is None: print("no evaluable"); sys.exit(1)
    if "--json" in sys.argv: print(json.dumps(r,indent=1)); sys.exit(0)
    print(f"╔══ {os.path.basename(v)}")
    for k in ("gradacion","textura","croma","audio","estabilidad","transiciones"):
        d=r[k]; extra=" ".join(f"{a}={b}" for a,b in d.items() if a not in("pts","max"))
        barra="█"*int(d["pts"]/d["max"]*20)
        print(f"║ {k:12s} {d['pts']:5.1f}/{d['max']:<3.0f} {barra:<20s} {extra}")
    print(f"╚══ TOTAL {r['TOTAL']}/100")
    print(f"   entropía: {r['serie_entropia']}")
    print(f"   bordes:   {r['serie_bordes']}")
