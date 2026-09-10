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
import glob
import fcntl
import http.server
import json
import os
import re
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.parse

CODIGO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAIZ = CODIGO
PUERTO = 8080
GUIONES_DIR = os.path.join(RAIZ, "produccion", "guiones")
OBRAS_DIR = os.path.join(RAIZ, "produccion", "obra")
VIDEOS_DIRS = (
    os.path.join(RAIZ, "videos", "entregas"),
    os.path.join(RAIZ, "videos", "experimentos"),
)
RESOLUCIONES = {(736, 416), (512, 288), (416, 736)}
MAX_CUERPO = 64 * 1024
MAX_TITULAR = 400
MAX_NOTICIA = 20_000
_trabajos = {}  # nombre -> {"log": ruta, "proc": Popen, "inicio": epoch}
_trabajos_lock = threading.RLock()
_lanzamiento_lock = threading.Lock()
_estado_cache_lock = threading.Lock()
_estado_cache = {"at": 0.0, "value": None}
FASES_ACTIVAS = {"planned", "waiting_resources", "generating", "mounting"}


def _bajo(ruta, directorio):
    """True si ruta resuelve dentro de directorio, tambien ante symlinks."""
    try:
        if os.path.islink(directorio):
            return False
        project = os.path.realpath(RAIZ)
        base = os.path.realpath(directorio)
        if os.path.commonpath((base, project)) != project:
            return False
        return os.path.commonpath((os.path.realpath(ruta), base)) == base
    except (OSError, ValueError):
        return False


def _pid_vivo(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def _runner_vivo(pid, nombre):
    """Evita que un PID reciclado deje la UI bloqueada por un estado viejo."""
    if not _pid_vivo(pid):
        return False
    try:
        with open(f"/proc/{int(pid)}/cmdline", "rb") as fh:
            arguments = [
                value.decode(errors="replace")
                for value in fh.read().split(b"\0")
                if value
            ]
    except (OSError, TypeError, ValueError):
        return False
    is_runner = any(
        os.path.basename(value) == "producir-anclado.sh" for value in arguments
    )
    return is_runner and nombre in arguments


def _obra_reservada():
    path = os.environ.get(
        "CERROJO", os.path.join(os.environ.get("TMPDIR", "/tmp"), "h3-generacion.lock")
    )
    if not os.path.exists(path):
        return False
    try:
        with open(path, "rb") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    except OSError:
        return False
    return False


def _sh(c):
    try:
        return subprocess.run(
            c, capture_output=True, text=True, timeout=15, check=False
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _json_estricto(raw):
    def reject_constant(value):
        raise ValueError(f"constante JSON no finita: {value}")

    return json.loads(raw, parse_constant=reject_constant)


def gpus():
    out = _sh(
        [
            "nvidia-smi",
            "--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ]
    )
    r = []
    for line in out.splitlines():
        p = [x.strip() for x in line.split(",")]
        try:
            if len(p) >= 5:
                usada, total = int(p[3]), int(p[4])
                r.append(
                    {
                        "i": p[0],
                        "nombre": p[1],
                        "uso": int(p[2]),
                        "usada": usada,
                        "total": total,
                        "libre": total - usada,
                    }
                )
        except ValueError:
            continue
    return r


def ram():
    try:
        with open("/sys/fs/cgroup/memory.max", encoding="ascii") as fh:
            maximum = fh.read().strip()
        with open("/sys/fs/cgroup/memory.current", encoding="ascii") as fh:
            current = int(fh.read().strip())
        if maximum == "max":
            with open("/proc/meminfo", encoding="ascii") as fh:
                total = int(fh.readline().split()[1]) * 1024
        else:
            total = int(maximum)
        return {
            "total_gb": round(total / 2**30, 1),
            "usada_gb": round(current / 2**30, 1),
            "libre_gb": round(max(0, total - current) / 2**30, 1),
        }
    except (OSError, ValueError, IndexError):
        return {"total_gb": 0, "usada_gb": 0, "libre_gb": 0}


def _leer_estado(ruta):
    try:
        if os.path.getsize(ruta) > 1024 * 1024:
            return None
        with open(ruta, encoding="utf-8") as fh:
            value = json.load(fh)
    except (OSError, ValueError, TypeError):
        return None
    if not isinstance(value, dict):
        return None
    phase = value.get("phase")
    name = value.get("name")
    updated = value.get("updated_at", "")
    if (
        not isinstance(phase, str)
        or not isinstance(name, str)
        or not isinstance(updated, str)
    ):
        return None
    for key in ("completed", "total", "pid"):
        if key in value and (
            isinstance(value[key], bool) or not isinstance(value[key], int)
        ):
            return None
    for key in ("message", "final"):
        if key in value and not isinstance(value[key], str):
            return None
    return value


def estados_durables():
    """Estados atomicos escritos por el runner, incluso si la UI se reinicio."""
    result = []
    pattern = os.path.join(OBRAS_DIR, "*", "estado.json")
    for path in glob.glob(pattern):
        if os.path.islink(path) or not _bajo(path, OBRAS_DIR):
            continue
        state = _leer_estado(path)
        if state is None:
            continue
        phase = state["phase"]
        pid = state.get("pid")
        alive = phase in FASES_ACTIVAS and _runner_vivo(pid, state["name"])
        visible_phase = "interrupted" if phase in FASES_ACTIVAS and not alive else phase
        result.append(
            {
                "nombre": state["name"],
                "fase": visible_phase,
                "vivo": alive,
                "completadas": state.get("completed"),
                "total": state.get("total"),
                "mensaje": state.get("message", ""),
                "final": state.get("final", ""),
                "actualizado": state.get("updated_at", ""),
            }
        )
    result.sort(key=lambda item: item["actualizado"], reverse=True)
    return result


def generando():
    """True durante toda la obra, incluidas esperas y montaje."""
    with _trabajos_lock:
        if any(t["proc"].poll() is None for t in _trabajos.values()):
            return True
    if any(state["vivo"] for state in estados_durables()):
        return True
    if _obra_reservada():
        return True
    # Detecta tambien generaciones arrancadas por herramientas legacy.
    out = _sh(["ps", "-eo", "comm"])
    return any(line.strip() == "sd-cli" for line in out.splitlines())


def videos():
    result = []
    for directory, label in zip(VIDEOS_DIRS, ("entrega", "experimento")):
        relative_dir = os.path.relpath(directory, RAIZ)
        candidates = glob.glob(os.path.join(directory, "*.mp4"))
        files = []
        for path in candidates:
            if os.path.islink(path) or not _bajo(path, directory):
                continue
            try:
                files.append((os.path.getmtime(path), path))
            except OSError:
                continue
        for _, path in sorted(files, reverse=True):
            try:
                st = os.stat(path)
            except OSError:
                continue
            name = os.path.basename(path)
            parsed_res = re.search(r"-(\d+)x(\d+)-", name)
            vertical = False
            if parsed_res:
                vertical = int(parsed_res.group(2)) > int(parsed_res.group(1))
            result.append(
                {
                    "nombre": name,
                    "carpeta": relative_dir,
                    "etiqueta": label,
                    "mb": round(st.st_size / 2**20, 1),
                    "fecha": time.strftime(
                        "%d/%m %H:%M", time.localtime(st.st_mtime)
                    ),
                    "vertical": vertical,
                    "url": "/video/"
                    + urllib.parse.quote_from_bytes(
                        os.fsencode(relative_dir + "/" + name),
                        safe="/",
                    ),
                }
            )
    return result


def _indice_guiones():
    result = {}
    pattern = os.path.join(GUIONES_DIR, "**", "*.guion")
    for path in sorted(glob.glob(pattern, recursive=True)):
        if (
            not os.path.isfile(path)
            or os.path.islink(path)
            or not _bajo(path, GUIONES_DIR)
        ):
            continue
        relative = os.path.relpath(path, RAIZ)
        result[relative] = path
    return result


def guiones():
    result = []
    for relative, path in _indice_guiones().items():
        try:
            if os.path.getsize(path) > 1024 * 1024:
                continue
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeError):
            continue
        number = len(re.findall(r"^(TOMA|HABLA)\|", text, re.M))
        match = re.search(r"^@TIPO\s+(\S+)", text, re.M)
        take_type = match.group(1) if match else "habla"
        result.append(
            {
                "ruta": relative,
                "nombre": os.path.basename(path)[:-6],
                "tomas": number,
                "tipo": take_type,
            }
        )
    return result


def logs_activos(n=3):
    """Los logs mas recientes del pipeline, los lance quien los lance.

    La primera version solo mostraba las tandas arrancadas DESDE la UI, asi que
    una cola lanzada por consola —que es como se lanzan casi todas— no aparecia
    en ninguna parte. Justo el hueco que hacia preguntar "¿esta trabajando?".
    """
    r=[]
    pattern = os.path.join(RAIZ, "produccion", "logs", "*.log")
    files = [
        path
        for path in glob.glob(pattern)
        if os.path.isfile(path)
        and not os.path.islink(path)
        and _bajo(path, os.path.join(RAIZ, "produccion", "logs"))
    ]
    files.sort(key=os.path.getmtime, reverse=True)
    now = time.time()
    for path in files[:n]:
        age = now - os.path.getmtime(path)
        try:
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                fh.seek(max(0, fh.tell() - 6000), os.SEEK_SET)
                text = fh.read().decode(errors="ignore").replace("\r", "\n")
        except OSError:
            continue
        lines = [
            line.rstrip()
            for line in text.splitlines()
            if line.strip()
            and not line.lstrip().startswith("|")
            and "###" not in line
        ]
        if not lines:
            continue
        r.append(
            {
                "nombre": os.path.basename(path)[:-4],
                "fresco": age < 300,
                "hace": f"{int(age)}s" if age < 120 else f"{int(age / 60)} min",
                "ultimas": lines[-10:],
            }
        )
    return r


def estado_trabajos():
    durable = {item["nombre"]: item for item in estados_durables()}
    result = []
    with _trabajos_lock:
        memory = list(_trabajos.items())
    for name, task in memory:
        rc = task["proc"].poll()
        tail = ""
        try:
            with open(task["log"], errors="ignore") as fh:
                tail = fh.read()[-4000:].replace("\r", "\n")
        except OSError:
            pass
        lines = [
            line
            for line in tail.splitlines()
            if line.strip() and not line.startswith("  |")
        ]
        state = durable.pop(name, None) or {}
        result.append(
            {
                "nombre": name,
                "vivo": rc is None,
                "fase": state.get("fase", "launching" if rc is None else "finished"),
                "completadas": state.get("completadas"),
                "total": state.get("total"),
                "mensaje": state.get("mensaje", ""),
                "rc": rc,
                "ultimas": lines[-12:],
                "actualizado": state.get("actualizado", ""),
            }
        )
    for state in durable.values():
        message = state.get("mensaje", "")
        result.append(
            {
                **state,
                "rc": None,
                "ultimas": [message] if message else [],
            }
        )
    result.sort(key=lambda item: item.get("actualizado", ""), reverse=True)
    return result


def _entero(value, field):
    if isinstance(value, bool):
        raise ValueError(f"{field} debe ser un entero")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    raise ValueError(f"{field} debe ser un entero exacto")


def _validar_lanzamiento(guion, nombre, frames, width, height, steps):
    scripts = _indice_guiones()
    if not isinstance(guion, str) or guion not in scripts:
        raise ValueError("el guion no pertenece al catalogo permitido")
    if not isinstance(nombre, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", nombre
    ):
        raise ValueError(
            "nombre invalido: usa 1-64 letras, numeros, guion o guion bajo"
        )
    frames = _entero(frames, "frames")
    width = _entero(width, "w")
    height = _entero(height, "h")
    steps = _entero(steps, "pasos")
    if frames < 22 or frames > 345 or (frames - 5) % 17:
        raise ValueError("frames debe cumplir 17k+5 y estar entre 22 y 345")
    if (width, height) not in RESOLUCIONES:
        raise ValueError("resolucion no habilitada en esta maquina")
    if steps < 1 or steps > 50:
        raise ValueError("pasos debe estar entre 1 y 50")
    return scripts[guion], frames, width, height, steps


def _preflight(path, nombre, frames, width, height, steps):
    process = subprocess.run(
        [
            sys.executable,
            os.path.join(RAIZ, "harness", "planificar.py"),
            path,
            "--nombre",
            nombre,
            "--frames",
            str(frames),
            "--width",
            str(width),
            "--height",
            str(height),
            "--steps",
            str(steps),
            "--fps",
            "24",
            "--seed",
            os.environ.get("SEED", "100"),
            "--model-id",
            "preflight-ui",
        ],
        cwd=RAIZ,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if process.returncode:
        detail = process.stderr.strip().splitlines()
        raise ValueError(detail[-1] if detail else "el guion no supera el preflight")
    try:
        plan = json.loads(process.stdout)
        return float(plan["duracion_estimada_s"]), plan.get("warnings", [])
    except (ValueError, KeyError, TypeError) as exc:
        raise ValueError("el preflight no devolvio un plan valido") from exc


def lanzar(guion, nombre, frames, w, h, pasos):
    """Lanza una tanda con el MISMO script del pipeline. No duplica logica."""
    try:
        path, frames, w, h, pasos = _validar_lanzamiento(
            guion, nombre, frames, w, h, pasos
        )
        duration, warnings = _preflight(path, nombre, frames, w, h, pasos)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": str(exc)}
    return _arrancar(
        nombre,
        [
            os.path.join(RAIZ, "produccion", "producir-anclado.sh"),
            path,
            nombre,
            str(frames),
            str(w),
            str(h),
            str(pasos),
        ],
        duration,
        warnings,
    )


def _arrancar(nombre, comando, duration, warnings):
    """Arranca `comando` en segundo plano y lo registra como trabajo en curso.

    Separado de lanzar() porque el reel de noticias NO se lanza con el runner
    anclado a pelo: ese camino se salta subtitular.py y exportar-reel.sh, que
    es justo lo que convierte el montaje interno en un reel publicable. El
    unico camino completo es produccion/reel-noticias.sh.
    """
    with _lanzamiento_lock:
        if generando():
            return {
                "ok": False,
                "error": "Ya hay una obra en curso; espera a que termine o falle.",
            }
        logs = os.path.join(RAIZ, "produccion", "logs")
        destination = os.path.join(RAIZ, "videos", "entregas")
        os.makedirs(logs, exist_ok=True)
        os.makedirs(destination, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000:06d}"
        log = os.path.join(logs, f"ui-{nombre}-{stamp}.log")
        environment = dict(os.environ)
        for control in (
            "MD",
            "DEST",
            "VALIDAR",
            "REUTILIZAR_LEGACY",
            "REGENERAR_LEGACY",
            "SD_FAIL",
            "FAIL_POST",
            "SHORT_OUTPUT",
        ):
            environment.pop(control, None)
        environment.update(MD=RAIZ, DEST=destination)
        try:
            handle = open(log, "x")
            try:
                process = subprocess.Popen(
                    comando,
                    cwd=RAIZ,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    start_new_session=True,
                )
            finally:
                handle.close()
        except OSError as exc:
            return {"ok": False, "error": f"no pude arrancar el pipeline: {exc}"}
        with _trabajos_lock:
            _trabajos[nombre] = {
                "log": log,
                "proc": process,
                "inicio": time.time(),
            }
        with _estado_cache_lock:
            _estado_cache.update(at=0.0, value=None)
    return {
        "ok": True,
        "nombre": nombre,
        "log": os.path.relpath(log, RAIZ),
        "duracion_estimada_s": duration,
        "avisos": warnings,
    }


def _validar_noticia(titular, texto, nombre, segundos):
    if not isinstance(titular, str) or not titular.strip():
        raise ValueError("hace falta un titular")
    if not isinstance(texto, str):
        texto = ""
    if "\x00" in titular or "\x00" in texto:
        raise ValueError("el texto contiene un byte nulo")
    if len(titular) > MAX_TITULAR:
        raise ValueError(f"el titular supera {MAX_TITULAR} caracteres")
    if len(texto) > MAX_NOTICIA:
        raise ValueError(f"el cuerpo supera {MAX_NOTICIA} caracteres")
    if not isinstance(nombre, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", nombre
    ):
        raise ValueError(
            "nombre invalido: usa 1-64 letras, numeros, guion o guion bajo"
        )
    # Lo que se elige es la duracion del REEL, no la de la toma: cada toma dura
    # lo que su texto tarda en decirse. Antes este campo era "fotogramas por
    # toma" y ademas se multiplicaba por 3 a escondidas para el presupuesto de
    # texto, asi que elegir 107 daba un reel de 9 s que tiraba media noticia.
    segundos = _entero(segundos, "segundos")
    if segundos < 8 or segundos > 90:
        raise ValueError("la duracion del reel debe estar entre 8 y 90 segundos")
    return titular.strip(), texto, nombre, segundos


def lanzar_reel(titular, texto, nombre, segundos):
    """Lanza el reel de noticias por su UNICO camino completo.

    Antes esto componia el guion a mano y llamaba al runner anclado, que se
    queda en el montaje interno a 416x736: sin subtitulos y sin 1080x1920. La
    nota de la propia interfaz prometia las dos cosas y no llegaban. Ahora se
    delega en produccion/reel-noticias.sh, que encadena runner + subtitulos +
    export, y por tanto no hay dos definiciones de que es un reel.

    Tampoco se elige ya la duracion de la toma: cada toma dura lo que su texto
    tarda en decirse. Lo que se elige es la duracion del REEL.
    """
    try:
        titular, texto, nombre, segundos = _validar_noticia(
            titular, texto, nombre, segundos
        )
    except (ValueError, TypeError) as exc:
        return {"ok": False, "error": str(exc)}

    reel = os.path.join(RAIZ, "produccion", "reel-noticias.sh")
    if not os.path.isfile(reel):
        return {"ok": False, "error": "falta produccion/reel-noticias.sh"}

    comando = [
        reel,
        "--titular", titular,
        "--nombre", nombre,
        "--seg-objetivo", str(segundos),
    ]
    if texto:
        comando += ["--texto", texto]

    # Primero se compone y valida el guion sin tocar la GPU: asi un titular que
    # no da para un reel se rechaza al instante, con su mensaje, en vez de
    # fallar veinte minutos despues.
    entorno = dict(os.environ)
    entorno.update(MD=RAIZ, SOLO_GUION="1")
    try:
        previo = subprocess.run(
            comando, cwd=RAIZ, capture_output=True, text=True,
            timeout=60, check=False, env=entorno, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": f"no pude componer el guion: {exc}"}
    if previo.returncode:
        detalle = (previo.stderr or previo.stdout or "").strip().splitlines()
        return {
            "ok": False,
            "error": detalle[-1] if detalle else "no se pudo componer el guion",
        }

    avisos = [
        linea.strip()[len("aviso:"):].strip()
        for linea in (previo.stdout or "").splitlines()
        if linea.strip().startswith("aviso:")
    ]
    duracion = 0.0
    for linea in (previo.stdout or "").splitlines():
        match = re.search(r"([0-9]+(?:\.[0-9]+)?) s de voz", linea)
        if match:
            duracion = float(match.group(1))
            break

    return _arrancar(nombre, comando, duracion, avisos)


def snapshot_estado():
    """Una sola sonda por segundo aunque el navegador abra varios recursos."""
    with _estado_cache_lock:
        now = time.monotonic()
        cached = _estado_cache["value"]
        if cached is not None and now - _estado_cache["at"] < 1.0:
            return cached
        value = {
            "gpus": gpus(),
            "ram": ram(),
            "generando": generando(),
            "videos": videos(),
            "guiones": guiones(),
            "trabajos": estado_trabajos(),
            "logs": logs_activos(),
        }
        _estado_cache.update(at=now, value=value)
        return value


PAGINA = """<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NewsLeters · reels</title><style>
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
.vids{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:14px}
.v{background:#000;border:1px solid var(--linea);border-radius:8px;overflow:hidden}
.v video{width:100%;display:block;background:#000}
.v.vert{max-width:240px}
.v.vert video{max-height:420px;object-fit:contain}
.v .m{padding:8px 10px;font-size:12px;color:var(--sec);background:var(--panel)}
.v .m b{color:var(--txt);font-weight:500;display:block;word-break:break-all;font-size:12px}
.tag{display:inline-block;font-size:10px;padding:1px 6px;border-radius:4px;margin-top:4px}
.tag.entrega{background:#14532d;color:#86efac}.tag.experimento{background:#3f3f46;color:#d4d4d8}
label{display:block;font-size:11px;color:var(--sec);margin:9px 0 3px}
select,input,textarea{width:100%;background:#0f1113;border:1px solid var(--linea);color:var(--txt);
padding:7px 9px;border-radius:6px;font:inherit;font-size:13px}
textarea{min-height:110px;resize:vertical}
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
details{margin-top:16px}
details>summary{cursor:pointer;color:var(--sec);font-size:12px;text-transform:uppercase;letter-spacing:.7px}
</style></head><body>
<header>
  <h1>NewsLeters · reels 9:16</h1>
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
      <h2>Reel de noticias</h2>
      <label>Titular</label><input id="titular" placeholder="Lo que ha pasado, en una frase">
      <label>Cuerpo (hechos, sin inventar)</label>
      <textarea id="cuerpo" placeholder="Pega aquí la noticia. Se dirá lo que quepa en la duración elegida."></textarea>
      <label>Nombre del corte</label><input id="nombre-reel" value="corte">
      <label>Duración del reel</label>
      <select id="segundos-reel">
        <option value="16">16 s · sólo el titular y un dato</option>
        <option value="32" selected>32 s · reel completo</option>
        <option value="48">48 s · la noticia entera</option>
      </select>
      <button id="btn-reel">Generar reel 9:16</button>
      <div class="nota" id="nota-reel">416×736 nativo, subtítulos quemados ya a 1080×1920, export 9:16. No inventa hechos: cada frase sale literal de lo que pegas. Cada toma dura lo que su texto tarda en decirse.</div>
    </div>
    <details class="panel" style="margin-top:16px">
      <summary>Guion avanzado</summary>
      <label>Guion</label><select id="guion"></select>
      <label>Nombre de la pieza</label><input id="nombre" value="pieza">
      <label>Fotogramas por toma <span id="seg" style="color:var(--sec)"></span></label>
      <select id="frames">
        <option value="107">107 — 4,5 s</option>
        <option value="192">192 — 8,0 s</option>
        <option value="345" selected>345 — 14,4 s</option>
      </select>
      <label>Resolución</label>
      <select id="res">
        <option value="416x736" selected>416 × 736 · 9:16 reel</option>
        <option value="736x416">736 × 416 · horizontal</option>
        <option value="512x288">512 × 288 (da aberraciones)</option>
      </select>
      <button id="btn">Generar guion</button>
      <div class="nota" id="nota"></div>
    </details>
    <div class="panel" style="margin-top:16px"><h2>Actividad del pipeline</h2><div id="logs"></div></div>\n    <div class="panel" style="margin-top:16px"><h2>Estado durable de las obras</h2><div id="trab"></div></div>
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
const fases={launching:'iniciando',planned:'planificada',waiting_resources:'esperando recursos',
  generating:'generando',mounting:'montando',review_pending:'pendiente de revisión',
  failed:'fallida',finished:'terminada',interrupted:'interrumpida · proceso ausente'};
function actualizaDuracion(){
  const o=$('#guion').selectedOptions[0], n=o ? +o.dataset.tomas : 0;
  const f=+$('#frames').value;
  $('#seg').textContent=n ? '· '+(n*f/24).toFixed(1)+' s finales estimados' : '';
}
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
    '<div class="v'+(v.vertical?' vert':'')+'"><video src="'+encodeURI(v.url)+'" controls preload="metadata"></video>'+
    '<div class="m"><b>'+esc(v.nombre)+'</b>'+esc(v.mb)+' MB · '+esc(v.fecha)+
    ' <span class="tag '+(v.etiqueta==='entrega'?'entrega':'experimento')+'">'+
    esc(v.etiqueta)+'</span>'+(v.vertical?' <span class="tag">9:16</span>':'')+
    '</div></div>').join('')
    : '<div class="nota">Todavía no hay vídeos.</div>';
  if(!guionesCargados && d.guiones.length){
    $('#guion').innerHTML=d.guiones.map(g=>'<option data-tomas="'+Number(g.tomas)+'" value="'+esc(g.ruta)+'">'+esc(g.nombre)+
      ' ('+esc(g.tomas)+' tomas, '+esc(g.tipo)+')</option>').join('');
    guionesCargados=true; actualizaDuracion();
  }
  $('#btn').disabled=d.generando;
  const br=$('#btn-reel'); if(br) br.disabled=d.generando;
  $('#logs').innerHTML = (d.logs||[]).length ? d.logs.map(l=>
    '<div style="margin-bottom:11px"><b>'+esc(l.nombre)+'</b> <span style="color:'+
    (l.fresco?'var(--busy)':'var(--sec)')+'">'+(l.fresco?'activo':'inactivo')+
    ' · hace '+esc(l.hace)+'</span><pre>'+l.ultimas.map(esc).join('\n')+'</pre></div>').join('')
    : '<div class="nota">Sin actividad reciente del pipeline.</div>';
  $('#trab').innerHTML = d.trabajos.length ? d.trabajos.map(t=>
    '<div style="margin-bottom:11px"><b>'+esc(t.nombre)+'</b> <span style="color:var(--sec)">'+
    esc(fases[t.fase]||t.fase)+(t.total!=null?' · '+esc(t.completadas||0)+'/'+esc(t.total):'')+
    (!t.vivo&&t.rc!=null?' · rc '+esc(t.rc):'')+'</span><pre>'+
    (t.ultimas.map(esc).join('\n')||'sin salida todavía')+'</pre></div>').join('')
    : '<div class="nota">Todavía no hay estados de obra registrados.</div>';
}
async function tic(){
  try{ pinta(await (await fetch('/api/estado')).json()); }
  catch(e){ $('#c-gen').innerHTML='<span class="dot off"></span>servidor caído'; }
}
$('#frames').onchange=actualizaDuracion;
$('#guion').onchange=actualizaDuracion;
$('#btn').onclick=async()=>{
  const [w,h]=$('#res').value.split('x');
  $('#btn').disabled=true; $('#nota').textContent='lanzando…';
  let r;
  try { r=await (await fetch('/api/lanzar',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({guion:$('#guion').value,nombre:$('#nombre').value,
        frames:+$('#frames').value,w:+w,h:+h,pasos:20})})).json(); }
  catch(e) { r={ok:false,error:'no respondió el servidor'}; }
  $('#nota').textContent = r.ok ? 'lanzada: '+r.nombre+' · '+r.duracion_estimada_s+
    ' s finales estimados · log en '+r.log+(r.avisos.length?' · '+r.avisos.join(' · '):'')
    : 'no se pudo: '+r.error;  // textContent: no interpreta HTML
  tic();
};
$('#btn-reel').onclick=async()=>{
  $('#btn-reel').disabled=true; $('#nota-reel').textContent='componiendo…';
  let r;
  try { r=await (await fetch('/api/reel',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({titular:$('#titular').value,texto:$('#cuerpo').value,
        nombre:$('#nombre-reel').value,segundos:+$('#segundos-reel').value})})).json(); }
  catch(e) { r={ok:false,error:'no respondió el servidor'}; }
  $('#nota-reel').textContent = r.ok ? 'lanzada: '+r.nombre+' · '+r.duracion_estimada_s+
    ' s finales estimados · log en '+r.log+(r.avisos&&r.avisos.length?' · '+r.avisos.join(' · '):'')
    : 'no se pudo: '+r.error;
  tic();
};
tic(); setInterval(tic,4000);
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; media-src 'self'; "
            "img-src 'self'; connect-src 'self'; frame-ancestors 'none'",
        )
        super().end_headers()

    def _json(self, value, code=200):
        # ensure_ascii tambien vuelve serializables nombres del filesystem con
        # surrogateescape (por ejemplo un byte 0xff), sin tumbar /api/estado.
        body = json.dumps(value, ensure_ascii=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _cliente_local(self):
        raw = self.headers.get("Host", "")
        if raw.startswith("["):
            host = raw.split("]", 1)[0] + "]"
        else:
            host = raw.rsplit(":", 1)[0] if ":" in raw else raw
        return host.lower() in {"localhost", "127.0.0.1", "[::1]"}

    def _origen_local(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        parsed = urllib.parse.urlparse(origin)
        return parsed.scheme in {"http", "https"} and parsed.hostname in {
            "localhost",
            "127.0.0.1",
            "::1",
        }

    def _lectura_local(self):
        if self.headers.get("Sec-Fetch-Site", "").lower() == "cross-site":
            return False
        if not self._origen_local():
            return False
        referer = self.headers.get("Referer")
        if not referer:
            return True
        return urllib.parse.urlparse(referer).hostname in {
            "localhost",
            "127.0.0.1",
            "::1",
        }

    def _archivo_video(self, relative):
        if "\x00" in relative or "\\" in relative:
            return None
        parts = relative.split("/")
        if len(parts) != 3 or parts[:2] not in (
            ["videos", "entregas"],
            ["videos", "experimentos"],
        ):
            return None
        if not parts[2] or not parts[2].lower().endswith(".mp4"):
            return None
        return relative

    def _rango(self, size):
        value = self.headers.get("Range")
        if not value:
            return 0, size - 1
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
        if not match or (not match.group(1) and not match.group(2)):
            return None
        start_text, end_text = match.groups()
        try:
            if not start_text:
                length = int(end_text)
                if length <= 0:
                    return None
                start = max(0, size - length)
                end = size - 1
            else:
                start = int(start_text)
                end = int(end_text) if end_text else size - 1
                if start >= size or end < start:
                    return None
                end = min(end, size - 1)
        except ValueError:
            return None
        return start, end

    def _servir_video(self, relative):
        # Abrir desde RAIZ y recorrer CADA componente con openat+O_NOFOLLOW.
        # Validar un path y abrirlo despues permitia sustituir `videos/` por un
        # symlink entre ambas operaciones.
        parts = relative.split("/")
        directory_fd = file_fd = None
        try:
            directory_fd = os.open(
                RAIZ, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
            for component in parts[:-1]:
                next_fd = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
                os.close(directory_fd)
                directory_fd = next_fd
            file_fd = os.open(
                parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd
            )
            details = os.fstat(file_fd)
            if not stat.S_ISREG(details.st_mode):
                raise OSError("no es un archivo regular")
        except OSError:
            if file_fd is not None:
                os.close(file_fd)
            if directory_fd is not None:
                os.close(directory_fd)
            return self._json({"error": "video no permitido"}, 403)
        os.close(directory_fd)
        # fdopen se hace ANTES de enviar cabeceras: cualquier excepcion o corte
        # de cliente posterior pasa por finally y no filtra el descriptor.
        handle = os.fdopen(file_fd, "rb")
        try:
            size = details.st_size
            if size == 0:
                return self._json({"error": "video vacio"}, 422)
            selected = self._rango(size)
            if selected is None:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = selected
            partial = self.headers.get("Range") is not None
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            remaining = end - start + 1
            handle.seek(start)
            while remaining:
                chunk = handle.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return
        finally:
            handle.close()

    def do_GET(self):
        if not self._cliente_local() or not self._lectura_local():
            return self._json({"error": "lectura no permitida"}, 403)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            body = PAGINA.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/estado":
            return self._json(snapshot_estado())
        if parsed.path.startswith("/video/"):
            relative = os.fsdecode(
                urllib.parse.unquote_to_bytes(parsed.path[len("/video/") :])
            )
            path = self._archivo_video(relative)
            if path is None:
                return self._json({"error": "video no permitido"}, 403)
            return self._servir_video(path)
        return self._json({"error": "no encontrado"}, 404)

    def do_HEAD(self):
        allowed = self._cliente_local() and self._lectura_local()
        self.send_response(405 if allowed else 403)
        if allowed:
            self.send_header("Allow", "GET, POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if not self._cliente_local() or not self._origen_local():
            return self._json({"ok": False, "error": "origen no permitido"}, 403)
        path = urllib.parse.urlparse(self.path).path
        if path not in {"/api/lanzar", "/api/reel"}:
            return self._json({"error": "no encontrado"}, 404)
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip()
        if content_type != "application/json":
            return self._json(
                {"ok": False, "error": "Content-Type debe ser application/json"},
                415,
            )
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._json({"ok": False, "error": "longitud invalida"}, 400)
        if length < 1 or length > MAX_CUERPO:
            return self._json({"ok": False, "error": "cuerpo demasiado grande"}, 413)
        try:
            data = _json_estricto(self.rfile.read(length))
        except (ValueError, UnicodeError):
            return self._json({"ok": False, "error": "json invalido"}, 400)
        if not isinstance(data, dict):
            return self._json({"ok": False, "error": "json debe ser un objeto"}, 400)
        if path == "/api/reel":
            result = lanzar_reel(
                data.get("titular", ""),
                data.get("texto", ""),
                data.get("nombre", "corte"),
                data.get("segundos", 32),
            )
        else:
            result = lanzar(
                data.get("guion", ""),
                data.get("nombre", "pieza"),
                data.get("frames", 345),
                data.get("w", 736),
                data.get("h", 416),
                data.get("pasos", 20),
            )
        return self._json(result, 202 if result.get("ok") else 409)

class Servidor(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    # 127.0.0.1 y no 0.0.0.0: es una UI local y no tiene autenticacion; escuchando
    # en todas las interfaces quedaria expuesta a la red, y su endpoint /api/lanzar
    # arranca procesos.
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and not sys.argv[1].isdigit()):
        raise SystemExit("uso: ui/servidor.py [puerto]")
    port = int(sys.argv[1]) if len(sys.argv) == 2 else PUERTO
    if port < 1 or port > 65535:
        raise SystemExit("puerto fuera de rango")
    with Servidor(("127.0.0.1", port), H) as s:
        print(f"UI en http://localhost:{port}  (raiz: {RAIZ})")
        s.serve_forever()
