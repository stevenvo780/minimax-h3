#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="codigo-salida"
exec 0</dev/null

# Un clasico que costo caro: escribir
#     echo "[$(date +%H:%M:%S)] rc=$?"
# hace que $(date) se ejecute ANTES que el echo y pise $?. Se reporta el codigo
# de salida de date —siempre 0— en vez del del comando que interesa.
#
# Paso de verdad: una pieza perdio una toma tras 6 intentos, el pipeline salio
# con 1 correctamente, y el log dijo "rc=0". Durante horas se dieron por buenas
# tandas que habian fallado. Aparecio en 14 scripts a la vez.
#
# Regla: capturar $? en una variable ANTES de cualquier otro comando, incluidas
# las sustituciones dentro de la propia linea del echo.

fallos=0
mapfile -t malas < <(grep -rn 'rc=\$?' --include='*.sh' "$RAIZ" 2>/dev/null \
  | grep -v '/archivo/' | grep -v '/pruebas/checks/' \
  | awk -F: '{line=$0; sub(/^[^:]*:[^:]*:/,"",line);
       t=line; sub(/^[ \t]+/,"",t);
       if (substr(t,1,1)=="#") next;          # los comentarios pueden mostrar el patron malo como ejemplo
       if (line ~ /\$\(/ && line ~ /rc=\$\?/) print $1":"$2": "line}')
if [ ${#malas[@]} -gt 0 ]; then
  echo "FALLA $nombre: \$? leido DESPUES de una sustitucion, que lo pisa:"
  printf '%s\n' "${malas[@]}" | sed 's/^/    /'
  echo "    Captura rc=\$? en su propia linea, antes del echo."
  fallos=1
fi

# Y que el comportamiento sea el esperado, no solo la forma del codigo.
r=$( (exit 3); echo "$(true) $?" | awk '{print $NF}' )
[ "$r" = 0 ] || { echo "FALLA $nombre: la premisa del check no se cumple en este shell"; fallos=1; }
r2=$( (exit 3); rc=$?; echo "$rc" )
[ "$r2" = 3 ] || { echo "FALLA $nombre: capturar antes tampoco conserva \$? ($r2)"; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre"
exit $fallos
