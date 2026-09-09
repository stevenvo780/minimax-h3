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


def frases_guion(path: str) -> list[str]:
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not (line.startswith("TOMA|") or line.startswith("HABLA|")):
                continue
            fields = line.split("|")
            if len(fields) < 2:
                continue
            contenido = fields[1].strip()
            tipo = fields[3].strip() if len(fields) > 3 and fields[3].strip() else ""
            if tipo and tipo not in TIPOS_VOZ:
                continue
            if contenido:
                out.append(contenido)
    if not out:
        error(f"el guion no tiene tomas habladas: {path}")
    return out


def _frases(texto: str) -> list[str]:
    t = re.sub(r"\s+", " ", texto.strip())
    partes = re.split(r"(?<=[.!?…])\s+", t)
    return [p.strip() for p in partes if p.strip()]


def envolver(texto: str, ancho: int = 28) -> str:
    words = texto.split()
    if not words:
        return ""
    lineas, actual = [], words[0]
    for w in words[1:]:
        if len(actual) + 1 + len(w) <= ancho:
            actual += " " + w
        else:
            lineas.append(actual)
            actual = w
    lineas.append(actual)
    # drawtext pinta una caja por filtro; dos lineas maximo unidas con \n
    # no van bien en todas las builds. Preferimos una linea, o dos filtros.
    return "\n".join(lineas[:2])


def cues_desde_frases(frases: list[str], duracion: float) -> list[tuple[float, float, str]]:
    pesos = [max(1, len(f.split())) for f in frases]
    total = sum(pesos)
    t, cues = 0.0, []
    for frase, peso in zip(frases, pesos):
        dt = duracion * peso / total
        texto = envolver(frase.rstrip("."))
        if texto:
            cues.append((t, min(duracion, t + dt), texto))
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
        texto = envolver(" ".join(lineas[stamp_i + 1 :]))
        if texto and end > start:
            cues.append((start, end, texto))
    if not cues:
        error(f"el SRT no tiene cues: {path}")
    return cues


def escape_drawtext(texto: str) -> str:
    # El texto va entre comillas simples del filtro. Escapar \, ', :, % y
    # saltos de linea (drawtext usa \n literal si text='a\nb', pero es
    # fragil: aplastamos a una linea).
    t = texto.replace("\n", " ").replace("\\", "\\\\")
    t = t.replace("'", r"\'").replace(":", r"\:").replace("%", r"\%")
    return t


def filtro(cues: list[tuple[float, float, str]], font: str) -> str:
    partes = []
    for start, end, texto in cues:
        t = escape_drawtext(texto)
        # y=h*0.62: por encima de la UI de TikTok/IG. x centrado.
        # fontsize relativo al alto para 416x736 y 1080x1920.
        partes.append(
            "drawtext=fontfile={font}:text='{text}':fontcolor=white:"
            "fontsize=h*0.045:x=(w-text_w)/2:y=h*0.62:"
            "box=1:boxcolor=black@0.62:boxborderw=18:"
            "enable='between(t,{start:.3f},{end:.3f})'".format(
                font=font.replace("\\", "\\\\").replace(":", r"\:").replace("'", r"\'"),
                text=t,
                start=start,
                end=end,
            )
        )
    return ",".join(partes)


def quemar(video: str, cues: list[tuple[float, float, str]], salida: str) -> None:
    if not cues:
        error("no hay subtitulos que quemar")
    if os.path.exists(salida):
        error(f"la salida ya existe y no se sobrescribe: {salida}")
    vf = filtro(cues, fuente())
    tmpdir = tempfile.mkdtemp(prefix="subs-")
    tmp = os.path.join(tmpdir, "out.mp4")
    try:
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
    a = ap.parse_args()
    if not os.path.isfile(a.video) and not a.solo_filtro:
        error(f"no existe el video: {a.video}")

    if a.srt:
        cues = cues_desde_srt(a.srt)
    else:
        if a.guion:
            frases = frases_guion(a.guion)
        elif a.texto:
            frases = _frases(a.texto)
        else:
            error("hace falta --guion, --texto o --srt")
        dur = 8.0 if a.solo_filtro else ffprobe_duracion(a.video)
        cues = cues_desde_frases(frases, dur)

    if a.solo_filtro:
        print(filtro(cues, fuente()))
        return
    quemar(a.video, cues, a.salida)
    print(a.salida)


if __name__ == "__main__":
    main()
