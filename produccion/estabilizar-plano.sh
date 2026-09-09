#!/bin/bash
# Deriva un B-roll deliberadamente estatico sin reutilizar frames inestables.
# La implementacion vive fuera del shell para poder validar tiempos racionales,
# hashes y la publicacion sin sobreescritura de forma fail-closed.
set -u

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
HERRAMIENTA=$RAIZ/harness/estabilizar_plano.py

[ -f "$HERRAMIENTA" ] && [ ! -L "$HERRAMIENTA" ] || {
  echo "ERROR: falta el helper regular: $HERRAMIENTA" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: falta python3" >&2
  exit 1
}

exec python3 "$HERRAMIENTA" "$@"
