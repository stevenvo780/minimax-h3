#!/usr/bin/env python3
"""Convierte una noticia real en las TOMAS habladas de un reel.

No inventa hechos. No parafrasea. El texto de cada toma sale del titular y
del cuerpo tal cual; lo unico que se permite es quitar la cola de una frase
larga, y eso deja un prefijo que sigue siendo substring de la fuente.

La medida esta en harness/redaccion.py y es UNA sola: la duracion real de la
toma. Antes habia dos presupuestos distintos y contradictorios, y por eso
salian tomas de 35 palabras en 8 segundos (4,4 pal/s, indecible) junto a
tomas de 8 palabras (1,0 pal/s, cinco segundos de cara callada).

Entradas:
  --titular + --texto
  --fichero  (primera linea = titular, o 'TITULAR:' / 'FUENTE:')
  --rss URL [--indice 0]   solo http(s); no se usa desde la UI (SSRF)

Salidas:
  --guion path.guion   compone el .guion de la categoria 'noticias'
  --json               el recorte, para inspeccionar sin escribir

Uso:
  noticias.py --titular "..." --texto "..." --guion out.guion
  noticias.py --fichero noticia.txt --guion out.guion --seg-objetivo 32

--seg-objetivo es la duracion del REEL, y ahora se cumple: con tomas de 8 s,
32 significa cuatro tomas y 32 segundos de video. Antes era el presupuesto de
un recorte intermedio y no correspondia con nada que se pudiera ver.
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
import redaccion  # noqa: E402

PALABRAS_POR_SEG = redaccion.PALABRAS_POR_SEG
MAX_CUERPO = 50_000
MAX_TITULAR = 400
USER_AGENT = "NewsLeters/1.0 (+local; generador de reels)"


def _limpia_html(texto: str) -> str:
    t = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", texto or "")
    t = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", t)
    t = re.sub(r"(?s)<[^>]+>", " ", t)
    t = html.unescape(t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def redactar(
    titular: str,
    cuerpo: str,
    seg_max_toma: float = 8.0,
    seg_objetivo: float = 32.0,
    una_toma: bool = False,
    vram_libre_mib: float = 13400.0,
) -> dict:
    """Devuelve las TOMAS del reel, cada una con su duracion en fotogramas.

    El reparto lo hace harness/redaccion.py. Aqui solo se limpia la entrada.
    `seg_max_toma` es la toma mas larga que cabe en el presupuesto de VRAM
    medido; cada toma acaba durando lo que su texto tarda en decirse.
    """
    titular = _limpia_html(titular)
    cuerpo = _limpia_html(cuerpo)
    if len(titular) > MAX_TITULAR:
        raise SystemExit(f"el titular supera {MAX_TITULAR} caracteres")
    if len(cuerpo) > MAX_CUERPO:
        raise SystemExit(f"el cuerpo supera {MAX_CUERPO} caracteres")
    if not titular.strip():
        raise SystemExit("hace falta un titular")
    if seg_max_toma <= 0:
        raise SystemExit("la duracion de toma tiene que ser positiva")

    try:
        if una_toma:
            # Primero se mide cuanto texto hay, sin techo de duracion; con eso
            # se elige la mayor resolucion 9:16 a la que esa locucion entera
            # cabe en UNA toma, y se compone contra esa duracion.
            #
            # El corte entre dos tomas del mismo plano no se puede hacer
            # invisible: ninguna llega al corte con la boca cerrada porque el
            # modelo estira la locucion hasta llenar la toma que se le pide.
            # La unica forma de que no se note es que no haya corte.
            tanteo = redaccion.guionizar(
                titular, cuerpo, 60.0, 9999, tomas_max=1, una_toma=True
            )
            frames, ancho, alto = redaccion.formato_una_toma(
                tanteo["palabras"], vram_libre_mib
            )
            segundos = frames / redaccion.FPS
            plan = redaccion.guionizar(
                titular, cuerpo, segundos, segundos, tomas_max=1,
                frames_max=frames, una_toma=True,
            )
            plan["formato"] = {"ancho": ancho, "alto": alto, "frames": frames}
        else:
            plan = redaccion.guionizar(titular, cuerpo, seg_max_toma, seg_objetivo)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    origen = titular + " " + cuerpo
    for toma in plan["tomas"]:
        # Cinturon y tirantes: si alguna vez un cambio en el recorte dejara de
        # ser literal, se descubre aqui y no despues de gastar la GPU.
        if not redaccion.en_fuente(toma, origen):
            raise SystemExit(f"toma que no esta en la fuente: {toma[:80]}")

    plan["titular"] = redaccion.frases(titular)[0]
    plan["texto"] = " ".join(plan["tomas"])
    return plan


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
    ritmo: list[str] | None = None,
) -> int:
    """Escribe el .guion con las tomas TAL COMO salieron de redactar().

    Antes esto pasaba `recorte["texto"]` a componer(), que volvia a partirlo
    con otro criterio: el trabajo de medir cada toma se tiraba y aparecian
    tomas de 35 palabras. Aqui las tomas viajan enteras.
    """
    cat = componer.cargar(categoria)
    filas = componer.repartir(
        cat, recorte["tomas"], ritmo=ritmo, frames=recorte.get("frames")
    )
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
    ap.add_argument(
        "--seg-objetivo", type=float, default=32.0,
        help="duracion del reel en segundos; se redondea a tomas enteras",
    )
    ap.add_argument(
        "--seg-por-toma", type=float, default=8.0,
        help="toma MAS LARGA que cabe en VRAM; cada toma dura lo que su texto",
    )
    ap.add_argument("--ritmo", help="tipos separados por comas; pisa la categoria")
    ap.add_argument(
        "--una-toma", action="store_true",
        help="toda la noticia en UN plano continuo; elige la mayor resolucion "
             "9:16 a la que su locucion entera cabe en la VRAM libre",
    )
    ap.add_argument(
        "--vram-libre", type=float, default=13400.0,
        help="MiB de VRAM libres; gobierna el tamaño en modo --una-toma",
    )
    ap.add_argument(
        "--formato-salida",
        help="fichero donde escribir ANCHO/ALTO/FRAMES para que lo lea el shell",
    )
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

    recorte = redactar(
        titular, cuerpo, a.seg_por_toma, a.seg_objetivo,
        una_toma=a.una_toma, vram_libre_mib=a.vram_libre,
    )
    if a.formato_salida and recorte.get("formato"):
        f = recorte["formato"]
        with open(a.formato_salida, "w", encoding="utf-8") as fh:
            fh.write("ANCHO=%d\nALTO=%d\nFRAMES=%d\n"
                     % (f["ancho"], f["alto"], f["frames"]))
    recorte["fuente"] = fuente
    n = 0
    if a.guion:
        ritmo = [x.strip() for x in a.ritmo.split(",") if x.strip()] if a.ritmo else None
        n = escribir_guion(recorte, a.guion, a.categoria, ritmo=ritmo or None)
        recorte["planos"] = n
        recorte["guion"] = a.guion
    if a.como_json:
        print(json.dumps(recorte, ensure_ascii=False, indent=2))
        return
    print(
        f"  {len(recorte['tomas'])} tomas habladas · {recorte['palabras']} palabras · "
        f"{recorte['duracion_s']:.1f} s de voz"
    )
    for i, (toma, r, f) in enumerate(
        zip(recorte["tomas"], recorte["ritmos"], recorte["frames"]), 1
    ):
        print(f"  {i}. [{f} f · {f / redaccion.FPS:.1f} s · {r:.2f} pal/s] {toma}")
    for aviso in recorte["avisos"]:
        print(f"  aviso: {aviso}")
    if a.guion:
        print(f"  guion: {a.guion} ({n} planos)")


if __name__ == "__main__":
    main()
