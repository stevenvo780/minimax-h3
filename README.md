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

## Notas de operación

- **Nunca edites un script mientras se está ejecutando.** Bash relee el fichero por offset de
  bytes: una edición a mitad de una producción de 7 horas hace que salte a un punto arbitrario
  y ejecute basura. Ya pasó una vez, al final de una tanda de 14 planos.
- `sd-cli` escribe en `<salida>.avi` aunque le pases `-o <salida>.mp4`. Usa `sd_salida` de
  `lib/comun.sh` en vez de construir la ruta a mano.
- Los OOM de VRAM son **transitorios** (picos del escritorio): `producir.sh` reintenta 4 veces
  con 90 s de espera y eso ha rescatado producciones reales.
- `old/` es material archivado de tandas anteriores. No se toca.

## Estructura

```
lib/comun.sh          rutas, parámetros y llamadas compartidas — el único sitio con rutas
produccion/           pipeline actual guiada por .guion
  guiones/            los .guion, con el porqué de cada diseño en su cabecera
  obra/<nombre>/      planos generados, anclas y montaje (resumible)
proyecto-minuto/      montaje de 14 planos + escalado en 2 GPU
old/                  tandas archivadas
```
