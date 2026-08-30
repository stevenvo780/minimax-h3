# Cómo lanzar una tanda

## La versión corta

```bash
cd minimax-h3
produccion/lazo.sh produccion/guiones/exis-toma-unica.guion mi-pieza \
    --meta 85 --horas 8 --frames 345 --w 736 --h 416 --pasos 20
```

Genera, mide, guarda cada intento con su nota, enlaza el mejor y sigue con otra
semilla hasta llegar a la meta o agotar las horas. **Es reanudable**: si lo matas
y lo relanzas, salta las semillas ya probadas.

Al terminar, en `produccion/obra/mi-pieza/intentos/`:

```
s100.avi  s100.jpg     cada intento y su hoja de contactos
s200.avi  s200.jpg
mejor.avi              enlace al de mejor nota
```

**Mira la hoja de contactos antes de dar nada por bueno.** La nota mide
degradación, no belleza: un clip puede sacar 90 y estar mal encuadrado.

## Por qué una sola toma y no varias encadenadas

Está medido. El modelo no se degrada con la duración:

| frames | duración | gradación | estructura |
|---|---|---|---|
| 56 → 517 | 2,3 → 21,5 s | **25/25** en todas | **20/20** en todas |

Encadenar sí degrada, con un acantilado en el tercer eslabón:

| planos | eslabones | TOTAL |
|---|---|---|
| 1 | 0 | 95,0 |
| 2 | 1 | 89,0 |
| 3 | 2 | 87,7 |
| 4 | 3 | **68,7** |

Por eso el lazo no encadena: alarga la toma y varía la semilla.

### Pero para pasar del minuto, se ANCLA

Una sola toma tiene techo: **345 fotogramas a 736x416** (14,4 s), y 685 a 512x288 — pero a
512x288 el modelo produce aberraciones de color (12 manchas medidas contra 0 a 736x416). Para
una pieza de un minuto hacen falta varias tomas, y ahí la elección no es «encadenar o no»:

| montaje | 4 tomas |
|---|---|
| encadenado | 68,7 |
| **anclado** | **85,9** |

Anclar es arrancar cada toma desde un fotograma **prístino** de la toma 1, no desde el último
fotograma de la anterior. Lo que degrada el encadenado es que el último fotograma reinyectado
ya lleva el realce del modelo, y el modelo realza encima: +3,2 % → +8,5 % → +13,5 % → +21,1 %
de energía de bordes acumulada. El ancla resetea esa deriva — salto de bordes −3 % en un
enlace normal frente a −16 % en cada punto de anclaje.

```bash
produccion/producir-anclado.sh guion.guion mi-pieza 345 736 416 20
```

### Varios formatos en una tanda

```bash
produccion/formatos.sh                      # detalle, camara, accion, paisaje
VALIDAR=1 produccion/producir-anclado.sh g.guion x   # revisar el guion SIN gastar GPU
```

Los seis tipos de plano están en `lib/prompt.sh` y documentados en el README.

## Comprobar una pieza a mano

```bash
produccion/auditar.py plano    video.avi     nota y bloques
produccion/auditar.py contacto video.avi h.jpg   9 fotogramas para MIRARLO
produccion/auditar.py habla    video.avi     que no se calle a la mitad
produccion/auditar.py audio    video.avi     ruido real, sin confundirlo con volumen
produccion/auditar.py obra     obra/nombre/  mide cada ESLABÓN si hay varios planos
produccion/auditar.py manchas  video.avi     escanea TODOS los fotogramas
produccion/auditar.py estabilidad video.avi  deriva, SIN suponer que hay una cara
produccion/comparar-formatos.sh              tabla comparable entre formatos
```

### Lo que NINGUNA métrica de este proyecto ve

Comprobado el 2026-08-29 mirando las piezas ya medidas:

| pieza | lo que dicen las métricas | lo que se ve al mirar |
|---|---|---|
| `formato-detalle` | 0 manchas · ESTABLE · −4,2 % | la **mano derecha está malformada** los 56 s: dedos fundidos, proporciones imposibles |
| `formato-accion` | 0 manchas · deriva leve | el **sujeto salta de sitio y de escala** en cada corte, y su cara cambia |

Las dos puntúan perfecto. Son defectos **semánticos** —anatomía, identidad,
continuidad— y el procesado de señal es ciego a ellos por construcción.

**Se intentó detectarlos por señal y NO funciona.** Se comparó la mediana temporal
de cada toma para cazar la incoherencia entre tomas: la pieza mala dio 1,81 % de
diferencia y la buena 3,87 %, o sea **al revés**. Dos imágenes pueden diferir
poquísimo en píxeles y muchísimo en significado. No lo reintentes.

```bash
calidad/revisar.py video.mp4 --obra produccion/obra/<nombre> --zona cara
```

Genera la tira de 12 momentos y el zoom de la misma región en cada toma — que es
lo que delata el salto de continuidad. **Y hay que mirarlas.**

**Quién puede mirar:** sólo Claude. `delegar_a_cloud` acepta únicamente texto, así
que Gemini, Codex y MiniMax **no pueden ver un fotograma** en este montaje: sólo
reciben la descripción que uno les escriba, que es justo el eslabón que falla. Sirven
para escribir el código del detector, no para revisar la imagen.

**Dos medidas mienten fuera del retrato hablado, y hay que saberlo:**

- `evaluar2` recorta **siempre el centro** (donde está la cara en un retrato) y compara sólo
  la primera muestra contra la última. Con esa vara un paisaje impecable sacó 44,6 y un plano
  de acción 79,0 *por que el sujeto se moviera, que es su función*. Para comparar formatos
  distintos, usa `estabilidad`, que mide el fotograma entero y compara medianas de tercios.
- `habla` sólo significa algo si hay diálogo. En un plano de manos o un paisaje no hay
  silencios que separen frases, así que lee el ambiente como voz continua y dictamina
  «ATROPELLADO». `producir-anclado.sh` ya se la salta cuando ninguna toma es de tipo `habla`.

## Hardware

El techo de VRAM sale de `lib/vram.sh`, que lo calcula sobre lo **libre en ese
instante**, no sobre el total, para no comerse el margen del escritorio. Si abres
algo que consume VRAM, el techo baja solo.

Ojo: los latentes crecen con el número de frames, así que una toma muy larga usa
más VRAM que el techo nominal. Si vas a dejarlo toda la noche con tomas de más de
500 frames, baja `--max-vram` o vigila con:

```bash
watch -n5 nvidia-smi --query-gpu=index,memory.free --format=csv
```

### En un contenedor sin CUDA o con otro glibc

`lib/compat.sh` lo resuelve solo: busca CUDA en el disco y, si `sd-cli` pide una
versión de glibc más nueva que la del sistema, trabaja sobre una **copia** del
binario sin esa exigencia. El original nunca se toca.

Los modelos completos piden ~42 GB de RAM. Con el **podado** bajan a 33 GB. Eso
importaba cuando el contenedor tenía 24 GB; desde el 2026-08-30 tiene **125 GB** y
el podado se usa por costumbre, no por necesidad. `lib/comun.sh` lo pone por
defecto porque es lo medido; el entero cabe ahora, pero **no está probado**:

```bash
MODELO=$PWD/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf \
  produccion/producir-toma-unica.sh guion.guion nombre 345 736 416 20
```

## Resolución: qué se puede y qué no

Todo lo entregado hasta el 2026-08-30 sale a **736x416**, y eso es poco en
cualquier pantalla. Hay dos palancas y **no son intercambiables**:

```bash
produccion/sonda-resolucion.sh 107          # fija fotogramas, sube el tamaño
produccion/sonda-duracion.sh 1024 576       # fija el tamaño, sube los fotogramas
produccion/escalar.sh videos/entregas/x.mp4 # acabado x4 en la 2060
```

Las dos sondas **generan de verdad**, no estiman: el buffer de cómputo crece con
el **producto** `fotogramas x ancho x alto`, así que no existe «la resolución
máxima» ni «la duración máxima», existe una curva. Y la elección que sale de ella
es de forma, no técnica: 10 planos de 8 s a 736x416 son 80 s de pieza; 10 planos
de 4,5 s a 1152x648 son 45 s con el doble de detalle.

Las tablas van a `medidas/`.

### El escalador SÍ sirve, y las dos medidas obvias dicen que no

`RealESRGAN x4` sobre una pieza terminada mejora la imagen de forma visible
—arrugas definidas donde el lanczos las funde— y sin embargo mide **−5,5 % de
bordes** y **+4,0 % de parpadeo**. Sobel no mide nitidez, mide gradiente, y el
grano de película es gradiente: el escalador lo limpia y cambia gradiente
repartido por detalle concentrado. El detalle completo, en
`medidas/escalador-esrgan.md`.

Es **acabado**, no generación: no inventa detalle que no se generó. Corre en la
**RTX 2060**, que no compite con la generación, pero a ~20 s/fotograma son ~6 h
por pieza de 46 s. Úsalo sobre una pieza ya aprobada, nunca durante la iteración.

**El tile hay que negociarlo, no fijarlo.** Con `--upscale-tile-size 512` la 2060
aborta SIEMPRE (`cublasCreate_v2 ... resource allocation failed`). La versión
anterior de `escalar.sh` lo tenía fijo en 512: fallaban los N fotogramas, se
negaba —con razón— a montar un vídeo incompleto, y **nunca escaló nada**.

## Qué NO hacer

- **No encadenes por defecto.** Cada eslabón cuesta, y el tercero cuesta 19 puntos.
- **No desenfoques para subir la nota.** Se probó: devuelve la energía de borde a
  la referencia y deja la cara sin poro ni pelo de barba. `lib/enlace.sh` tiene un
  tope duro en σ 0,35 y se niega a pasar.
- **No pidas el fondo por negación.** «no objects, no furniture, no walls» mete
  muebles y paredes. Descríbelo en positivo: «a plain matte black backdrop».
- **No edites un script mientras corre.** Bash relee por offset de bytes. **Ha pasado, con el
  script en marcha:** una escritura en sitio sobre `producir-anclado.sh` durante una tanda dio
  `pdate: command not found` y `syntax error near unexpected token 'done'` — el proceso leyó
  basura a mitad de `$(date` y murió **justo antes de montar**, tras 6 tomas buenas. Se recuperó
  volviendo a lanzar (las tomas existían y se saltan), pero pudo costar 2 h de GPU.
  La regla no es "ten cuidado": es **escribe a un temporal y `mv` encima**, siempre. El `rename`
  es atómico y el proceso vivo conserva su inode. Si tienes que
  cambiarlo con una tanda viva, escribe a un temporal y `mv` encima: el `rename` es atómico y
  el proceso vivo conserva su inode. La tanda siguiente ya coge la versión nueva.
- **Nunca mates procesos con `pkill -f` ni `pgrep -f`.** El patrón hace match con **tu propia
  línea de comandos**, así que te matas a ti mismo. Ha pasado **tres veces** en este proyecto,
  la tercera en el comando siguiente a documentar la segunda. Escribirlo no basta: no uses esa
  familia de comandos, punto. Lo que sí funciona:

  ```bash
  # por nombre EXACTO de proceso: un shell nunca se llama sd-cli
  for p in $(ps -eo pid,comm | awk '$2=="sd-cli"{print $1}'); do kill -TERM $p; done

  # por script, con el patrón PARTIDO para que tu cmdline no lo contenga entero
  P='fi'; P="${P}x.sh"
  ps -eo pid,args | awk -v a="$P" -v mio=$$ '$1!=mio && index($0,a){print $1}'
  ```
- **No midas mientras genera.** Escanear todos los fotogramas de un clip mientras el modelo
  decodifica el VAE mató una toma en el paso 16/20: 18 minutos de GPU. Durante una generación
  la RAM del cgroup baja a decenas de MiB. `comparar-formatos.sh` se niega solo; para forzarlo
  hace falta `MEDIR_IGUAL=1`, a sabiendas.
- **No compruebes un guion produciéndolo.** Usa `VALIDAR=1`, que además imprime el prompt
  exacto que recibe el modelo. Comprobar la sintaxis arrancando una generación real deja dos
  procesos peleándose por el cerrojo.
- **No ancles un plano de detalle a un fotograma de cara: le mete la cara dentro.** En
  `3-absurdo` las tomas de apoyo salieron **híbridas** —la mano con la piedra *y* el rostro del
  hombre— porque estaban ancladas a la toma 1, que es un primer plano de cara. El mismo
  mecanismo que da continuidad es el que contamina, y sale intermitente porque depende de cuánta
  cara traiga el fotograma usado como ancla.
  Ninguna métrica lo vio: la pieza sacó **ESTABLE, 0 manchas y la mejor variedad de las cinco**.
  Se ve mirando y sólo mirando.
  Arreglo: darle a la toma de apoyo su **escena propia** (campo 5) y modo `inicio`. Pierde
  continuidad de identidad —irrelevante en un plano de manos— y gana pureza de encuadre.
- **El anclaje es incompatible con un movimiento de cámara continuo.** Cada toma anclada
  arranca desde un fotograma de la toma 1, así que un dolly vuelve siempre a la distancia
  inicial: en `formato-camara` el tamaño de la lámpara hace pequeño-mayor-**pequeño**-mayor a
  lo largo del minuto, o sea que la cámara salta atrás en cada corte. Pedirle «continúa
  avanzando» no sirve — no puede continuar desde donde no está. Para un movimiento continuo:
  una sola toma (techo 14,4 s), o encadenar en vez de anclar y pagar la degradación.
- **Un `Aborted (core dumped)` NO es un OOM de RAM: mira `produccion/logs/<pieza>-t<N>.log`.**
  La salida completa de `sd-cli` ya se guarda ahí, con el motivo exacto. En la consola la barra
  de progreso lo sobrescribe con retornos de carro y sólo queda la traza, que no dice nada. El
  mensaje que buscas se lee así:
  ```
  ggml_backend_cuda_buffer_type_alloc_buffer: allocating 665.05 MiB on device 0:
  cudaMalloc failed: out of memory
  ```
  Eso es **VRAM**, no RAM. Pasó cuando el escritorio del usuario subió de 3,5 a 5,7 GB y la
  generación dejó de caber. Se perdió una tarde ajustando umbrales de RAM por no leer ese log.
- **Soltar la caché con `posix_fadvise(DONTNEED)` NO ayuda: probado y descartado.** Entre tomas
  la caché de ficheros del cgroup es de ~0,4 GB, así que no hay nada que soltar. El pico es el
  conjunto de trabajo propio de `sd-cli` (19,3 GB medidos), no caché reclamable. Con ~19,5 GB
  libres cada toma **anclada** pasa rozando: por eso las limpias salen y las ancladas fallan más.
- **`rc=$?` después de `$(...)` reporta el código de salida equivocado.** Escrito así:
  ```bash
  echo "[$(date +%H:%M:%S)] rc=$?"     # MAL: $(date) se ejecuta primero y pisa $?
  rc=$?; echo "[$(date +%H:%M:%S)] rc=$rc"   # bien
  ```
  Costó una sesión entera de conclusiones falsas: una pieza perdió una toma tras 6 intentos, el
  pipeline salió con 1 correctamente, y el log dijo **`rc=0`**. Apareció en **14 scripts a la
  vez**. `pruebas/checks/codigo-salida.sh` lo caza.
- **La suite de humo es frágil con una generación en curso.** Un check rojo aislado mientras
  `sd-cli` tiene la memoria al límite no significa lo mismo que uno con la máquina en reposo:
  pasó el 2026-08-30, un fallo que desapareció al repetirlo sin cambiar nada. Antes de perseguir
  un rojo, repite la suite con la GPU libre.
- **`te=disk` parece resolver los OOM: úsalo.** `--params-backend diffusion=cpu,te=disk` deja
  los 17 GB del codificador de texto en el fichero en vez de en RAM; sólo hace falta al arrancar,
  para condicionar el prompt. Medido tras aplicarlo: **10 reintentos antes → 0 después**, y el
  contador `oom_kill` del kernel **congelado**, con una toma anclada pasando a la primera donde
  otra había caído seis veces. Señal fuerte, no prueba cerrada: son 3 tomas y el fallo era
  probabilístico.
- **[CADUCADO el 2026-08-30] El cgroup ya no son 24 GB, son 125.** Todo lo que
  viene a continuación sobre OOM de RAM describe una máquina que ya no es esta:
  `memory.max` = 125 GB y los 73 `oom_kill` de `memory.events` son históricos.
  **No se borra porque el razonamiento sigue siendo correcto** y vuelve a aplicar
  en cuanto el contenedor se encoja. Lo que hoy limita la resolución es sólo la
  VRAM. Compruébalo antes de creerte nada de lo de abajo:
  ```bash
  awk '{printf "%.0f GB\n", $1/1073741824}' /sys/fs/cgroup/memory.max
  ```
- **LA CAUSA RAÍZ de los OOM: los pesos no caben, y punto.** El modelo podado ocupa **10,6 GB**
  y el codificador de texto otros **17,0 GB** — **27,6 GB de pesos en un cgroup de 24**. Funciona
  sólo porque están mapeados desde disco y el kernel expulsa páginas (el codificador no hace
  falta durante la difusión), y **revienta cuando el desalojo no llega a tiempo**.
  Consecuencias que hay que aceptar:
  1. El fallo es **probabilístico** y depende del ritmo de paginación, no de los parámetros. Eso
     explica 16 tomas seguidas sin un fallo un día y fallos constantes al siguiente con la misma
     configuración.
  2. **Ningún ajuste del pipeline lo arregla.** Se probaron cinco —umbral de RAM, tope de VRAM,
     descuento de VRAM, `ram_libre_mb`, menos fotogramas— y ninguno cambió nada, porque ninguno
     tocaba la causa. Antes de "arreglar" el presupuesto otra vez, lee esto.
  3. La respuesta correcta contra un fallo probabilístico es **reintentar** (`REINTENTOS=6`), no
     seguir afinando. Las palancas reales serían un cgroup mayor o un codificador más pequeño.
- **`sd-cli` llega a 19,3 GB de RAM y el contenedor tiene 24. El margen es CERO.** Medido
  muestreando a **1 Hz** y guardando el máximo; muestreando cada 5 s salían 14,2 GB, porque el
  pico se escapaba entre muestras. **Si mides un pico, muestrea rápido o no lo estás midiendo.**
- **Los clips CORTOS son menos fiables que los largos, al revés de lo que parece.** Con pocos
  fotogramas el buffer es pequeño, la fórmula reparte el hueco al modelo y sube `cuda0`; ahí
  aparecieron cinco OOM seguidos en la misma toma a 107 fotogramas, mientras la configuración de
  **345 fotogramas lleva ~20 tomas seguidas sin un fallo**. Para probar un prompt, usa la
  configuración probada aunque tarde más: una prueba «barata» que no termina sale carísima.
- **La huella la fija el MODELO MAPEADO, no la configuración.** `sd-cli` mapea los GGUF en
  memoria; esas páginas cuentan como `file` en el cgroup y **no se pueden liberar** mientras se
  usan. Con la generación en marcha: `anon` 8,1 GB + `file` **12,9 GB** + kernel/slab 5,2 GB, y
  de ahí sale el pico de 19,3 GB. **Ningún ajuste de los scripts baja eso**: las palancas reales
  son un modelo más pequeño o un cgroup más grande.
  *Ojo con medirlo mal*: un muestreo tomado justo después de matar un proceso daba `file` 3,5 GB
  y llevó a descartar la caché por error. La caché tarda en volver a llenarse — **mide con la
  generación en régimen, no recién arrancada**.
- **Antes de culpar a la VRAM de un OOM, mira si es de RAM.** El cgroup tiene 24 GB y `sd-cli`
  necesita **14,2 GB medidos**; el resto de procesos más el kernel y el driver se comen ~10 GB.
  Los umbrales de espera estaban a ojo (8 GB para arrancar, 10 para reintentar), así que el
  script daba luz verde con 13,4 GB libres y el OOM killer lo mataba en el paso 7 de 20, tres
  veces en la misma toma. Ahora es un solo número, `RAM_NECESARIA=16000`, sacado de medir.
  Descartado por el camino: no era el presupuesto de VRAM (se bajó de `cuda0=7` a `4` y murió
  igual) ni la caché de página (`anon` 17,6 GB contra `file` 3,5 GB).
- **No bajes `VRAM_COLCHON` por debajo del margen del guardián.** Si el presupuesto autoriza
  más VRAM de la que el guardián tolera, el sistema mata la generación que él mismo autorizó:
  pasó, y costó una toma en el paso 13/20. Y ojo, **anclar engorda el buffer ~1,7 GB** sobre
  la ruta limpia — `vram_arg_trabajo` necesita saber si la toma va anclada.
- **La barba erizada NO es falta de resolución: es el prompt.** `close-cropped` (al rape es
  cerdoso por definición) más una luz dura y rasante dan pelos rectos y separados que se
  recortan uno a uno contra el fondo — una barba postiza. Pedir la barba *llena y en mechones
  blandos* con *luz grande y difusa* la convierte en pelo de verdad. Medido: el habla cuesta
  −1,3 % de detalle fino, la codificación −1,4 %, y doblar la resolución sólo da +4,7 %.
  Ninguno de los tres era la causa.
- **Ojo: en la textura de la barba, la métrica va AL REVÉS que el ojo.** La barba blanda, que
  se ve mucho mejor, mide **−4,2 %** de detalle fino. Y es correcto: cada pelo aislado contra
  fondo negro es un borde de máximo contraste, así que lo erizado puntúa más alto. Optimizar
  ese número lleva derecho a la barba de cepillo. **Aquí hay que mirar, no medir.**
- **No iguales el brillo de un plano que es distinto A PROPÓSITO.** El montaje
  nivela la luminancia de cada toma contra la toma 1, y eso es correcto para una
  toma **anclada**: la diferencia es deriva del anclado. Pero una toma en modo
  `inicio` con escena propia —un puerto frío al amanecer, la cara de un segundo
  interlocutor— es otra imagen por decisión, y forzarla al brillo de un primer
  plano cálido **aplana el contraste que es la mitad de la forma**. La ganancia
  está acotada a `[0,5 , 2,0]`, así que no salta en ninguna métrica: se ve o no
  se ve. `producir-anclado.sh` ya sólo nivela lo anclado y sin escena propia, y
  deja constancia en el log de lo que NO nivela.
- **Sourea `lib/comun.sh` y nada más.** Ese fichero carga ya `compat.sh`,
  `prompt.sh` y `vram.sh`. Antes cada script tenía que acordarse de los cuatro, y
  olvidarse no da un error al cargar: da un `command not found` **a mitad de
  trabajo**. Costó dos veces el mismo día — seis scripts morían al tocar la GPU
  por no tener `compat.sh`, y la sonda de resolución esperó **hora y media** a
  que se liberase la tarjeta para caerse en su primera línea con
  `construir_prompt: command not found`. Si añades otra librería, cárgala desde
  `comun.sh`, no desde cada script.
- **No des por buena una nota sin saber qué mide.** Tres medidas de este proyecto han dado
  falsas alarmas: `evaluar2` fuera del retrato hablado, la cobertura de voz en planos mudos, y
  un «audio 5/15» que en realidad decía que mis clips eran más limpios que la referencia.
