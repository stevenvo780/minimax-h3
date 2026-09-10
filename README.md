# NewsLeters — reels de noticias para TikTok e Instagram

De un titular al MP4 vertical 9:16, con presentadora, diálogo sincronizado y
subtítulos quemados en la zona que no tapa la UI de TikTok/IG.

También puedes generar **imágenes de noticias con Codex**, desde cualquier
agente con terminal:

```bash
python3 harness/imagenes.py --titular "Abre una nueva biblioteca" \
  --texto "Cuenta con una sala de lectura infantil." --nombre biblioteca
```

Requiere Codex CLI autenticado con generación de imágenes y `ffmpeg`.
Usa `--solo-prompt` para preparar sin generar. Consulta el
[módulo de imágenes](imagenes/README.md) y la [guía para agentes](AGENTS.md).

Para **carruseles de Instagram 1080×1350**, con láminas ordenadas, caption y ZIP:

```bash
python3 harness/carruseles.py --noticias imagenes/ejemplos-ia.json --indice 0 --generar
```

Incluye cinco noticias reales de archivo de 2024 como ejemplos; usa `--solo-prompt`
para revisar antes de generar y `--indice 0` a `4` para elegir la noticia.

El motor es MiniMax-H3 local (`bin/sd-cli`): no se encadena, se **ancla**;
nativo **416×736** (los mismos píxeles que 736×416, que es lo medido); export a
**1080×1920**. No inventa la noticia: cada frase que se dice es literalmente un
trozo del texto que le das.

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
produccion/tanda-noticias-dia.sh          # todo noticias/dia/, en serie
ui/servidor.py                            # http://localhost:8080
```

La UI pega titular + cuerpo y lanza **el mismo** `reel-noticias.sh`. El RSS
**no** se ofrece en la UI (sería SSRF). `BROLL=1` intercala planos de apoyo,
que no llevan voz y por eso duran menos (107 f = 4,5 s).

Lo que sale, en `videos/entregas/`:

```
corte-vivienda-416x736-27s-….mp4                 el montaje interno
corte-vivienda-416x736-27s-…-reel-1080x1920.mp4  el reel: subtitulado y a -14 LUFS
```

**El producto es el `-reel-`.** El otro fichero es el montaje nativo, sin
subtítulos y a −19 LUFS: sirve para revisar, no para publicar.
`produccion/sondear-dia.sh` comprueba exactamente eso antes de dar una tanda
por buena.

## Cómo se escribe lo que dice la presentadora

Esta es la parte que más se nota y la que menos se veía. Vive en
`harness/redaccion.py` y tiene **una sola regla dura**: cada frase que se dice
es un trozo literal del titular o del cuerpo. No se parafrasea, no se resume,
no se añade. `produccion/sondear-dia.sh` lo verifica frase a frase contra la
fuente antes de dar la tanda por buena.

Dentro de esa regla, el reparto hace cuatro cosas:

| | |
|---|---|
| **Mide** | 2,6 palabras/s. Cada toma dura **lo que su texto tarda en decirse**, redondeado a la escalera 17k+5 que acepta el modelo (73, 90, 107 … 192 f). Un titular de ocho palabras ocupa 90 f (3,8 s), no 192. |
| **No corta frases** | Una toma nunca empieza a media frase. Si una frase no cabe, se le quita la **cola** cortando solo donde queda una oración completa —y se comprueba que el trozo tiene verbo—; si no hay corte limpio, la frase se descarta con un aviso. |
| **No repite** | La entradilla de un teletipo reformula el titular por convención periodística. Se compara por raíz aproximada y se salta lo que ya se ha dicho, para no gastar media pieza contando un hecho dos veces. |
| **Avisa** | Si una toma queda fuera de la banda de 1,6–3,0 palabras/s, se dice por pantalla antes de tocar la GPU. |

Los avisos importan: `frase descartada`, `ya dicho al 67%` y `toma 2 a 3,4
pal/s` son la diferencia entre un reel decente y uno que hay que tirar.

### Lo que NO hace, y hay que saberlo

No reescribe a lenguaje hablado. Un titular está escrito para leerse, no para
decirse, y suena a titular. Eso es el precio de la regla dura de arriba: la
única forma de arreglarlo sin romperla sería una reescritura verificada contra
la fuente, y hoy no existe.

### Historia, porque explica constantes que siguen ahí

El pipeline nació para vídeos de **filosofía**: un hombre de unos 55 años con
barba, retrato cerrado sobre fondo negro, tomas de 14,4 s, voz calmada, formato
apaisado 736×416. Las 2,6 palabras/s se midieron ahí. Casi todo lo demás de esa
etapa se ha quitado; si aparece un número que solo tiene sentido para un
retrato apaisado, es un resto y hay que tratarlo como un defecto.

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
  produccion/guiones/noticias/generados/corte.guion corte 192 416 736 20
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
cat produccion/obra/corte/estado.json
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

Los seis originales se generaron y se midieron **en la etapa de filosofía**
(107 fotogramas, 736×416 apaisado, 20 pasos): ninguno produjo manchas de color.
`informativo` es el mismo retrato hablado con otra entrega, en 9:16. En el reel
sólo se usan `informativo` y, con `BROLL=1`, `detalle`.

Sólo `habla` e `informativo` llevan voz. Esa lista vive en **un sitio por
lenguaje** y hay que mantenerla igual en los dos: `PROMPT_TIPOS_VOZ` en
`lib/prompt.sh` y `TIPOS_VOZ` en `harness/redaccion.py`. Estuvo copiada en
cinco sitios y faltaba justo donde más dolía: el runner preguntaba
`= habla` a secas, así que en un reel —cuyas tomas son `informativo`— el
selector de ancla neutral y la medida de cobertura de voz **no se ejecutaban
nunca**.

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

## Otros puntos de entrada

| Script | Para qué |
|---|---|
| `herramientas/h3.sh "prompt"` | un clip suelto, rápido, para probar un prompt |
| `herramientas/generar-1080p.sh "prompt"` | genera pequeño y escala ×4 repartiendo frames entre las dos GPU |
| `produccion/escalar.sh <video>` | RealESRGAN ×4 y remonte a 1080p. **No está en el camino del reel**: el export escala con ffmpeg |

## Medir la calidad, no mirarla a ojo

```bash
calidad/evaluar2.py <video.mp4> [--seg <segundos por plano>]
```

`evaluar2.py` es **anti-trampa**: toma el primer plano como referencia y penaliza desviarse
en *cualquier* dirección. Nació al detectar que el evaluador anterior premiaba inyectar
grano sintético.

**Aviso de calibración**: `evaluar2.py` recorta la zona de la cara donde estaba
en el retrato apaisado. En 9:16 esa ventana cae sobre cuello y camisa, así que
sus números no significan lo mismo para un reel. Sirve para comparar dos tomas
del mismo formato, no para dar un reel por bueno.

No hay puerta de calidad automatica en el camino del reel: lo que se publica es
lo que sale. `calidad/auditar.py` y `calidad/revisar.py` son herramientas de
MIRAR, a mano y despues. El evaluador v2 —YuNet + SFace + ASR con informe
verificable— existio y se retiro: nunca se enchufo a produccion, y su ASR
depende del filtro `whisper`, que existe desde ffmpeg 8.0. Esta en el historial
de git si se quiere recuperar y cablear de verdad.

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
se lleva el detalle legitimo. Es justo la trampa por la que existe
`evaluar2.py`. (El módulo `lib/enlace.sh` que aplicaba ese tope se retiró con
la maquinaria de encadenado: el pipeline ancla, no encadena.)

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
bajan a 33 GB. (Esa cuenta era contra el contenedor de 24 GB + 24 GB de
swap; desde el 2026-08-30 el cgroup son 125 GB y lo que limita es la VRAM.
Ver la nota CADUCADO en COMO-LANZAR.md.)

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
con scripts, documentación y los pesos, y las herramientas de medida repartidas entre
`produccion/` y la raíz. `pruebas/checks/estructura.sh` lo mantiene así: sin vídeos
sueltos en la raíz, los pesos agrupados en `modelos/` y la medida sólo en `calidad/`.

Las tres capas son **harness/** (texto → guion), **produccion/** (guion → vídeo)
y **calidad/** (vídeo → informe). La frontera no es perfecta —`seleccionar-ancla.py`
vive en `calidad/` y corre en caliente durante la generación— pero es la que
explica dónde buscar cada cosa.

```
README.md · COMO-LANZAR.md

lib/                  lo compartido — el único sitio con rutas
  comun.sh            rutas, parámetros, ff/ffp, cerrojo, nivel de luminancia
  estado_obra.py      estado atómico, SHA de receta, huellas y gate de vídeo
  compat.sh           hace ejecutable sd-cli en este contenedor
  vram.sh             presupuesto de VRAM adaptativo
  prompt.sh           tipos de plano y cuáles llevan voz (PROMPT_TIPOS_VOZ)

noticias/dia/         LA ENTRADA: la noticia en crudo, con TITULAR y FUENTE.
                      La leen las dos mitades: el reel y el carrusel

harness/              NOTICIA → INSTRUCCIONES DE GENERACIÓN
  redaccion.py        noticia → tomas decibles: mide, no corta frases, no repite
  noticias.py         lee la noticia (fichero, RSS o argumentos) y escribe el .guion
  investigar.py       de un TEMA a la noticia del catálogo del día
  componer.py         tomas + categoría → .guion, con el ritmo de planos
  planificar.py       compila .guion a un plan JSON canónico y reproducible
  categorias/         noticias.json — el mundo audiovisual del reel

produccion/           GUION → VÍDEO
  reel-noticias.sh     EL CAMINO COMPLETO: guion → tomas → subtítulos → 1080×1920
  tanda-noticias-dia.sh todo noticias/dia/, en serie, un cerrojo
  producir-anclado.sh  plan + tomas ancladas + reanudación verificada + montaje
  subtitular.py        cues por toma, sin truncar, a la resolución final
  exportar-reel.sh     9:16, yuv420p, +faststart, −14 LUFS, y quema el rótulo
  sondear-dia.sh       ACEPTACIÓN: que lo entregado sea un reel, no el montaje
  escalar.sh           RealESRGAN x4 y remonte a 1080p (no está en el reel)
  lazo.sh              itera semillas hasta una meta
  guiones/             el ejemplo versionado; los generados no se versionan
  obra/<nombre>/       tomas, anclas y montaje (resumible)

ui/servidor.py         cockpit local: lanza reel-noticias.sh, estado, MP4 confinados

calidad/              VÍDEO → INFORME
  auditar.py           obra · plano · contacto · audio · habla · fondo ·
                       manchas · estabilidad
  evaluar2.py          librería de medida — OJO: pensada para retrato hablado
  comparar-formatos.sh tabla comparable ENTRE formatos distintos
  revisar.py           láminas para MIRAR: lo semántico no lo ve
                       ninguna métrica (manos, identidad, continuidad)
  seleccionar-ancla.py elige un frame neutral con YuNet y evidencia JSON
  preparar-modelos-evaluacion.sh instala modelos locales con SHA fijado

herramientas/         piezas sueltas de un solo uso
  guardian-vram.sh     corta la generación si baja el margen de GPU del usuario
  h3.sh                un clip para probar un prompt
  generar-1080p.sh

videos/               LO QUE SE ENTREGA
  entregas/           piezas buenas + sidecar verificable (DEST por defecto)

modelos/              los pesos, agrupados (fuera de git)
  diffusion_models/ · text_encoders/ · vae/ · upscalers/ · evaluacion/

pruebas/humo.sh       punto de entrada único · descubre checks/ automáticamente
medidas/              mediciones de VRAM (versionadas). Todas apaisadas: del
                      formato vertical no hay ni una medida propia
```
