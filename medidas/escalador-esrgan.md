# ¿Sirve RealESRGAN x4 sobre lo que genera este pipeline?

**Sí, y las dos medidas obvias dicen que no.** Es la séptima falsa alarma de
medición de la sesión y la más limpia de todas.

## El experimento

48 fotogramas (2 s) de `3-absurdo`, un primerísimo plano de una mano sobre una
piedra. Dos caminos hasta 1080p:

- **lanczos**: 736x416 → 1080p, que es lo que hace cualquier reproductor solo.
- **esrgan**: 736x416 → RealESRGAN x4 → 2944x1664 → 1080p.

## Lo que dijeron las medidas

|          | bordes (sobel) | parpadeo (tblend diff) |
|----------|---------------:|-----------------------:|
| lanczos  |        15.2894 |                 1.6701 |
| esrgan   |        14.4488 |                 1.7374 |

Menos energía de bordes (−5.5 %) y más parpadeo (+4.0 %). Leído a secas: el
escalador empeora la imagen en los dos ejes.

## Lo que se ve al mirar

Lo contrario, y sin ambigüedad. En el mismo recorte y el mismo instante, el
ESRGAN tiene las arrugas del nudillo definidas donde el lanczos las tiene
fundidas, el borde de la uña limpio donde el lanczos lo tiene baboso, y grano
de piedra donde el lanczos tiene una mancha gris.

## Por qué mintieron las dos

**Sobel no mide nitidez, mide gradiente** — y el GRANO de película es
gradiente. El pipeline genera con `fine film grain` en el prompt. El lanczos
conserva ese grano y lo emborrona en el remuestreo, sumando gradiente en cada
píxel. El ESRGAN lo interpreta como ruido y lo limpia, cambiando gradiente
repartido por detalle concentrado. La cifra baja mientras la imagen mejora.

**El parpadeo sube por lo mismo**: el escalador reconstruye cada fotograma por
separado y no reconstruye igual dos veces. Un +4 % sobre un fondo que ya
parpadea por el grano no se ve; sería otra cosa a +40 %.

## Consecuencia práctica

El escalado es **acabado**, no generación: no inventa detalle que no se generó,
pero recupera el que el remuestreo perdía. Y corre en la **RTX 2060**, que ha
estado parada toda la sesión mientras se peleaba por memoria en la 5070 Ti.
Escalar en la 2060 mientras se genera en la 5070 Ti no cuesta tiempo de reloj.

Lo que NO resuelve: 20 s/fotograma en la 2060 son ~6 h por pieza de 46 s. Sólo
compensa como paso final sobre una pieza ya aprobada, nunca durante la
iteración.

Y no sustituye a generar más grande, que es lo único que produce detalle de
verdad. Ver `produccion/sonda-resolucion.sh`.

## La lección, otra vez

Mismo patrón que la barba: la versión arreglada midió −4.2 % y se veía mucho
mejor. **Cuando la medida y el ojo se contradicen, hay que averiguar qué está
contando la medida antes de creerle.** Aquí contaba grano.
