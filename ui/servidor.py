#!/usr/bin/env python3
"""UI local del proyecto: ver lo generado, lanzar tandas y seguir el progreso.

Por que existe: Steven no veia los resultados. Los videos estaban en
videos/entregas/ y el estado, repartido entre logs de /tmp y comandos sueltos que
solo yo ejecutaba. Tambien reporto tres veces "veo la PC quieta" sin forma de
distinguir una espera deliberada de un cuelgue.

Esto no genera nada por si mismo: lee el estado real (procesos, GPU, ficheros) y
lanza los mismos scripts del pipeline. Si algo falla, falla igual que en consola.

Uso:  ui/servidor.py [puerto]        (por defecto 8080)
"""
import http.server, socketserver, json, os, subprocess, glob, urllib.parse, threading, sys, re, time

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUERTO = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
_trabajos = {}   # nombre -> {"log": ruta, "proc": Popen}

def _sh(c):
    try: return subprocess.run(c, capture_output=True, text=True, timeout=15).stdout.strip()
    except Exception: return ""

def gpus():
    out = _sh(["nvidia-smi","--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
               "--format=csv,noheader,nounits"])
    r = []
    for l in out.splitlines():
        p = [x.strip() for x in l.split(",")]
        if len(p) >= 5:
            r.append({"i":p[0],"nombre":p[1],"uso":int(p[2]),
                      "usada":int(p[3]),"total":int(p[4]),
                      "libre":int(p[4])-int(p[3])})
    return r

def ram():
    try:
        mx=int(open("/sys/fs/cgroup/memory.max").read().strip())
        cur=int(open("/sys/fs/cgroup/memory.current").read().strip())
        return {"total_gb":round(mx/2**30,1),"usada_gb":round(cur/2**30,1),
                "libre_gb":round((mx-cur)/2**30,1)}
    except Exception:
        return {"total_gb":0,"usada_gb":0,"libre_gb":0}

def generando():
    """True si hay un sd-cli vivo. Se mira por NOMBRE exacto de proceso: un
    patron sobre la linea de comandos haria match con este propio servidor."""
    out = _sh(["ps","-eo","comm"])
    return any(l.strip()=="sd-cli" for l in out.splitlines())

def videos():
    r=[]
    for d,etiq in (("videos/entregas","entrega"),("videos/experimentos","experimento")):
        for f in sorted(glob.glob(os.path.join(RAIZ,d,"*.mp4")), key=os.path.getmtime, reverse=True):
            st=os.stat(f)
            r.append({"nombre":os.path.basename(f),"carpeta":d,"etiqueta":etiq,
                      "mb":round(st.st_size/2**20,1),
                      "fecha":time.strftime("%d/%m %H:%M", time.localtime(st.st_mtime)),
                      "url":"/video/"+urllib.parse.quote(d+"/"+os.path.basename(f))})
    return r

def guiones():
    r=[]
    for f in sorted(glob.glob(os.path.join(RAIZ,"produccion/guiones/**/*.guion"), recursive=True)):
        rel=os.path.relpath(f,RAIZ)
        try: txt=open(f, encoding="utf-8").read()
        except Exception: continue
        n=len(re.findall(r'^(TOMA|HABLA)\|', txt, re.M))
        tipo=(re.search(r'^@TIPO\s+(\S+)', txt, re.M) or [None,"habla"])[1]
        r.append({"ruta":rel,"nombre":os.path.basename(f)[:-6],"tomas":n,"tipo":tipo})
    return r

def logs_activos(n=3):
    """Los logs mas recientes del pipeline, los lance quien los lance.

    La primera version solo mostraba las tandas arrancadas DESDE la UI, asi que
    una cola lanzada por consola —que es como se lanzan casi todas— no aparecia
    en ninguna parte. Justo el hueco que hacia preguntar "¿esta trabajando?".
    """
    r=[]
    # SOLO se leen logs de dentro del proyecto. La primera version tambien
    # rastreaba /tmp/claude-*/, que es escribible por otros procesos: su
    # contenido acabaria en el navegador de quien abra la UI. Si hace falta mirar
    # un log de fuera, se apunta explicitamente con SCRATCH_LOGS.
    pats=[os.path.join(RAIZ,"produccion/logs/*.log")]
    scratch=os.environ.get("SCRATCH_LOGS")
    if scratch and os.path.isdir(scratch):
        pats.append(os.path.join(os.path.realpath(scratch),"*.log"))
    fs=[]
    for p in pats: fs.extend(glob.glob(p))
    fs=[f for f in fs if os.path.isfile(f)]
    fs.sort(key=os.path.getmtime, reverse=True)
    ahora=time.time()
    for f in fs[:n]:
        edad=ahora-os.path.getmtime(f)
        try:
            with open(f, errors="ignore") as fh: txt=fh.read()[-6000:].replace("\r","\n")
        except Exception: continue
        lineas=[l.rstrip() for l in txt.splitlines()
                if l.strip() and not l.lstrip().startswith("|") and "###" not in l]
        if not lineas: continue
        r.append({"nombre":os.path.basename(f)[:-4],
                  "fresco": edad < 300,
                  "hace": f"{int(edad)}s" if edad<120 else f"{int(edad/60)} min",
                  "ultimas":lineas[-10:]})
    return r

def estado_trabajos():
    r=[]
    for nombre,t in list(_trabajos.items()):
        vivo = t["proc"].poll() is None
        cola=""
        try:
            with open(t["log"], errors="ignore") as fh:
                cola = fh.read()[-4000:].replace("\r","\n")
        except Exception: pass
        lineas=[l for l in cola.splitlines() if l.strip() and not l.startswith("  |")]
        r.append({"nombre":nombre,"vivo":vivo,"ultimas":lineas[-12:]})
    return r

def lanzar(guion, nombre, frames, w, h, pasos):
    """Lanza una tanda con el MISMO script del pipeline. No duplica logica."""
    if generando():
        return {"ok":False,"error":"Ya hay una generacion en curso. El cerrojo la "
                "serializaria igualmente, pero es mejor no encolar a ciegas."}
    g=os.path.join(RAIZ,guion)
    if not os.path.isfile(g): return {"ok":False,"error":f"no existe el guion {guion}"}
    nombre=re.sub(r'[^A-Za-z0-9_-]','',nombre) or "pieza"
    logs=os.path.join(RAIZ,"produccion/logs"); os.makedirs(logs,exist_ok=True)
    log=os.path.join(logs,f"ui-{nombre}.log")
    env=dict(os.environ, DEST=os.path.join(RAIZ,"videos/entregas"))
    fh=open(log,"w")
    p=subprocess.Popen([os.path.join(RAIZ,"produccion/producir-anclado.sh"),
                        g,nombre,str(frames),str(w),str(h),str(pasos)],
                       cwd=RAIZ, stdout=fh, stderr=subprocess.STDOUT, env=env,
                       stdin=subprocess.DEVNULL)
    _trabajos[nombre]={"log":log,"proc":p}
    return {"ok":True,"nombre":nombre,"log":os.path.relpath(log,RAIZ)}

PAGINA = """<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MiniMax-H3</title><style>
:root{--bg:#0f1113;--panel:#17191c;--linea:#2a2d31;--txt:#e6e8ea;--sec:#9aa0a6;--ok:#4ade80;--busy:#fbbf24;--acc:#60a5fa}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);
font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{padding:14px 20px;border-bottom:1px solid var(--linea);display:flex;gap:22px;align-items:center;flex-wrap:wrap}
h1{font-size:15px;margin:0;font-weight:600;letter-spacing:.2px}
.chip{background:var(--panel);border:1px solid var(--linea);border-radius:999px;padding:4px 11px;font-size:12px;color:var(--sec)}
.chip b{color:var(--txt);font-weight:600}
main{display:grid;grid-template-columns:minmax(0,2fr) minmax(300px,1fr);gap:18px;padding:18px;align-items:start}
@media(max-width:900px){main{grid-template-columns:1fr}}
.panel{background:var(--panel);border:1px solid var(--linea);border-radius:10px;padding:14px}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.7px;color:var(--sec);margin:0 0 12px}
.vids{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px}
.v{background:#000;border:1px solid var(--linea);border-radius:8px;overflow:hidden}
.v video{width:100%;display:block;background:#000}
.v .m{padding:8px 10px;font-size:12px;color:var(--sec);background:var(--panel)}
.v .m b{color:var(--txt);font-weight:500;display:block;word-break:break-all;font-size:12px}
.tag{display:inline-block;font-size:10px;padding:1px 6px;border-radius:4px;margin-top:4px}
.tag.entrega{background:#14532d;color:#86efac}.tag.experimento{background:#3f3f46;color:#d4d4d8}
label{display:block;font-size:11px;color:var(--sec);margin:9px 0 3px}
select,input{width:100%;background:#0f1113;border:1px solid var(--linea);color:var(--txt);
padding:7px 9px;border-radius:6px;font:inherit;font-size:13px}
button{width:100%;margin-top:13px;background:var(--acc);color:#06131f;border:0;padding:9px;
border-radius:6px;font:inherit;font-weight:600;cursor:pointer}
button:disabled{background:#2a2d31;color:var(--sec);cursor:not-allowed}
pre{background:#0b0d0f;border:1px solid var(--linea);border-radius:6px;padding:9px;
font-size:11px;max-height:190px;overflow:auto;color:var(--sec);white-space:pre-wrap;margin:6px 0 0}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:1px}
.dot.on{background:var(--busy)}.dot.off{background:#3f3f46}
.barra{height:4px;background:#0b0d0f;border-radius:2px;overflow:hidden;margin-top:5px}
.barra i{display:block;height:100%;background:var(--acc)}
.nota{font-size:11px;color:var(--sec);margin-top:9px;line-height:1.45}
</style></head><body>
<header>
  <h1>MiniMax-H3</h1>
  <span class="chip" id="c-gen"><span class="dot off"></span>—</span>
  <span class="chip" id="c-gpu0">GPU0 —</span>
  <span class="chip" id="c-gpu1">GPU1 —</span>
  <span class="chip" id="c-ram">RAM —</span>
</header>
<main>
  <div>
    <div class="panel"><h2>Vídeos generados</h2><div class="vids" id="vids"></div></div>
  </div>
  <div>
    <div class="panel">
      <h2>Generar</h2>
      <label>Guion</label><select id="guion"></select>
      <label>Nombre de la pieza</label><input id="nombre" value="pieza">
      <label>Fotogramas por toma <span id="seg" style="color:var(--sec)"></span></label>
      <select id="frames">
        <option value="107">107 — 4,5 s</option>
        <option value="192">192 — 8,0 s</option>
        <option value="345" selected>345 — 14,4 s</option>
      </select>
      <label>Resolución</label>
      <select id="res"><option value="736x416" selected>736 × 416</option>
      <option value="512x288">512 × 288 (da aberraciones)</option></select>
      <button id="btn">Generar</button>
      <div class="nota" id="nota"></div>
    </div>
    <div class="panel" style="margin-top:16px"><h2>Actividad del pipeline</h2><div id="logs"></div></div>\n    <div class="panel" style="margin-top:16px"><h2>Lanzado desde aquí</h2><div id="trab"></div></div>
  </div>
</main>
<script>
const $=s=>document.querySelector(s);
// Todo lo que entra en innerHTML se escapa. El contenido no es de fiar: los
// nombres de fichero los pone quien genera, y las lineas de log salen de
// ficheros en rutas escribibles por otros procesos. Una linea con <script> se
// ejecutaria en el navegador de quien abra la UI.
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let guionesCargados=false;
function pinta(d){
  $('#c-gen').innerHTML='<span class="dot '+(d.generando?'on':'off')+'"></span>'+
    (d.generando?'generando':'en reposo');
  d.gpus.forEach(g=>{
    const e=$('#c-gpu'+g.i); if(!e)return;
    e.innerHTML='GPU'+g.i+' <b>'+g.uso+'%</b> · '+(g.libre/1024).toFixed(1)+' GB libres'+
      '<div class="barra"><i style="width:'+(100*g.usada/g.total)+'%"></i></div>';
  });
  $('#c-ram').innerHTML='RAM <b>'+d.ram.libre_gb+'</b> / '+d.ram.total_gb+' GB libres';
  $('#vids').innerHTML = d.videos.length ? d.videos.map(v=>
    '<div class="v"><video src="'+encodeURI(v.url)+'" controls preload="metadata"></video>'+
    '<div class="m"><b>'+esc(v.nombre)+'</b>'+esc(v.mb)+' MB · '+esc(v.fecha)+
    ' <span class="tag '+(v.etiqueta==='entrega'?'entrega':'experimento')+'">'+
    esc(v.etiqueta)+'</span></div></div>').join('')
    : '<div class="nota">Todavía no hay vídeos.</div>';
  if(!guionesCargados && d.guiones.length){
    $('#guion').innerHTML=d.guiones.map(g=>'<option value="'+esc(g.ruta)+'">'+esc(g.nombre)+
      ' ('+esc(g.tomas)+' tomas, '+esc(g.tipo)+')</option>').join('');
    guionesCargados=true;
  }
  $('#btn').disabled=d.generando;
  $('#logs').innerHTML = (d.logs||[]).length ? d.logs.map(l=>
    '<div style="margin-bottom:11px"><b>'+esc(l.nombre)+'</b> <span style="color:'+
    (l.fresco?'var(--busy)':'var(--sec)')+'">'+(l.fresco?'activo':'inactivo')+
    ' · hace '+esc(l.hace)+'</span><pre>'+l.ultimas.map(esc).join('\n')+'</pre></div>').join('')
    : '<div class="nota">Sin actividad reciente del pipeline.</div>';
  $('#trab').innerHTML = d.trabajos.length ? d.trabajos.map(t=>
    '<div style="margin-bottom:11px"><b>'+esc(t.nombre)+'</b> <span style="color:var(--sec)">'+
    (t.vivo?'en curso':'terminado')+'</span><pre>'+
    (t.ultimas.map(esc).join('\n')||'sin salida todavía')+'</pre></div>').join('')
    : '<div class="nota">Ninguna tanda lanzada desde aquí. Las que se lanzaron por consola no aparecen, pero su efecto sí se ve arriba.</div>';
}
async function tic(){
  try{ pinta(await (await fetch('/api/estado')).json()); }
  catch(e){ $('#c-gen').innerHTML='<span class="dot off"></span>servidor caído'; }
}
$('#frames').onchange=()=>{const f=+$('#frames').value;$('#seg').textContent='';};
$('#btn').onclick=async()=>{
  const [w,h]=$('#res').value.split('x');
  $('#btn').disabled=true; $('#nota').textContent='lanzando…';
  const r=await (await fetch('/api/lanzar',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({guion:$('#guion').value,nombre:$('#nombre').value,
      frames:+$('#frames').value,w:+w,h:+h,pasos:20})})).json();
  $('#nota').textContent = r.ok ? 'lanzada: '+r.nombre+' · log en '+r.log : 'no se pudo: '+r.error;  // textContent: no interpreta HTML
  tic();
};
tic(); setInterval(tic,4000);
</script></body></html>"""

class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
    def _json(self,o,code=200):
        b=json.dumps(o).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path)
        if u.path=="/":
            b=PAGINA.encode()
            self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        if u.path=="/api/estado":
            return self._json({"gpus":gpus(),"ram":ram(),"generando":generando(),
                               "videos":videos(),"guiones":guiones(),"trabajos":estado_trabajos(),"logs":logs_activos()})
        if u.path.startswith("/video/"):
            rel=urllib.parse.unquote(u.path[len("/video/"):])
            # Nunca servir fuera del proyecto: se resuelve y se comprueba el prefijo.
            f=os.path.realpath(os.path.join(RAIZ,rel))
            if not f.startswith(os.path.realpath(RAIZ)+os.sep) or not os.path.isfile(f):
                return self._json({"error":"ruta no permitida"},403)
            self.send_response(200); self.send_header("Content-Type","video/mp4")
            self.send_header("Content-Length",str(os.path.getsize(f)))
            self.send_header("Accept-Ranges","none"); self.end_headers()
            with open(f,"rb") as fh:
                while True:
                    c=fh.read(65536)
                    if not c: break
                    try: self.wfile.write(c)
                    except BrokenPipeError: return
            return
        self._json({"error":"no encontrado"},404)
    def do_POST(self):
        if urllib.parse.urlparse(self.path).path!="/api/lanzar":
            return self._json({"error":"no encontrado"},404)
        n=int(self.headers.get("Content-Length",0))
        try: d=json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self._json({"ok":False,"error":"json invalido"},400)
        self._json(lanzar(d.get("guion",""), d.get("nombre","pieza"),
                          int(d.get("frames",345)), int(d.get("w",736)),
                          int(d.get("h",416)), int(d.get("pasos",20))))

class Servidor(socketserver.ThreadingTCPServer):
    allow_reuse_address=True; daemon_threads=True

if __name__=="__main__":
    # 127.0.0.1 y no 0.0.0.0: es una UI local y no tiene autenticacion; escuchando
    # en todas las interfaces quedaria expuesta a la red, y su endpoint /api/lanzar
    # arranca procesos.
    with Servidor(("127.0.0.1",PUERTO),H) as s:
        print(f"UI en http://localhost:{PUERTO}  (raiz: {RAIZ})")
        s.serve_forever()
