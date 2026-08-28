#!/bin/bash
set -u
NOMBRE="montaje-rc"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
PROD_SH="$RAIZ/produccion/producir.sh"

# Sin errexit a proposito: todas las comprobaciones son explicitas via `fallar`.
# (Reactivar `set -e` entre escenarios hacia el check fragil sin aportar nada.)
fallar() { echo "FALLA $NOMBRE: $1"; exit 1; }

[ -f "$PROD_SH" ] || fallar "no existe $PROD_SH"

WORK=$(mktemp -d /tmp/montaje-rc.XXXXXX) || fallar "no se pudo crear tmpdir"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/stubs" "$WORK/fuentes" "$WORK/mdA" "$WORK/mdB" "$WORK/salida"

# -- stub ffmpeg: exito/fallo segun si el argumento de -i contiene FFMPEG_FAIL_MARK --
cat > "$WORK/stubs/ffmpeg" <<'EOF'
#!/bin/bash
args=("$@")
n=${#args[@]}
[ "$n" -ge 1 ] || exit 0
out="${args[$((n-1))]}"
input=""
for ((i=0;i<n;i++)); do
  if [ "${args[i]}" = "-i" ] && [ $((i+1)) -lt "$n" ]; then input="${args[i+1]}"; fi
done
if [ -n "${FFMPEG_FAIL_MARK:-}" ] && printf '%s' "$input" | grep -qF "$FFMPEG_FAIL_MARK"; then
  echo "[ffmpeg-falso] fallo simulado para: $input" >&2
  exit 1
fi
: > "$out" || exit 1
exit 0
EOF
chmod +x "$WORK/stubs/ffmpeg"

# -- stub ffprobe: duracion y dimensiones fijas, para no depender de ffprobe real --
cat > "$WORK/stubs/ffprobe" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *width,height*)    echo "1280,720" ;;
  *format=duration*) echo "2.0000" ;;
  *)                 echo "" ;;
esac
exit 0
EOF
chmod +x "$WORK/stubs/ffprobe"

: > "$WORK/fuentes/bueno.mp4"
: > "$WORK/fuentes/malo.mp4"

cat > "$WORK/esc.guion" <<EOF
BROLL|$WORK/fuentes/bueno.mp4
BROLL|$WORK/fuentes/malo.mp4
EOF

# ── ESCENARIO A: un clip falla, el otro se monta igual ──────────────────────
PATH="$WORK/stubs:$PATH" MD="$WORK/mdA" DEST="$WORK/salida" FFMPEG_FAIL_MARK="malo.mp4" \
  bash "$PROD_SH" "$WORK/esc.guion" smokeA > "$WORK/outA.log" 2>&1
rcA=$?

# Diagnostico honesto: si ni siquiera llego al montaje, el fallo NO es el del rc.
grep -q "ENSAMBLANDO" "$WORK/outA.log" || \
  fallar "escenario A: el script no llego siquiera a la fase de montaje (rc=$rcA); esto NO prueba nada sobre el chequeo de rc de ffmpeg. Log: $(cat "$WORK/outA.log")"

[ "$rcA" -eq 0 ] || fallar "escenario A (1 clip malo, 1 bueno) debia salir 0, salio $rcA. Log: $(cat "$WORK/outA.log")"

LISTA_A="$WORK/mdA/produccion/obra/smokeA/montaje/lista.txt"
[ -s "$LISTA_A" ] || fallar "escenario A: lista.txt no existe o quedo vacia, deberia tener el clip bueno"
[ "$(wc -l < "$LISTA_A")" -eq 1 ] || fallar "escenario A: lista.txt deberia tener exactamente 1 linea (el clip malo no debe entrar), tiene: $(cat "$LISTA_A")"
grep -qF "01.mp4" "$LISTA_A" || fallar "escenario A: lista.txt no referencia el clip bueno (01.mp4)"
grep -qF "02.mp4" "$LISTA_A" && fallar "escenario A: lista.txt NO debe referenciar el clip que fallo (02.mp4) -- el bug era meterlo igual"
[ -f "$WORK/mdA/produccion/obra/smokeA/montaje/01.mp4" ] || fallar "escenario A: no se genero el clip bueno 01.mp4"

grep -qF "CLIP 2 FALLO al procesar" "$WORK/outA.log" || fallar "escenario A: no se vio el aviso de que el CLIP 2 fallo"
grep -qF "OMITIDO del montaje" "$WORK/outA.log" || fallar "escenario A: no se vio el aviso de que el clip fue OMITIDO"

ls "$WORK/salida/smokeA-"*.mp4 >/dev/null 2>&1 || fallar "escenario A: con un clip bueno superviviente SI debia generarse un video final"

# ── ESCENARIO B: fallan TODOS los clips -> debe abortar, sin video final ────
PATH="$WORK/stubs:$PATH" MD="$WORK/mdB" DEST="$WORK/salida" FFMPEG_FAIL_MARK=".mp4" \
  bash "$PROD_SH" "$WORK/esc.guion" smokeB > "$WORK/outB.log" 2>&1
rcB=$?

grep -q "ENSAMBLANDO" "$WORK/outB.log" || \
  fallar "escenario B: el script no llego siquiera a la fase de montaje (rc=$rcB). Log: $(cat "$WORK/outB.log")"

[ "$rcB" -eq 1 ] || fallar "escenario B (fallan todos los clips) debia salir 1, salio $rcB. Log: $(cat "$WORK/outB.log")"
grep -qF "FALLO: ningun clip llego al montaje" "$WORK/outB.log" || fallar "escenario B: falta el mensaje de guarda de lista.txt vacia"
grep -qF "LISTO:" "$WORK/outB.log" && fallar "escenario B: el script anuncio LISTO pese a que ningun clip sobrevivio"

LISTA_B="$WORK/mdB/produccion/obra/smokeB/montaje/lista.txt"
[ -s "$LISTA_B" ] && fallar "escenario B: lista.txt no deberia tener contenido (todos los clips fallaron)"

ls "$WORK/salida/smokeB-"*.mp4 >/dev/null 2>&1 && fallar "escenario B: NO debia generarse video final si todos los clips fallaron"

echo "PASA $NOMBRE"
exit 0