# Imágenes de noticias con Codex

## Carruseles de Instagram

`harness/carruseles.py` admite noticias con 2–10 diapositivas revisadas. Genera
una imagen por lámina mediante Codex, manteniendo la misma dirección de arte.
Exporta JPEG a **1080×1350 (4:5)**, sin recortar contenido: ajusta tamaño y añade
un margen marfil cuando la proporción original varía ligeramente. Rechaza
imágenes pequeñas o con proporciones alejadas de 4:5.

Hay cinco ejemplos reales de archivo en `imagenes/ejemplos-ia.json`: GPT-4o,
AlphaFold 3, Llama 3.1, SAM 2 y Gemini 1.5. Llevan fuentes primarias y fechas
de 2024: son una retrospectiva, no noticias actuales.

```bash
# Revisar uno de los cinco ejemplos (índices 0–4).
python3 harness/carruseles.py --noticias imagenes/ejemplos-ia.json \
  --indice 0 --solo-prompt

# Generar las tres láminas con Codex CLI y empaquetarlas.
python3 harness/carruseles.py --noticias imagenes/ejemplos-ia.json \
  --indice 0 --generar

# Un agente con image_gen puede ejecutar los prompts directamente e importar
# después los archivos generados, en su orden de publicación.
python3 harness/carruseles.py --noticias imagenes/ejemplos-ia.json \
  --indice 0 --importar /ruta/portada.png /ruta/contexto.png /ruta/cierre.png
```

La salida está en `imagenes/generadas/carruseles/<nombre>/`: `01.jpg`, `02.jpg`,
etc., `caption.txt`, `textos-alternativos.txt`, manifiesto con fuentes, prompts
y hashes, y `publicar.zip`. No sobrescribe entregas. `--destino` permite crear
una tanda nueva. La salida JSON y los códigos siguen el contrato del módulo
de imágenes. `--generar` conserva además los originales y logs de Codex.

Para otras noticias, copia la estructura JSON y cambia textos, fuente, URL,
fecha, tema, color y descripción visual. La propiedad `serie` define la
etiqueta visible; se puede sustituir con `--serie`. Si no se proporciona,
se usa «Noticias de IA». El módulo no investiga ni verifica automáticamente
los textos aportados. Revisa las imágenes y sus textos antes de publicar.

Para subir manualmente: crea una publicación de varias fotos, selecciona
los JPEG en orden numérico y pega `caption.txt`. Cada carpeta es una publicación
independiente. El módulo prepara los archivos; no publica en la cuenta.

Interfaz de terminal y Python para cualquier agente con acceso al repositorio.
Recibe una noticia ya seleccionada y solicita una imagen con su titular y la
etiqueta «Ilustración IA». Usa `codex exec` y pide la herramienta nativa
`image_gen`; no llama directamente a la API de imágenes.

## Preparación

Python 3.10+, `ffmpeg` y Codex CLI en `PATH`, con una sesión iniciada mediante
`codex login` y acceso a generación de imágenes. Se conserva la configuración
y autenticación local de Codex. La disponibilidad depende de esa sesión: tener
el binario instalado no garantiza acceso a la herramienta.
Consulta la [documentación oficial de Codex CLI](https://learn.chatgpt.com/docs/codex/cli).

## Uso desde cualquier agente

Desde la raíz del clon:

```bash
# Revisar el prompt: no llama a Codex, no necesita ffmpeg ni escribe archivos.
python3 harness/imagenes.py --titular "Abre una nueva biblioteca" \
  --texto "La biblioteca tiene una sala de lectura infantil." --solo-prompt

# Generar una imagen (consume el uso de la sesión de Codex).
python3 harness/imagenes.py --titular "Abre una nueva biblioteca" \
  --texto "La biblioteca tiene una sala de lectura infantil." \
  --nombre biblioteca --formato vertical

# Mismo formato de noticia.txt que el módulo de reels.
python3 harness/imagenes.py --fichero noticia.txt --nombre portada \
  --formato cuadrado --estilo ilustracion
```

El fichero puede empezar por `TITULAR:` y `FUENTE:` y continuar con el cuerpo,
o usar la primera línea como titular. `--fuente` permite aportar la procedencia
con la entrada por argumentos; no descarga ni verifica enlaces.

Formatos: `vertical` (9:16), `cuadrado` (1:1), `horizontal` (16:9).
Estilos: `editorial`, `ilustracion`, `infografia`. Son instrucciones al generador;
las dimensiones reales quedan en el manifiesto, sin escalado ni recorte automático.
Revisar visualmente relación de aspecto, texto y fidelidad a la noticia.

`--destino /ruta` cambia la carpeta de entregas; `--codex /ruta/codex`
selecciona el ejecutable; `--timeout 900` cambia el límite de segundos.
Se puede invocar el script por ruta absoluta desde otro directorio.

## Contrato para automatización

Éxito: código 0 y un único objeto JSON por stdout. `--solo-prompt` devuelve
`estado=preparado`; una generación validada devuelve `estado=review_pending`,
`imagen` (ruta absoluta), `ancho`, `alto`, `sha256`, noticia y prompt.
Los errores operativos devuelven código 1 y JSON por stderr; los errores de
sintaxis de argumentos usan el código 2 de argparse.

Cada ejecución reserva `imagenes/generadas/<nombre>/` de forma exclusiva:

- `imagen.png`: PNG que ha decodificado correctamente con ffmpeg.
- `manifiesto.json`: entrada, prompt, estado y metadatos de la imagen.
- `codex.log`: diagnóstico local de la ejecución.

No se sobrescriben directorios existentes. Para reintentar un fallo o generar
variantes, elegir otro nombre. Si falla Codex, falta su herramienta, devuelve
una respuesta incorrecta o no produce un PNG válido, el estado es `error`.
No se cambia de proveedor automáticamente. La validación técnica no certifica
el contenido; `review_pending` requiere revisión editorial antes de publicar.
El módulo no inserta las imágenes automáticamente en los reels.

```python
from harness.imagenes import preparar, generar

solicitud = preparar("Abre una nueva biblioteca", "Tiene una sala infantil.",
                     formato="cuadrado")
resultado = generar(solicitud, nombre="biblioteca-python")
print(resultado["imagen"])
```

Pruebas sin red ni consumo de generación:

```bash
bash pruebas/checks/imagenes.sh
```

Los tests simulan Codex y validan archivos reales con ffmpeg; no prueban el
acceso de la cuenta a `image_gen` ni la calidad de una generación real.
