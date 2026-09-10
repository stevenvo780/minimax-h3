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
# Tipos que consumen el TEXTO (dialogo). El resto del ritmo se rellena con
# planos de apoyo y no lleva narracion: el modelo solo genera voz con una cara.
# Vive en redaccion.py, que es quien decide que se dice y en cuantas tomas.
sys.path.insert(0, os.path.join(RAIZ, "harness"))
from redaccion import FRAMES_APOYO, TIPOS_VOZ  # noqa: E402

def cargar(nombre):
    f = os.path.join(CATS, nombre + ".json")
    if not os.path.isfile(f):
        disp = ", ".join(sorted(x[:-5] for x in os.listdir(CATS) if x.endswith(".json")))
        sys.exit(f"no existe la categoria '{nombre}'. Disponibles: {disp}")
    return json.load(open(f, encoding="utf-8"))

_ABREV = re.compile(
    r"\b(EE\.UU|U\.S|EEUU|Sr|Sra|Dr|Dra|n[oº]|etc)\.",
    re.IGNORECASE,
)


def frases(texto):
    t = re.sub(r"\s+", " ", texto.strip())
    t = _ABREV.sub(lambda m: m.group(0)[:-1] + "\uE000", t)
    partes = re.split(r"(?<=[.!?])\s+", t)
    return [p.replace("\uE000", ".").strip() for p in partes if p.strip()]

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

def repartir(cat, bloques, ritmo=None, frames=None):
    """Reparte BLOQUES YA MEDIDOS entre los planos que pide el ritmo.

    Separado de componer() porque las noticias llegan con las tomas ya
    decididas por harness/redaccion.py: volver a partirlas aqui era
    justamente el bug que metia 35 palabras en una toma de 8 segundos.

    `frames` opcional trae la duracion que redaccion.py calculo para cada
    bloque de texto. Un plano de apoyo no lleva voz, asi que se queda sin
    duracion propia y el runner le aplica la de la linea de ordenes.
    """
    bloques = list(bloques)
    frames = list(frames) if frames else []
    ritmo = list(ritmo) if ritmo else list(cat.get("ritmo") or ["habla"])
    apoyos = list(cat.get("apoyos") or [])
    filas, i_bloque, i_apoyo, i_ritmo = [], 0, 0, 0
    # Se recorre el ritmo hasta colocar TODOS los bloques de texto. Los planos que
    # el ritmo pida y no sean 'habla' se rellenan con los apoyos, en circulo.
    while i_bloque < len(bloques):
        tipo = ritmo[i_ritmo % len(ritmo)]; i_ritmo += 1
        if tipo in TIPOS_VOZ:
            f = frames[i_bloque] if i_bloque < len(frames) else None
            filas.append((bloques[i_bloque], tipo, f)); i_bloque += 1
        elif apoyos:
            # El apoyo dura menos: no lleva voz que llenar.
            filas.append((apoyos[i_apoyo % len(apoyos)], tipo, FRAMES_APOYO)); i_apoyo += 1
        # sin apoyos definidos, un ritmo sin voz se salta en vez de inventar
    return filas

def componer(cat, texto, seg_por_toma, ritmo=None):
    """Camino clasico: un churro de texto que aqui se parte en tomas."""
    return repartir(cat, agrupar(frases(texto), seg_por_toma), ritmo=ritmo)

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
    for i, fila in enumerate(filas):
        cont, tipo = fila[0], fila[1]
        f = fila[2] if len(fila) > 2 else None
        # Un plano de apoyo (manos, calle, portatil) NO se ancla al rostro:
        # anclarlo le mete la cara de la presentadora en un plano que su propio
        # prompt describe sin nadie, y encima paga el sobrecoste de VRAM del
        # camino anclado para estropear la imagen.
        modo = "inicio" if i == 0 or tipo not in TIPOS_VOZ else "ancla"
        # 'frames=N' es un campo CON NOMBRE: los campos 5 y 6 ya eran escena y
        # ambiente propias. Es opcional, y un guion de cuatro campos escrito a
        # mano sigue valiendo exactamente igual.
        lineas.append(
            f"TOMA|{cont}|{modo}|{tipo}" + (f"|frames={f}" if f else "")
        )
    os.makedirs(os.path.dirname(os.path.abspath(salida)) or ".", exist_ok=True)
    open(salida, "w", encoding="utf-8").write("\n".join(lineas) + "\n")
    return len(filas)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("categoria"); ap.add_argument("salida")
    ap.add_argument("--texto"); ap.add_argument("--fichero")
    # 14,4 s era la toma del retrato de filosofia (345 f). El producto de hoy
    # son tomas de 8 s (192 f); quien componga otra cosa que lo diga.
    ap.add_argument("--seg-por-toma", type=float, default=8.0)
    ap.add_argument(
        "--ritmo",
        help="ritmo de tipos separado por comas; pisa el de la categoria",
    )
    a = ap.parse_args()
    if a.fichero:
        texto = open(a.fichero, encoding="utf-8").read()
    elif a.texto:
        texto = a.texto
    else:
        sys.exit("hace falta --texto o --fichero")
    cat = cargar(a.categoria)
    ritmo = [x.strip() for x in a.ritmo.split(",") if x.strip()] if a.ritmo else None
    filas = componer(cat, texto, a.seg_por_toma, ritmo=ritmo)
    if not filas: sys.exit("el texto no produjo ninguna toma")
    n = escribir(cat, filas, a.salida, texto)
    # Cuenta TIPOS_VOZ, no solo 'habla': con un guion de noticias este contador
    # decia "0 habladas, 4 de apoyo" para un reel entero de presentadora.
    hab = sum(1 for fila in filas if fila[1] in TIPOS_VOZ)
    print(f"  {a.salida}")
    segundos = sum(
        (fila[2] / 24 if len(fila) > 2 and fila[2] else a.seg_por_toma)
        for fila in filas
    )
    print(f"  {n} tomas ({hab} habladas, {n-hab} de apoyo) · {segundos:.1f} s")
