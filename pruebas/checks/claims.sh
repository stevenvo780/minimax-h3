#!/bin/bash
set -u
NOMBRE="claims"
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
SUT="$RAIZ/proyecto-minuto/escalar-pipeline.sh"

WORKDIR=""
fail() {
  echo "FALLA $NOMBRE: $1"
  [ -n "$WORKDIR" ] && echo "         (evidencia conservada en $WORKDIR)"
  exit 1
}

[ -f "$SUT" ] || fail "no existe el script a probar: $SUT"

WORKDIR=$(mktemp -d /tmp/check-claims.XXXXXX) || fail "no pude crear workdir temporal"
FAKE_MD="$WORKDIR/md"
STUBBIN="$WORKDIR/stubbin"
LOG="$WORKDIR/sdcli-calls.log"
OUT_LOG="$WORKDIR/run.log"
P="$FAKE_MD/proyecto-minuto"

mkdir -p "$FAKE_MD/bin" "$STUBBIN" "$P/shots" "$P/claims" || fail "no pude crear arbol fake"
: > "$LOG"

# --- stub ffmpeg: crea los ficheros de salida que escalar_plano espera, sin
#     tocar ni necesitar ffmpeg/ffprobe reales (esta maquina no tiene ffmpeg).
cat > "$STUBBIN/ffmpeg" <<'EOF'
#!/bin/bash
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  *%04d.png)
    d=$(dirname "$last")
    mkdir -p "$d"
    : > "$d/0001.png"
    : > "$d/0002.png"
    ;;
  *.wav) : > "$last" ;;
  *.mp4) : > "$last" ;;
esac
exit 0
EOF
chmod +x "$STUBBIN/ffmpeg"

# --- stub sleep: hace instantaneos los "sleep 60"/"sleep 30" del script, para
#     correr el pipeline entero (incl. los 3 reintentos) en milisegundos.
cat > "$STUBBIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUBBIN/sleep"

# --- stub pgrep: SIEMPRE "no hay generacion en curso" (exit 1).
#     Sin esto el check es un falso positivo andante: el script espera en
#     `while pgrep -f ...generar.sh; do sleep; done`, asi que CUALQUIER proceso
#     ajeno de la maquina cuya linea de comandos contenga "generar.sh" (incluida
#     la propia shell que lanza el check) cuelga la fase 2 hasta el timeout y el
#     check acusa de "bucle infinito" a codigo que esta perfectamente bien.
cat > "$STUBBIN/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUBBIN/pgrep"

# --- stub sd-cli: se instala en $FAKE_MD/bin/sd-cli (la ruta que usan tanto
#     comun.sh como la version vieja). Registra cada llamada en LOG. Si la
#     entrada es un frame de "sBAD" (plano roto a proposito), NO crea el PNG de
#     salida -> escalar_plano lo vera INCOMPLETO y fallara, como un plano roto real.
cat > "$FAKE_MD/bin/sd-cli" <<EOF
#!/bin/bash
IN="" OUT=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) IN=\$2; shift 2 ;;
    -o) OUT=\$2; shift 2 ;;
    *) shift ;;
  esac
done
echo "CALL \$IN -> \$OUT" >> "$LOG"
case "\$IN" in
  *sBAD-in*) exit 0 ;;
  *) : > "\$OUT" ;;
esac
exit 0
EOF
chmod +x "$FAKE_MD/bin/sd-cli"

# --- planos de prueba: s01 (sano) y sBAD (roto a proposito) ---
: > "$P/shots/s01.avi"
: > "$P/shots/sBAD.avi"

# --- Simula el estado que deja una ejecucion anterior interrumpida:
#   1) un claim huerfano de s01 (directorio sin su up-mp4): antes del arreglo el
#      mkdir del claim fallaba para siempre y ESE plano no se volvia a procesar.
#   2) una marca .FALLIDO vieja de sBAD: antes del arreglo no se limpiaba al
#      arrancar, asi que un plano marcado fallido quedaba fallido para siempre.
mkdir -p "$P/claims/s01" || fail "no pude crear claim huerfano de prueba"
: > "$P/claims/sBAD.FALLIDO" || fail "no pude crear marca FALLIDO vieja de prueba"

# --- huella del repo ANTES: el check no debe escribir NADA dentro de $RAIZ.
#     No sirve `git status`: up-mp4/, wk/, claims/ y GENERACION_LISTA estan en
#     .gitignore, o sea que git es CIEGO justo a los ficheros que este script
#     crea. Hay que comparar el arbol real (ruta|tamano|mtime).
huella_raiz() {
  find "$RAIZ" -path "$RAIZ/.git" -prune -o -printf '%p|%s|%T@\n' 2>/dev/null | LC_ALL=C sort
}
HUELLA_ANTES="$WORKDIR/raiz-antes.txt"
HUELLA_DESPUES="$WORKDIR/raiz-despues.txt"
huella_raiz > "$HUELLA_ANTES"

# --- corre el script REAL bajo prueba (solo lectura) contra el arbol fake ---
timeout 10 env -i \
  HOME="${HOME:-/tmp}" PATH="$STUBBIN:/usr/bin:/bin" \
  MD="$FAKE_MD" \
  bash "$SUT" > "$OUT_LOG" 2>&1
RC=$?

huella_raiz > "$HUELLA_DESPUES"
if ! cmp -s "$HUELLA_ANTES" "$HUELLA_DESPUES"; then
  echo "  --- diferencias dentro de $RAIZ ---"
  diff "$HUELLA_ANTES" "$HUELLA_DESPUES" | head -20
  fail "INSEGURO: la ejecucion modifico ficheros DENTRO del repo $RAIZ (MD no se respeto)"
fi

# --- si el arbol bajo prueba esta incompleto, ff()/sd_upscale() no existen y
#     TODOS los planos dan "sin frames": el resultado no diria nada de claims.
if grep -q 'comun\.sh: No such file or directory' "$OUT_LOG"; then
  fail "el arbol bajo prueba no tiene lib/comun.sh (RAIZ=$RAIZ incompleta): sin ff()/sd_upscale() ningun plano se procesa y el resultado no dice nada sobre la logica de claims -- ver $OUT_LOG"
fi

CALLS_SBAD=$(grep -c 'sBAD-in' "$LOG" 2>/dev/null) || CALLS_SBAD=0
CALLS_TOT=$(wc -l < "$LOG")

# --- si el script ni siquiera uso el arbol de prueba, NO se le puede achacar
#     nada sobre claims: hay que decirlo, no confundirlo con un bucle infinito.
if [ "$CALLS_TOT" -eq 0 ] && [ ! -d "$P/up-mp4" ]; then
  fail "el script no uso el arbol de prueba (0 llamadas a sd-cli y ni siquiera creo up-mp4/): ignora la variable MD, asi que este check no puede juzgar su logica de claims -- ver $OUT_LOG"
fi

if [ "$RC" -eq 124 ]; then
  if [ "$CALLS_SBAD" -gt 6 ]; then
    fail "el pipeline NO termino en 10s y sd-cli se invoco $CALLS_SBAD veces sobre el plano roto sBAD: BUCLE INFINITO de reintentos, no se respeta el tope de 3 -- ver $OUT_LOG"
  fi
  fail "el pipeline NO termino en 10s ($CALLS_SBAD llamadas a sd-cli sobre sBAD) -- ver $OUT_LOG"
fi
if [ "$RC" -ne 0 ]; then
  fail "escalar-pipeline.sh salio con codigo $RC (se esperaba 0) -- ver $OUT_LOG"
fi

# --- 1) el plano sano, pese al claim huerfano previo, se proceso esta vez ---
[ -f "$P/up-mp4/s01.mp4" ] || fail "up-mp4/s01.mp4 no existe: el claim huerfano de una ejecucion anterior dejo el plano sin procesar en esta 2a ejecucion"
[ -d "$P/claims/s01" ] && fail "claims/s01 sigue existiendo tras terminar: el claim huerfano no se limpio"

# --- 2) el plano roto, pese a la marca .FALLIDO vieja, tuvo esta ejecucion
#        una tanda fresca de reintentos (relanzar == reintentar) ---
[ "$CALLS_SBAD" -gt 0 ] || fail "sd-cli nunca se invoco para sBAD: la marca .FALLIDO vieja no se limpio al arrancar y el plano se salteo sin reintentarlo"

# --- 3) el reintento esta acotado a 3 intentos, NO es un bucle infinito:
#        2 frames por intento x 3 intentos = 6 llamadas, ni una mas ---
[ "$CALLS_SBAD" -eq 6 ] || fail "sd-cli se invoco $CALLS_SBAD veces para sBAD (se esperaban exactamente 6 = 2 frames x 3 intentos): el tope de 3 reintentos no se esta respetando"

# --- 4) tras agotar los 3 intentos, sBAD queda marcado FALLIDO y su claim
#        liberado (no colgado ni reclamado por otro worker) ---
[ -f "$P/claims/sBAD.FALLIDO" ] || fail "tras agotar 3 intentos, claims/sBAD.FALLIDO no existe: no se marco el fallo permanente"
[ -d "$P/claims/sBAD" ] && fail "claims/sBAD sigue existiendo tras agotar los 3 intentos: el claim no se libero"
[ -f "$P/up-mp4/sBAD.mp4" ] && fail "up-mp4/sBAD.mp4 existe: el plano deliberadamente roto no deberia haber podido completarse"

grep -qF 'FALLIDO PERMANENTEMENTE (agotados 3 intentos)' "$OUT_LOG" || fail "no aparecio el mensaje de fallo permanente tras 3 intentos en la salida -- ver $OUT_LOG"
grep -qF 'limpiando claim huérfano: s01' "$OUT_LOG" || fail "no aparecio el mensaje de limpieza de claim huerfano al arrancar -- ver $OUT_LOG"

rm -rf "$WORKDIR" 2>/dev/null
echo "PASA $NOMBRE"
exit 0