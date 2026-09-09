# Evaluador fuerte V2.2

Evalúa cada toma contra su tipo y contra el `plan.json`; no compara los bordes
de una escena con los de otra. El resultado es un informe JSON versionado y uno
de cuatro estados:

- `PASS` (exit 0): todos los gates aplicables están cubiertos y pasan.
- `FAIL` (exit 1): al menos un gate de veto falla.
- `ERROR` (exit 2): no pudo completarse una medición solicitada.
- `REVIEW` (exit 3): hay un resultado dudoso o una capacidad necesaria está
  ausente. `UNKNOWN` nunca se convierte en `PASS`.

Uso sobre una obra ensamblada con fundidos:

```bash
calidad/v2/evaluar.sh produccion/obra/mi-obra \
  --montage videos/entregas/mi-obra.mp4 \
  --transition-style xfade --transition-seconds 0.5 \
  --output /tmp/mi-obra-calidad-v2.json
```

Para un montaje a corte, usar `--transition-style cut`. No declarar la
transición deja ese control como `UNKNOWN` con el perfil estricto.

`--transition-style` es una declaración, no evidencia. Cuando se entrega
`--montage`, V2 también comprueba el archivo final: geometría, FPS, conteo y
decodificación completa, duración derivada de las fuentes y, para `cut`, una
correspondencia visual densa contra cada toma en el orden del plan. Un archivo
ajeno, negro, reordenado o con dimensiones/FPS distintos no puede aprobar
aunque se declare `cut`.

## Capacidades opcionales

El wrapper usa `.venv-calidad/bin/python` si existe. El evaluador autodetecta:

- `modelos/evaluacion/face_detection_yunet_2023mar.onnx` (rostros, 8 fps),
- `modelos/evaluacion/face_recognition_sface_2021dec.onnx` (identidad),
- `modelos/evaluacion/ggml-small.bin` (ASR de FFmpeg/whisper),
- `modelos/evaluacion/ggml-silero-v6.2.0.bin` (VAD opcional).

Los modelos nunca se descargan desde el evaluador. Se pueden indicar rutas con
`--face-detector`, `--face-recognizer`, `--whisper-model` y
`--whisper-vad-model`. `--no-face-backend` y `--no-asr-backend` permiten probar
explícitamente el modo degradado.

## Qué mide

- integridad: streams, resolución, fps, frames, duración, decodificación y
  cobertura A/V real sobre PCM;
- temporal denso: negro, cortes internos, flicker, congelación, movimiento por
  tipo, jitter y residuo tras alineación como proxy de warping;
- audio: LUFS integrado, true peak, clipping, banda alta y consistencia de
  loudness entre tomas del mismo rol;
- semántica: fidelidad ASR, voz o rostro prohibidos, cobertura facial,
  estabilidad de landmarks, identidad SFace densa y cola vocal limpia con una
  segunda pasada temporal Whisper+Silero;
- transiciones: un fundido que superpone un rostro con un plano que lo prohíbe
  puede vetar la entrega y genera evidencia en el centro del solape.

El informe sólo incluye `scores.total` cuando la cobertura semántica está
completa. Los umbrales del perfil `estricto-v2` son provisionales y están
visibles en el propio JSON. Jitter, warping y landmarks son proxies: no
certifican por sí solos anatomía, sincronía labial ni naturalidad artística.

Cuando se proporciona `--montage`, el bloque `montage_audio` mide la entrega
real: LUFS, true peak, clipping, banda alta, duración y cobertura A/V. Esos son
los gates de audio autoritativos. Los niveles de cada `tNN` se conservan como
`scope: SOURCE` y `advisory: true`, porque el ensamblador los normaliza antes de
mezclarlos. La sincronización técnica de cada fuente continúa siendo un gate
duro. Sin `--montage`, los gates de audio de las tomas siguen siendo
autoritativos y fail-closed.

El bloque `montage_semantic` ejecuta ASR sobre el montaje final completo y lo
compara con la concatenación ordenada de los diálogos del `plan.json`. Ese ASR
es la autoridad semántica de entrega y sus timestamps se vuelven a validar por
las ventanas de cada toma: exige el diálogo en su plano y veta voz reconocida
en planos que la prohíben. Los ASR por fuente pasan a diagnóstico `SOURCE`. Si
Whisper no está disponible, la entrega queda en `REVIEW`, nunca en `PASS`. La
equivalencia visual densa del corte hace que los controles faciales de las
fuentes sean transferibles al montaje; para otras transiciones esa equivalencia
queda `UNKNOWN`.

YuNet sólo aporta cinco landmarks. Las anchuras de boca publicadas en el JSON
son métricas descriptivas para dirigir la revisión humana: no son un gate de
anatomía ni de sincronía labial. V2 no afirma validar dientes, cavidad oral,
movimiento labial ni naturalidad sin un backend específico validado. Además,
si `VideoCapture` no demuestra que recorrió todos los frames, el control facial
queda `ERROR`/`UNKNOWN`, jamás `PASS` por ausencia de detecciones.

Para cada toma `habla`, V2.2 vuelve a segmentar con una cola corta de un segundo
y Silero VAD. Exige al menos 1,0 s desde el último segmento verbal hasta el
corte; menos de 0,75 s es `FAIL` y el intervalo intermedio es `REVIEW`. Las
etiquetas no verbales conocidas como `[Música]`, `[BLANK_AUDIO]`, `(Música)` o
`<silence>` no cuentan como voz. El gate detecta diálogo cortado,
pero no afirma que los labios estén cerrados: ante fallo/revisión extrae tanto
el último instante vocal como el fotograma final para inspección humana.

Cuando existe `--montage`, la cola de cada fuente pasa a diagnóstico advisory y
la autoridad es `semantic.delivery.speech_tail`, calculada otra vez sobre cada
ventana del archivo final. Por eso un montaje que desplaza una locución hasta el
corte no puede heredar el `PASS` de su AVI fuente. Una transición sin ventanas
verificables, la ausencia de Silero o cualquier palabra sin timestamp válido
produce `UNKNOWN`/`ERROR`, nunca un aprobado parcial.

Prueba reproducible, sin GPU ni assets del proyecto:

```bash
bash pruebas/checks/calidad-v2.sh
```

`evaluar.sh` serializa instancias de V2 con un cerrojo propio. OpenCV y las dos
pasadas de Whisper pueden acercarse al límite de threads del contenedor; dos
evaluaciones simultáneas producirían `ERROR`, no más evidencia. El cerrojo no
reserva GPU ni bloquea la generación.
