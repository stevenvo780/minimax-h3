# NewsLeters — reels de noticias para TikTok e Instagram

De un titular al MP4 vertical 9:16, con presentadora, diálogo sincronizado y
subtítulos en la zona que no tapa la UI de TikTok/IG.

El motor sigue siendo MiniMax-H3 local (`bin/sd-cli`), el mismo que ya estaba
medido: no se encadena, se **ancla**; nativo **416×736** (los mismos píxeles que
736×416); export a **1080×1920**. No inventa la noticia: recorta el texto que le
das al presupuesto de ~20 s.

```bash
produccion/reel-noticias.sh \
  --titular "El congreso aprueba hoy la ley de vivienda" \
  --texto "El texto fija un tope al alquiler en zonas tensionadas y entra en vigor el mes que viene." \
  --nombre corte-vivienda
```

```bash
VALIDAR=1 produccion/reel-noticias.sh --fichero noticia.txt --nombre corte
SOLO_GUION=1 produccion/reel-noticias.sh --fichero noticia.txt --nombre corte
produccion/reel-noticias.sh --rss https://ejemplo.tld/rss.xml --nombre corte
produccion/reel-noticias.sh --tema "avion miami" --nombre corte
produccion/tanda-noticias-dia.sh          # las cinco noticias del dia, en serie
ui/servidor.py                            # http://localhost:8080
```

La UI pega titular + cuerpo y lanza el mismo pipeline. El RSS **no** se ofrece
en la UI (sería SSRF). Un plano de apoyo en este runner dura lo mismo que una
toma hablada y el modelo no hace voz en off: el ritmo por defecto es solo
`informativo`. `BROLL=1` intercalas apoyos y fuerza tomas de 4,5 s.

Lo que sale, en `videos/entregas/`:

```
corte-vivienda-416x736-16s-….mp4                 el montaje nativo
corte-vivienda-416x736-16s-…-subs.mp4            con subtítulos quemados
corte-vivienda-416x736-16s-…-reel-1080x1920.mp4  listo para el feed
```

El resto de este README es el motor: cómo se genera, se ancla, se mide y se
reanuda. Sigue haciendo falta para no romper una tanda de horas.

## Requisitos

- `bin/sd-cli` compilado con soporte CUDA.
- Los pesos en `modelos/{diffusion_models,text_encoders,vae,upscalers}/` (~51 GB, **fuera de git**).
- `ffmpeg` / `ffprobe` con `libx264`, `aac`, filtros `xfade`, `acrossfade`, `loudnorm`, `alimiter`, `ebur128`, `drawtext`.
- `python3` (el pipeline principal usa sólo la librería estándar).

El evaluador fuerte es opcional y aislado en `.venv-calidad`: usa OpenCV para
YuNet/SFace y modelos locales para ASR/VAD. Los pesos se descargan de forma
explícita, con SHA-256 fijado; evaluar una obra nunca accede a la red:

```bash
python3 -m venv .venv-calidad
.venv-calidad/bin/pip install opencv-python-headless
calidad/preparar-modelos-evaluacion.sh
```

Las rutas ya **no** están clavadas: `lib/comun.sh` deduce la raíz del proyecto de su propia
ubicación. Se puede forzar con `MD=/otra/ruta` y el destino con `DEST=/otra/carpeta`.

## Uso del motor: producción guiada por `.guion`

```bash
produccion/producir-anclado.sh \
  produccion/guiones/existencialismo.guion existencialismo 345 736 416 20
```

El runner compila primero un `plan.json` canónico, genera cada toma y ensambla en `$DEST`.
**Es resumible por contenido**: sólo reutiliza una toma si coinciden su huella efectiva
(guion, prompt, semilla, parámetros, ancla, modelos y binario) y un `ffprobe` confirma vídeo,
audio y resolución. Lo cambiado se mueve a `produccion/obra/<nombre>/historial/`; no se borra.
La salida final se publica únicamente si están exactamente las tomas del plan, el montaje
termina con código cero y el vídeo decodifica completo. El manifiesto SHA-256 se sincroniza
antes de hacer visible el MP4, y ambos quedan juntos en `$DEST`.

La primera producción real lee una vez los ~33 GB de la receta para identificarlos por
contenido; después usa una caché ligada a device/inode/tamaño/mtime/ctime y revalida el
manifiesto justo antes de cada `sd-cli`. El runner anclado reserva un único cerrojo global
durante generación, espera y montaje; toda entrada legacy a generación o escalado usa ese
mismo recurso, así que no puede solaparse por accidente.

Seguimiento durable, incluso si la interfaz se reinicia:

```bash
ui/servidor.py                            # http://localhost:8080
cat produccion/obra/existencialismo/estado.json
```

La UI sólo escucha en `127.0.0.1`, muestra esperas/generación/montaje y sirve exclusivamente
MP4 de `videos/entregas` y `videos/experimentos`. El estado final normal es
`review_pending`: significa «ensamblado y validado técnicamente», no «aprobado visualmente».

### Formato del `.guion`

Cabecera (una vez), que alimenta las tres secciones del prompt del modelo:

```
@TIPO       tipo de plano por defecto (opcional, por defecto `habla`)
@ESCENA     descripción física del sujeto, la luz y el encuadre (en inglés)
@AMBIENTE   overall_soundscape
@MUSICA     non_diegetic_music
```

Y una línea por plano:

```
TOMA|<contenido>|<modo>|<tipo opcional>|<escena opcional>|<ambiente opcional>
HABLA|<diálogo en español>|<modo>|<tipo opcional>|<escena opcional>|<ambiente opcional>
```

`TOMA|` es la forma general; `HABLA|` se mantiene porque los guiones antiguos la usan. El
runner anclado acepta un sexto campo opcional para sustituir `@AMBIENTE` en esa toma. `BROLL`
pertenece al runner histórico `producir.sh` y no forma parte del contrato anclado.

El **quinto campo** sustituye a `@ESCENA` sólo en esa toma. Hace falta para dos cosas que de
otro modo son imposibles: meter un **segundo interlocutor** (toda toma `ancla:1` hereda la cara de
la toma 1, así que sin esto el guion no puede ni pedir otra persona), y evitar que un **plano de
detalle** arrastre el rostro del ancla. Combínalo con el modo `inicio`.

El cuarto campo permite **mezclar tipos dentro de un mismo guion**: una toma hablada, luego un
detalle de las manos, luego un plano general, sin salir del mismo `.guion`.

### Tipos de plano

El pipeline nació para un único formato —una persona hablando de frente— con el prompt
escrito a mano dentro del script de producción. Eso hacía imposible cualquier plano sin
diálogo. Ahora el tipo es un parámetro (`lib/prompt.sh`), y añadir uno es añadir un `case`
y nada más.

| Tipo | Qué genera | Cuándo usarlo |
|---|---|---|
| `habla` | retrato con diálogo sincronizado | la voz la dispara la marca `<d>[Spanish]…</d>`; sin ella el modelo no habla |
| `informativo` | presentador de noticias, frases cortas a cámara | reels 9:16; no usa la calma de `habla` |
| `muda` | persona en plano, sin hablar | reacción, escucha, silencio. **Es el más nítido de los seis** |
| `accion` | algo ocurre, con sujeto o sin él | figura que entra, se mueve, se detiene |
| `detalle` | primerísimo plano de un objeto o parte del cuerpo | manos, un libro. Sin rostro |
| `paisaje` | espacio sin personas | atmósfera, luz, establecimiento |
| `camara` | el movimiento **es** el sujeto | el contenido describe la trayectoria del dolly |

Los seis originales se generaron y se midieron (107 fotogramas, 736x416, 20 pasos): **ninguno produjo
manchas de color**. `informativo` es el mismo retrato hablado con otra entrega, en 9:16.
Para producir los cuatro más distintos entre sí de una tanda:

```bash
produccion/formatos.sh                       # detalle, camara, accion, paisaje
FORMATOS="muda paisaje" produccion/formatos.sh   # sólo algunos
```

Es resumible: salta el formato que ya tenga su `.mp4`. Van **en serie a propósito** — dos
generaciones concurrentes se mataron entre ellas por OOM.

#### Resultado medido de los cuatro formatos (56 s, 4 tomas ancladas, 736x416)

| formato | manchas | deriva tono | deriva bordes | veredicto |
|---|---|---|---|---|
| `paisaje` | 0 | +1,9 % | −0,2 % | **ESTABLE** |
| `camara` | 0 | +2,7 % | +2,0 % | **ESTABLE** |
| `detalle` | 0 | −2,8 % | −4,2 % | **ESTABLE** |
| `accion` | 0 | −2,1 % | +5,2 % | deriva leve |

Cero manchas en ~5400 fotogramas escaneados. Las versiones de 56 s salen **mejor** que las de
28 s (`camara` y `paisaje` venían de DERIVA): con la nivelación de luminancia actuando en tres
enlaces en vez de uno, la pieza queda mucho mejor equilibrada.

### Revisar un guion sin gastar GPU

```bash
VALIDAR=1 produccion/producir-anclado.sh mi.guion x
```

Comprueba la cabecera y los tipos, **imprime el prompt exacto que recibirá el modelo** y sale
antes de tocar la GPU. Es la forma de revisar por qué un plano sale raro: casi siempre el
prompt montado no dice lo que uno creía.

Sin esto, comprobar «¿parsea bien este guion?» arrancaba una generación de verdad, que además
competía por el cerrojo con la tanda en curso. `pruebas/checks/guiones.sh` valida así todos los
guiones del repo en cada humo.

Modos:

| Modo | Efecto |
|---|---|
| `inicio` | arranca limpio, sin imagen de partida |
| `ancla` / `ancla:1` | usa un frame prístino de la toma 1 |
| `ancla:N` | usa un frame prístino de una toma anterior N; sirve para otro personaje |
| `encadena` | compatibilidad: se normaliza a `ancla:1` con aviso, porque encadenar degrada |
| `ancla:anclas/aNN.png` | sintaxis histórica: se normaliza a `ancla:1` con aviso |

La primera toma siempre es efectiva como `inicio`; una referencia `ancla:N` debe apuntar hacia
atrás. El montaje usa por defecto un corte directo (`fundir.py`): conserva completa la cola de
audio y evita la doble exposición entre rostro y B-roll. `TRANSICION=fundido` mantiene el modo
histórico como opción explícita; `TRANSICION=negro` ofrece una separación breve sin mezclar dos
imágenes.

### Por qué existen las anclas

Está documentado en la cabecera de cada `.guion`, y es el núcleo del diseño:

- Arrancar un tramo limpio hacía que el modelo **reinventara la cara** — parecía otra persona.
- Encadenar sin límite **acumulaba artefactos** (dispersión cromática monótona 1.79 → 2.88 en 5 eslabones).
- Anclar cada tramo a un frame prístino de `p01` fija la identidad con una imagen real que
  nunca se degrada. Anclas distintas dan poses distintas.

Para retrato hablado se puede activar la selección neutral estricta:

```bash
ANCLA_NEUTRAL=1 produccion/producir-anclado.sh mi.guion mi-obra
```

En ese modo se recorren todos los fotogramas de la fuente con YuNet y sólo se publica un PNG
si hay una única cara persistente, suficientemente nítida y con pose/boca neutral. El PNG y su
JSON lateral forman parte de las huellas de reanudación. Si el selector o el modelo faltan, la
producción falla: no cae silenciosamente al fotograma histórico.

### Comparar candidatos sin tocar la obra

Una variación de semilla, prompt, modelo o ancla se genera en un banco direccionado por
contenido. Cada candidato es inmutable y lleva receta, SHA-256 y validación técnica:

```bash
produccion/generar-candidato.sh \
  --plan produccion/obra/mi-obra/plan.json --toma 3 \
  --modelo modelos/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf \
  --steps 20 --seed 303

python3 harness/candidatos.py listar produccion/candidatos/mi-obra
python3 harness/candidatos.py seleccionar RUTA_CANDIDATO \
  --output produccion/obra/mi-obra/selecciones/t03.json --note "promoción revisada"
python3 harness/candidatos.py preparar \
  produccion/obra/mi-obra/selecciones/t03.json \
  --output produccion/obra/mi-obra/t03.avi
```

El generador serializa el uso de GPU y vuelve a comprobar el ancla antes y después del trabajo;
una mutación concurrente no puede entrar en una receta publicada. Para B-roll que debe ser
deliberadamente estático, `produccion/estabilizar-plano.sh` deriva desde un fotograma elegido una
toma MJPEG+PCM determinista con grano luma sutil, duración/FPS exactos y manifiesto verificable.

## Otros puntos de entrada

| Script | Para qué |
|---|---|
| `herramientas/h3.sh "prompt"` | un clip suelto, rápido, para probar un prompt |
| `herramientas/encadenar.sh "prompt"` | vídeo largo encadenando N segmentos a calidad nativa |
| `herramientas/generar-1080p.sh "prompt"` | genera pequeño y escala ×4 repartiendo frames entre las dos GPU |
| `proyecto-minuto/` | montaje de 14 planos independientes + escalado a 1080p en paralelo |

## Medir la calidad, no mirarla a ojo

```bash
calidad/evaluar2.py <video.mp4> [--seg <segundos por plano>]
calidad/deriva.sh <nombre-obra>
```

`evaluar2.py` es **anti-trampa**: toma el primer plano como referencia y penaliza desviarse
en *cualquier* dirección. Nació al detectar que `evaluar.py` (el primero) premiaba inyectar
grano sintético. Usa `evaluar2.py`; `evaluar.py` se conserva como referencia histórica.

`deriva.sh` diagnostica una cadena: PSNR de cada unión (>36 dB imperceptible, <30 salto
visible) y deriva de la firma de color respecto a `p01` (<15 estable, >40 la escena cambió).

Antes de entregar una obra completa, el gate recomendado es V2 y debe recibir tanto el plan
como el montaje real:

```bash
calidad/v2/evaluar.sh produccion/obra/mi-obra \
  --plan produccion/obra/mi-obra/plan.json \
  --montage produccion/obra/mi-obra/final.mp4 \
  --transition-style cut \
  --output produccion/obra/mi-obra/calidad-v2.json
```

V2 valida integridad y decodificación completa, correspondencia densa entre montaje y fuentes,
orden del plan, temporalidad por tipo de toma, YuNet/SFace, ASR por ventanas, cola vocal limpia
con Whisper+Silero y audio final. Sus
salidas son `PASS`, `FAIL`, `ERROR` o `REVIEW`; una capacidad ausente o desconocida nunca se
convierte en `PASS`. La boca sólo se reporta como proxy para revisión humana: el evaluador no
afirma certificar dientes, anatomía ni sincronía labial.

Las mediciones de VRAM que sustentan las decisiones de resolución y `--max-vram` están en
`medidas/` y **sí se versionan**: son 112 KB irrepetibles sin volver a gastar horas de GPU.

## Probar que nada se ha roto

```bash
pruebas/humo.sh            # todo lo que la máquina permita
pruebas/humo.sh checks     # solo los checks de regresión, ~30 s, sin GPU
```

Cuatro bloques. **A** descubre todos los checks de regresión que corren en cualquier máquina; cada uno
se verificó en las dos direcciones —pasa con el código actual y **falla** contra el código
que tenía el fallo—, así que ninguno es decorativo. **B** informa de qué hay disponible.
**C** hace una generación real de ~1 min en la 5070 Ti. **D** monta una obra entera con
ffmpeg, sin GPU, sobre una copia.

Lo que no se puede comprobar en una máquina se marca **SALTA**, no FALLA: no está roto,
es que ahí no hay con qué mirarlo. El resumen imprime el total real; no está clavado en la
documentación.

Cada check vive en `pruebas/checks/<nombre>.sh`, es autocontenido y se puede correr suelto:

| check | qué protege |
|---|---|
| `noticias-reel` | recorte sin inventar, tipo `informativo`, 9:16, subtítulos, export 1080×1920 |
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
| `plan-obra` | contrato canónico, modos, determinismo e invalidación selectiva |
| `reanudacion-anclada` | huellas de receta/toma, salidas atómicas y montaje fail-closed |
| `cerrojo-generacion` | exclusión real, argumentos/stdio/RC y timeout del `sd-cli` |
| `ui-segura` | catálogo, estado durable, límites HTTP, rutas de vídeo y rangos |
| `ordenar-seguro` | simulación y archivo recuperable sin tocar material personal |

## Ordenar los vídeos

```bash
herramientas/ordenar-videos.sh            # enseña qué haría, sin tocar nada
herramientas/ordenar-videos.sh --hazlo    # deja a la vista solo la pieza actual
herramientas/ordenar-videos.sh --hazlo mi-obra  # conserva la más nueva que coincida
```

Archiva por defecto en `$DEST/archivo-minimax/` todo menos la salida válida más reciente; si
se da un filtro, conserva la más reciente que coincida. `ARCHIVO_DEST` permite elegir otra
ubicación. No borra ni sobrescribe: sólo mueve un MP4 si su nombre es ASCII y tiene el sidecar
`.minimax-h3.json` publicado por el runner, con un SHA-256 que todavía coincide. Mueve juntos
vídeo y manifiesto; directorios, enlaces, colisiones, entregas antiguas sin procedencia demostrable
y vídeos personales quedan quietos.

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

**El anclaje SI borra la deriva.** Medido sobre `obra/existencialismo`, 14 planos
anclados a p01 cada cuatro. El exceso de borde sube dentro de cada tramo y cae a
cero en cada ancla:

```
p01 +2.9   p02 +6.2   p03 +10.6   p04 +17.6     tramo 1
p05 +6.7   p06 +8.8   p07 +10.8   p08 +18.3     tramo 2  <- ancla
p09 +7.3   p10 +12.4  p11 +17.8   p12 +22.2     tramo 3  <- ancla
p13 +6.4   p14 +11.2                            tramo 4  <- ancla
```

En un enlace normal el salto de bordes es −3 %. En los tres puntos de anclaje es
**−16,2 %, −15,5 % y −17,3 %**: la deriva vuelve al punto de partida.

El techo aislado medido a 512x288 fue 685 frames (28,5 s), pero esa resolución produjo
aberraciones de color. A 736x416, la configuración recomendada, el techo probado es 345
frames (14,4 s); por eso es también el valor por defecto.

**Conclusión operativa para 1-2 minutos:** tomas de hasta 14,4 s a 736x416, cada una
**anclada** a una fuente prístina anterior, **ninguna encadenada**. Así no hay acumulación:
cada toma empieza desde material limpio y el montaje conserva el corte documental sin
superponer semánticamente dos tomas.

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
- Los OOM de RAM/VRAM pueden ser **transitorios**: `producir-anclado.sh` espera recursos,
  conserva cada intento fallido y reintenta sin publicar su salida aparente. `SIGABRT` y
  `SIGSEGV` sólo se reintentan si el log del intento demuestra OOM o fallo de asignación CUDA.
- El coste de un plano tiene un **suelo fijo de ~38 s** (codificador de texto Qwen3-VL en CPU);
  el resto escala con píxeles × frames × pasos. Por eso una prueba de humo sale por ~1 min.

## Estructura

Reordenado el 2026-08-29: la raíz había llegado a 29 entradas, con 12 vídeos sueltos mezclados
con scripts, documentación y los 51 GB de pesos, y las herramientas de medida repartidas entre
`produccion/` y la raíz. Ahora son 13 entradas, y `pruebas/checks/estructura.sh` lo mantiene así.

```
README.md · COMO-LANZAR.md

lib/                  lo compartido — el único sitio con rutas
  comun.sh            rutas, parámetros, ff/ffp, cerrojo, nivel de luminancia
  estado_obra.py      estado atómico, SHA de receta, huellas y gate de vídeo
  compat.sh           hace ejecutable sd-cli en este contenedor
  vram.sh             presupuesto de VRAM adaptativo
  prompt.sh           tipos de plano (habla, informativo, muda, accion, detalle, paisaje, camara)
  enlace.sh           limpieza de enlaces (con tope duro)

produccion/           GENERAR
  producir-anclado.sh  plan + tomas ancladas + reanudación verificada + montaje
  generar-candidato.sh variantes inmutables sin modificar la obra base
  estabilizar-plano.sh B-roll estático determinista con manifiesto
  formatos.sh          los cuatro formatos en serie, resumible
  alargar-formatos.sh  de 29 s a ~58 s sin regenerar lo ya hecho
  lazo.sh              itera semillas hasta una meta
  guiones/             los .guion, con el porqué en la cabecera
  obra/<nombre>/       tomas, anclas y montaje (resumible)

harness/
  planificar.py        compila .guion a un plan JSON canónico y reproducible
  componer.py          texto + categoría → .guion
  noticias.py          recorta una noticia al presupuesto del reel (sin inventar)
  candidatos.py        verifica, selecciona y prepara candidatos por contenido
  estabilizar_plano.py motor reproducible del estabilizador de B-roll
  categorias/          filosofia, documental, noticias (9:16)

produccion/reel-noticias.sh   titular → guion → MiniMax → subtítulos → 1080×1920
produccion/subtitular.py      quema captions en zona segura TikTok/IG
produccion/exportar-reel.sh   9:16, yuv420p, +faststart, −14 LUFS

ui/servidor.py         cockpit local: reel de noticias, estado durable, MP4 confinados

calidad/              MEDIR — todo junto, ya no repartido
  auditar.py           obra · plano · contacto · audio · habla · fondo ·
                       manchas · estabilidad
  evaluar.py           criterio original del autor (intacto)
  evaluar2.py          idem — OJO: sólo vale para retrato hablado
  comparar-formatos.sh tabla comparable ENTRE formatos distintos
  medir-barba.py       detalle fino en una zona concreta
  revisar.py           laminas para MIRAR: lo semantico no lo ve
                       ninguna metrica (manos, identidad, continuidad)
  deriva.sh            deriva a lo largo de una cadena
  seleccionar-ancla.py elige un frame neutral con YuNet y evidencia JSON
  preparar-modelos-evaluacion.sh instala modelos locales con SHA fijado
  v2/                  gate fail-closed de obra, montaje, identidad, ASR y audio

herramientas/         piezas sueltas de un solo uso
  guardian-vram.sh     corta la generación si baja el margen de GPU del usuario
  h3.sh                un clip para probar un prompt
  encadenar.sh · generar-1080p.sh · ordenar-videos.sh

videos/               LO QUE SE ENTREGA
  entregas/           piezas buenas + sidecar verificable (DEST por defecto)
  experimentos/       clips de experimentos (barbas, resoluciones)

modelos/              los 51 GB de pesos, agrupados (fuera de git)
  diffusion_models/ · text_encoders/ · vae/ · upscalers/

pruebas/humo.sh       punto de entrada único · descubre checks/ automáticamente
medidas/              mediciones de VRAM (versionadas)
archivo/              material apartado, no borrado
proyecto-minuto/      pipeline anterior de 14 planos (histórico)
```
