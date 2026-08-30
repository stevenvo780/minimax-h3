#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="guardian"
exec 0</dev/null

# El guardian de VRAM mata procesos. La primera version cortaba a QUIEN OCUPARA
# la GPU sin mirar de quien era, y el 2026-08-30 mato un proceso python del
# usuario mientras el pipeline no tenia nada generando.
#
# Contrato que este check fija: solo puede matar procesos PROPIOS.

G="$RAIZ/herramientas/guardian-vram.sh"
[ -f "$G" ] || { echo "FALLA $nombre: no existe $G"; exit 1; }
fallos=0
bash -n "$G" || { echo "FALLA $nombre: no parsea"; fallos=1; }

# 1. Tiene que cruzar los PID de la GPU con los procesos propios.
grep -q 'query-compute-apps' "$G" || {
  echo "FALLA $nombre: no consulta que PID ocupan la GPU"; fallos=1; }
grep -q '\$2=="sd-cli"' "$G" || {
  echo "FALLA $nombre: no filtra por el nombre EXACTO de proceso sd-cli"; fallos=1; }

# 2. Nunca por patron sobre la linea de comandos: haria match consigo mismo.
# Se ignoran los comentarios: la cabecera del guardian menciona pkill -f y
# pgrep -f justo para advertir de que NO se usen.
if grep -vE '^\s*#' "$G" | grep -qE 'pkill -f|pgrep -f'; then
  echo "FALLA $nombre: usa pkill/pgrep -f, que hace match con el propio guardian"; fallos=1
fi

# 3. Tiene que existir la rama que NO mata cuando el ocupante es ajeno.
grep -qi 'NO es sd-cli\|No toco nada' "$G" || {
  echo "FALLA $nombre: no contempla el caso de que quien ocupa la GPU sea ajeno"; fallos=1; }

# 4. La logica de cruce, probada: un PID ajeno no se selecciona.
sel=$(ocupan="111111 222222"; mios="333333 444444"; pid=""
      for o in $ocupan; do for m in $mios; do [ "$o" = "$m" ] && pid=$o && break 2; done; done
      echo "$pid")
[ -z "$sel" ] || { echo "FALLA $nombre: el cruce selecciono un PID ajeno ($sel)"; fallos=1; }
sel2=$(ocupan="111111 555555"; mios="555555 444444"; pid=""
       for o in $ocupan; do for m in $mios; do [ "$o" = "$m" ] && pid=$o && break 2; done; done
       echo "$pid")
[ "$sel2" = 555555 ] || { echo "FALLA $nombre: el cruce NO encontro el PID propio ($sel2)"; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre"
exit $fallos
