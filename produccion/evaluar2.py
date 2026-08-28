#!/usr/bin/env python3
"""
Evaluador ANTI-TRAMPA. El primer plano es la REFERENCIA (lo que se ve natural).
Todo lo que se aleje de su carácter penaliza, tanto por perder como por AÑADIR.
Diseñado tras detectar que el evaluador anterior premiaba inyectar grano y ruido.
Uso: evaluar2.py <video> [--seg <s>]
"""
import subprocess, sys, math, collections, os, tempfile

def run(c): return subprocess.run(c, capture_output=True, text=False)
def dur(v):
    r=subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                      "-of","default=noprint_wrappers=1:nokey=1",v],capture_output=True,text=True)
    return float(r.stdout.strip())
def frame(v,t,out,crop=None):
    vf = f"crop={crop}" if crop else "null"
    subprocess.run(["ffmpeg","-nostdin","-y","-v","error","-ss",str(t),"-i",v,"-vf",vf,
                    "-frames:v","1","-update","1",out],capture_output=True)
def gb(png,vf):
    r=run(["ffmpeg","-v","error","-i",png,"-vf",vf,"-f","rawvideo","-"]); return r.stdout

def entropia_limpia(png):
    """Entropía TRAS quitar ruido: el grano sintético no la infla."""
    b=gb(png,"format=gray,gblur=sigma=0.9")
    if not b: return None
    c=collections.Counter(b); n=len(b)
    return -sum((k/n)*math.log2(k/n) for k in c.values())

def ruido_alta_frec(png):
    """Energía de alta frecuencia tras restar la versión suavizada = grano."""
    a=gb(png,"format=gray"); s=gb(png,"format=gray,gblur=sigma=0.9")
    if not a or not s or len(a)!=len(s): return None
    return sum(abs(x-y) for x,y in zip(a,s))/len(a)

def bordes_estr(png):
    b=gb(png,"format=gray,gblur=sigma=1.3,sobel")
    return sum(b)/len(b) if b else None

def croma_disp(png):
    v=[]
    for ch in "rgb":
        r=gb(png,f"gblur=sigma=1.3,format=rgb24,extractplanes={ch},sobel")
        if not r: return None
        v.append(sum(r)/len(r))
    return max(v)-min(v)

def audio_piso(v,t):
    """RMS en 1.5s: el mínimo de la serie aproxima el suelo de ruido."""
    r=subprocess.run(["ffmpeg","-v","info","-ss",str(t),"-t","1.5","-i",v,"-vn",
                      "-af","astats=metadata=1:reset=0","-f","null","-"],capture_output=True,text=True)
    for l in r.stderr.splitlines():
        if "RMS level dB" in l:
            try: return float(l.split(":")[-1].strip())
            except: return None
    return None

def pts_bidir(ref, val, tol, lim, maxp):
    """Penaliza desviarse de la referencia en CUALQUIER dirección."""
    if ref is None or val is None or ref==0: return 0.0, 0.0
    d=abs(val-ref)/abs(ref)
    if d<=tol: p=maxp
    elif d>=lim: p=0.0
    else: p=maxp*(1-(d-tol)/(lim-tol))
    return p, d*100

def evaluar(v, seg=None):
    D=dur(v); T=tempfile.mkdtemp()
    W=subprocess.run(["ffprobe","-v","error","-select_streams","v","-show_entries",
                      "stream=width,height","-of","csv=p=0",v],capture_output=True,text=True).stdout.strip()
    w,h=[int(x) for x in W.split(",")[:2]]
    cara=f"{int(w*0.45)}:{int(h*0.6)}:{int(w*0.28)}:{int(h*0.22)}"
    plano=f"{int(w*0.20)}:{int(h*0.25)}:{int(w*0.02)}:{int(h*0.03)}"   # esquina = fondo
    ts=[D*x for x in (0.04,0.20,0.36,0.52,0.68,0.84,0.96)]
    ent,bor,cro,hf=[],[],[],[]
    for i,t in enumerate(ts):
        pc=os.path.join(T,f"c{i}.png"); pp=os.path.join(T,f"p{i}.png")
        frame(v,t,pc,cara); frame(v,t,pp,plano)
        if os.path.exists(pc):
            ent.append(entropia_limpia(pc)); bor.append(bordes_estr(pc)); cro.append(croma_disp(pc))
        if os.path.exists(pp):
            hf.append(ruido_alta_frec(pp))
    f=lambda L:[x for x in L if x is not None]
    ent,bor,cro,hf=f(ent),f(bor),f(cro),f(hf)
    if len(ent)<4: return None
    res={}
    # 1 GRADACIÓN 25 — no perder gradación real (medida sin ruido)
    p1,d1=pts_bidir(ent[0],ent[-1],0.03,0.20,25.0)
    res["gradacion"]={"pts":round(p1,1),"max":25,"desv_%":round(d1,1),"ini":round(ent[0],3),"fin":round(ent[-1],3)}
    # 2 ESTRUCTURA 20 — bordes estructurales estables
    p2,d2=pts_bidir(bor[0],bor[-1],0.05,0.40,20.0)
    res["estructura"]={"pts":round(p2,1),"max":20,"desv_%":round(d2,1),"ini":round(bor[0],2),"fin":round(bor[-1],2)}
    # 3 GRANO 20 — NO añadir ruido de alta frecuencia sobre la referencia
    peor=max(hf) if hf else None
    if peor is not None:
        # umbral ABSOLUTO: por debajo de 0.35 el grano es imperceptible,
        # da igual el ratio (evita dividir por casi-cero)
        if peor<=0.35:
            p3=20.0; res["grano"]={"pts":20.0,"max":20,"peor_abs":round(peor,3),
                                   "nota":"imperceptible"}
        else:
            base=max(hf[0],0.35)
            exc=max(0.0,(peor-base)/base)
            p3=20.0 if exc<=0.10 else (0.0 if exc>=0.80 else 20.0*(1-(exc-0.10)/0.70))
            res["grano"]={"pts":round(p3,1),"max":20,"exceso_%":round(exc*100,1),
                          "ref":round(base,2),"peor":round(peor,2)}
    else: p3=0.0; res["grano"]={"pts":0,"max":20}
    # 4 CROMA 10
    p4,d4=pts_bidir(cro[0],cro[-1],0.10,0.50,10.0)
    res["croma"]={"pts":round(p4,1),"max":10,"desv_%":round(d4,1)}
    # 5 AUDIO 15 — el suelo de ruido NO debe subir respecto al más limpio
    pis=[audio_piso(v,t) for t in ts]; pis=[x for x in pis if x is not None]
    if len(pis)>=4:
        piso=min(pis)                       # nivel absoluto del suelo de ruido
        rango=max(pis)-piso                 # y su variación
        # -34 dB o menos = limpio · -18 dB = zumbido evidente
        pa=10.0 if piso<=-34 else (0.0 if piso>=-18 else 10.0*(( -18-piso)/16.0))
        pb=5.0 if rango<=7.0 else (0.0 if rango>=16.0 else 5.0*(1-(rango-7.0)/9.0))
        p5=pa+pb
        res["audio"]={"pts":round(p5,1),"max":15,"piso_dB":round(piso,1),
                      "rango_dB":round(rango,1),"nivel":round(pa,1),"estab":round(pb,1)}
    else: p5=0.0; res["audio"]={"pts":0,"max":15}
    # 6 TRANSICIONES 10
    p6=10.0; res["transiciones"]={"pts":10.0,"max":10,"nota":"sin uniones"}
    if seg and 0<seg<D:
        rs=[]
        for k in range(1,int(round(D/seg))):
            t=k*seg
            for nm,tt in (("a",t-1/24),("b",t+1/24),("c",t+0.6),("d",t+0.6+2/24)):
                frame(v,tt,os.path.join(T,f"{nm}{k}.png"))
            def mad(x,y):
                r=run(["ffmpeg","-v","error","-i",os.path.join(T,f"{x}{k}.png"),
                       "-i",os.path.join(T,f"{y}{k}.png"),"-filter_complex",
                       "[0:v][1:v]blend=all_mode=difference,format=gray","-f","rawvideo","-"])
                return sum(r.stdout)/len(r.stdout) if r.stdout else None
            s_,n_=mad("a","b"),mad("c","d")
            if s_ and n_ and n_>0: rs.append(s_/n_)
        if rs:
            pe=max(rs)
            p6=10.0 if pe<=1.3 else (0.0 if pe>=4.0 else 10.0*(1-(pe-1.3)/2.7))
            res["transiciones"]={"pts":round(p6,1),"max":10,"peor":round(pe,2)}
    res["TOTAL"]=round(p1+p2+p3+p4+p5+p6,1)
    res["_ent"]=[round(x,3) for x in ent]; res["_hf"]=[round(x,2) for x in hf]
    subprocess.run(["rm","-rf",T]); return res

if __name__=="__main__":
    v=sys.argv[1]; seg=None
    for i,a in enumerate(sys.argv):
        if a=="--seg" and i+1<len(sys.argv): seg=float(sys.argv[i+1])
    r=evaluar(v,seg)
    if not r: print("no evaluable"); sys.exit(1)
    print(f"╔══ {os.path.basename(v)}")
    for k in ("gradacion","estructura","grano","croma","audio","transiciones"):
        d=r[k]; ex=" ".join(f"{a}={b}" for a,b in d.items() if a not in("pts","max"))
        print(f"║ {k:13s} {d['pts']:5.1f}/{d['max']:<3.0f} {'█'*int(d['pts']/d['max']*18):<18s} {ex}")
    print(f"╚══ TOTAL {r['TOTAL']}/100")
    print(f"   entropía(limpia): {r['_ent']}")
    print(f"   grano:            {r['_hf']}")
