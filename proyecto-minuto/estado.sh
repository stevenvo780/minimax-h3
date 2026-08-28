#!/bin/bash
P=/home/stev/Modelos-IA/minimax-h3/proyecto-minuto
G=$(ls -1 $P/shots/s*.avi 2>/dev/null | wc -l)
U=$(ls -1 $P/up-mp4/s*.mp4 2>/dev/null | wc -l)
echo "════════ PROYECTO 1 MINUTO ════════  $(date '+%H:%M:%S')"
barra() { local n=$1 t=14 i; local o=""; for ((i=1;i<=t;i++)); do [ $i -le $n ] && o="$o#" || o="$o."; done; echo "$o"; }
printf "  GENERACIÓN  %2d/14  [%s]\n" $G "$(barra $G)"
printf "  ESCALADO    %2d/14  [%s]\n" $U "$(barra $U)"
echo
S=$(ls -t $P/logs/s*.log 2>/dev/null | head -1)
if pgrep -f "proyecto-minuto/generar.sh" >/dev/null; then
  echo "  generando: $(basename $S .log) -> $(tr '\r' '\n' < $S | grep -oE '[0-9]+/20 - [0-9.]+s/it' | tail -1)"
else
  echo "  generación: TERMINADA"
fi
if pgrep -f "escalar-pipeline.sh" >/dev/null; then
  echo "  escalando:  $(grep -oE '\[CUDA[01]\] s[0-9]+ (LISTO|en [0-9]+s)' $P/logs/escalado.log 2>/dev/null | tail -1)"
  grep -q "FASE 2" $P/logs/escalado.log 2>/dev/null && echo "              (fase 2: ambas GPU)" || echo "              (fase 1: solo 2060)"
else
  echo "  escalado:   no activo"
fi
echo
echo "  GPUs:"; nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used --format=csv,noheader | sed 's/^/    /'
echo
echo "  VER RESULTADOS:"
echo "    nativos 768p : ~/Vídeos/proyecto-minuto-planos/"
echo "    escalados    : $P/up-mp4/"
echo "    comparativa  : ~/Vídeos/COMPARATIVA-escalado.png"
