#!/bin/bash
NOMBRE_CHECK="orden-tab"
falla() { echo "FALLA $NOMBRE_CHECK: $1"; exit 1; }

RAIZ=${RAIZ:?falta RAIZ}
[ -f "$RAIZ/produccion/producir.sh" ] || falla "no se encuentra $RAIZ/produccion/producir.sh"

SANDBOX=$(mktemp -d /tmp/orden-tab.XXXXXX) || falla "no se pudo crear sandbox en /tmp"
# ORDEN_TAB_KEEP=1 conserva el sandbox para poder inspeccionarlo tras un fallo.
if [ "${ORDEN_TAB_KEEP:-0}" = "1" ]; then
  trap 'echo "  (sandbox conservado en $SANDBOX)"' EXIT
else
  trap 'rm -rf "$SANDBOX"' EXIT
fi

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN" "$SANDBOX/salida" "$SANDBOX/assets" "$SANDBOX/produccion" || falla "no se pudo preparar el sandbox"

# ── stub sd-cli: crea "<lo que le pasen a -o>.avi" ──────────────────────────
# OJO: se instala en $SANDBOX/bin porque el codigo bajo prueba invoca
# "$MD/bin/sd-cli" por ruta ABSOLUTA (no via PATH), y aqui MD=$SANDBOX.
cat > "$STUBBIN/sd-cli" <<'EOF'
#!/bin/bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
[ -n "$out" ] || { echo "fake sd-cli: falta -o" >&2; exit 1; }
: > "$out.avi"
exit 0
EOF

# ── stub ffmpeg: exige que el -i (o cada fichero del concat) EXISTA de
#    verdad; si orden.txt se partiese por espacios, el -i llegaria
#    incompleto y este stub fallaria como fallaria el ffmpeg real ──────────
cat > "$STUBBIN/ffmpeg" <<'EOF'
#!/bin/bash
LOG="${ORDEN_TAB_LOG:-/dev/null}"
{
  echo "== llamada =="
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$LOG"

args=("$@")
n=${#args[@]}
out="${args[$((n-1))]}"

input=""
concat=0
i=0
while [ "$i" -lt "$n" ]; do
  if [ "${args[$i]}" = "-i" ]; then
    j=$((i+1))
    input="${args[$j]}"
  fi
  [ "${args[$i]}" = "concat" ] && concat=1
  i=$((i+1))
done

if [ "$concat" = "1" ]; then
  ok=1
  while IFS= read -r line; do
    case "$line" in
      "file "*)
        f=$(printf '%s\n' "$line" | cut -d"'" -f2)
        [ -n "$f" ] && [ -f "$f" ] || ok=0
        ;;
    esac
  done < "$input"
  [ "$ok" = "1" ] || { echo "fake ffmpeg: concat con fichero(s) inexistente(s)" >&2; exit 1; }
  : > "$out"
  exit 0
fi

if [ -n "$input" ] && [ -f "$input" ]; then
  : > "$out"
  exit 0
fi
echo "fake ffmpeg: no existe el input: [$input]" >&2
exit 1
EOF

# ── stub ffprobe: valores fijos, no participa en la propiedad bajo prueba ──
cat > "$STUBBIN/ffprobe" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *width,height*) echo "1376,768"; exit 0 ;;
  esac
done
echo "4.4583"
exit 0
EOF

chmod +x "$STUBBIN/sd-cli" "$STUBBIN/ffmpeg" "$STUBBIN/ffprobe" || falla "no se pudo dar permiso de ejecucion a los stubs"

# ── material BROLL cuya ruta tiene un ESPACIO: el caso que rompia el bug ───
BROLL_PATH="$SANDBOX/assets/mi broll con espacio.mp4"
echo "contenido falso" > "$BROLL_PATH" || falla "no se pudo crear el BROLL de prueba"

GUION="$SANDBOX/prueba.guion"
cat > "$GUION" <<EOF2
@ESCENA escena de prueba
@AMBIENTE ambiente de prueba
@MUSICA musica de prueba
HABLA|hola mundo||
BROLL|$BROLL_PATH||
EOF2

CALLLOG="$SANDBOX/ffmpeg_calls.log"
: > "$CALLLOG"

# ── ejecutar el pipeline REAL (no tocamos el repo: MD/DEST apuntan a /tmp) ─
OUT=$(MD="$SANDBOX" DEST="$SANDBOX/salida" ORDEN_TAB_LOG="$CALLLOG" PATH="$STUBBIN:$PATH" \
      bash "$RAIZ/produccion/producir.sh" "$GUION" prueba 2>&1)
RC=$?

OBRA="$SANDBOX/produccion/obra/prueba"
ORDEN="$OBRA/orden.txt"
MONT="$OBRA/montaje"

# ── PRECONDICION: el script tiene que haber trabajado DENTRO del sandbox.
#    Si no, ignora MD del entorno (rutas absolutas hardcodeadas) y este check
#    no llega siquiera a poder observar la propiedad del TAB: hay que decirlo
#    con todas las letras en vez de disfrazarlo de "volvio el bug del TAB".
if [ ! -d "$OBRA" ]; then
  falla "PRECONDICION NO CUMPLIDA (no es el bug del TAB): el script no respeta MD del entorno y no escribio nada en el sandbox; arregla antes la portabilidad de rutas. Salida: $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

[ -f "$ORDEN" ] || falla "no se genero orden.txt (salida: $(printf '%s' "$OUT" | tail -5))"

NLINEAS=$(wc -l < "$ORDEN" 2>/dev/null || echo 0)
[ "$NLINEAS" -eq 2 ] || falla "orden.txt deberia tener 2 lineas y tiene $NLINEAS"

L1=$(sed -n '1p' "$ORDEN")
case "$L1" in *$'\t'*) : ;; *) falla "la linea 1 de orden.txt no esta separada por TAB: [$L1]" ;; esac
F1=$(printf '%s' "$L1" | cut -f1)
M1=$(printf '%s' "$L1" | cut -f2)
[ "$F1" = "$OBRA/p01.avi" ] || falla "campo de fichero mal parseado en la linea HABLA: [$F1]"
[ "$M1" = "tramo" ] || falla "campo de marca mal parseado en la linea HABLA: [$M1]"

L2=$(sed -n '2p' "$ORDEN")
[ "$L2" = "$BROLL_PATH" ] || falla "la ruta BROLL con espacio se corrompio en orden.txt: [$L2]"

[ -f "$MONT/01.mp4" ] || falla "no se genero montaje/01.mp4 (clip HABLA)"
[ -f "$MONT/02.mp4" ] || falla "no se genero montaje/02.mp4 (clip BROLL con espacio): volvio el bug del corte por espacio"

[ -f "$MONT/lista.txt" ] || falla "no se genero lista.txt"
NCLIPS=$(grep -c "^file " "$MONT/lista.txt")
[ "$NCLIPS" -eq 2 ] || falla "lista.txt no tiene los 2 clips esperados (tiene $NCLIPS)"

grep -qxF "$BROLL_PATH" "$CALLLOG" || falla "ffmpeg nunca recibio la ruta COMPLETA del BROLL como -i (llego partida)"

[ "$RC" -eq 0 ] || falla "el pipeline termino con codigo $RC"

VIDEO_FINAL=$(find "$SANDBOX/salida" -maxdepth 1 -name 'prueba-*.mp4' 2>/dev/null | head -1)
[ -n "$VIDEO_FINAL" ] && [ -f "$VIDEO_FINAL" ] || falla "no se genero el video final en DEST"

echo "PASA $NOMBRE_CHECK"
exit 0