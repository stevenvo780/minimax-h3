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

## Comprobar una pieza a mano

```bash
produccion/auditar.py plano    video.avi     nota y bloques
produccion/auditar.py contacto video.avi h.jpg   9 fotogramas para MIRARLO
produccion/auditar.py habla    video.avi     que no se calle a la mitad
produccion/auditar.py audio    video.avi     ruido real, sin confundirlo con volumen
produccion/auditar.py obra     obra/nombre/  mide cada ESLABÓN si hay varios planos
```

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
- **No edites un script mientras corre.** Bash relee por offset de bytes.
