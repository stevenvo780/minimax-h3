#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
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
rm -rf "$RAIZ/produccion/obra/chk-no-generar" 2>/dev/null

# Un tipo inexistente tiene que rebotar, no colarse hasta la GPU.
printf '@TIPO noexiste\n@ESCENA E.\n@AMBIENTE A.\n@MUSICA M.\nTOMA|Algo.|inicio|\n' > "$T/malo.guion"
if VALIDAR=1 timeout 30 bash "$S" "$T/malo.guion" x >/dev/null 2>&1; then
  echo "FALLA $nombre: un @TIPO inexistente salio con 0"
  fallos=1
fi

[ $fallos -eq 0 ] && echo "ok $nombre ($((${#GUIONES[@]})) guiones)"
exit $fallos
