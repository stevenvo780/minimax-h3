#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRUEBA DE HUMO EN KRATOS — valida los arreglos con la 5070 Ti de verdad.
#  Uso:  bash prueba-gpu.sh
#  Coste: ~1 min de GPU + unos minutos de CPU. NO toca material de entrada.
# ═══════════════════════════════════════════════════════════════════════════
set -u
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OK=0; MAL=0; SALT=0
paso(){ printf "  %-46s " "$1"; }
si()   { echo "PASA";  OK=$((OK+1)); }
no()   { echo "FALLA: $1"; MAL=$((MAL+1)); }
salta(){ echo "SALTA ($1)"; SALT=$((SALT+1)); }

# Que hay disponible en ESTA maquina. Sin GPU/ffmpeg los bloques 3 y 4 se saltan,
# no se dan por fallidos: no estan rotos, es que aqui no se pueden comprobar.
HAY_SDCLI=0; "$RAIZ/bin/sd-cli" --help >/dev/null 2>&1 && HAY_SDCLI=1
HAY_FF=0;    command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && HAY_FF=1
HAY_GPU=0;   command -v nvidia-smi >/dev/null 2>&1 && [ -e /dev/nvidia0 ] && HAY_GPU=1

echo "═══ 1. ENTORNO ═══"
paso "sd-cli arranca"; [ $HAY_SDCLI -eq 1 ] && si || salta "sin CUDA en esta maquina"
paso "ffmpeg y ffprobe";  [ $HAY_FF -eq 1 ]    && si || salta "no instalados aqui"
paso "CUDA0 es la 5070 Ti"
if [ $HAY_GPU -eq 1 ]; then
  G0=$(nvidia-smi -i 0 --query-gpu=name --format=csv,noheader 2>/dev/null)
  case "$G0" in *5070*) si;; *) no "CUDA0 = '$G0'";; esac
else salta "sin GPU en esta maquina"; fi

echo "═══ 2. RUTAS Y PARÁMETROS (lo que cambió el refactor) ═══"
paso "comun.sh deduce MD correctamente"
M=$(unset MD; . "$RAIZ/lib/comun.sh"; echo "$MD")
[ "$M" = "$RAIZ" ] && si || no "MD='$M' != '$RAIZ'"

# Cada script debe seguir produciendo SUS parámetros originales, no los del vecino.
while IFS='|' read -r f esp; do
  [ -z "$f" ] && continue
  paso "params de $f"
  got=$(unset W H FRAMES STEPS PARAMS_BACKEND MAXVRAM
        . "$RAIZ/lib/comun.sh"
        eval "$(grep -E '^(params_defecto|PARAMS_BACKEND=|MAXVRAM=)' "$RAIZ/$f" | head -5)"
        echo "${W}x${H}:${FRAMES}:${STEPS}:${MAXVRAM}:${PARAMS_BACKEND}")
  [ "$got" = "$esp" ] && si || no "esperado $esp / obtenido $got"
done <<'TABLA'
h3.sh|864x480:56:20:cuda0=8:diffusion=cpu
encadenar.sh|1376x768:124:20:cuda0=2:diffusion=cpu
generar-1080p.sh|512x288:56:20:cuda0=6:diffusion=cpu
produccion/producir.sh|1376x768:107:20:cuda0=2:diffusion=cpu,vae=cpu
proyecto-minuto/generar.sh|1376x768:107:20:cuda0=2:diffusion=cpu
TABLA

# Este check exige DOS cosas: que params_defecto EXISTA y que respete el entorno.
# Sin la primera comprobacion daba PASA en falso (W/H conservaban lo exportado
# aunque comun.sh no se hubiera cargado siquiera).
paso "params_defecto existe y respeta el entorno"
got=$(export W=1280 H=704
      . "$RAIZ/lib/comun.sh" 2>/dev/null || { echo "SIN-COMUN"; exit; }
      declare -F params_defecto >/dev/null || { echo "SIN-FUNCION"; exit; }
      params_defecto 864 480 56 20; echo "${W}x${H}")
[ "$got" = "1280x704" ] && si || no "obtenido '$got'"

paso "sin entorno manda el default del script"
got=$(unset W H FRAMES STEPS
      . "$RAIZ/lib/comun.sh" 2>/dev/null || { echo "SIN-COMUN"; exit; }
      declare -F params_defecto >/dev/null || { echo "SIN-FUNCION"; exit; }
      params_defecto 864 480 56 20; echo "${W}x${H}")
[ "$got" = "864x480" ] && si || no "obtenido '$got'"

echo "═══ 3. GENERACIÓN REAL EN LA 5070 Ti (~1 min) ═══"
T=$(mktemp -d /tmp/humo-XXXXXX)
if [ $HAY_SDCLI -eq 0 ] || [ $HAY_GPU -eq 0 ]; then
  paso "generacion en la 5070 Ti"; salta "requiere kratos: aqui no hay GPU ni CUDA"
else
echo "    512x288, 22 frames, 8 pasos — mínimo que ejercita todo el camino"
T0=$SECONDS
W=512 H=288 FRAMES=22 STEPS=8 OUT=$T/humo.mp4 \
  bash "$RAIZ/h3.sh" "A man sits in a dim study and looks at the camera." > "$T/gen.log" 2>&1
RC=$?
echo "    terminó en $((SECONDS-T0))s (rc=$RC)"

paso "sd-cli escribió en <salida>.mp4.avi"
# Este es EXACTAMENTE el contrato que una regresión rompió: -o X.mp4 -> X.mp4.avi
[ -f "$T/humo.mp4.avi" ] && si || { no "no existe $T/humo.mp4.avi"; ls -la "$T"; tail -15 "$T/gen.log"; }

if [ -f "$T/humo.mp4.avi" ]; then
  paso "el clip tiene vídeo y audio"
  ST=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$T/humo.mp4.avi" 2>/dev/null | tr '\n' ',')
  case "$ST" in *video*audio*|*audio*video*) si;; *) no "streams='$ST'";; esac
  paso "resolución y nº de frames correctos"
  WH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T/humo.mp4.avi" 2>/dev/null)
  [ "$WH" = "512,288" ] && si || no "resolución=$WH, esperada 512,288"
  paso "h3.sh anuncia la ruta REAL del fichero"
  grep -q "$T/humo.mp4.avi" "$T/gen.log" && si || no "el script no imprimió la ruta .avi real"
fi

fi

echo "═══ 4. MONTAJE COMPLETO SIN GPU (sobre una COPIA, no toca el original) ═══"
OBRA=$RAIZ/produccion/obra
if [ $HAY_FF -eq 0 ]; then
  paso "montaje de los 14 planos"; salta "requiere ffmpeg"
elif [ -d "$OBRA/existencialismo" ]; then
  rm -rf "$OBRA/humo-montaje"
  cp -r "$OBRA/existencialismo" "$OBRA/humo-montaje"
  # Fronteras de tramo falsas: si producir.sh NO limpia tramos.txt, sobreviven.
  mkdir -p "$OBRA/humo-montaje/montaje"
  printf '02\n07\n11\n' > "$OBRA/humo-montaje/montaje/tramos.txt"
  DEST=$T bash "$RAIZ/produccion/producir.sh" \
      "$RAIZ/produccion/guiones/existencialismo.guion" humo-montaje > "$T/mont.log" 2>&1
  paso "los 14 planos se saltan (idempotencia)"
  [ "$(grep -c 'ya existe, salto' "$T/mont.log")" -eq 14 ] && si || no "$(grep -c 'ya existe, salto' "$T/mont.log")/14"
  paso "tramos.txt se regeneró (05 09 13, no 02 07 11)"
  TR=$(tr '\n' ' ' < "$OBRA/humo-montaje/montaje/tramos.txt" 2>/dev/null)
  [ "$TR" = "05 09 13 " ] && si || no "tramos='$TR' (las fronteras falsas sobrevivieron)"
  paso "el vídeo final se ensambló"
  F=$(ls -1t "$T"/humo-montaje-*.mp4 2>/dev/null | head -1)
  [ -n "$F" ] && [ -s "$F" ] && si || { no "sin fichero final"; tail -15 "$T/mont.log"; }
  if [ -n "${F:-}" ]; then
    paso "dura ~61 s y tiene 14 planos con 3 fundidos"
    D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$F" 2>/dev/null)
    awk "BEGIN{exit !($D>59 && $D<64)}" && si || no "duración=$D s"
  fi
  rm -rf "$OBRA/humo-montaje"
else
  echo "  (saltado: no existe obra/existencialismo)"
fi

echo
echo "═══ RESULTADO: $OK pasan · $MAL fallan · $SALT saltados ═══"
echo "    log de generación: $T/gen.log"
echo "    log de montaje   : $T/mont.log"
[ $MAL -eq 0 ] || exit 1
