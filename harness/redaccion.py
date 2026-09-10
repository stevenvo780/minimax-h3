#!/usr/bin/env python3
"""De una noticia al TEXTO DE CADA TOMA, ya medido para que quepa hablado.

Por que existe este modulo
──────────────────────────
Antes habia dos presupuestos de palabras que no se hablaban entre si:

  * ``noticias.redactar()`` recortaba contra ``seg_objetivo/2`` (con
    ``--seg-objetivo 20``, tomas imaginarias de 10 s = 26 palabras),
  * ``componer.agrupar()`` agrupaba contra la toma REAL (192 f / 24 = 8 s =
    20 palabras) y ademas nunca parte una frase,

asi que un trozo de 35 palabras entraba entero en una toma de 8 segundos. Eso
son 4,4 palabras/s cuando el ritmo medido del proyecto es 2,6: el modelo no
puede decirlo, y lo que sale es habla atropellada o una frase que se corta.
El sintoma opuesto tambien estaba: el titular solo, 8 palabras en 8 segundos,
es 1,0 palabras/s — tres segundos de voz y cinco de presentadora mirando.

Aqui hay UN solo presupuesto, y es el de la toma real. La unidad de trabajo es
la TOMA, no un churro de texto que alguien vuelve a partir mas tarde.

Que se conserva del diseño anterior
───────────────────────────────────
No se inventa nada. Cada toma se construye con frases del titular y del cuerpo
tal cual, y el unico recorte permitido es quitar la COLA de una frase larga.
Un prefijo sigue siendo substring de la fuente, asi que el verificador
(``sondear-dia.sh``) puede seguir comprobando que nada salio de la nada.

Que cambia
──────────
1. Una toma NUNCA empieza a media frase. Antes ``_partir_larga`` cortaba por
   comas y producia tomas sin verbo que la presentadora leia como noticias:
   "homicidio imprudente y organizacion criminal, tras apreciar indicios...".
2. Para acortar una frase que no cabe se corta la cola SOLO en marcadores que
   dejan detras una oracion principal completa. La coma pelada esta excluida a
   proposito: en "Witkoff y Kushner, yerno del presidente Trump, impulsaron..."
   la coma abre una aposicion, y cortar ahi deja un sintagma sin verbo.
3. Lo que ya se dijo no se repite. La entradilla de un teletipo reformula el
   titular por convencion periodistica; decir las dos cosas seguidas gastaba la
   mitad del reel en contar una vez lo mismo, y lo que de verdad paso —cinco
   muertos, un Boeing 767-300— no llegaba a decirse nunca.
4. Cada toma sale con su ritmo medido. Si una queda fuera de banda, se avisa:
   antes eso no se veia hasta ver el video, con la GPU ya gastada.
"""
from __future__ import annotations

import re
import unicodedata

# Tipos de plano que llevan una cara hablando: los unicos que consumen texto,
# necesitan subtitulo y se comprueban contra la fuente. El espejo para bash
# esta en lib/prompt.sh::PROMPT_TIPOS_VOZ.
TIPOS_VOZ = frozenset({"habla", "informativo"})

# Ritmo medido en las piezas que salieron bien. Nacio de los retratos de
# filosofia (14,4 s de toma con unas 37 palabras) y se ha sostenido en los
# reels de presentadora: es una propiedad del modelo hablando español, no del
# formato. Si algun dia se remide, este es el unico sitio donde tocarlo.
PALABRAS_POR_SEG = 2.6

# Banda aceptable alrededor de ese ritmo. Fuera de aqui hay defecto audible:
# por debajo, segundos de cara callada; por encima, habla atropellada o la
# frase se corta antes de terminar.
RITMO_MIN = 1.6
RITMO_MAX = 3.0

# Holgura sobre la capacidad nominal de la toma. 1,15 deja llegar a 3,0 pal/s,
# que es el techo de la banda.
HOLGURA = 1.15
# Por debajo de esto una toma se considera vacia y se intenta rellenar.
SUELO_REL = 0.62

_MARCA = ""

# Marcadores donde SI se puede cortar la cola de una frase: todos abren un
# complemento o una subordinada, asi que lo que queda delante es una oracion
# que se sostiene sola.
MARCADORES_COLA = (
    " pese a ", " a pesar de ", " tras ", " despues de ", " antes de ",
    " mientras ", " aunque ", " porque ", " ya que ", " puesto que ",
    " segun ", " para ", " por ", " contra ", " con ", " sin ",
    " durante ", " desde ", " hasta ", " entre ", " sobre ",
    " y ", " e ", " o ", " pero ", " que ",
)

# Una toma no puede terminar en una palabra que pide continuacion.
FINAL_PROHIBIDO = frozenset(
    """de del a al en y e o u con sin por para que el la los las un una unos
    unas su sus lo le les se como cuando donde mas entre sobre tras desde
    hasta segun contra durante ante bajo mientras pese antes despues aunque
    porque ni pero si""".split()
)

# Palabras sin carga informativa: no cuentan para decidir si una frase repite
# lo ya dicho.
_VACIAS = frozenset(
    """el la los las un una unos unas de del en y o a al por con para que se
    su sus es son ha han fue era lo le les como mas este esta estos estas ese
    esa esos esas tras pese segun desde hasta entre sobre no si ya muy tambien
    entre cuando donde porque pero aunque durante ante bajo sin""".split()
)

# ── Verbo finito ───────────────────────────────────────────────────────────
# Una toma sin verbo no es una noticia, es un rotulo: "El enviado de EE.UU.
# Steve Witkoff y Jared Kushner, yerno del presidente Donald Trump." Eso se
# emitio de verdad y la presentadora lo leyo como si informara de algo.
#
# No hay analizador morfologico aqui ni hace falta: basta con reconocer las
# formas finitas que aparecen en prosa periodistica. Se combina una lista
# cerrada (irregulares y presentes de los verbos con los que se cuentan
# noticias) con terminaciones que en español casi solo son verbos. Las tildes
# NO se quitan a proposito: sin ellas "acuerdo" y "logró" acaban igual.
#
# Ante la duda, la respuesta es "no hay verbo": una frase descartada de mas es
# barata, una toma sin verbo se ve en el video.
_VERBO_FIN = re.compile(
    r"(ó|ió|aron|ieron|eron|ará|erá|irá|arán|erán|irán|aba|aban)$",
    re.IGNORECASE,
)
_VERBO_CERRADO = frozenset(
    """es son era eran fue fueron será serán sería serían está están estaba
    estaban estuvo estuvieron ha han había habían hay habrá habrán tiene
    tienen tenía tenían tuvo tuvieron va van iba iban fueron puede pueden
    podía podían debe deben dice dicen dijo dijeron hace hacen hizo hicieron
    sigue siguen seguía queda quedan quedó da dan dio dieron ve ven vio vieron
    sabe saben supo quiere quieren quiso viene vienen vino pone ponen puso
    sale salen salió abre abren afirma afirman alcanza alcanzan anuncia
    anuncian apunta apuntan aprueba aprueban arrasa asciende asegura aseguran
    atribuye aumenta avanza cae caen celebra cifra confirma considera crece
    critica denuncia descarta desconoce desconocen destaca detiene entra
    entran exige explica fija gana impulsa incluye indica informa insiste
    investiga lidera llega llegan mantiene mantienen muere mueren niega
    niegan ocurre ordena pide piden plantea prevé prohíbe propone reclama
    recuerda rechaza registra resulta revela roza señala sostiene sostienen
    sube sugiere supera supone vota votan""".split()
)


def tiene_verbo(texto: str) -> bool:
    """¿Hay al menos una forma verbal finita reconocible?"""
    for palabra in re.findall(r"[\wáéíóúüñÁÉÍÓÚÜÑ]+", texto or ""):
        baja = palabra.lower()
        if baja in _VERBO_CERRADO:
            return True
        if len(baja) >= 4 and _VERBO_FIN.search(baja):
            return True
    return False


_ABREV = re.compile(
    r"\b(EE\.UU|U\.S|EEUU|Sr|Sra|Dr|Dra|n[oº]|etc|Ud|Vd|Av|Pza)\.",
    re.IGNORECASE,
)


def palabras(texto: str) -> list[str]:
    return [w for w in re.split(r"\s+", (texto or "").strip()) if w]


def frases(texto: str) -> list[str]:
    """Parte en frases. 'EE.UU.' no es un final de frase."""
    t = re.sub(r"\s+", " ", (texto or "").strip())
    if not t:
        return []
    t = _ABREV.sub(lambda m: m.group(0)[:-1] + _MARCA, t)
    salida = []
    for parte in re.split(r"(?<=[.!?…])\s+", t):
        parte = parte.replace(_MARCA, ".").strip(" \t«»\"'“”")
        if parte:
            salida.append(parte)
    return salida


def _sin_tildes(texto: str) -> str:
    t = unicodedata.normalize("NFD", (texto or "").lower())
    return "".join(c for c in t if unicodedata.category(c) != "Mn")


# Terminaciones que se recortan SOLO para comparar dos frases entre si. La
# entradilla de un teletipo reformula el titular por convencion periodistica:
# "arrasa en Sajonia-Anhalt" y "logro una victoria historica en las elecciones
# regionales de Sajonia-Anhalt" cuentan lo mismo con otras palabras. Comparando
# palabras crudas no se parecen, y el reel gastaba sus dos primeras tomas —la
# mitad de su duracion— en contar un hecho dos veces. Esto no es un lematizador
# ni pretende serlo: recorta lo justo para que salio/salido e impulsa/impulsaron
# caigan en la misma raiz.
_SUFIJOS = (
    "aciones", "amiento", "imiento", "aremos", "eremos", "iremos", "ieron",
    "mente", "adas", "ados", "ando", "aran", "aron", "cion", "endo",
    "eran", "eron", "idas", "idos", "iran", "sion", "ada", "ado", "ara",
    "era", "ida", "ido", "ira", "an", "ar", "as", "en", "er", "es", "ir",
    "os", "a", "e", "o",
)


def raiz(palabra: str) -> str:
    """Raiz aproximada: el prefijo que queda al quitar una terminacion."""
    for sufijo in _SUFIJOS:
        if len(palabra) - len(sufijo) >= 4 and palabra.endswith(sufijo):
            palabra = palabra[: -len(sufijo)]
            break
    # La 'd' final del participio: "salido" acaba en "salid" y "salio" en
    # "sali". Sin este paso, la entradilla que dice "se ha salido de la pista"
    # no se reconocia como el titular que dice "se salio de la pista".
    if len(palabra) > 4 and palabra.endswith("d"):
        palabra = palabra[:-1]
    return palabra


def contenido(texto: str) -> set[str]:
    """Palabras con carga informativa, normalizadas y reducidas a su raiz."""
    return {
        raiz(w)
        for w in re.findall(r"[a-z0-9]+", _sin_tildes(texto))
        if len(w) > 2 and w not in _VACIAS
    }


def ritmo(texto: str, segundos: float) -> float:
    return len(palabras(texto)) / segundos if segundos > 0 else 0.0


def _cerrar(texto: str) -> str:
    texto = texto.rstrip(" ,;:")
    return texto if texto[-1:] in ".!?…" else texto + "."


def acortar(frase: str, tope: int, minimo: int) -> str | None:
    """Prefijo mas largo de `frase` que quepa en `tope` palabras.

    Solo corta en un marcador de cola, y nunca dentro de una enumeracion de
    cifras ("los dias 30 y 31 de julio" no puede quedar en "los dias 30").
    Devuelve None si no hay ningun corte que deje una oracion presentable: en
    ese caso la frase se descarta entera, que es preferible a decir un trozo
    sin verbo.
    """
    ws = palabras(frase)
    if len(ws) <= tope:
        return _cerrar(frase)

    plano = " " + _sin_tildes(frase) + " "
    mejor = 0
    for marcador in MARCADORES_COLA:
        desde = 0
        while True:
            i = plano.find(marcador, desde)
            if i < 0:
                break
            desde = i + 1
            n = len(palabras(plano[:i]))
            if not (minimo <= n <= tope and n > mejor):
                continue
            ultima = _sin_tildes(ws[n - 1]).strip(".,;:()")
            if ultima in FINAL_PROHIBIDO:
                continue
            # Sin verbo lo que queda es un sintagma, no una oracion.
            if not tiene_verbo(" ".join(ws[:n])):
                continue
            if marcador in (" y ", " e ", " o "):
                # No se parte una enumeracion por su ultima conjuncion: "los
                # dias 30 y 31 de julio" no puede quedar en "los dias 30", ni
                # "entre EE.UU., Rusia y Ucrania" en "entre EE.UU., Rusia".
                # La coma cercana es lo que delata que hay una lista.
                if re.fullmatch(r"[0-9.,%]+", ultima):
                    continue
                if any(w.endswith(",") for w in ws[max(0, n - 3):n]):
                    continue
            mejor = n
    return _cerrar(" ".join(ws[:mejor])) if mejor else None


# Longitud minima de una cadena de palabras repetida para considerarla una
# reiteracion literal. Con 5 se caza "al menos cinco personas murieron", que
# salia en la toma 1 y otra vez en la toma 2 del reel del avion de Miami; con 4
# se cazaria tambien "de inmigrantes en Ceuta", que en la pieza de Ceuta es
# inevitable porque es el sujeto de la noticia.
REPETICION_LITERAL = 5

# Nexos por los que se puede cortar el arranque repetido de una frase.
_NEXOS = ("y", "e", "pero", "aunque", "mientras", "ademas")


def _fichas(texto: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", _sin_tildes(texto))


def prefijo_repetido(unidad: str, dichas_fichas: list[str], minimo: int) -> int:
    """Cuantas palabras del PRINCIPIO de `unidad` ya se han dicho seguidas.

    Devuelve 0 si no hay una cadena repetida bastante larga. Solo mira el
    principio: repetir al arrancar es lo que se oye como tartamudeo, y es
    ademas lo que se puede quitar dejando una frase que sigue en pie.
    """
    fichas = _fichas(unidad)
    if len(fichas) < minimo:
        return 0
    n = len(dichas_fichas)
    mejor = 0
    for largo in range(min(len(fichas), n), minimo - 1, -1):
        aguja = fichas[:largo]
        for i in range(n - largo + 1):
            if dichas_fichas[i:i + largo] == aguja:
                return largo
    return mejor


def podar_repeticion(unidad: str, largo: int) -> str | None:
    """Quita las `largo` primeras palabras y lo que quede de nexo.

    "Al menos cinco personas murieron y otras cinco resultaron heridas, tres
    de ellas de gravedad." queda en "Otras cinco resultaron heridas, tres de
    ellas de gravedad.", que es exactamente lo que aporta. Sigue siendo texto
    literal de la fuente: en_fuente() compara en minusculas, asi que poner la
    inicial en mayuscula no lo convierte en invento.
    """
    palabras_unidad = palabras(unidad)
    if largo >= len(palabras_unidad):
        return None
    resto = palabras_unidad[largo:]
    while resto and _sin_tildes(resto[0]).strip(",;:") in _NEXOS:
        resto = resto[1:]
    while resto and resto[0].strip(",;:") == "":
        resto = resto[1:]
    if len(resto) < 5:
        return None
    texto = " ".join(resto).lstrip(",;: ")
    if not tiene_verbo(texto):
        return None
    return _cerrar(texto[0].upper() + texto[1:])


def guionizar(
    titular: str,
    cuerpo: str,
    seg_max_toma: float,
    seg_objetivo: float = 32.0,
    tomas_max: int = 8,
    repeticion_max: float = 0.55,
    nuevas_min: int = 3,
    frames_max: int | None = None,
    una_toma: bool = False,
) -> dict:
    """titular + cuerpo -> las tomas de un reel, cada una con SU duracion.

    `seg_max_toma` es la toma mas larga que el modelo puede generar con el
    presupuesto de VRAM medido (8 s = 192 f a 416x736). Es el techo contra el
    que se empaqueta el texto. Despues cada toma se ajusta a lo que su texto
    tarda en decirse: un titular de ocho palabras no ocupa ocho segundos.

    `seg_objetivo` es la duracion del reel, y ahora se cumple de verdad: se
    dejan de añadir tomas cuando la suma de sus duraciones reales la alcanza.
    """
    if seg_max_toma <= 0:
        raise ValueError("seg_max_toma tiene que ser positivo")
    if tomas_max < 1:
        raise ValueError("tomas_max tiene que ser al menos 1")

    # El techo real es el del modelo, no lo que pida quien llama: cada toma ya
    # dura lo que su texto. Pedir tomas cortas y ademas recortar el texto a esa
    # longitud tiraba frases enteras —incluido el titular, que es el gancho— y
    # ya no hace falta, porque una toma corta se consigue con menos fotogramas.
    techo = frames_max if frames_max else FRAMES_MAX
    seg_max_toma = min(seg_max_toma, techo / FPS)
    # La vara con la que se ELIGE el texto es fija, y no la duracion de la
    # toma. Si se deja que crezca con la toma, `acortar` conserva frases mas
    # largas, esas frases traen mas palabras nuevas y la entradilla repetida
    # vuelve a pasar el filtro: medido, con una toma de 60 s la pieza de Ceuta
    # pasaba de 33 palabras a 128 y decia dos veces lo de la juez. Que se diga
    # de corrido o en tres cortes es una decision de capacidad; QUE se dice es
    # una decision editorial, y no puede depender de cuanta VRAM haya.
    capacidad = min(seg_max_toma, SEG_REFERENCIA) * PALABRAS_POR_SEG
    tope = max(6, int(capacidad * HOLGURA))
    suelo = max(4, int(capacidad * SUELO_REL))
    minimo_corte = max(6, int(capacidad * 0.45))

    avisos: list[str] = []
    unidades: list[str] = []
    for i, frase in enumerate(frases(titular)[:1] + frases(cuerpo)):
        corta = acortar(frase, tope, minimo_corte)
        if corta is None:
            if i == 0:
                # El titular es el gancho del reel: sin el no hay reel. Si no
                # hay un corte limpio se dice entero y se avisa del ritmo.
                unidades.append(_cerrar(frase))
                avisos.append(
                    "el titular no tiene un corte limpio y se dice entero: %d palabras"
                    % len(palabras(frase))
                )
                continue
            avisos.append(
                "frase descartada: no cabe en %.1f s sin dejarla coja · %s…"
                % (seg_max_toma, frase[:60])
            )
            continue
        unidades.append(corta)
    if not unidades:
        raise ValueError("no hay ninguna frase que quepa en una toma")

    dichas: set[str] = set()
    dichas_fichas: list[str] = []
    tomas: list[str] = []
    frames: list[int] = []
    duracion = 0.0
    actual: list[str] = []
    n_actual = 0

    def cerrar_toma() -> None:
        nonlocal actual, n_actual, duracion
        if not actual:
            return
        toma = " ".join(actual)
        f = frames_para(toma, maximo=techo)
        tomas.append(toma)
        frames.append(f)
        duracion += f / FPS
        actual, n_actual = [], 0

    def lleno() -> bool:
        return len(tomas) >= tomas_max or duracion >= seg_objetivo

    for unidad in unidades:
        if lleno():
            break
        carga = contenido(unidad)
        nuevas = carga - dichas
        # El solape se mide contra el conjunto MAS PEQUEÑO de los dos. Contra
        # la frase nueva a secas, una entradilla larga que repite el titular
        # entero salia con poco porcentaje —tiene muchas palabras propias— y
        # se colaba. Cuando ya se ha dicho mucho, min() vuelve a ser la frase
        # nueva y el criterio es el de siempre.
        referencia = min(len(carga), len(dichas)) if dichas else len(carga)
        repetido = (len(carga) - len(nuevas)) / referencia if referencia else 0.0
        if carga and (len(nuevas) < nuevas_min or repetido >= repeticion_max):
            avisos.append(
                "ya dicho al %.0f%%, se salta · %s…" % (repetido * 100, unidad[:55])
            )
            continue
        # Reiteracion LITERAL, que es distinta del solape de vocabulario de
        # arriba: una frase puede aportar palabras nuevas de sobra y aun asi
        # arrancar repitiendo una clausula entera de la toma anterior. Eso se
        # oye como un tartamudeo y el filtro de conjuntos no lo ve.
        repetido_literal = prefijo_repetido(unidad, dichas_fichas, REPETICION_LITERAL)
        if repetido_literal:
            podada = podar_repeticion(unidad, repetido_literal)
            if podada is None:
                avisos.append(
                    "repite %d palabras seguidas y no queda frase al podar, se salta · %s…"
                    % (repetido_literal, unidad[:50])
                )
                continue
            avisos.append(
                "repetia %d palabras seguidas, se poda el arranque · %s…"
                % (repetido_literal, podada[:50])
            )
            unidad = podada
            carga = contenido(unidad)

        peso = len(palabras(unidad))
        if actual and not una_toma and n_actual + peso > tope:
            cerrar_toma()
            if lleno():
                break
        actual.append(unidad)
        n_actual += peso
        dichas |= carga
        dichas_fichas.extend(_fichas(unidad))
        # Si ya no cabe nada mas, la toma esta llena: cerrarla aqui evita
        # arrastrar una unidad entera a la siguiente.
        if not una_toma and n_actual >= suelo and n_actual + minimo_corte > tope:
            cerrar_toma()
    if not lleno():
        cerrar_toma()

    for i, (toma, f) in enumerate(zip(tomas, frames), 1):
        r = ritmo(toma, f / FPS)
        if r > RITMO_MAX:
            avisos.append(
                "toma %d a %.2f pal/s: por encima de %.1f, se dira atropellada"
                % (i, r, RITMO_MAX)
            )
        elif r < RITMO_MIN:
            avisos.append(
                "toma %d a %.2f pal/s: por debajo de %.1f, sobrara cara callada"
                % (i, r, RITMO_MIN)
            )

    return {
        "tomas": tomas,
        "frames": frames,
        "avisos": avisos,
        "palabras": sum(len(palabras(t)) for t in tomas),
        "seg_max_toma": round(seg_max_toma, 4),
        "duracion_s": round(duracion, 2),
        "ritmos": [round(ritmo(t, f / FPS), 2) for t, f in zip(tomas, frames)],
        "capacidad_palabras": tope,
    }


# ── Duracion de cada toma ──────────────────────────────────────────────────
# El modelo solo acepta longitudes de la forma 17k+5 fotogramas. A 24 fps eso
# es una escalera: 73 f = 3,04 s, 90 = 3,75, 107 = 4,46, 124 = 5,17, 141 =
# 5,88, 158 = 6,58, 175 = 7,29, 192 = 8,00.
#
# Antes TODAS las tomas duraban 192 f. Un titular da para 3-6 s de voz, asi
# que la primera toma de cada reel terminaba con la presentadora callada
# mirando a camara: medido en las cinco entregas del 7 de septiembre, entre
# 0,98 s (afd) y 3,55 s (kyiv) de silencio, un 22 % de la pieza.
#
# El techo son 192 f a proposito: frames x pixeles es lo que gobierna la VRAM,
# y 192 f a 416x736 es el presupuesto que esta medido. Subir de ahi seria
# extrapolar.
FPS = 24
FRAMES_MIN = 73
# Techo por defecto. Ya no es una constante de fe: se mide con
# produccion/sonda-duracion.sh y formato_una_toma() lo recalcula por pieza.
FRAMES_MAX = 396
# Duracion de referencia con la que se recortan y se filtran las frases. Es la
# toma con la que se valido el texto de las cinco noticias del dia; cambiarla
# cambia QUE se dice, no solo como se reparte.
SEG_REFERENCIA = 8.0

# ── Cuanto vídeo cabe en la GPU ────────────────────────────────────────────
# Medido con la sonda de duracion el 2026-09-10 a 416x736, cinco puntos:
#
#   192 f -> 6.232 MiB     345 f -> 10.651 MiB
#   243 f -> 7.695 MiB     396 f -> 12.114 MiB   <- el ultimo que cabe
#   294 f -> 9.166 MiB     447 f -> NO CABE
#
# Perfectamente lineal: 28,75 MiB por fotograma a 416x736, mas 722 MiB de base.
# Normalizado por pixel eso son 9,39e-5 MiB por pixel-fotograma, y con esa
# constante se puede resolver la pregunta al reves: dado un texto, cual es la
# mayor resolucion 9:16 a la que su locucion entera cabe en UNA sola toma.
#
# Por que importa: el corte entre dos tomas del mismo plano no se puede hacer
# invisible —ninguna toma llega al corte con la boca cerrada, porque el modelo
# estira la locucion hasta llenar la toma— asi que la unica forma de que no se
# note es que NO HAYA corte.
MIB_BASE = 722.0
MIB_POR_PXFRAME = 28.75 / (416 * 736)
# Margen sobre la VRAM libre: la sonda midio con el escritorio ocupando 2,5 GB
# y el consumo real varia unos cientos de MiB entre corridas.
MIB_MARGEN = 400.0
# Presupuesto DECLARADO, no lectura instantanea. Que el formato de una pieza
# dependiera de cuanta VRAM habia libre en ese segundo hacia la salida
# irreproducible: la misma noticia daba 368x656 o 336x624 segun lo que
# estuviera abierto en el escritorio, y eso choca de frente con el plan y las
# huellas, que existen para que la misma entrada de la misma salida.
# La lectura viva se sigue usando, pero como GUARDA: si hay menos de esto, se
# avisa y se espera, no se encoge la pieza en silencio.
VRAM_PRESUPUESTO_MIB = 12900.0
# Hasta donde llega la medicion. El modelo lineal se ajusto entre 192 y 396
# fotogramas y NO se ha comprobado mas alla. Extrapolarlo costo un aborto:
# a 566 fotogramas predecia 11.865 MiB, habia 12.300 libres y sd-cli murio con
# SIGABRT en 20 s. Por encima de este numero no se sabe, y no saber se trata
# como no caber: la pieza se parte en varias tomas en vez de apostar.
#
# Para subirlo hay que volver a medir:
#   produccion/sonda-duracion.sh 336 624 447 498 566 617
#
# Y hay DOS topes, no uno. Estas cuatro observaciones lo demuestran:
#
#   396 f a 416x736 = 121 Mpx-f  ->  CABE
#   447 f a 416x736 = 137 Mpx-f  ->  no cabe
#   532 f a 352x640 = 120 Mpx-f  ->  CABE
#   566 f a 336x624 = 119 Mpx-f  ->  no cabe
#
# Las dos ultimas tienen el mismo presupuesto de pixel-fotograma y resultado
# opuesto: el numero de FOTOGRAMAS pesa por si solo, aparte de los pixeles.
# Es lo que cabe esperar de la atencion sobre el eje temporal. Asi que se
# respetan los dos: el presupuesto de memoria Y el mayor recuento que se ha
# visto funcionar.
FRAMES_MEDIDOS = 532


def frames_que_caben(ancho: int, alto: int, vram_libre_mib: float) -> int:
    """Fotogramas 17k+5 que caben a esa resolucion con esa VRAM libre."""
    disponible = vram_libre_mib - MIB_BASE - MIB_MARGEN
    if disponible <= 0:
        return FRAMES_MIN
    crudo = int(disponible / (ancho * alto * MIB_POR_PXFRAME))
    return max(FRAMES_MIN, ((crudo - 5) // 17) * 17 + 5)


def formato_una_toma(
    palabras_totales: int,
    vram_libre_mib: float = VRAM_PRESUPUESTO_MIB,
    ancho_max: int = 416,
    alto_max: int = 736,
) -> tuple[int, int, int]:
    """La mayor resolucion 9:16 a la que ESTE texto cabe en una sola toma.

    Devuelve (fotogramas, ancho, alto). Si el texto es corto se queda en la
    resolucion maxima y solo acorta la toma; si es largo, baja el tamaño lo
    justo para no partir la pieza en dos.
    """
    segundos = palabras_totales / PALABRAS_POR_SEG + COLA_S
    frames = ((int(round(segundos * FPS)) - 5) // 17 + 1) * 17 + 5
    frames = max(FRAMES_MIN, frames)
    if frames > FRAMES_MEDIDOS:
        # Se recorta al mayor recuento que se ha visto funcionar. El texto no
        # se toca: se dice un poco mas rapido, y si eso lo saca de la banda de
        # ritmo, guionizar() lo avisa y quien mira decide.
        frames = FRAMES_MEDIDOS
    disponible = vram_libre_mib - MIB_BASE - MIB_MARGEN
    if disponible <= 0:
        return FRAMES_MIN, ancho_max, alto_max
    px = disponible / (frames * MIB_POR_PXFRAME)
    if px >= ancho_max * alto_max:
        return frames, ancho_max, alto_max
    # 9:16, ambos lados multiplos de 16: sd-cli redondea por su cuenta si no.
    alto = int((px * 16 / 9) ** 0.5 / 16) * 16
    ancho = int(alto * 9 / 16 / 16) * 16
    return frames, max(16, ancho), max(16, alto)
# Aire despues de la ultima palabra: el remate de la frase, el gesto de cierre
# y el fundido de audio de 0,25 s del montaje.
COLA_S = 0.7
# Duracion de un plano de apoyo: no lleva voz, y el modelo no genera voz en
# off. Ocho segundos de silencio rompen un reel; 4,5 s son un corte visual.
FRAMES_APOYO = 107


def frames_validos(minimo: int = FRAMES_MIN, maximo: int = FRAMES_MAX) -> list[int]:
    """La escalera 17k+5 que acepta el modelo, dentro del rango util."""
    return [f for f in range(5, maximo + 1, 17) if f >= minimo]


def frames_para(texto: str, fps: int = FPS, maximo: int = FRAMES_MAX) -> int:
    """Fotogramas que necesita este texto para decirse sin prisa ni sobras."""
    segundos = len(palabras(texto)) / PALABRAS_POR_SEG + COLA_S
    escalera = frames_validos(maximo=maximo)
    # El escalon mas cercano, no el siguiente: redondear siempre hacia arriba
    # devolvia el silencio por la puerta de atras.
    return min(escalera, key=lambda f: abs(f / fps - segundos))


def en_fuente(toma: str, origen: str) -> bool:
    """Cada frase de la toma tiene que estar literalmente en la fuente.

    Se comprueba FRASE A FRASE, no la toma entera: al saltarse lo repetido,
    una toma puede juntar dos frases que en el original no eran contiguas.
    """
    plano = re.sub(r"\s+", " ", (origen or "").lower())
    for frase in frases(toma):
        nucleo = re.sub(r"\s+", " ", frase.lower()).strip().rstrip(".!?…")
        if nucleo and nucleo not in plano:
            return False
    return True
