# Generación de vídeo con MiniMax-H3

Pipeline local de generación de vídeo con audio y diálogo, sobre
[`stable-diffusion.cpp`](https://github.com/leejet/stable-diffusion.cpp) (`bin/sd-cli`),
en dos GPU NVIDIA (5070 Ti como principal, 2060 para escalado).

## Requisitos

- `bin/sd-cli` compilado con soporte CUDA.
- Los pesos en `diffusion_models/`, `text_encoders/`, `vae/`, `upscalers/` (~51 GB, **fuera de git**).
- `ffmpeg` / `ffprobe` con `libx264`, `aac`, filtros `xfade`, `acrossfade`, `loudnorm`, `drawtext`.
- `python3` (solo librería estándar).

Las rutas ya **no** están clavadas: `lib/comun.sh` deduce la raíz del proyecto de su propia
ubicación. Se puede forzar con `MD=/otra/ruta` y el destino con `DEST=/otra/carpeta`.

## Uso normal: producción guiada por `.guion`

```bash
produccion/producir.sh produccion/guiones/existencialismo.guion existencialismo
```

Lee un `.guion`, genera cada plano hablado, encadena los marcados y ensambla el vídeo final
en `$DEST`. **Es resumible**: los planos que ya existen en `produccion/obra/<nombre>/` se
saltan, así que relanzarlo tras un fallo continúa donde quedó. Nunca sobrescribe material
de entrada.

Seguimiento en otra terminal:

```bash
produccion/estado.sh existencialismo     # progreso, GPU, estimación
produccion/preview.sh existencialismo    # publica cada plano terminado + un preview parcial
```

### Formato del `.guion`

Cabecera (una vez), que alimenta las tres secciones del prompt del modelo:

```
@ESCENA     descripción física del sujeto, la luz y el encuadre (en inglés)
@AMBIENTE   overall_soundscape
@MUSICA     non_diegetic_music
```

Y una línea por plano:

```
HABLA|<diálogo en español>|<modo>|<encuadre opcional>
BROLL|<ruta relativa a proyecto-minuto/ o absoluta>
```

Modos:

| Modo | Efecto |
|---|---|
| `inicio` | arranca limpio, sin imagen de partida |
| `encadena` | usa el último frame del plano anterior como `--init-img` (continuidad exacta) |
| `ancla:anclas/aNN.png` | arranca desde un frame prístino guardado (fija la identidad sin acumular artefactos) |

El montaje hace **corte duro dentro de un tramo** (la continuidad ya es exacta) y **fundido
de 0.5 s entre tramos** (`fundir.py`). Un tramo empieza en cada plano que no sea `encadena`.

### Por qué existen las anclas

Está documentado en la cabecera de cada `.guion`, y es el núcleo del diseño:

- Arrancar un tramo limpio hacía que el modelo **reinventara la cara** — parecía otra persona.
- Encadenar sin límite **acumulaba artefactos** (dispersión cromática monótona 1.79 → 2.88 en 5 eslabones).
- Anclar cada tramo a un frame prístino de `p01` fija la identidad con una imagen real que
  nunca se degrada. Anclas distintas dan poses distintas.

## Otros puntos de entrada

| Script | Para qué |
|---|---|
| `h3.sh "prompt"` | un clip suelto, rápido, para probar un prompt |
| `encadenar.sh "prompt"` | vídeo largo encadenando N segmentos a calidad nativa |
| `generar-1080p.sh "prompt"` | genera pequeño y escala ×4 repartiendo frames entre las dos GPU |
| `proyecto-minuto/` | montaje de 14 planos independientes + escalado a 1080p en paralelo |

## Medir la calidad, no mirarla a ojo

```bash
produccion/evaluar2.py <video.mp4> [--seg <segundos por plano>]
produccion/deriva.sh <nombre-obra>
```

`evaluar2.py` es **anti-trampa**: toma el primer plano como referencia y penaliza desviarse
en *cualquier* dirección. Nació al detectar que `evaluar.py` (el primero) premiaba inyectar
grano sintético. Usa `evaluar2.py`; `evaluar.py` se conserva como referencia histórica.

`deriva.sh` diagnostica una cadena: PSNR de cada unión (>36 dB imperceptible, <30 salto
visible) y deriva de la firma de color respecto a `p01` (<15 estable, >40 la escena cambió).

Las mediciones de VRAM que sustentan las decisiones de resolución y `--max-vram` están en
`medidas/` y **sí se versionan**: son 112 KB irrepetibles sin volver a gastar horas de GPU.

## Probar que nada se ha roto

```bash
pruebas/humo.sh            # todo lo que la máquina permita
pruebas/humo.sh checks     # solo los checks de regresión, ~30 s, sin GPU
```

Cuatro bloques. **A** son 12 checks de regresión que corren en cualquier máquina; cada uno
se verificó en las dos direcciones —pasa con el código actual y **falla** contra el código
que tenía el fallo—, así que ninguno es decorativo. **B** informa de qué hay disponible.
**C** hace una generación real de ~1 min en la 5070 Ti. **D** monta una obra entera con
ffmpeg, sin GPU, sobre una copia.

Lo que no se puede comprobar en una máquina se marca **SALTA**, no FALLA: no está roto,
es que ahí no hay con qué mirarlo. En un portátil sin GPU salen 19 PASA y 3 SALTA.

Cada check vive en `pruebas/checks/<nombre>.sh`, es autocontenido y se puede correr suelto:

| check | qué protege |
|---|---|
| `rutas-comun` | que ninguna ruta de un solo puesto vuelva a clavarse |
| `params-defecto` | que cada script conserve SUS W/H/frames/pasos y respete el entorno |
| `sd-salida` | que `-o X.mp4` se busque en `X.mp4.avi`, o todos los planos "fallan" |
| `nostdin` | que ffmpeg no vuelva a comerse líneas del guion |
| `tramos-limpieza` | que no sobrevivan fronteras de tramo de ejecuciones viejas |
| `orden-tab` | que una ruta con espacios no rompa el montaje |
| `guarda-resolucion` | que un concat con resoluciones mezcladas no salga corrupto en silencio |
| `montaje-rc` | que un clip que falla no entre igualmente en el montaje |
| `claims` | que el escalado en 2 GPU se pueda relanzar y no entre en bucle |
| `ensamblar` | fuente tipográfica, rótulos de planos inexistentes, duración derivada |
| `fundir` | errores de ffprobe con mensaje, temporales, resoluciones distintas |
| `estado` | contadores, pasos y `pgrep` que ya no están clavados |

## Ordenar los vídeos

```bash
ordenar-videos.sh            # enseña qué haría, sin tocar nada
ordenar-videos.sh --hazlo    # deja a la vista solo la pieza actual
```

Archiva en `~/Vídeos/archivo-minimax/` todo menos la pieza más reciente. No borra, y solo
toca ficheros con la firma de nombre de esta pipeline: los vídeos personales que estén en
la misma carpeta no se mueven.

## Notas de operación

- **Nunca edites un script mientras se está ejecutando.** Bash relee el fichero por offset de
  bytes: una edición a mitad de una producción de 7 horas hace que salte a un punto arbitrario
  y ejecute basura. Ya pasó una vez, al final de una tanda de 14 planos.
- `sd-cli` escribe en `<salida>.avi` aunque le pases `-o <salida>.mp4`. Usa `sd_salida` de
  `lib/comun.sh` en vez de construir la ruta a mano.
- Los OOM de VRAM son **transitorios** (picos del escritorio): `producir.sh` reintenta 4 veces
  con 90 s de espera y eso ha rescatado producciones reales.
- El coste de un plano tiene un **suelo fijo de ~38 s** (codificador de texto Qwen3-VL en CPU);
  el resto escala con píxeles × frames × pasos. Por eso una prueba de humo sale por ~1 min.

## Estructura

```
README.md
lib/comun.sh          rutas, parámetros y llamadas compartidas — el único sitio con rutas
ordenar-videos.sh     deja a la vista solo la pieza actual
h3.sh                 un clip suelto, para probar un prompt
encadenar.sh          vídeo largo encadenando segmentos
generar-1080p.sh      genera pequeño y escala x4 en las dos GPU
pruebas/
  humo.sh             punto de entrada único de las pruebas
  checks/             12 checks de regresión, uno por fallo arreglado
produccion/           pipeline actual guiada por .guion
  guiones/            los .guion, con el porqué de cada diseño en su cabecera
  obra/<nombre>/      planos generados, anclas y montaje (resumible)
  experimentos/       postproceso de un solo uso, atado a tomas concretas
medidas/              mediciones de VRAM (versionadas)
proyecto-minuto/      montaje de 14 planos + escalado en 2 GPU
```
