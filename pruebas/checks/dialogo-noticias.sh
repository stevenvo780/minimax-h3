#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  DIALOGO DE NOTICIAS — que lo que dice la presentadora SE PUEDA DECIR.
#
#  noticias-reel.sh ya comprobaba que el texto no se inventa y que el formato
#  es 9:16. Nada comprobaba lo unico que se oye: si el texto de una toma cabe
#  hablado en los segundos que dura esa toma. Por eso paso a produccion un
#  guion con 35 palabras en 8 segundos (4,38 pal/s, cuando el ritmo medido del
#  modelo es 2,6) junto a otro con 8 palabras en los mismos 8 segundos.
#
#  Este check corre sobre las NOTICIAS REALES del dia, no sobre un fixture:
#  el defecto solo aparecia con frases largas de teletipo.
#
#  No gasta GPU.
# ═══════════════════════════════════════════════════════════════════════════
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="dialogo-noticias"
exec 0</dev/null

python3 - "$RAIZ" <<'PY'
import os, sys

raiz = sys.argv[1]
sys.path.insert(0, os.path.join(raiz, "harness"))
import redaccion  # noqa: E402
import noticias  # noqa: E402

fallos = []
dia = os.path.join(raiz, "noticias", "dia")
fuentes = sorted(f for f in os.listdir(dia) if f.endswith(".txt"))
if len(fuentes) < 5:
    print(f"FALLA dialogo-noticias: hacen falta 5 noticias del dia, hay {len(fuentes)}")
    sys.exit(1)

SEG_MAX = 8.0  # 192 f / 24 fps, la toma mas larga que cabe en VRAM
for fichero in fuentes:
    titular, cuerpo, _ = noticias.leer_fichero(os.path.join(dia, fichero))
    plan = noticias.redactar(titular, cuerpo, seg_max_toma=SEG_MAX, seg_objetivo=32)
    origen = titular + " " + cuerpo
    if not plan["tomas"]:
        fallos.append(f"{fichero}: no produjo ninguna toma")
        continue
    for i, (toma, frames) in enumerate(zip(plan["tomas"], plan["frames"]), 1):
        marca = f"{fichero} toma {i}"
        segundos = frames / redaccion.FPS
        if frames < 5 or (frames - 5) % 17:
            fallos.append(f"{marca}: frames={frames} no cumple 17k+5")
        if frames > redaccion.FRAMES_MAX:
            fallos.append(f"{marca}: frames={frames} pasa del presupuesto medido")
        r = redaccion.ritmo(toma, segundos)
        # El techo es duro: por encima el modelo no puede decirlo y la frase
        # sale atropellada o cortada.
        if r > redaccion.RITMO_MAX:
            fallos.append(f"{marca}: {r:.2f} pal/s, indecible en {segundos:.1f} s · {toma[:60]}")
        # Una toma no puede empezar a media frase: "homicidio imprudente y
        # organizacion criminal, tras apreciar..." se leia como una noticia.
        primera = toma.split()[0]
        if not (primera[0].isupper() or primera[0].isdigit() or primera[0] in "«\"¿¡"):
            fallos.append(f"{marca}: empieza a media frase · {toma[:60]}")
        if toma.rstrip()[-1:] not in ".!?…":
            fallos.append(f"{marca}: no termina la frase · {toma[-40:]}")
        ultima = toma.rstrip(".!?…").split()[-1].lower().strip(".,;:")
        if ultima in redaccion.FINAL_PROHIBIDO:
            fallos.append(f"{marca}: termina en palabra colgando '{ultima}'")
        if r < redaccion.RITMO_MIN:
            fallos.append(
                f"{marca}: {r:.2f} pal/s en {segundos:.1f} s, sobra cara callada · {toma[:50]}"
            )
        if not redaccion.en_fuente(toma, origen):
            fallos.append(f"{marca}: no esta en la fuente · {toma[:60]}")

# El presupuesto pedido tiene que corresponder con el video que sale: la suma
# de las duraciones reales no puede pasarse de lo pedido mas una toma.
titular, cuerpo, _ = noticias.leer_fichero(os.path.join(dia, fuentes[0]))
for objetivo in (16, 24, 32):
    plan = noticias.redactar(titular, cuerpo, seg_max_toma=SEG_MAX, seg_objetivo=objetivo)
    if plan["duracion_s"] > objetivo + SEG_MAX:
        fallos.append(
            f"--seg-objetivo {objetivo} dio {plan['duracion_s']:.1f} s de video"
        )

# acortar() nunca puede devolver un sintagma sin verbo: si no hay corte
# limpio, la frase se descarta entera.
sin_corte_limpio = (
    "El enviado de EE.UU. Steve Witkoff y Jared Kushner, yerno del presidente "
    "Donald Trump, impulsaron la reanudacion de conversaciones trilaterales "
    "entre EE.UU., Rusia y Ucrania."
)
corto = redaccion.acortar(sin_corte_limpio, 14, 6)
if corto is not None and "impulsaron" not in corto:
    fallos.append(f"acortar() dejo un sintagma sin verbo: {corto}")

# Una enumeracion no se parte por su ultima conjuncion.
fechas = redaccion.acortar(
    "La entrada masiva tuvo lugar los dias 30 y 31 de julio segun el auto de la juez.",
    12, 6,
)
if fechas and fechas.rstrip(".").endswith("30"):
    fallos.append(f"acortar() partio una enumeracion de cifras: {fechas}")

# ── UNA TOMA: el texto elegido no puede depender de la duracion ────────────
# La seleccion de frases es editorial; la duracion es de capacidad. Cuando se
# acoplaron, una toma de 60 s dejaba pasar frases largas cuyas palabras nuevas
# burlaban el filtro de repeticion: la pieza de Ceuta pasaba de 33 palabras a
# 128 y decia dos veces lo de la juez.
for fichero in fuentes:
    titular, cuerpo, _ = noticias.leer_fichero(os.path.join(dia, fichero))
    corta = redaccion.guionizar(titular, cuerpo, 8.0, 999, tomas_max=99)
    larga = redaccion.guionizar(titular, cuerpo, 60.0, 999, tomas_max=1, una_toma=True)
    if corta["palabras"] != larga["palabras"]:
        fallos.append(
            f"{fichero}: el texto cambia con la duracion "
            f"({corta['palabras']} palabras en tomas de 8 s, "
            f"{larga['palabras']} en una toma de 60 s)"
        )
    if len(larga["tomas"]) != 1:
        fallos.append(f"{fichero}: --una-toma produjo {len(larga['tomas'])} tomas")

# El formato de una toma tiene que caber en la VRAM que se le declara, y el
# ritmo seguir siendo decible.
for fichero in fuentes:
    titular, cuerpo, _ = noticias.leer_fichero(os.path.join(dia, fichero))
    plan = noticias.redactar(titular, cuerpo, una_toma=True, vram_libre_mib=13400)
    f = plan["formato"]
    coste = redaccion.MIB_BASE + f["frames"] * f["ancho"] * f["alto"] * redaccion.MIB_POR_PXFRAME
    if coste > 13400:
        fallos.append(f"{fichero}: el formato pide {coste:.0f} MiB de 13400")
    if f["ancho"] % 16 or f["alto"] % 16:
        fallos.append(f"{fichero}: {f['ancho']}x{f['alto']} no es multiplo de 16")
    r = plan["ritmos"][0]
    if not (redaccion.RITMO_MIN <= r <= redaccion.RITMO_MAX):
        fallos.append(f"{fichero}: una toma a {r:.2f} pal/s, fuera de banda")

for f in fallos:
    print("FALLA dialogo-noticias:", f)
sys.exit(1 if fallos else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "ok $nombre (ritmo decible, frases enteras, presupuesto honesto)"
exit $rc
