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

Los modelos completos piden ~42 GB de RAM. Con el **podado** bajan a 33 GB y
entran en un contenedor de 24 GB + 24 de swap:

```bash
MODELO=$PWD/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf \
  produccion/producir-toma-unica.sh guion.guion nombre 345 736 416 20
```

## Qué NO hacer

- **No encadenes por defecto.** Cada eslabón cuesta, y el tercero cuesta 19 puntos.
- **No desenfoques para subir la nota.** Se probó: devuelve la energía de borde a
  la referencia y deja la cara sin poro ni pelo de barba. `lib/enlace.sh` tiene un
  tope duro en σ 0,35 y se niega a pasar.
- **No pidas el fondo por negación.** «no objects, no furniture, no walls» mete
  muebles y paredes. Descríbelo en positivo: «a plain matte black backdrop».
- **No edites un script mientras corre.** Bash relee por offset de bytes. Si tienes que
  cambiarlo con una tanda viva, escribe a un temporal y `mv` encima: el `rename` es atómico y
  el proceso vivo conserva su inode. La tanda siguiente ya coge la versión nueva.
- **No midas mientras genera.** Escanear todos los fotogramas de un clip mientras el modelo
  decodifica el VAE mató una toma en el paso 16/20: 18 minutos de GPU. Durante una generación
  la RAM del cgroup baja a decenas de MiB. `comparar-formatos.sh` se niega solo; para forzarlo
  hace falta `MEDIR_IGUAL=1`, a sabiendas.
- **No compruebes un guion produciéndolo.** Usa `VALIDAR=1`, que además imprime el prompt
  exacto que recibe el modelo. Comprobar la sintaxis arrancando una generación real deja dos
  procesos peleándose por el cerrojo.
- **No bajes `VRAM_COLCHON` por debajo del margen del guardián.** Si el presupuesto autoriza
  más VRAM de la que el guardián tolera, el sistema mata la generación que él mismo autorizó:
  pasó, y costó una toma en el paso 13/20. Y ojo, **anclar engorda el buffer ~1,7 GB** sobre
  la ruta limpia — `vram_arg_trabajo` necesita saber si la toma va anclada.
- **No des por buena una nota sin saber qué mide.** Tres medidas de este proyecto han dado
  falsas alarmas: `evaluar2` fuera del retrato hablado, la cobertura de voz en planos mudos, y
  un «audio 5/15» que en realidad decía que mis clips eran más limpios que la referencia.
