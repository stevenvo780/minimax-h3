#!/usr/bin/env python3
"""De un TEMA a titular+cuerpo investigado. No inventa.

Busca en produccion/noticias/dia/*.txt la noticia cuyo titular, tema y
cuerpo mejor cubren las palabras del tema. Escribe el fichero de noticia
(listo para noticias.py --fichero) y un JSON con url de fuente.

Uso:
  investigar.py --tema "avion miami" --salida noticia.txt
  investigar.py --tema "afd alemania" --json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata

_HARNESS = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(_HARNESS)
if _HARNESS not in sys.path:
    sys.path.insert(0, _HARNESS)
import noticias  # noqa: E402

DIA = os.path.join(RAIZ, "produccion", "noticias", "dia")
STOP = {
    "el", "la", "los", "las", "un", "una", "de", "del", "en", "y", "o", "a",
    "al", "por", "con", "para", "que", "se", "su", "sus", "es", "son",
}


def _norm(texto: str) -> str:
    t = unicodedata.normalize("NFD", texto.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return t


def _tokens(texto: str) -> set[str]:
    return {
        w
        for w in re.findall(r"[a-z0-9áéíóúñ]+", _norm(texto))
        if len(w) > 2 and w not in STOP
    }


def listar() -> list[dict]:
    if not os.path.isdir(DIA):
        raise SystemExit(f"no hay catalogo de noticias del dia: {DIA}")
    items = []
    for name in sorted(os.listdir(DIA)):
        if not name.endswith(".txt"):
            continue
        path = os.path.join(DIA, name)
        titular, cuerpo, fuente = noticias.leer_fichero(path)
        raw = open(path, encoding="utf-8").read()
        tema = ""
        for line in raw.splitlines():
            m = re.match(r"^TEMA\s*:\s*(.*)$", line.strip(), re.I)
            if m:
                tema = m.group(1).strip()
                break
        items.append(
            {
                "id": name[:-4],
                "path": path,
                "titular": titular,
                "cuerpo": cuerpo,
                "fuente": fuente,
                "tema": tema,
                "texto": raw,
            }
        )
    if not items:
        raise SystemExit("el catalogo de noticias del dia esta vacio")
    return items


def elegir(tema: str, items: list[dict] | None = None) -> dict:
    tema = (tema or "").strip()
    if not tema:
        raise SystemExit("hace falta un tema")
    items = items if items is not None else listar()
    q = _tokens(tema)
    if not q:
        raise SystemExit("el tema no tiene palabras utiles")
    best = None
    best_score = -1
    for item in items:
        hay = _tokens(
            " ".join(
                [
                    item["id"].replace("-", " "),
                    item.get("tema") or "",
                    item["titular"],
                    item["cuerpo"],
                ]
            )
        )
        score = len(q & hay)
        if item["id"] in _norm(tema).replace(" ", "-"):
            score += 2
        if score > best_score:
            best, best_score = item, score
    if best is None or best_score <= 0:
        raise SystemExit(f"ninguna noticia del catalogo cubre el tema '{tema}'")
    return best


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tema", required=True)
    ap.add_argument("--salida")
    ap.add_argument("--json", action="store_true", dest="como_json")
    a = ap.parse_args()
    item = elegir(a.tema)
    payload = {
        "id": item["id"],
        "titular": item["titular"],
        "cuerpo": item["cuerpo"],
        "fuente": item["fuente"],
        "path": item["path"],
        "tema": a.tema,
    }
    if a.salida:
        os.makedirs(os.path.dirname(os.path.abspath(a.salida)) or ".", exist_ok=True)
        open(a.salida, "w", encoding="utf-8").write(item["texto"])
        sidecar = a.salida + ".fuente.json"
        open(sidecar, "w", encoding="utf-8").write(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
        )
    if a.como_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    print(f"  {item['id']}")
    print(f"  {item['titular']}")
    print(f"  fuente: {item['fuente']}")
    if a.salida:
        print(f"  escrito: {a.salida}")


if __name__ == "__main__":
    main()
