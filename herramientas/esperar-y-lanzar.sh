#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ESPERAR Y LANZAR — arranca un trabajo en cuanto la GPU 0 se libere.
#
#  Por que existe: Steven ha reportado CUATRO veces "veo la PC quieta". Dos de
#  esas veces la maquina estaba de verdad parada esperando algo que no iba a
#  llegar. Y ahora la 5070 Ti la ocupa un proceso que ni siquiera vive en este
#  contenedor: nvidia-smi ve los 15 GB en memory.used pero no puede atribuirlos
#  a ningun PID de aqui. No hay nada que matar ni a quien pedirle turno.
#
#  Quedarse mirando no sirve: lo que sirve es dejar armado el trabajo para que
#  entre solo en cuanto haya sitio, sin que nadie tenga que estar delante.
#
#  Exige el hueco DOS veces seguidas: la memoria de una GPU baja un instante
#  entre dos trabajos ajenos, y entrar en ese hueco es pelearse por la tarjeta
#  con quien la estaba usando.
#
#  Uso:  esperar-y-lanzar.sh <mib_libres> <espera_max_s> <comando...>
# ═══════════════════════════════════════════════════════════════════════════
set -u
NECESITA=${1:?faltan los MiB}; shift
LIMITE=${1:?falta la espera maxima}; shift
[ $# -gt 0 ] || { echo "falta el comando"; exit 1; }

libre() { nvidia-smi -i 0 --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }
t=0; seguidas=0
echo "ESPERA: la GPU 0 tiene $(libre) MiB libres, hacen falta $NECESITA. Reviso cada 60 s."
while [ $t -lt "$LIMITE" ]; do
  l=$(libre)
  if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge "$NECESITA" ]; then
    seguidas=$((seguidas+1))
    if [ $seguidas -ge 2 ]; then
      echo "ESPERA: la GPU 0 lleva dos comprobaciones con $l MiB libres. Lanzo."
      exec "$@"
    fi
    echo "ESPERA: $l MiB libres (${seguidas}/2 comprobaciones), confirmo en la siguiente."
  else
    [ $seguidas -gt 0 ] && echo "ESPERA: volvio a ocuparse ($l MiB), reinicio la cuenta."
    seguidas=0
    [ $((t % 900)) = 0 ] && echo "ESPERA: llevo $((t/60)) min · $l MiB libres de los $NECESITA que hacen falta"
  fi
  sleep 60; t=$((t+60))
done
echo "ESPERA: $((LIMITE/60)) min y la GPU 0 sigue ocupada por algo de fuera de este contenedor. No lanzo."
exit 1
