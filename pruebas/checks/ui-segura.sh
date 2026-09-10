#!/bin/bash
# Regresion de los limites de confianza de la UI local. Todo ocurre en un
# arbol temporal y el lanzamiento HTTP se sustituye por una funcion inocua.
set -euo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/minimax-ui-segura-XXXXXX")
trap 'rm -rf "$TEMP"' EXIT

python3 - "$RAIZ/ui/servidor.py" "$TEMP" <<'PY'
import http.client
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading


module_path = Path(sys.argv[1])
root = Path(sys.argv[2]) / "proyecto"
outside = Path(sys.argv[2]) / "fuera"

spec = importlib.util.spec_from_file_location("minimax_ui_segura", module_path)
ui = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(ui)

scripts = root / "produccion" / "guiones"
works = root / "produccion" / "obra"
deliveries = root / "videos" / "entregas"
experiments = root / "videos" / "experimentos"
for directory in (scripts, works, deliveries, experiments, outside):
    directory.mkdir(parents=True, exist_ok=True)

good = scripts / "valido.guion"
good.write_text(
    "@TIPO habla\n@ESCENA estudio\n@AMBIENTE silencio\n@MUSICA ninguna\n"
    "TOMA|Una persona mira a camara.|inicio|habla|\n",
    encoding="utf-8",
)
(outside / "escapado.guion").write_text("TOMA|inicio|No debe verse.\n", encoding="utf-8")
(outside / "directorio").mkdir()
(outside / "directorio" / "otro.guion").write_text(
    "TOMA|inicio|Tampoco debe verse.\n", encoding="utf-8"
)
os.symlink(outside / "escapado.guion", scripts / "enlace.guion")
os.symlink(outside / "directorio", scripts / "salto")

# reel-noticias.sh de mentira: comprueba que la interfaz llama al camino
# COMPLETO (runner + subtitulos + export) sin gastar GPU, y compone el guion
# con SOLO_GUION igual que el de verdad, para que la asercion sobre el .guion
# siga midiendo algo.
reel = root / "produccion" / "reel-noticias.sh"
reel.write_text(
    "#!/bin/bash\n"
    "set -u\n"
    'DEST="$(dirname "$0")/guiones/noticias/generados"\n'
    "mkdir -p \"$DEST\"\n"
    "NOMBRE=corte; TIT=\n"
    "while [ $# -gt 0 ]; do\n"
    '  case "$1" in\n'
    "    --nombre) NOMBRE=$2; shift 2 ;;\n"
    "    --titular) TIT=$2; shift 2 ;;\n"
    "    *) shift ;;\n"
    "  esac\n"
    "done\n"
    '[ -n "$TIT" ] || { echo "falta titular" >&2; exit 2; }\n'
    '{ echo "@TIPO informativo"; echo "@ESCENA e"; echo "@AMBIENTE a";\n'
    '  echo "@MUSICA m"; echo "TOMA|$TIT|inicio|informativo|frames=192"; } \\\n'
    '  > "$DEST/$NOMBRE.guion"\n'
    'echo "  2 tomas habladas · 20 palabras · 16.0 s de voz"\n'
    "exit 0\n",
    encoding="utf-8",
)
reel.chmod(0o755)

ui.RAIZ = str(root)
ui.GUIONES_DIR = str(scripts)
ui.OBRAS_DIR = str(works)
ui.VIDEOS_DIRS = (str(deliveries), str(experiments))
ui._trabajos.clear()

# El catalogo es la autoridad: ni un path suministrado por el cliente ni un
# symlink que escape del directorio de guiones se convierten en ejecutables.
catalog = ui._indice_guiones()
expected_script = "produccion/guiones/valido.guion"
assert catalog == {expected_script: str(good)}, catalog


def must_reject(*args):
    try:
        ui._validar_lanzamiento(*args)
    except ValueError:
        return
    raise AssertionError(f"lanzamiento invalido aceptado: {args!r}")


must_reject("../../fuera/escapado.guion", "pieza", 345, 736, 416, 20)
must_reject(expected_script, "../pieza", 345, 736, 416, 20)
must_reject(expected_script, "pieza", 100, 736, 416, 20)
must_reject(expected_script, "pieza", 345, 999, 416, 20)
must_reject(expected_script, "pieza", 345, 736, 416, 51)
must_reject(expected_script, "pieza", True, 736, 416, 20)
must_reject(expected_script, "pieza", 345.9, 736, 416, 20)
must_reject(expected_script, "pieza", float("inf"), 736, 416, 20)
validated = ui._validar_lanzamiento(
    expected_script, "pieza_segura-01", 345, 736, 416, 20
)
assert validated[0] == str(good)
validated_reel = ui._validar_lanzamiento(
    expected_script, "pieza_segura-01", 192, 416, 736, 20
)
assert validated_reel[0] == str(good)
must_reject(expected_script, "pieza", 192, 736, 736, 20)

# El lanzamiento real fija su propio árbol, limpia flags de control heredados y
# reserva la instancia antes de admitir un segundo POST. Popen se sustituye por
# un proceso falso: no se ejecuta ningún script.
captured = []


class FakeProcess:
    def poll(self):
        return None


def fake_popen(argv, **kwargs):
    captured.append((argv, kwargs))
    return FakeProcess()


real_popen = ui.subprocess.Popen
real_preflight = ui._preflight
real_generating = ui.generando
ui.subprocess.Popen = fake_popen
ui._preflight = lambda *_args: (14.0, [])
ui.generando = lambda: any(
    task["proc"].poll() is None for task in ui._trabajos.values()
)
os.environ.update(MD="/arbol-equivocado", DEST="/destino-equivocado", VALIDAR="1")
try:
    launch = ui.lanzar(expected_script, "entorno", 345, 736, 416, 20)
    assert launch["ok"] is True and len(captured) == 1, (launch, captured)
    child_env = captured[0][1]["env"]
    assert child_env["MD"] == str(root), child_env["MD"]
    assert child_env["DEST"] == str(deliveries), child_env["DEST"]
    assert "VALIDAR" not in child_env
    second = ui.lanzar(expected_script, "otra", 345, 736, 416, 20)
    assert second["ok"] is False and len(captured) == 1, second
finally:
    ui.subprocess.Popen = real_popen
    ui._preflight = real_preflight
    ui.generando = real_generating
    ui._trabajos.clear()
    for key in ("MD", "DEST", "VALIDAR"):
        os.environ.pop(key, None)

# Un estado activo con PID existente no basta. El PID de este propio proceso
# esta vivo, pero no ejecuta producir-anclado.sh: simula un PID reciclado.
fake_work = works / "pid-reciclado"
fake_work.mkdir()
(fake_work / "estado.json").write_text(
    json.dumps(
        {
            "phase": "generating",
            "name": "pid-reciclado",
            "pid": os.getpid(),
            "updated_at": "2099-01-01T00:00:00Z",
        }
    ),
    encoding="utf-8",
)
durable = ui.estados_durables()
assert len(durable) == 1 and durable[0]["vivo"] is False, durable
assert durable[0]["fase"] == "interrupted", durable
ui._sh = lambda _command: ""
assert ui.generando() is False

# Un estado con tipos corruptos se ignora y nunca rompe el sort de la API.
bad_work = works / "estado-mal-tipado"
bad_work.mkdir()
(bad_work / "estado.json").write_text(
    json.dumps({"phase": "failed", "name": "malo", "updated_at": 7}),
    encoding="utf-8",
)
assert len(ui.estados_durables()) == 1

# Ficheros de video de prueba. No necesitan ser MP4 reales: aqui se verifica
# el confinamiento de ruta y la semantica HTTP de bytes, no los codecs.
(deliveries / "clip.mp4").write_bytes(b"0123456789")
(experiments / "prueba.mp4").write_bytes(b"abcdefghij")
(outside / "secreto.mp4").write_bytes(b"SECRETO")
os.symlink(outside / "secreto.mp4", deliveries / "enlace.mp4")

launch_calls = []
arranques = []


def harmless_launch(*args):
    launch_calls.append(args)
    return {"ok": True, "nombre": args[1], "simulado": True}


def harmless_arranque(nombre, comando, duracion=0.0, avisos=()):
    # Se intercepta _arrancar y no lanzar(): el reel de noticias no pasa por
    # lanzar(). Interceptando solo lanzar() esta prueba daba PASA mientras la
    # interfaz publicaba el montaje interno en vez de un reel.
    arranques.append((nombre, list(comando)))
    return {"ok": True, "nombre": nombre, "simulado": True}


ui.lanzar = harmless_launch
ui._arrancar = harmless_arranque
server = ui.Servidor(("127.0.0.1", 0), ui.H)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
port = server.server_address[1]


def request(method, path, *, host="localhost", headers=None, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    all_headers = {"Host": host}
    all_headers.update(headers or {})
    connection.request(method, path, body=body, headers=all_headers)
    response = connection.getresponse()
    payload = response.read()
    result = response.status, dict(response.getheaders()), payload
    connection.close()
    return result


try:
    status, _, _ = request("GET", "/", host="atacante.example")
    assert status == 403, status

    status, _, _ = request("HEAD", "/README.md", host="atacante.example")
    assert status == 403, status
    status, _, payload = request("HEAD", "/README.md")
    assert status == 405 and payload == b"", (status, payload)

    status, _, _ = request(
        "GET", "/api/estado?nonce=1", headers={"Sec-Fetch-Site": "cross-site"}
    )
    assert status == 403, status

    status, headers, payload = request(
        "GET",
        "/video/videos/entregas/clip.mp4",
        headers={"Range": "bytes=2-5"},
    )
    assert status == 206, status
    assert payload == b"2345", payload
    assert headers.get("Content-Range") == "bytes 2-5/10", headers
    assert headers.get("Accept-Ranges") == "bytes", headers

    status, headers, payload = request(
        "GET",
        "/video/videos/entregas/clip.mp4",
        headers={"Range": "bytes=99-100"},
    )
    assert status == 416 and payload == b"", (status, payload)
    assert headers.get("Content-Range") == "bytes */10", headers

    # Un nombre con bytes no UTF-8 no puede tumbar el snapshot ni el JSON. La
    # URL usa percent-encoding de bytes y vuelve al mismo nombre del filesystem.
    odd_path = os.fsencode(deliveries) + b"/\xff.mp4"
    odd_fd = os.open(odd_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(odd_fd, b"BYTE-NAME")
    os.close(odd_fd)
    ui._estado_cache = {"at": 0.0, "value": None}
    status, _, payload = request("GET", "/api/estado?bytes=1")
    assert status == 200, (status, payload)
    decoded = json.loads(payload)
    odd = next(item for item in decoded["videos"] if item["nombre"] == "\udcff.mp4")
    status, _, payload = request("GET", odd["url"])
    assert status == 200 and payload == b"BYTE-NAME", (status, payload)

    # La validación sintáctica y la apertura están separadas. Sustituir el
    # ancestro `videos` justo entre ambas no debe servir el fichero del enlace.
    original_video_check = ui.H._archivo_video
    legitimate_videos = root / "videos-legitimos"
    evil_videos = outside / "videos-sustitutos"
    (evil_videos / "entregas").mkdir(parents=True)
    (evil_videos / "experimentos").mkdir()
    (evil_videos / "entregas" / "clip.mp4").write_bytes(b"SECRET")
    swapped = {"done": False}

    def swap_ancestor(self, relative):
        result = original_video_check(self, relative)
        if result is not None and not swapped["done"]:
            swapped["done"] = True
            os.rename(root / "videos", legitimate_videos)
            os.symlink(evil_videos, root / "videos")
        return result

    ui.H._archivo_video = swap_ancestor
    try:
        status, _, payload = request("GET", "/video/videos/entregas/clip.mp4")
        assert status == 403 and b"SECRET" not in payload, (status, payload)
    finally:
        ui.H._archivo_video = original_video_check
        if (root / "videos").is_symlink():
            os.unlink(root / "videos")
        os.rename(legitimate_videos, root / "videos")

    status, _, payload = request(
        "GET", "/video/videos/experimentos/prueba.mp4"
    )
    assert status == 200 and payload == b"abcdefghij", (status, payload)

    forbidden = (
        "/video/secreto.mp4",
        "/video/videos/privados/secreto.mp4",
        "/video/videos/entregas/%2e%2e/%2e%2e/fuera/secreto.mp4",
        "/video/videos/entregas/enlace.mp4",
    )
    for path in forbidden:
        status, _, _ = request("GET", path)
        assert status == 403, (path, status)

    status, _, _ = request(
        "POST",
        "/api/lanzar",
        headers={"Content-Type": "text/plain"},
        body=b"{}",
    )
    assert status == 415 and not launch_calls, (status, launch_calls)

    status, _, _ = request(
        "POST",
        "/api/lanzar",
        headers={"Content-Type": "application/json"},
        body=b"x" * (ui.MAX_CUERPO + 1),
    )
    assert status == 413 and not launch_calls, (status, launch_calls)

    status, _, _ = request(
        "POST",
        "/api/lanzar",
        headers={"Content-Type": "application/json"},
        body=b'{"frames":NaN}',
    )
    assert status == 400 and not launch_calls, (status, launch_calls)

    body = json.dumps(
        {
            "guion": expected_script,
            "nombre": "simulada",
            "frames": 345,
            "w": 736,
            "h": 416,
            "pasos": 20,
        }
    ).encode()
    status, _, payload = request(
        "POST",
        "/api/lanzar",
        headers={"Content-Type": "application/json"},
        body=body,
    )
    assert status == 202, (status, payload)
    assert len(launch_calls) == 1, launch_calls

    # Reel: el cliente no elige resolucion ni RSS. Un titular vacio no lanza.
    status, _, payload = request(
        "POST",
        "/api/reel",
        headers={"Content-Type": "application/json"},
        body=json.dumps(
            {"titular": "", "texto": "cuerpo", "nombre": "corte", "segundos": 32}
        ).encode(),
    )
    assert status == 409, (status, payload)
    assert len(launch_calls) == 1, launch_calls

    status, _, payload = request(
        "POST",
        "/api/reel",
        headers={"Content-Type": "application/json"},
        body=json.dumps(
            {
                "titular": "El congreso aprueba la ley de vivienda.",
                "texto": "El tope al alquiler entra en vigor el mes que viene.",
                "nombre": "corte-ui",
                "segundos": 32,
            }
        ).encode(),
    )
    assert status == 202, (status, payload)
    # El reel NO se lanza con el runner anclado a pelo: ese camino se salta
    # subtitular.py y exportar-reel.sh, o sea que entrega el montaje interno
    # a 416x736 en vez de un reel. El unico camino completo es reel-noticias.sh.
    assert len(arranques) == 1, arranques
    comando = arranques[0][1]
    assert comando[0].endswith("produccion/reel-noticias.sh"), comando
    assert "--titular" in comando and "--nombre" in comando, comando
    assert comando[comando.index("--nombre") + 1] == "corte-ui", comando
    assert "--seg-objetivo" in comando, comando
    assert comando[comando.index("--seg-objetivo") + 1] == "32", comando
    # Y el guion se compone de verdad: reel-noticias.sh lo escribe con
    # SOLO_GUION antes de gastar GPU, asi que un titular imposible se rechaza
    # al instante en vez de veinte minutos despues.
    composed = scripts / "noticias" / "generados" / "corte-ui.guion"
    assert composed.is_file() and "informativo" in composed.read_text(
        encoding="utf-8"
    ), composed
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)

# Una raiz confiable no puede convertirse en enlace hacia fuera.
linked_root = root / "videos" / "raiz-enlace"
os.symlink(outside, linked_root)
assert ui._bajo(outside / "secreto.mp4", linked_root) is False

print("PASA ui-segura (catalogo, estado durable, HTTP local, videos, Range, POST y reel)")
PY
