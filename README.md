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

## Lo que degrada la imagen, medido

El sintoma es "el video se va acartonando a cada segundo". Tiene firma numerica
y una causa concreta, y no es la que parece.

**No es el modelo cansandose con la duracion.** Un plano solo, alargandolo, no
se degrada nada:

| frames | duracion | TOTAL | gradacion | estructura |
|---|---|---|---|---|
| 56  | 2,3 s  | 91,5 | 25/25 | 20/20 |
| 107 | 4,5 s  | 90,0 | 25/25 | 20/20 |
| 175 | 7,3 s  | 89,0 | 25/25 | 20/20 |
| 260 | 10,8 s | 90,0 | 25/25 | 20/20 |
| 345 | 14,4 s | 90,0 | 25/25 | 20/20 |

**Es el eslabon.** Encadenando los mismos cuatro planos, la nota se desploma, y
con un acantilado en el tercer enlace:

| planos | eslabones | TOTAL | estructura | croma |
|---|---|---|---|---|
| 1 | 0 | 95,0 | 20,0 | 10,0 |
| 2 | 1 | 89,0 | 14,1 | 10,0 |
| 3 | 2 | 87,7 | 15,0 | 10,0 |
| 4 | 3 | **68,7** | **7,4** | **3,4** |

**Por que.** El ultimo frame de un plano se reinyecta como `--init-img` del
siguiente. Ese frame ya lleva el realce que el modelo aplico, y el modelo realza
encima: fotocopiar una fotocopia. La energia de borde sobre el primer frame del
primer plano crece monotona — +3,2 % → +8,5 % → +13,5 % → +21,1 %.

Y hay una segunda causa que se suma: la **deriva**. Los mismos dos eslabones
puntuan 87,7 con material fresco y 81,0 con material ya derivado, aunque el
ultimo plano por si solo saque 92,9. Reanclar ataca esta; menos eslabones ataca
la otra.

**Conclusion operativa: el mejor video largo es el que no tiene ningun eslabon.**
Ver `guiones/exis-toma-unica.guion`.

### Una palanca que se probo y se descarto

Desenfocar el frame de enlace para devolverle la energia de borde de la
referencia **sube la nota y estropea la imagen**. Escalera medida sobre un frame
con +21,1 % de exceso, mirando el recorte del ojo y la barba:

| sigma | exceso | detalle |
|---|---|---|
| 0,20 | +20,8 % | intacto |
| **0,35** | +19,5 % | **ultimo punto sano** |
| 0,50 | +17,2 % | la barba empieza a fundirse |
| 0,80 | +12,0 % | masa borrosa |
| 1,47 | −0,1 % | clava el numero, destruye la imagen |

Igualar la energia de borde contra *otra imagen distinta* no deshace el realce:
se lleva el detalle legitimo. `lib/enlace.sh` tiene un tope duro en 0,35 y se
niega a pasar de ahi. Es justo la trampa por la que existe `evaluar2.py`.

### Limite conocido del medidor

`evaluar2.py` mide **degradacion, no belleza**. Un video uniformemente mediocre
puntua alto. Un clip de 345 frames saco 90,0 con los cinco bloques visuales
perfectos, y al mirarlo estaba oscuro, con el encuadre ido a plano medio y una
ventana clara que el guion prohibia. La nota es condicion necesaria, no
suficiente: hay que mirar el video.

## Hardware

### Presupuesto de VRAM

`lib/vram.sh` calcula el techo sobre la VRAM **libre en ese instante**, no sobre
el total: el escritorio ocupa ~3,4 GB de la 5070 Ti y un techo sobre el total se
come el margen del usuario y provoca OOM — fue lo que tumbo p05 y p10. La
sobrecorreccion tampoco valia: los scripts quedaron en `cuda0=2`, 2 GB de 16.

### Ejecutar en un contenedor con otro userland

`lib/compat.sh` resuelve dos cosas sin tocar el binario original: localiza CUDA
en el disco (esta en los venv de otros proyectos) y copia `sd-cli` quitandole la
exigencia de una version de glibc mas nueva que la del sistema. De glibc 2.43
solo necesitaba `atan2f` y `sqrtf`, que existen desde hace decadas.

Ojo con la RAM: los modelos completos piden ~42 GB. Con el modelo **podado**
bajan a 33 GB y entran en un contenedor de 24 GB + 24 GB de swap.

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
