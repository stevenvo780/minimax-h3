#!/bin/bash
set -u
NOMBRE="fundir"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
FALLOS=0
falla() { echo "FALLA $NOMBRE: $*"; FALLOS=$((FALLOS+1)); }

if [ ! -f "$RAIZ/produccion/fundir.py" ]; then
  echo "FALLA $NOMBRE: no se encontro $RAIZ/produccion/fundir.py"
  exit 1
fi

WORK="$(mktemp -d /tmp/chk_fundir.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"

# ffmpeg stub: registra la llamada y simula crear el fichero de salida (ultimo argumento)
cat > "$BIN/ffmpeg" <<'EOS'
#!/usr/bin/env bash
echo "ffmpeg $*" >> "${CHK_LOG:-/dev/null}"
last="${@: -1}"
touch "$last"
exit 0
EOS
chmod +x "$BIN/ffmpeg"

# ---------- CASO A: dur() falla con mensaje claro y exit!=0 (no ValueError crudo) ----------
# La UNICA consulta que falla es la de duracion; cualquier otra consulta (metadatos)
# devuelve datos validos. Asi un error solo puede ser atribuible a dur().
cat > "$BIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
echo "ffprobe $*" >> "${CHK_LOG:-/dev/null}"
if [[ "$*" == *"format=duration"* ]]; then
  echo "stub: fallo simulado de ffprobe" >&2
  exit 2
fi
echo "1920,1080,yuv420p,30/1"
exit 0
EOS
chmod +x "$BIN/ffprobe"

MONT_A="$WORK/montA"; LOG_A="$WORK/log_A.txt"
mkdir -p "$MONT_A"; : > "$LOG_A"
touch "$MONT_A/00.mp4" "$MONT_A/01.mp4"
echo "01" > "$MONT_A/tramos.txt"   # fuerza 2 tramos -> se llega a dur() en el fundido

OUT_A="$(PATH="$BIN:$PATH" CHK_LOG="$LOG_A" python3 "$RAIZ/produccion/fundir.py" "$MONT_A" "$MONT_A/final.mp4" 2>&1)"
EXIT_A=$?

if ! grep -q "format=duration" "$LOG_A"; then
  falla "CASO A no llego a consultar la duracion (dur() nunca se ejecuto); el caso no prueba nada"
else
  if [ "$EXIT_A" -eq 0 ]; then
    falla "CASO A: con ffprobe fallando, dur() deberia terminar en exit!=0 pero termino en 0"
  fi
  if echo "$OUT_A" | grep -qi "Traceback (most recent call last)"; then
    falla "CASO A: dur() deja escapar una traceback cruda de Python (ValueError) en vez de un mensaje claro"
  fi
  if ! echo "$OUT_A" | grep -q "ERROR:"; then
    falla "CASO A: dur() no imprimio un mensaje de error claro ('ERROR:') al fallar ffprobe"
  fi
fi

# ---------- CASO B: limpia tramo*.mp4 y l*.txt de ejecuciones anteriores ----------
cat > "$BIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
echo "ffprobe $*" >> "${CHK_LOG:-/dev/null}"
if [[ "$*" == *"format=duration"* ]]; then echo "1.0"; exit 0; fi
echo "1920,1080,yuv420p,30/1"
exit 0
EOS
chmod +x "$BIN/ffprobe"

MONT_B="$WORK/montB"; LOG_B="$WORK/log_B.txt"
mkdir -p "$MONT_B"; : > "$LOG_B"
touch "$MONT_B/00.mp4" "$MONT_B/01.mp4"
echo "01" > "$MONT_B/tramos.txt"   # 2 tramos: ejercita la regeneracion real
# huerfanos de una ejecucion previa hipotetica con mas tramos
touch "$MONT_B/tramo5.mp4" "$MONT_B/tramo99.mp4" "$MONT_B/l5.txt" "$MONT_B/l7.txt"

OUT_B="$(PATH="$BIN:$PATH" CHK_LOG="$LOG_B" python3 "$RAIZ/produccion/fundir.py" "$MONT_B" "$MONT_B/final.mp4" 2>&1)"
EXIT_B=$?
if [ "$EXIT_B" -ne 0 ]; then
  falla "CASO B (limpieza) debia terminar en exit 0 y termino en $EXIT_B: $OUT_B"
fi
for huerfano in tramo5.mp4 tramo99.mp4 l5.txt l7.txt; do
  if [ -e "$MONT_B/$huerfano" ]; then
    falla "CASO B: no se limpio '$huerfano' de una ejecucion anterior antes de regenerar los tramos"
  fi
done
# la limpieza no puede llevarse por delante las entradas legitimas
for vivo in 00.mp4 01.mp4 tramos.txt; do
  if [ ! -e "$MONT_B/$vivo" ]; then
    falla "CASO B: la limpieza borro la entrada legitima '$vivo'"
  fi
done
if [ ! -e "$MONT_B/final.mp4" ]; then
  falla "CASO B: no genero el fichero final esperado"
fi

# ---------- CASO C: rechaza tramos con distinta resolucion ANTES del xfade ----------
cat > "$BIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
echo "ffprobe $*" >> "${CHK_LOG:-/dev/null}"
if [[ "$*" == *"format=duration"* ]]; then echo "1.0"; exit 0; fi
last="${@: -1}"
if [[ "$last" == *tramo0.mp4 ]]; then echo "1920,1080,yuv420p,30/1"; else echo "1280,720,yuv420p,30/1"; fi
exit 0
EOS
chmod +x "$BIN/ffprobe"

MONT_C="$WORK/montC"; LOG_C="$WORK/log_C.txt"
mkdir -p "$MONT_C"; : > "$LOG_C"
touch "$MONT_C/00.mp4" "$MONT_C/01.mp4"
echo "01" > "$MONT_C/tramos.txt"   # fuerza 2 tramos con resoluciones distintas

OUT_C="$(PATH="$BIN:$PATH" CHK_LOG="$LOG_C" python3 "$RAIZ/produccion/fundir.py" "$MONT_C" "$MONT_C/final.mp4" 2>&1)"
EXIT_C=$?
if [ "$EXIT_C" -eq 0 ]; then
  falla "CASO C: tramos con resoluciones distintas (1920x1080 vs 1280x720) deberian rechazarse y no lo hicieron"
fi
if ! echo "$OUT_C" | grep -qi "incompatibles"; then
  falla "CASO C: no se reporto la incompatibilidad de resolucion entre tramos"
fi
if grep -q "xfade" "$LOG_C"; then
  falla "CASO C: se lanzo el xfade pese a las resoluciones incompatibles (debia abortar ANTES)"
fi

# ---------- CASO D: la aritmetica del offset acumulado de xfade NO cambia ----------
# 3 tramos de 2.0s con TR=0.5 -> offsets acumulados 1.5000 y 3.0000
cat > "$BIN/ffprobe" <<'EOS'
#!/usr/bin/env bash
echo "ffprobe $*" >> "${CHK_LOG:-/dev/null}"
if [[ "$*" == *"format=duration"* ]]; then echo "2.0"; exit 0; fi
echo "1920,1080,yuv420p,30/1"
exit 0
EOS
chmod +x "$BIN/ffprobe"

MONT_D="$WORK/montD"; LOG_D="$WORK/log_D.txt"
mkdir -p "$MONT_D"; : > "$LOG_D"
touch "$MONT_D/00.mp4" "$MONT_D/01.mp4" "$MONT_D/02.mp4"
printf '01\n02\n' > "$MONT_D/tramos.txt"

OUT_D="$(PATH="$BIN:$PATH" CHK_LOG="$LOG_D" python3 "$RAIZ/produccion/fundir.py" "$MONT_D" "$MONT_D/final.mp4" 2>&1)"
EXIT_D=$?
if [ "$EXIT_D" -ne 0 ]; then
  falla "CASO D: con 3 tramos validos debia terminar en exit 0 y termino en $EXIT_D: $OUT_D"
fi
if ! grep -q "offset=1.5000" "$LOG_D" || ! grep -q "offset=3.0000" "$LOG_D"; then
  falla "CASO D: la aritmetica del offset acumulado de xfade cambio (esperaba offset=1.5000 y offset=3.0000 con 3 tramos de 2.0s y TR=0.5); filtro: $(grep -o 'offset=[0-9.]*' "$LOG_D" | tr '\n' ' ')"
fi

if [ "$FALLOS" -ne 0 ]; then
  echo "FALLA $NOMBRE: $FALLOS comprobacion(es) fallida(s)"
  exit 1
fi
echo "PASA $NOMBRE"
exit 0