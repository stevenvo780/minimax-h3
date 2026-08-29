#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="herramientas"
exec 0</dev/null

# ── Por que existe este check ─────────────────────────────────────────────
# ffmpeg y ffprobe llegaron a vivir SOLO dentro de un venv del scratchpad de
# la sesion, fuera del PATH del proceso de produccion. La generacion arrancaba
# igual (sd-cli no necesita ffmpeg) y moria 23 minutos despues, al extraer las
# anclas de la toma 1, con "ffmpeg: command not found". El fallo se pagaba en
# GPU, no en segundos.
#
# El contrato que este check fija: los scripts de produccion comprueban sus
# herramientas ANTES de generar nada, y salen != 0 con un mensaje que nombra
# lo que falta.

for s in produccion/producir-anclado.sh produccion/producir.sh; do
  [ -f "$RAIZ/$s" ] || { echo "FALLA $nombre: no existe $RAIZ/$s"; exit 1; }
done

T=$(mktemp -d /tmp/chk-herramientas.XXXXXX) || { echo "FALLA $nombre: no pude crear tmpdir"; exit 1; }
trap 'rm -rf "$T"' EXIT

# PATH sin ffmpeg/ffprobe pero CON lo basico, para que el script llegue a la
# comprobacion en vez de morir antes por no encontrar bash o dirname.
mkdir -p "$T/bin"
for b in bash dirname basename sed grep awk cat mkdir rm id date printf; do
  p=$(command -v $b 2>/dev/null) && ln -sf "$p" "$T/bin/$b" 2>/dev/null
done

# Un guion minimo valido: los scripts validan argumentos antes de nada, y sin
# ellos saldrian por "falta el guion" sin llegar a comprobar herramientas.
cat > "$T/m.guion" <<'G'
@TIPO habla
@ESCENA Una escena.
@AMBIENTE Ambiente.
@MUSICA Musica.
HABLA|Hola.|inicio|
G

fallos=0
for s in produccion/producir-anclado.sh produccion/producir.sh; do
  out=$(cd "$RAIZ" && env PATH="$T/bin" HOME="$T" bash "$RAIZ/$s" "$T/m.guion" prueba 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "FALLA $nombre: $s salio 0 sin ffmpeg en el PATH (deberia negarse)"
    fallos=1; continue
  fi
  if ! printf '%s' "$out" | grep -qi 'FALTAN HERRAMIENTAS'; then
    echo "FALLA $nombre: $s no dijo que faltaban herramientas."
    echo "  salida: $(printf '%s' "$out" | head -3)"
    fallos=1; continue
  fi
  if ! printf '%s' "$out" | grep -q 'ffmpeg'; then
    echo "FALLA $nombre: $s no nombro ffmpeg entre lo que falta"
    fallos=1
  fi
done

# La funcion en si: acierta en ambos sentidos.
( . "$RAIZ/lib/comun.sh" 2>/dev/null
  exigir_herramientas ffmpeg ffprobe >/dev/null 2>&1 ) || {
    echo "FALLA $nombre: exigir_herramientas falla con las herramientas presentes"; fallos=1; }
( . "$RAIZ/lib/comun.sh" 2>/dev/null
  PATH=/nonexistent exigir_herramientas ffmpeg >/dev/null 2>&1 ) && {
    echo "FALLA $nombre: exigir_herramientas devolvio 0 sin ffmpeg"; fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre"
exit $fallos
