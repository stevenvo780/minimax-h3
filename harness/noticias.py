#!/usr/bin/env python3
"""Convierte una noticia real en el texto hablado de un reel.

No inventa hechos. No parafrasea. Toma el titular y las frases del cuerpo
en orden, y recorta al presupuesto de palabras que cabe en 15-30 s a
~2.6 palabras/s (el ritmo medido de las piezas que salieron bien).

Entradas:
  --titular + --texto
  --fichero  (primera linea = titular, o 'TITULAR:' / 'FUENTE:')
  --rss URL [--indice 0]   solo http(s); no se usa desde la UI (SSRF)

Salidas:
  --guion path.guion   compone el .guion de la categoria 'noticias'
  --json               el recorte, para inspeccionar sin escribir

Uso:
  noticias.py --titular "..." --texto "..." --guion out.guion
  noticias.py --fichero noticia.txt --guion out.guion --seg-objetivo 20
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

_HARNESS = os.path.dirname(os.path.abspath(__file__))
if _HARNESS not in sys.path:
    sys.path.insert(0, _HARNESS)
import componer  # noqa: E402

PALABRAS_POR_SEG = componer.PALABRAS_POR_SEG
MAX_CUERPO = 50_000
MAX_TITULAR = 400
USER_AGENT = "NewsLeters/1.0 (+local; generador de reels)"


def _palabras(texto: str) -> list[str]:
    return [w for w in re.split(r"\s+", texto.strip()) if w]


_ABREV = re.compile(
    r"\b(EE\.UU|U\.S|EEUU|Sr|Sra|Dr|Dra|n[oº]|etc)\.",
    re.IGNORECASE,
)


def _frases(texto: str) -> list[str]:
    t = re.sub(r"\s+", " ", (texto or "").strip())
    if not t:
        return []
    # EE.UU. no es un final de frase: el punto de la abreviatura no corta.
    t = _ABREV.sub(lambda m: m.group(0)[:-1] + "\uE000", t)
    partes = re.split(r"(?<=[.!?…])\s+", t)
    out = []
    for p in partes:
        p = p.replace("\uE000", ".").strip(" \t«»\"'“”")
        if not p:
            continue
        if p[-1] not in ".!?…":
            p += "."
        out.append(p)
    return out


def _limpia_html(texto: str) -> str:
    t = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", texto or "")
    t = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", t)
    t = re.sub(r"(?s)<[^>]+>", " ", t)
    t = html.unescape(t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _partir_larga(frase: str, tope: int) -> list[str]:
    """Si una frase no cabe en una toma, parte por coma o punto y coma.

    Sigue sin inventar: cada trozo es un substring del original.
    """
    words = _palabras(frase)
    if len(words) <= tope:
        return [frase]
    trozos, actual = [], []
    for pieza in re.split(r"(?<=[,;:])\s+", frase):
        w = _palabras(pieza)
        if actual and len(actual) + len(w) > tope:
            t = " ".join(actual).rstrip(",;:")
            if t[-1:] not in ".!?…":
                t += "."
            trozos.append(t)
            actual = w
        else:
            actual.extend(w)
    if actual:
        t = " ".join(actual).rstrip(",;:")
        if t[-1:] not in ".!?…":
            t += "."
        trozos.append(t)
    return trozos or [frase]


def redactar(titular: str, cuerpo: str, seg_objetivo: float = 20.0) -> dict:
    """Recorta al presupuesto. Devuelve las frases que se van a decir."""
    titular = _limpia_html(titular)
    cuerpo = _limpia_html(cuerpo)
    if len(titular) > MAX_TITULAR:
        raise SystemExit(f"el titular supera {MAX_TITULAR} caracteres")
    if len(cuerpo) > MAX_CUERPO:
        raise SystemExit(f"el cuerpo supera {MAX_CUERPO} caracteres")
    if not titular.strip():
        raise SystemExit("hace falta un titular")

    tope = max(8, int(round(seg_objetivo * PALABRAS_POR_SEG)))
    tope_toma = max(8, int(round(min(14.4, max(4.0, seg_objetivo / 2)) * PALABRAS_POR_SEG)))

    gancho = _frases(titular)[0]
    usadas = [gancho]
    n = len(_palabras(gancho))
    avisos: list[str] = []

    vistas = {re.sub(r"\s+", " ", gancho.lower().rstrip("."))}
    for frase in _frases(cuerpo):
        clave = re.sub(r"\s+", " ", frase.lower().rstrip("."))
        if clave in vistas:
            continue
        partes = _partir_larga(frase, tope_toma)
        for parte in partes:
            w = len(_palabras(parte))
            if n + w > tope:
                avisos.append(
                    f"recorte al presupuesto de {tope} palabras "
                    f"(~{seg_objetivo:.0f} s); el resto del cuerpo no entra"
                )
                break
            usadas.append(parte)
            n += w
            vistas.add(re.sub(r"\s+", " ", parte.lower().rstrip(".")))
        else:
            continue
        break

    texto = " ".join(usadas)
    return {
        "titular": gancho,
        "frases": usadas,
        "texto": texto,
        "palabras": n,
        "duracion_est_s": round(n / PALABRAS_POR_SEG, 1),
        "avisos": avisos,
    }


def leer_fichero(ruta: str) -> tuple[str, str, str]:
    raw = open(ruta, encoding="utf-8").read()
    if len(raw) > MAX_CUERPO + MAX_TITULAR + 100:
        raise SystemExit("el fichero es demasiado grande")
    titular, cuerpo, fuente = "", "", ""
    lineas = raw.splitlines()
    resto: list[str] = []
    for i, line in enumerate(lineas):
        s = line.strip()
        m = re.match(r"^(TITULAR|TITULO|FUENTE|TEMA)\s*:\s*(.*)$", s, re.I)
        if m:
            clave, valor = m.group(1).upper(), m.group(2).strip()
            if clave in {"TITULAR", "TITULO"}:
                titular = valor
            elif clave == "FUENTE":
                fuente = valor
            continue
        resto = lineas[i:]
        break
    if not titular:
        # Primera linea no vacia = titular; el resto, cuerpo.
        while resto and not resto[0].strip():
            resto.pop(0)
        if resto:
            titular = resto.pop(0).strip()
    cuerpo = "\n".join(resto).strip()
    return titular, cuerpo, fuente


class _SoloHttp(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        scheme = urllib.parse.urlparse(newurl).scheme.lower()
        if scheme not in {"http", "https"}:
            raise ValueError(f"redireccion a esquema no permitido: {scheme}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _url_http(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() not in {"http", "https"}:
        raise SystemExit("el RSS solo admite http o https (nada de file:// ni otros)")
    if not parsed.netloc:
        raise SystemExit("URL de RSS sin host")
    return url


def _texto_xml(el: ET.Element | None) -> str:
    if el is None or el.text is None:
        return ""
    return el.text.strip()


def leer_rss(url: str, indice: int = 0) -> tuple[str, str, str]:
    url = _url_http(url)
    opener = urllib.request.build_opener(_SoloHttp())
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with opener.open(req, timeout=15) as resp:
            data = resp.read(2_000_000)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise SystemExit(f"no pude leer el RSS: {exc}") from exc
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise SystemExit(f"el RSS no es XML valido: {exc}") from exc

    items = root.findall(".//item")
    if not items:
        ns = {"a": "http://www.w3.org/2005/Atom"}
        items = root.findall(".//a:entry", ns) or root.findall(".//{http://www.w3.org/2005/Atom}entry")
    if not items:
        raise SystemExit("el RSS no tiene entradas")
    if indice < 0 or indice >= len(items):
        raise SystemExit(f"indice {indice} fuera de rango (hay {len(items)} entradas)")
    item = items[indice]
    title = _texto_xml(item.find("title")) or _texto_xml(
        item.find("{http://www.w3.org/2005/Atom}title")
    )
    body = (
        _texto_xml(item.find("description"))
        or _texto_xml(item.find("{http://purl.org/rss/1.0/modules/content/}encoded"))
        or _texto_xml(item.find("{http://www.w3.org/2005/Atom}summary"))
        or _texto_xml(item.find("{http://www.w3.org/2005/Atom}content"))
    )
    channel = root.find("channel")
    fuente = _texto_xml(channel.find("title") if channel is not None else None)
    if not title:
        raise SystemExit("la entrada del RSS no tiene titular")
    return _limpia_html(title), _limpia_html(body), fuente


def escribir_guion(
    recorte: dict,
    salida: str,
    categoria: str = "noticias",
    seg_por_toma: float = 8.0,
    ritmo: list[str] | None = None,
) -> int:
    cat = componer.cargar(categoria)
    filas = componer.componer(cat, recorte["texto"], seg_por_toma, ritmo=ritmo)
    if not filas:
        raise SystemExit("el recorte no produjo ninguna toma")
    return componer.escribir(cat, filas, salida, recorte["texto"])


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--titular")
    ap.add_argument("--texto")
    ap.add_argument("--fichero")
    ap.add_argument("--rss")
    ap.add_argument("--indice", type=int, default=0)
    ap.add_argument("--guion")
    ap.add_argument("--categoria", default="noticias")
    ap.add_argument("--seg-objetivo", type=float, default=20.0)
    ap.add_argument("--seg-por-toma", type=float, default=8.0)
    ap.add_argument("--ritmo", help="tipos separados por comas; pisa la categoria")
    ap.add_argument("--json", action="store_true", dest="como_json")
    a = ap.parse_args()

    fuente = ""
    if a.rss:
        titular, cuerpo, fuente = leer_rss(a.rss, a.indice)
    elif a.fichero:
        titular, cuerpo, fuente = leer_fichero(a.fichero)
    elif a.titular:
        titular, cuerpo = a.titular, a.texto or ""
    else:
        sys.exit("hace falta --titular, --fichero o --rss")

    recorte = redactar(titular, cuerpo, a.seg_objetivo)
    recorte["fuente"] = fuente
    n = 0
    if a.guion:
        ritmo = [x.strip() for x in a.ritmo.split(",") if x.strip()] if a.ritmo else None
        n = escribir_guion(
            recorte, a.guion, a.categoria, a.seg_por_toma, ritmo=ritmo or None
        )
        recorte["tomas"] = n
        recorte["guion"] = a.guion
    if a.como_json:
        print(json.dumps(recorte, ensure_ascii=False, indent=2))
        return
    print(f"  {recorte['palabras']} palabras · ~{recorte['duracion_est_s']} s")
    for frase in recorte["frases"]:
        print(f"  · {frase}")
    for aviso in recorte["avisos"]:
        print(f"  aviso: {aviso}")
    if a.guion:
        print(f"  guion: {a.guion} ({n} tomas)")


if __name__ == "__main__":
    main()
