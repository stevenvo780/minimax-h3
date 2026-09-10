#!/usr/bin/env python3
"""Quema subtitulos en la zona segura de un reel vertical.

TikTok e Instagram cubren el tercio inferior (descripcion, barra) y el
margen derecho (botones). Los subtitulos van centrados, hacia el 62 % de
la altura, maximo dos lineas, caja oscura. Sin eso el reel se ve mudo.

Uso:
  subtitular.py VIDEO --guion GUION --salida OUT.mp4
  subtitular.py VIDEO --texto "frase. otra." --salida OUT.mp4
  subtitular.py VIDEO --srt FILE.srt --salida OUT.mp4
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TIPOS_VOZ = {"habla", "informativo"}
FUENTES = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
)


def error(msg: str) -> None:
    sys.stderr.write(f"ERROR: {msg}\n")
    raise SystemExit(1)


def fuente() -> str:
    for path in FUENTES:
        if os.path.isfile(path):
            return path
    error("no hay fuente sans-serif en el sistema (DejaVu o Liberation)")
    raise AssertionError


def ffprobe_duracion(video: str) -> float:
    r = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            video,
        ],
        capture_output=True,
        text=True,
    )
    try:
        d = float(r.stdout.strip())
    except ValueError:
        error(f"ffprobe no devolvio duracion para {video}")
    if d <= 0:
        error(f"duracion invalida: {d}")
    return d


FRAMES_RE = re.compile(r"frames=([0-9]{1,9})")


def tomas_guion(path: str) -> list[tuple[str, int | None]]:
    """(texto, fotogramas) por TOMA, en orden, con "" donde no hay voz.

    Antes se devolvia solo la lista de tomas HABLADAS, sin su posicion, y el
    subtitulo se repartia por peso de palabras sobre el video entero. Con un
    plano de apoyo en medio —o con tomas de duraciones distintas, que es lo
    normal desde que cada una dura lo que su texto— el texto se despegaba del
    audio. Conservando el hueco y la duracion, cada toma cae en SU tramo.
    """
    out: list[tuple[str, int | None]] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not (line.startswith("TOMA|") or line.startswith("HABLA|")):
                continue
            fields = [f.strip() for f in line.split("|")]
            if len(fields) < 2:
                continue
            frames = None
            posicionales = []
            for campo in fields[2:]:
                named = FRAMES_RE.fullmatch(campo)
                if named:
                    frames = int(named.group(1))
                else:
                    posicionales.append(campo)
            tipo = posicionales[1] if len(posicionales) > 1 else ""
            if tipo and tipo not in TIPOS_VOZ:
                out.append(("", frames))
                continue
            out.append((fields[1], frames))
    if not any(texto for texto, _ in out):
        error(f"el guion no tiene tomas habladas: {path}")
    return out


def cues_desde_tomas(
    tomas: list[tuple[str, int | None]], duracion: float, fps: int = 24
) -> list[tuple[float, float, str]]:
    """Cada toma ocupa SU tramo, proporcional a sus fotogramas."""
    if not tomas:
        return []
    pesos = [f if f else 0 for _, f in tomas]
    if not all(pesos):
        # Un guion sin duraciones declaradas: todas las tomas miden igual.
        pesos = [1] * len(tomas)
    total = sum(pesos)
    cues, t = [], 0.0
    for (texto, _), peso in zip(tomas, pesos):
        dt = duracion * peso / total
        if texto:
            cues.extend(repartir(texto.rstrip("."), t, min(duracion, t + dt)))
        t += dt
    return cues


def _frases(texto: str) -> list[str]:
    t = re.sub(r"\s+", " ", texto.strip())
    partes = re.split(r"(?<=[.!?…])\s+", t)
    return [p.strip() for p in partes if p.strip()]


# Ancho de linea en caracteres, y no es un numero elegido a ojo.
#
# El reel es 9:16, asi que w = h*0.5625. Con fontsize = h*ALTURA_FUENTE y un
# avance medio de ~0.60 em en DejaVu Sans Bold, cada caracter ocupa
# 0.60*ALTURA_FUENTE*h. Dejando un 8 % de margen a cada lado:
#
#   ancho_max = 0.5625*h*0.92 / (0.60*0.045*h) ≈ 19 caracteres
#
# Se usa 17 y no 19: la caja añade boxborderw a cada lado, y con 19 la caja
# llegaba a tocar los bordes del cuadro.
#
# Antes eran 28 y ademas se aplastaban dos lineas en una: 55 caracteres en un
# cuadro de 416 px. Se veia "a vinculado a Amazon s" — cortado por los dos
# lados— y las otras 44 letras de la frase no se pintaban en ninguna parte.
ALTURA_FUENTE = 0.045
# 15 y no 17: medido sobre un fotograma real, DejaVu Sans Bold avanza ~0,66 em
# por caracter, no 0,60. Con 17 la caja salia 1042 px de ancho en un cuadro de
# 1080 —19 px de margen— y con 15 quedan 76.
ANCHO_LINEA = 15
LINEAS_MAX = 2
# La caja y el interlineado se piden en PIXELES ABSOLUTOS, y drawtext de
# ffmpeg 6.1 NO admite expresiones ahi: 'boxborderw=h*0.019' se ignora en
# silencio y pinta la caja como si fuera 0 (comprobado midiendo el recuadro:
# 172 px de alto contra 200 con boxborderw=14). Como el subtitulo se quema
# despues de escalar a 1080x1920, hay que escalar estos dos numeros a mano.
BORDE_CAJA_REL = 0.019
INTERLINEA_REL = 0.008
ALTO_REFERENCIA = 736


def envolver(texto: str, ancho: int = ANCHO_LINEA) -> list[str]:
    """Parte en lineas de como mucho `ancho` caracteres. NO tira nada."""
    words = texto.split()
    if not words:
        return []
    lineas, actual = [], words[0]
    for w in words[1:]:
        if len(actual) + 1 + len(w) <= ancho:
            actual += " " + w
        else:
            lineas.append(actual)
            actual = w
    lineas.append(actual)
    return lineas


def repartir(
    texto: str, inicio: float, fin: float,
    ancho: int = ANCHO_LINEA, lineas_max: int = LINEAS_MAX,
) -> list[tuple[float, float, str]]:
    """Una frase larga se parte en VARIOS cues, no se recorta.

    Cada cue lleva a lo sumo `lineas_max` lineas y se queda con la parte del
    tiempo que le corresponde por numero de palabras. Antes lo que no cabia
    en dos lineas simplemente no se decia en pantalla.
    """
    lineas = envolver(texto, ancho)
    if not lineas:
        return []
    grupos = [lineas[i:i + lineas_max] for i in range(0, len(lineas), lineas_max)]
    pesos = [sum(len(ln.split()) for ln in g) or 1 for g in grupos]
    total = sum(pesos)
    cues, t = [], inicio
    for grupo, peso in zip(grupos, pesos):
        dt = (fin - inicio) * peso / total
        cues.append((t, min(fin, t + dt), "\n".join(grupo)))
        t += dt
    return cues


def cues_desde_frases(frases: list[str], duracion: float) -> list[tuple[float, float, str]]:
    pesos = [max(1, len(f.split())) for f in frases]
    total = sum(pesos)
    t, cues = 0.0, []
    for frase, peso in zip(frases, pesos):
        dt = duracion * peso / total
        cues.extend(repartir(frase.rstrip("."), t, min(duracion, t + dt)))
        t += dt
    return cues


def cues_desde_srt(path: str) -> list[tuple[float, float, str]]:
    raw = open(path, encoding="utf-8-sig").read()
    bloques = re.split(r"\n\s*\n", raw.strip())
    cues = []
    tiempo = re.compile(
        r"(\d+):(\d+):(\d+)[,.](\d+)\s+-->\s+(\d+):(\d+):(\d+)[,.](\d+)"
    )

    def seg(h, m, s, ms) -> float:
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms.ljust(3, "0")[:3]) / 1000

    for bloque in bloques:
        lineas = [ln.rstrip() for ln in bloque.splitlines() if ln.strip()]
        stamp_i = next((i for i, ln in enumerate(lineas) if tiempo.search(ln)), None)
        if stamp_i is None:
            continue
        match = tiempo.search(lineas[stamp_i])
        assert match is not None
        g = match.groups()
        start, end = seg(*g[:4]), seg(*g[4:])
        texto = " ".join(lineas[stamp_i + 1 :])
        if texto and end > start:
            cues.extend(repartir(texto, start, end))
    if not cues:
        error(f"el SRT no tiene cues: {path}")
    return cues


def escape_ruta(ruta: str) -> str:
    """Escapa una ruta para meterla en un filtro de ffmpeg."""
    return ruta.replace("\\", "\\\\").replace(":", r"\:").replace("'", r"\'")


def filtro(
    cues: list[tuple[float, float, str]], font: str, dirtexto: str,
    alto: int = ALTO_REFERENCIA,
) -> str:
    r"""Un drawtext por cue, con el texto en un FICHERO.

    Con text='...' inline hay que escapar \ ' : % y ademas no hay forma
    portable de meter un salto de linea: probado en ffmpeg 6.1, text='a\nb'
    pinta "anb". Por eso antes se aplastaba todo a una linea y se recortaba.
    Con textfile= el texto va literal, con saltos de linea de verdad, y no
    hay nada que escapar dentro del texto.
    """
    borde = max(4, round(alto * BORDE_CAJA_REL))
    interlinea = max(2, round(alto * INTERLINEA_REL))
    partes = []
    for i, (start, end, texto) in enumerate(cues):
        ruta = os.path.join(dirtexto, f"cue{i:03d}.txt")
        with open(ruta, "w", encoding="utf-8") as fh:
            fh.write(texto)
        # y=h*0.62: por encima de la UI de TikTok/IG. x centrado.
        # fontsize relativo al alto: vale igual para 416x736 y 1080x1920.
        partes.append(
            "drawtext=fontfile={font}:textfile={txt}:fontcolor=white:"
            "fontsize=h*{fuente}:line_spacing={interlinea}:x=(w-text_w)/2:y=h*0.62:"
            "box=1:boxcolor=black@0.62:boxborderw={borde}:"
            "enable='between(t,{start:.3f},{end:.3f})'".format(
                font=escape_ruta(font),
                txt=escape_ruta(ruta),
                fuente=ALTURA_FUENTE,
                interlinea=interlinea,
                borde=borde,
                start=start,
                end=end,
            )
        )
    return ",".join(partes)


def quemar(
    video: str, cues: list[tuple[float, float, str]], salida: str,
    alto: int = ALTO_REFERENCIA,
) -> None:
    if not cues:
        error("no hay subtitulos que quemar")
    if os.path.exists(salida):
        error(f"la salida ya existe y no se sobrescribe: {salida}")
    tmpdir = tempfile.mkdtemp(prefix="subs-")
    tmp = os.path.join(tmpdir, "out.mp4")
    try:
        vf = filtro(cues, fuente(), tmpdir, alto)
        cmd = [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-v",
            "error",
            "-i",
            video,
            "-vf",
            vf,
            "-c:v",
            "libx264",
            "-preset",
            "fast",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "copy",
            tmp,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            detalle = (r.stderr or r.stdout or "").strip()
            error(f"ffmpeg no pudo quemar subtitulos: {detalle[-500:]}")
        os.makedirs(os.path.dirname(os.path.abspath(salida)) or ".", exist_ok=True)
        os.replace(tmp, salida)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("video")
    ap.add_argument("--guion")
    ap.add_argument("--texto")
    ap.add_argument("--srt")
    ap.add_argument("--salida", required=True)
    ap.add_argument("--solo-filtro", action="store_true", help="imprime el -vf y sale")
    ap.add_argument(
        "--alto", type=int, default=None,
        help="alto en pixeles del video FINAL sobre el que se pintara; escala "
             "la caja y el interlineado, que drawtext solo acepta en pixeles",
    )
    ap.add_argument(
        "--dir-textos",
        help="donde dejar los ficheros de texto de cada cue; con --solo-filtro "
             "el que llama se queda con ellos y decide cuando borrarlos",
    )
    a = ap.parse_args()
    if not os.path.isfile(a.video) and not a.solo_filtro:
        error(f"no existe el video: {a.video}")

    if a.srt:
        cues = cues_desde_srt(a.srt)
    else:
        dur_defecto = 8.0
        if a.guion:
            tomas = tomas_guion(a.guion)
            if a.solo_filtro:
                dur = sum((f / 24 if f else dur_defecto) for _, f in tomas)
            else:
                dur = ffprobe_duracion(a.video)
            cues = cues_desde_tomas(tomas, dur)
        elif a.texto:
            dur = dur_defecto if a.solo_filtro else ffprobe_duracion(a.video)
            cues = cues_desde_frases(_frases(a.texto), dur)
        else:
            error("hace falta --guion, --texto o --srt")

    alto = a.alto or ALTO_REFERENCIA
    if alto < 64:
        error("--alto tiene que ser al menos 64")
    if a.solo_filtro:
        # Con --dir-textos el filtro es utilizable por otro proceso: asi
        # exportar-reel.sh quema los subtitulos EN LA MISMA pasada en que
        # escala a 1080x1920. Antes se quemaban a 416x736 y despues se
        # ampliaban 2,6x, con lo que el texto salia borroso por construccion,
        # y ademas costaba una generacion entera de x264 de mas.
        propio = a.dir_textos is None
        tmpdir = a.dir_textos or tempfile.mkdtemp(prefix="subs-filtro-")
        os.makedirs(tmpdir, exist_ok=True)
        try:
            print(filtro(cues, fuente(), tmpdir, alto))
        finally:
            if propio:
                shutil.rmtree(tmpdir, ignore_errors=True)
        return
    quemar(a.video, cues, a.salida, alto)
    print(a.salida)


if __name__ == "__main__":
    main()
