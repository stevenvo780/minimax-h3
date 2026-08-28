#!/bin/bash
set -u
NOMBRE="estado"
# RAIZ = arbol de scripts BAJO PRUEBA.  REPO = repo git (solo lectura) del que
# se saca el patron pgrep de 478960b para el contraste de (D).  Van separados a
# proposito: asi se puede apuntar RAIZ a un volcado de la version vieja en /tmp
# sin que el check reviente con "not a git repository".
RAIZ="${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}"
REPO="${REPO:-/workspace/GeneracionDeVideos/minimax-h3}"
FAIL=""

TMP=$(mktemp -d /tmp/chk-estado.XXXXXX) || { echo "FALLA $NOMBRE: no se pudo crear tmp"; exit 1; }
PIDS=""
limpiar() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; rm -rf "$TMP"; }
trap limpiar EXIT

# nvidia-smi no existe en esta maquina: stub minimo para que el script llegue
# limpio hasta el final (no afecta a nada de lo que se comprueba).
mkdir -p "$TMP/stubbin"
printf '#!/bin/bash\necho "0, 0 %%, 0 MiB"\n' > "$TMP/stubbin/nvidia-smi"
chmod +x "$TMP/stubbin/nvidia-smi"
export PATH="$TMP/stubbin:$PATH"

# ── arbol de datos falso, compartido por los casos ────────────────────────
FAKE="$TMP/md"
mkdir -p "$FAKE/produccion/guiones" "$FAKE/produccion/obra/humo" \
         "$FAKE/produccion/obra/humob" "$FAKE/produccion/obra/humoc" \
         "$FAKE/produccion/logs" \
         "$FAKE/proyecto-minuto/shots" "$FAKE/proyecto-minuto/up-mp4" \
         "$FAKE/proyecto-minuto/prompts" "$FAKE/proyecto-minuto/logs"
printf 'BROLL|paisaje de fondo\nBROLL|otra toma\n' > "$FAKE/produccion/guiones/humo.guion"
printf 'HABLA|hola\nHABLA|mundo\n'                 > "$FAKE/produccion/guiones/humob.guion"
printf 'HABLA|solo dialogo\nHABLA|sin b-roll\n'     > "$FAKE/produccion/guiones/humoc.guion"
printf '3/7 - 1.23s/it\r'                          > "$FAKE/produccion/logs/humob-p1.log"
printf 'prompt uno\n'      > "$FAKE/proyecto-minuto/prompts/s1.txt"
printf 'prompt dos\n'      > "$FAKE/proyecto-minuto/prompts/s2.txt"
printf '4/9 - 2.00s/it\r'  > "$FAKE/proyecto-minuto/logs/s1.log"

# ── espejo de los scripts bajo prueba ─────────────────────────────────────
# Se copian y se redirige su raiz de datos al arbol falso.  Sobre el codigo
# ACTUAL el sed es un NO-OP (esa ruta literal ya no aparece: la raiz sale de
# lib/comun.sh y de $MD).  Sobre 478960b, que lleva la ruta clavada, es lo unico
# que permite ejecutarlo fuera de la maquina de Steven: sin esto el script no
# encuentra ningun guion, los bugs (A) y (B) no llegan a manifestarse y el check
# daria PASA sobre codigo roto.
ESP="$TMP/espejo"
mkdir -p "$ESP/produccion" "$ESP/proyecto-minuto"
[ -d "$RAIZ/lib" ] && cp -r "$RAIZ/lib" "$ESP/lib"
for f in produccion/estado.sh proyecto-minuto/estado.sh; do
  [ -f "$RAIZ/$f" ] || { echo "FALLA $NOMBRE: no existe $RAIZ/$f"; exit 1; }
  sed "s|/home/stev/Modelos-IA/minimax-h3|$FAKE|g" "$RAIZ/$f" > "$ESP/$f"
  chmod +x "$ESP/$f"
done

correr() {  # correr <script> <STEPS> [args...]
  local s="$1" st="$2"; shift 2
  MD="$FAKE" DEST="$TMP/videos" HOME="$TMP" STEPS="$st" bash "$s" "$@"
}

# ════════════════════════════════════════════════════════════════════════
# A) el contador NO se corrompe a "0\n0" con un guion sin lineas HABLA.
#    grep -c cuenta 0 pero SALE CON 1, asi que el "|| echo 0" de 478960b
#    tambien corria y anadia una segunda linea "0": printf recibia un
#    argumento de mas, reciclaba el formato y sacaba la linea dos veces.
# ════════════════════════════════════════════════════════════════════════
# A1) guion con BROLL pero SIN NINGUNA linea HABLA -> se rompe el contador
#     de hablados.
OUT_A=$(correr "$ESP/produccion/estado.sh" 20 humo 2>"$TMP/errA.txt")

# Se cuenta SOLO la linea del contador (anclada), no cualquier linea que
# mencione el texto: el script imprime tambien "2060: escalando B-roll a
# 1080p" si hay un proceso escalar-2060 vivo, y eso colaria un falso fallo.
NHAB=$(printf '%s\n' "$OUT_A" | grep -cE '^[[:space:]]*HABLADOS[[:space:]]+[0-9]')
[ "$NHAB" -eq 1 ] || \
  FAIL="${FAIL}(A) produccion: la linea HABLADOS salio $NHAB veces (se esperaba 1) con un guion sin HABLA; "
LINEA_A=$(printf '%s\n' "$OUT_A" | grep -E '^[[:space:]]*HABLADOS[[:space:]]+[0-9]' | head -1)
printf '%s' "$LINEA_A" | grep -qE '0/ ?0' || \
  FAIL="${FAIL}(A) produccion: la linea HABLADOS no da 0/0 -> [$LINEA_A]; "
grep -qEi 'invalid number|printf:' "$TMP/errA.txt" && \
  FAIL="${FAIL}(A) produccion: printf dio error con guion sin HABLA (senal del 0\\n0): $(tr '\n' ' ' < "$TMP/errA.txt"); "

# A2) guion con HABLA pero SIN NINGUNA linea BROLL -> el mismo patron roto,
#     esta vez en el contador de B-roll.
OUT_A2=$(correr "$ESP/produccion/estado.sh" 20 humoc 2>"$TMP/errA2.txt")
NBROLL=$(printf '%s\n' "$OUT_A2" | grep -cE '^[[:space:]]*B-roll[[:space:]]+[0-9]')
[ "$NBROLL" -eq 1 ] || \
  FAIL="${FAIL}(A) produccion: la linea B-roll salio $NBROLL veces (se esperaba 1) con un guion sin BROLL; "
LINEA_A2=$(printf '%s\n' "$OUT_A2" | grep -E '^[[:space:]]*B-roll[[:space:]]+[0-9]' | head -1)
printf '%s' "$LINEA_A2" | grep -qE 'B-roll[[:space:]]+0' || \
  FAIL="${FAIL}(A) produccion: la linea B-roll no da 0 con guion sin BROLL -> [$LINEA_A2]; "
grep -qEi 'invalid number|printf:' "$TMP/errA2.txt" && \
  FAIL="${FAIL}(A) produccion: printf dio error con guion sin BROLL (senal del 0\\n0): $(tr '\n' ' ' < "$TMP/errA2.txt"); "

# ════════════════════════════════════════════════════════════════════════
# B) el numero de pasos del progreso sale de $STEPS, no de un 20 clavado.
#    Los senuelos se lanzan de forma que casen TANTO el patron actual COMO el
#    de 478960b, para que lo unico que mida este bloque sea el /$STEPS.
#    Se espera a que el senuelo tenga ya su linea de comando definitiva
#    mirando SU /proc/<pid>/cmdline: no se escanea la tabla de procesos, que
#    con este check corriendo inline se casaria a si misma.
# ════════════════════════════════════════════════════════════════════════
mkdir -p "$TMP/dummy/produccion" "$TMP/dummy/proyecto-minuto"
printf '#!/bin/bash\nsleep 20\n' > "$TMP/dummy/produccion/producir.sh"
printf '#!/bin/bash\nsleep 20\n' > "$TMP/dummy/proyecto-minuto/generar.sh"
chmod +x "$TMP/dummy/produccion/producir.sh" "$TMP/dummy/proyecto-minuto/generar.sh"

esperar_cmdline() {  # esperar_cmdline <pid> <texto-que-debe-contener>
  local pid="$1" txt="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$txt"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# cmdline "bash producir.sh": casa "bash producir.sh" (478960b) y "producir\.sh"
P1=$(cd "$TMP/dummy/produccion" && { bash producir.sh >/dev/null 2>&1 & echo $!; })
# cmdline "bash <abs>/proyecto-minuto/generar.sh": casa "proyecto-minuto/generar.sh"
# (478960b) y "[/ ]generar\.sh"
bash "$TMP/dummy/proyecto-minuto/generar.sh" >/dev/null 2>&1 &
P2=$!
PIDS="$P1 $P2"
esperar_cmdline "$P1" "bash producir.sh" || \
  FAIL="${FAIL}(B) el senuelo producir.sh no llego a arrancar; "
esperar_cmdline "$P2" "proyecto-minuto/generar.sh" || \
  FAIL="${FAIL}(B) el senuelo generar.sh no llego a arrancar; "

OUT_B=$(correr "$ESP/produccion/estado.sh" 7 humob 2>"$TMP/errB.txt")
LINEA_GEN_B=$(printf '%s\n' "$OUT_B" | grep "generando:")
printf '%s' "$LINEA_GEN_B" | grep -qE '3/7 - 1\.23s/it' || \
  FAIL="${FAIL}(B) produccion: no se uso \$STEPS (esperaba '3/7 - 1.23s/it' con STEPS=7) -> [$LINEA_GEN_B]; "

OUT_C=$(correr "$ESP/proyecto-minuto/estado.sh" 9 2>"$TMP/errC.txt")
LINEA_GEN_C=$(printf '%s\n' "$OUT_C" | grep "generando:")
printf '%s' "$LINEA_GEN_C" | grep -qE '4/9 - 2\.00s/it' || \
  FAIL="${FAIL}(B) proyecto-minuto: no se uso \$STEPS (esperaba '4/9 - 2.00s/it' con STEPS=9) -> [$LINEA_GEN_C]; "

# ════════════════════════════════════════════════════════════════════════
# D) el patron de pgrep casa ./script, "bash script" y ruta absoluta.
#    Se extrae el patron REAL del fichero y se aplica como ERE sobre lineas de
#    comando sinteticas (la misma semantica que usa pgrep -f), y se contrasta
#    con el patron de 478960b para probar que la comprobacion tiene mordida.
# ════════════════════════════════════════════════════════════════════════
extraer_patron_pgrep() {
  local archivo="$1" pista="$2" linea
  linea=$(grep -m1 "pgrep -f.*$pista" "$archivo" 2>/dev/null)
  if [[ "$linea" =~ pgrep\ -f\ \"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$linea" =~ pgrep\ -f\ \'([^\']*)\' ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}
extraer_de_git() {  # extraer_de_git <ruta-en-el-repo> <pista>
  local ruta="$1" pista="$2" tmpf="$TMP/desde-git.sh"
  git -C "$REPO" show "478960b:$ruta" > "$tmpf" 2>/dev/null || return 1
  [ -s "$tmpf" ] || return 1
  extraer_patron_pgrep "$tmpf" "$pista"
}

PAT_PROD_NUEVO=$(extraer_patron_pgrep "$RAIZ/produccion/estado.sh" producir)
PAT_MIN_NUEVO=$(extraer_patron_pgrep "$RAIZ/proyecto-minuto/estado.sh" generar)
# Patrones de 478960b: del repo si hay git; si no, los literales conocidos, para
# que el contraste siga existiendo aunque el arbol se copie sin historia.
PAT_PROD_VIEJO=$(extraer_de_git produccion/estado.sh producir)
PAT_MIN_VIEJO=$(extraer_de_git proyecto-minuto/estado.sh generar)
[ -n "$PAT_PROD_VIEJO" ] || PAT_PROD_VIEJO='bash producir.sh'
[ -n "$PAT_MIN_VIEJO" ]  || PAT_MIN_VIEJO='proyecto-minuto/generar.sh'

if [ -z "$PAT_PROD_NUEVO" ] || [ -z "$PAT_MIN_NUEVO" ]; then
  FAIL="${FAIL}(D) no se pudo extraer el patron pgrep de los scripts bajo prueba; "
else
  for cmd in "./producir.sh" "bash producir.sh" \
             "bash /home/stev/Modelos-IA/minimax-h3/produccion/producir.sh"; do
    grep -qE -- "$PAT_PROD_NUEVO" <<<"$cmd" || \
      FAIL="${FAIL}(D) produccion: el patron [$PAT_PROD_NUEVO] no casa '$cmd'; "
  done
  for cmd in "./generar.sh" "bash generar.sh" \
             "bash /home/stev/Modelos-IA/minimax-h3/proyecto-minuto/generar.sh"; do
    grep -qE -- "$PAT_MIN_NUEVO" <<<"$cmd" || \
      FAIL="${FAIL}(D) proyecto-minuto: el patron [$PAT_MIN_NUEVO] no casa '$cmd'; "
  done
  # Contraste: el patron de 478960b DEBE fallar en los casos que cubre el
  # arreglo.  Si ya casaba, la comprobacion de arriba no demostraria nada.
  grep -qE -- "$PAT_PROD_VIEJO" <<<"./producir.sh" && \
    FAIL="${FAIL}(D) el patron de 478960b ya casaba './producir.sh': el contraste no vale; "
  grep -qE -- "$PAT_PROD_VIEJO" <<<"bash /ruta/abs/produccion/producir.sh" && \
    FAIL="${FAIL}(D) el patron de 478960b ya casaba la ruta absoluta: el contraste no vale; "
  grep -qE -- "$PAT_MIN_VIEJO" <<<"./generar.sh" && \
    FAIL="${FAIL}(D) el patron de 478960b ya casaba './generar.sh': el contraste no vale; "
  grep -qE -- "$PAT_MIN_VIEJO" <<<"bash generar.sh" && \
    FAIL="${FAIL}(D) el patron de 478960b ya casaba 'bash generar.sh': el contraste no vale; "
fi

# ════════════════════════════════════════════════════════════════════════
if [ -n "$FAIL" ]; then
  echo "FALLA $NOMBRE: $FAIL"
  exit 1
fi
echo "PASA $NOMBRE"
exit 0