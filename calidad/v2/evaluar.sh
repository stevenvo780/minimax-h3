#!/bin/bash
set -u
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PY="$RAIZ/.venv-calidad/bin/python"
[ -x "$PY" ] || PY=python3

# Dos evaluadores fuertes en paralelo pueden agotar el limite de threads del
# cgroup (OpenCV + varios ffmpeg/Whisper) y convertir una medicion valida en
# ERROR/EAGAIN. Serializar la evaluacion evita ese falso fallo operacional sin
# compartir el cerrojo de GPU de la generacion.
if [ -n "${CALIDAD_V2_CERROJO:-}" ]; then
  LOCK=$CALIDAD_V2_CERROJO
else
  RUNTIME_BASE=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
  LOCK_DIR="$RUNTIME_BASE/minimax-h3-calidad-$(id -u)"
  if [ -L "$LOCK_DIR" ]; then
    echo "el directorio privado del evaluador no puede ser un symlink: $LOCK_DIR" >&2
    exit 2
  fi
  mkdir -m 700 -p "$LOCK_DIR" || { echo "no pude crear $LOCK_DIR" >&2; exit 2; }
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || {
    echo "directorio privado invalido para el evaluador: $LOCK_DIR" >&2
    exit 2
  }
  [ "$(stat -c %u "$LOCK_DIR" 2>/dev/null)" = "$(id -u)" ] || {
    echo "el directorio del evaluador pertenece a otro usuario: $LOCK_DIR" >&2
    exit 2
  }
  chmod 700 "$LOCK_DIR" || exit 2
  LOCK="$LOCK_DIR/evaluar.lock"
fi
ESPERA=${CALIDAD_V2_ESPERA:-1800}
case "$ESPERA" in
  ''|*[!0-9]*) echo "CALIDAD_V2_ESPERA debe ser un entero no negativo" >&2; exit 2 ;;
esac
command -v flock >/dev/null 2>&1 || { echo "falta flock para serializar el evaluador" >&2; exit 2; }
[ ! -L "$LOCK" ] || { echo "el cerrojo del evaluador no puede ser un symlink: $LOCK" >&2; exit 2; }
[ ! -e "$LOCK" ] || [ -f "$LOCK" ] || { echo "cerrojo invalido: $LOCK" >&2; exit 2; }
umask 077
# Append evita truncar incluso una ruta personalizada. El directorio privado
# por defecto, ownership y rechazo de symlinks cierran la sustitucion del lock.
exec 9>>"$LOCK" || { echo "no pude abrir el cerrojo del evaluador: $LOCK" >&2; exit 2; }
if ! flock -n 9; then
  echo "calidad-v2: hay otra evaluacion en curso; espero mi turno" >&2
  flock -w "$ESPERA" 9 || {
    echo "calidad-v2: el turno sigue ocupado despues de ${ESPERA}s" >&2
    exit 2
  }
fi
exec "$PY" "$RAIZ/calidad/v2/evaluar.py" "$@"
