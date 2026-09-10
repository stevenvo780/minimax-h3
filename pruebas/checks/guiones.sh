#!/bin/bash
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
nombre="guiones"
exec 0</dev/null

# Todo .guion del repo tiene que parsear y construir sus prompts. Antes esto
# solo se sabia produciendolo: un @TIPO mal escrito o una linea TOMA| con el
# separador cambiado se descubria despues de encolar la tanda. VALIDAR=1 lo
# comprueba sin tocar la GPU, asi que puede vivir en el humo.
S="$RAIZ/produccion/producir-anclado.sh"
[ -f "$S" ] || { echo "FALLA $nombre: no existe $S"; exit 1; }

mapfile -t GUIONES < <(find "$RAIZ/produccion/guiones" -name '*.guion' 2>/dev/null | sort)
[ ${#GUIONES[@]} -gt 0 ] || { echo "FALLA $nombre: no encontre ningun .guion"; exit 1; }

fallos=0
for g in "${GUIONES[@]}"; do
  o=$(VALIDAR=1 timeout 30 bash "$S" "$g" validacion 2>&1)
  if ! printf '%s' "$o" | grep -q 'guion valido'; then
    echo "FALLA $nombre: ${g#$RAIZ/} no valida"
    printf '%s' "$o" | head -3 | sed 's/^/    /'
    fallos=1
  fi
done

# VALIDAR=1 no puede generar NADA: si escribiera un .avi estaria gastando GPU.
T=$(mktemp -d /tmp/chk-guiones.XXXXXX); trap 'rm -rf "$T"' EXIT
printf '@TIPO muda\n@ESCENA E.\n@AMBIENTE A.\n@MUSICA M.\nTOMA|Algo.|inicio|\n' > "$T/v.guion"
VALIDAR=1 timeout 30 bash "$S" "$T/v.guion" chk-no-generar >/dev/null 2>&1
if compgen -G "$RAIZ/produccion/obra/chk-no-generar/*.avi" >/dev/null; then
  echo "FALLA $nombre: VALIDAR=1 genero video (deberia salir antes de tocar la GPU)"
  fallos=1
fi
rm -rf "$RAIZ/produccion/obra/chk-no-generar" "$RAIZ/produccion/obra/validacion" \
       "$RAIZ/produccion/obra/campos" 2>/dev/null

# Un tipo inexistente tiene que rebotar, no colarse hasta la GPU.
printf '@TIPO noexiste\n@ESCENA E.\n@AMBIENTE A.\n@MUSICA M.\nTOMA|Algo.|inicio|\n' > "$T/malo.guion"
if VALIDAR=1 timeout 30 bash "$S" "$T/malo.guion" x >/dev/null 2>&1; then
  echo "FALLA $nombre: un @TIPO inexistente salio con 0"
  fallos=1
fi

# Los campos POR TOMA (5 escena, 6 ambiente) sustituyen de verdad a los
# globales, y VALIDAR enseña EXACTAMENTE lo que se generaria.
#
# Esto ultimo no es teorico: cuando se añadio la escena por toma, VALIDAR
# seguia imprimiendo la @ESCENA global. Revisar un guion sin gastar GPU es
# justo para lo que sirve VALIDAR, y estaba enseñando un prompt distinto del
# que iba a recibir el modelo. Mentia en lo unico que hace.
printf '@TIPO habla\n@ESCENA ESCENA-GLOBAL.\n@AMBIENTE AMBIENTE-GLOBAL.\n@MUSICA M.\n' > "$T/campos.guion"
printf 'TOMA|Uno.|inicio|habla|\n' >> "$T/campos.guion"
printf 'TOMA|Dos.|inicio|detalle|ESCENA-PROPIA.|AMBIENTE-PROPIO.\n' >> "$T/campos.guion"
o=$(VALIDAR=1 timeout 30 bash "$S" "$T/campos.guion" campos 2>&1)
t2=$(printf '%s' "$o" | sed -n '/toma 2 /,$p')
printf '%s' "$t2" | grep -q 'ESCENA-PROPIA'   || { echo "FALLA $nombre: el campo 5 no sustituye a @ESCENA en la toma 2"; fallos=1; }
printf '%s' "$t2" | grep -q 'AMBIENTE-PROPIO' || { echo "FALLA $nombre: el campo 6 no sustituye a @AMBIENTE en la toma 2"; fallos=1; }
printf '%s' "$t2" | grep -q 'ESCENA-GLOBAL'   && { echo "FALLA $nombre: la toma 2 conserva la @ESCENA global teniendo escena propia"; fallos=1; }
printf '%s' "$t2" | grep -q 'AMBIENTE-GLOBAL' && { echo "FALLA $nombre: la toma 2 conserva el @AMBIENTE global teniendo ambiente propio"; fallos=1; }
# Y la toma 1, sin campos propios, sigue heredando los globales.
t1=$(printf '%s' "$o" | sed -n '/toma 1 /,/toma 2 /p')
printf '%s' "$t1" | grep -q 'ESCENA-GLOBAL'   || { echo "FALLA $nombre: la toma 1 perdio la @ESCENA global"; fallos=1; }
printf '%s' "$t1" | grep -q 'AMBIENTE-GLOBAL' || { echo "FALLA $nombre: la toma 1 perdio el @AMBIENTE global"; fallos=1; }

# Lo anterior mira por la ventana de VALIDAR, que es lo unico observable sin
# GPU. Si generar() divergiera y VALIDAR siguiera bien, no se notaria: por eso
# ademas se comprueba a la cara que generar() pasa las variables POR TOMA y no
# las globales. Es una asercion sobre el texto del script, fea pero necesaria.
g=$(sed -n '/^generar() {/,/^}/p' "$S")
printf '%s' "$g" | grep -q 'construir_prompt "\$tipo" "\$esc" "\$cont" "\$amb" "\$MUSICA"' || {
  echo "FALLA $nombre: generar() no construye el prompt con la escena y el ambiente de la toma"
  printf '%s' "$g" | grep -n 'construir_prompt' | sed 's/^/    /'
  fallos=1; }

[ $fallos -eq 0 ] && echo "ok $nombre ($((${#GUIONES[@]})) guiones)"
exit $fallos
