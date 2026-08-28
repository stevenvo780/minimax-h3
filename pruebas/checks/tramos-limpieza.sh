#!/bin/bash
nombre="tramos-limpieza"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"

[ -d "$RAIZ" ] || { echo "FALLA $nombre: RAIZ no es un directorio: $RAIZ"; exit 1; }

T=$(mktemp -d /tmp/tramos-limpieza.XXXXXX) || { echo "FALLA $nombre: no se pudo crear directorio temporal"; exit 1; }
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/lib" "$T/produccion" "$T/bin" "$T/stubbin" "$T/salida" || {
  echo "FALLA $nombre: no se pudo preparar el arbol temporal en $T"; exit 1; }

# El arnes se ejecuta SIEMPRE contra la copia de $T, nunca contra el repo. Estas
# variables, si vienen del entorno, harian que producir.sh escriba obra/ y logs/
# DENTRO del arbol real (MD) o alterarian el conteo de planos (FRAMES/W/H...).
unset MD W H FRAMES STEPS SEED FPS CFG BACKEND PARAMS_BACKEND MAXVRAM

for rel in lib/comun.sh produccion/producir.sh produccion/fundir.py; do
  if ! cp "$RAIZ/$rel" "$T/$rel" 2>"$T/cperr"; then
    echo "FALLA $nombre: no pude copiar $rel desde $RAIZ: $(cat "$T/cperr")"; exit 1
  fi
done
chmod +x "$T/produccion/producir.sh" || { echo "FALLA $nombre: no pude marcar producir.sh como ejecutable"; exit 1; }

# ── stub sd-cli: crea "<lo que sigue a -o>.avi" (igual que el sd-cli real) ──
cat > "$T/bin/sd-cli" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && : > "${out}.avi"
exit 0
EOF

# ── stub ffmpeg: crea el ultimo argumento que no sea flag (la salida) ──────
cat > "$T/stubbin/ffmpeg" <<'EOF'
#!/bin/bash
last=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) last="$a" ;;
  esac
done
if [ -n "$last" ]; then
  mkdir -p "$(dirname "$last")" 2>/dev/null
  : > "$last"
fi
exit 0
EOF

# ── stub ffprobe: duracion / dimensiones / metadatos segun lo que se pida ──
# OJO: la rama r_frame_rate NO sobra: la usa get_video_metadata() de fundir.py,
# que exige 4 campos y aborta si recibe menos.
cat > "$T/stubbin/ffprobe" <<'EOF'
#!/bin/bash
case " $* " in
  *r_frame_rate*) echo "1376,768,yuv420p,24/1" ;;
  *width,height*) echo "1376,768" ;;
  *duration*)     echo "5.0000" ;;
  *)              echo "" ;;
esac
exit 0
EOF
chmod +x "$T/bin/sd-cli" "$T/stubbin/ffmpeg" "$T/stubbin/ffprobe"

# El stub va PRIMERO en el PATH: el check debe ser determinista tambien en una
# maquina que si tenga ffmpeg/ffprobe reales (kratos).
export PATH="$T/stubbin:$PATH"
export DEST="$T/salida"

# Guion 1: dos planos hablados SIN encadenar -> frontera de tramo en el indice 2.
cat > "$T/g1.guion" <<'EOF'
@ESCENA saloncomedor
@AMBIENTE silencio
@MUSICA ninguna
HABLA|Primera frase de prueba.||
HABLA|Segunda frase de prueba.||
EOF

# Guion 2: dos planos ENCADENADOS -> continuidad pura, NINGUNA frontera nueva.
# Si sobrevive la frontera "02" de la tanda 1, fundir.py parte aqui en dos
# tramos y aplica un fundido de 0.5s justo donde el guion dice "encadena".
cat > "$T/g2.guion" <<'EOF'
@ESCENA saloncomedor
@AMBIENTE silencio
@MUSICA ninguna
HABLA|Primera frase de prueba.||
HABLA|Segunda frase de prueba.|encadena|
EOF

nombre_obra="prueba-tramos"
MONT="$T/produccion/obra/$nombre_obra/montaje"

# ── 1a tanda: crea la frontera de tramo "02" ───────────────────────────────
out1=$("$T/produccion/producir.sh" "$T/g1.guion" "$nombre_obra" 2>&1)
rc1=$?
if [ $rc1 -ne 0 ]; then
  echo "FALLA $nombre: la 1a ejecucion de producir.sh fallo (rc=$rc1): $(printf '%s' "$out1" | tail -3)"
  exit 1
fi
if [ ! -f "$MONT/tramos.txt" ]; then
  echo "FALLA $nombre: precondicion invalida, la 1a tanda no genero montaje/tramos.txt"
  exit 1
fi
frontera1=$(tr '\n' ' ' < "$MONT/tramos.txt")
if [ "$frontera1" != "02 " ]; then
  echo "FALLA $nombre: precondicion invalida, tramos.txt tras la 1a tanda = '$frontera1' (se esperaba '02')"
  exit 1
fi

# ── 2a tanda: MISMA obra, guion sin ninguna frontera de tramo nueva ────────
out2=$("$T/produccion/producir.sh" "$T/g2.guion" "$nombre_obra" 2>&1)
rc2=$?
if [ $rc2 -ne 0 ]; then
  echo "FALLA $nombre: la 2a ejecucion de producir.sh fallo (rc=$rc2; tramos.txt='$(tr '\n' ' ' < "$MONT/tramos.txt" 2>/dev/null)'): $(printf '%s' "$out2" | tail -3)"
  exit 1
fi

# Precondicion positiva: la 2a tanda REHIZO de verdad el reensamblado. Sin esto
# el check podria dar PASA porque no llego a pasar nada.
if [ ! -s "$MONT/lista.txt" ] || [ ! -f "$MONT/01.mp4" ] || [ ! -f "$MONT/02.mp4" ]; then
  echo "FALLA $nombre: precondicion invalida, la 2a tanda no rehizo el montaje (lista.txt/01.mp4/02.mp4 ausentes)"
  exit 1
fi

# Sintoma 1 (estado): la frontera fantasma sobrevive en disco.
if [ -s "$MONT/tramos.txt" ]; then
  echo "FALLA $nombre: tramos.txt sigue con frontera(s) fantasma tras la 2a tanda ('$(tr '\n' ' ' < "$MONT/tramos.txt")'); producir.sh no borro montaje/tramos.txt al reensamblar"
  exit 1
fi

# Sintoma 2 (efecto): producir.sh anuncia y aplica un fundido que el guion
# actual no pide. Es el dano real en produccion, no solo un fichero de sobra.
if printf '%s' "$out2" | grep -q "fundidos entre tramos"; then
  echo "FALLA $nombre: la 2a tanda aplica fundidos heredados ($(printf '%s' "$out2" | grep -m1 'fundidos entre tramos')) pese a que su guion no tiene ninguna frontera de tramo"
  exit 1
fi

echo "PASA $nombre"
exit 0