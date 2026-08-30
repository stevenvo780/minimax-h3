#!/usr/bin/env python3
"""Compone un .guion a partir de un TEXTO y una CATEGORIA.

Hasta ahora cada guion se escribia a mano, repitiendo la escena, el ambiente y la
musica en cada fichero, y repartiendo el texto en tomas a ojo. Eso no escala a
varias categorias ni permite probar el mismo texto en dos formatos.

Aqui una CATEGORIA es un mundo audiovisual reutilizable (escena, ambiente,
musica, ritmo de planos, planos de apoyo) y el guion se compone dando solo el
texto. El harness:
  1. parte el texto en frases y las agrupa en TOMAS que quepan en la duracion
  2. asigna un tipo de plano a cada toma segun el RITMO de la categoria
  3. intercala los planos de APOYO donde el ritmo pida algo que no sea habla
  4. deja la toma 1 en 'inicio' y las demas en 'ancla'

Limite del modelo que condiciona todo esto, y que conviene tener presente: solo
genera voz sincronizada con una CARA. En un plano de apoyo no hay narracion, hay
silencio. Por eso el ritmo de una categoria no es decorativo: decide donde se
INTERRUMPE el discurso.

Uso:
  componer.py <categoria> <salida.guion> --texto "frase. frase. frase."
  componer.py <categoria> <salida.guion> --fichero texto.txt [--seg-por-toma 14]
"""
import json, os, re, sys, argparse, textwrap

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATS = os.path.join(RAIZ, "harness", "categorias")

# ~2.6 palabras por segundo es el ritmo medido en las piezas que salieron bien:
# 14.4 s de toma con unas 37 palabras de dialogo.
PALABRAS_POR_SEG = 2.6

def cargar(nombre):
    f = os.path.join(CATS, nombre + ".json")
    if not os.path.isfile(f):
        disp = ", ".join(sorted(x[:-5] for x in os.listdir(CATS) if x.endswith(".json")))
        sys.exit(f"no existe la categoria '{nombre}'. Disponibles: {disp}")
    return json.load(open(f, encoding="utf-8"))

def frases(texto):
    t = re.sub(r"\s+", " ", texto.strip())
    partes = re.split(r"(?<=[.!?])\s+", t)
    return [p.strip() for p in partes if p.strip()]

def agrupar(fs, seg_por_toma):
    """Agrupa frases en tomas sin partir ninguna: una frase cortada a la mitad
    suena mal y el modelo la termina como puede."""
    tope = int(seg_por_toma * PALABRAS_POR_SEG)
    tomas, actual, n = [], [], 0
    for f in fs:
        w = len(f.split())
        if actual and n + w > tope:
            tomas.append(" ".join(actual)); actual, n = [f], w
        else:
            actual.append(f); n += w
    if actual: tomas.append(" ".join(actual))
    return tomas

def componer(cat, texto, seg_por_toma):
    bloques = agrupar(frases(texto), seg_por_toma)
    ritmo = cat.get("ritmo") or ["habla"]
    apoyos = list(cat.get("apoyos") or [])
    filas, i_bloque, i_apoyo, i_ritmo = [], 0, 0, 0
    # Se recorre el ritmo hasta colocar TODOS los bloques de texto. Los planos que
    # el ritmo pida y no sean 'habla' se rellenan con los apoyos, en circulo.
    while i_bloque < len(bloques):
        tipo = ritmo[i_ritmo % len(ritmo)]; i_ritmo += 1
        if tipo == "habla":
            filas.append((bloques[i_bloque], tipo)); i_bloque += 1
        elif apoyos:
            filas.append((apoyos[i_apoyo % len(apoyos)], tipo)); i_apoyo += 1
        # sin apoyos definidos, un ritmo no-habla se salta en vez de inventar
    return filas

def escribir(cat, filas, salida, texto_original):
    cab = textwrap.dedent(f"""\
        # ── {cat['nombre'].upper()} · compuesto por harness/componer.py ──────────────
        # {cat['descripcion']}
        #
        # {len(filas)} tomas · ritmo de la categoria: {'+'.join(cat.get('ritmo') or ['habla'])}
        #
        # NO editar a mano si se piensa recomponer: este fichero se regenera.
        # Para cambiar el aspecto, edita harness/categorias/{cat['nombre']}.json.
        #
        # {cat.get('notas','')}
        """)
    lineas = [cab,
              f"@TIPO {(cat.get('ritmo') or ['habla'])[0]}",
              f"@ESCENA {cat['escena']}",
              f"@AMBIENTE {cat['ambiente']}",
              f"@MUSICA {cat['musica']}",
              ""]
    for i, (cont, tipo) in enumerate(filas):
        modo = "inicio" if i == 0 else "ancla"
        lineas.append(f"TOMA|{cont}|{modo}|{tipo}")
    os.makedirs(os.path.dirname(os.path.abspath(salida)) or ".", exist_ok=True)
    open(salida, "w", encoding="utf-8").write("\n".join(lineas) + "\n")
    return len(filas)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("categoria"); ap.add_argument("salida")
    ap.add_argument("--texto"); ap.add_argument("--fichero")
    ap.add_argument("--seg-por-toma", type=float, default=14.4)
    a = ap.parse_args()
    if a.fichero:
        texto = open(a.fichero, encoding="utf-8").read()
    elif a.texto:
        texto = a.texto
    else:
        sys.exit("hace falta --texto o --fichero")
    cat = cargar(a.categoria)
    filas = componer(cat, texto, a.seg_por_toma)
    if not filas: sys.exit("el texto no produjo ninguna toma")
    n = escribir(cat, filas, a.salida, texto)
    hab = sum(1 for _, t in filas if t == "habla")
    print(f"  {a.salida}")
    print(f"  {n} tomas ({hab} habladas, {n-hab} de apoyo) · "
          f"{n*a.seg_por_toma:.0f} s a {a.seg_por_toma} s por toma")
