# Guía para agentes — NewsLeters

Este repositorio se puede operar desde cualquier agente que ejecute comandos
de terminal. Trabaja desde la raíz del clon; no depende de un editor concreto.
Lee `README.md` para el pipeline y `COMO-LANZAR.md` para producción de vídeo.

## Puntos de entrada

- Carruseles Instagram: `python3 harness/carruseles.py --help`.
  Entrada JSON con noticias y diapositivas ya revisadas. `--solo-prompt`
  prepara; `--generar` usa Codex; `--importar` empaqueta imágenes creadas
  con la herramienta nativa. Guía en `imagenes/README.md`.
- Imágenes con Codex: `python3 harness/imagenes.py --help`.
  Contrato, requisitos y ejemplos en `imagenes/README.md`. Usa `--solo-prompt`
  para revisar la solicitud; genera con `--nombre` único. El agente que llama
  puede ser cualquiera, pero la generación requiere Codex autenticado con
  acceso a su herramienta nativa de imágenes.
- Noticias a reels: `produccion/reel-noticias.sh`; `SOLO_GUION=1` prepara
  únicamente el guion, `VALIDAR=1` permite validación sin generación.
- UI local: `python3 ui/servidor.py`.
- Checks sin generar contenido: `bash pruebas/humo.sh checks`.
  El humo completo puede consumir GPU; elegirlo cuando corresponda a la tarea.

## Convenciones

Mantén las interfaces y documentación en español. El pipeline principal usa
la biblioteca estándar de Python y scripts Bash; no añadas SDKs si no hacen falta.
Los scripts Bash de producción cargan `lib/comun.sh` para resolver las rutas.
No versiones pesos, credenciales ni artefactos generados. Conserva cambios
ajenos y no sobrescribas entregas de otros agentes.

No inventes hechos de noticias. Conserva su fuente cuando esté disponible.
`review_pending` significa validación técnica pendiente de revisión editorial,
no aprobación para publicar. Al informar pruebas distingue simulación,
validación técnica y generación real.
