#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PRUEBA DE HUMO — valida la pipeline de punta a punta.
#
#  Uso:  pruebas/humo.sh            todo lo que esta maquina permita
#        pruebas/humo.sh checks     solo los checks de regresion (rapido)
#
#  Bloque A  checks de regresion   corren en CUALQUIER maquina, sin GPU
#  Bloque B  entorno               que hay disponible aqui
#  Bloque C  generacion real       necesita la 5070 Ti (~1 min)
#  Bloque D  montaje completo      necesita ffmpeg, sin GPU
#
#  Lo que no se puede comprobar en esta maquina se marca SALTA, no FALLA:
#  no esta roto, es que aqui no hay con que mirarlo.
# ═══════════════════════════════════════════════════════════════════════════
set -u
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export RAIZ
SOLO=${1:-todo}
OK=0; MAL=0; SALT=0
paso(){ printf "  %-46s " "$1"; }
si()   { echo "PASA";  OK=$((OK+1)); }
no()   { echo "FALLA: $1"; MAL=$((MAL+1)); }
salta(){ echo "SALTA ($1)"; SALT=$((SALT+1)); }

HAY_SDCLI=0; "$RAIZ/bin/sd-cli" --help >/dev/null 2>&1 && HAY_SDCLI=1
HAY_FF=0;    command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && HAY_FF=1
HAY_GPU=0;   command -v nvidia-smi >/dev/null 2>&1 && [ -e /dev/nvidia0 ] && HAY_GPU=1

echo "═══ A. CHECKS DE REGRESION ═══"
SUCIO_ANTES=$(git -C "$RAIZ" status --porcelain 2>/dev/null | wc -l)
for c in "$RAIZ"/pruebas/checks/*.sh; do
  [ -f "$c" ] || continue
  n=$(basename "$c" .sh)
  paso "$n"
  salida=$(timeout 120 bash "$c" 2>&1)
  if [ $? -eq 0 ]; then si; else no "$(printf '%s' "$salida" | tail -1 | cut -c1-90)"; fi
done
SUCIO=$(git -C "$RAIZ" status --porcelain 2>/dev/null | wc -l)
paso "los checks no han ensuciado el repo"
[ "$SUCIO" = "$SUCIO_ANTES" ] && si || no "git status paso de $SUCIO_ANTES a $SUCIO cambios"
[ "$SOLO" = "checks" ] && { echo; echo "═══ $OK pasan · $MAL fallan · $SALT saltados ═══"; [ $MAL -eq 0 ]; exit $?; }

echo "═══ B. ENTORNO ═══"
paso "sd-cli arranca";   [ $HAY_SDCLI -eq 1 ] && si || salta "sin CUDA en esta maquina"
paso "ffmpeg y ffprobe"; [ $HAY_FF -eq 1 ]    && si || salta "no instalados aqui"
paso "CUDA0 es la 5070 Ti"
if [ $HAY_GPU -eq 1 ]; then
  G0=$(nvidia-smi -i 0 --query-gpu=name --format=csv,noheader 2>/dev/null)
  case "$G0" in *5070*) si;; *) no "CUDA0 = '$G0'";; esac
else salta "sin GPU en esta maquina"; fi

echo "═══ C. GENERACION REAL EN LA 5070 Ti (~1 min) ═══"
T=$(mktemp -d /tmp/humo-XXXXXX)
if [ $HAY_SDCLI -eq 0 ] || [ $HAY_GPU -eq 0 ]; then
  paso "generacion 512x288 22f 8 pasos"; salta "requiere kratos"
else
  echo "    512x288, 22 frames, 8 pasos — el minimo que ejercita el camino entero"
  T0=$SECONDS
  W=512 H=288 FRAMES=22 STEPS=8 OUT=$T/humo.mp4 \
    bash "$RAIZ/herramientas/h3.sh" "A man sits in a dim study and looks at the camera." > "$T/gen.log" 2>&1
  echo "    termino en $((SECONDS-T0))s"
  paso "sd-cli escribio en <salida>.mp4.avi"
  [ -f "$T/humo.mp4.avi" ] && si || { no "no existe $T/humo.mp4.avi"; tail -12 "$T/gen.log"; }
  if [ -f "$T/humo.mp4.avi" ]; then
    paso "el clip tiene video y audio"
    ST=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$T/humo.mp4.avi" 2>/dev/null | tr '\n' ',')
    case "$ST" in *video*audio*|*audio*video*) si;; *) no "streams='$ST'";; esac
    paso "sale a la resolucion pedida"
    WH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T/humo.mp4.avi" 2>/dev/null)
    [ "$WH" = "512,288" ] && si || no "resolucion=$WH"
    paso "herramientas/h3.sh anuncia la ruta REAL"
    grep -q "$T/humo.mp4.avi" "$T/gen.log" && si || no "no imprimio la ruta .avi"
  fi
fi

echo "═══ D. MONTAJE COMPLETO (sin GPU, sobre una COPIA) ═══"
OBRA=$RAIZ/produccion/obra
ORIG=""
for cand in existencialismo-4p existencialismo existencialismo-largo; do
  [ -d "$OBRA/$cand" ] && [ -n "$(ls "$OBRA/$cand"/p*.avi 2>/dev/null)" ] && { ORIG=$cand; break; }
done
if [ $HAY_FF -eq 0 ]; then
  paso "montaje de la obra"; salta "requiere ffmpeg"
elif [ -z "$ORIG" ]; then
  paso "montaje de la obra"; salta "no hay ninguna obra con planos"
else
  N=$(ls "$OBRA/$ORIG"/p*.avi | wc -l)
  GUION=$RAIZ/produccion/guiones/exis4.guion
  [ "$ORIG" = existencialismo ] && GUION=$RAIZ/produccion/guiones/existencialismo.guion
  [ "$ORIG" = existencialismo-largo ] && GUION=$RAIZ/produccion/guiones/existencialismo-largo.guion
  rm -rf "$OBRA/humo-montaje"; cp -r "$OBRA/$ORIG" "$OBRA/humo-montaje"
  mkdir -p "$OBRA/humo-montaje/montaje"
  printf '02\n07\n11\n' > "$OBRA/humo-montaje/montaje/tramos.txt"   # fronteras falsas a proposito
  DEST=$T bash "$RAIZ/produccion/producir.sh" "$GUION" humo-montaje > "$T/mont.log" 2>&1
  paso "los $N planos se saltan (idempotencia)"
  [ "$(grep -ac 'ya existe, salto' "$T/mont.log")" -eq "$N" ] && si || no "$(grep -ac 'ya existe, salto' "$T/mont.log")/$N"
  # Que el fichero ya no exista es el resultado IDEAL: exis4 no tiene fronteras
  # de tramo, asi que tras limpiarlo no hay motivo para volver a crearlo.
  paso "tramos.txt se regenero (no sobrevive lo falso)"
  TRF=$OBRA/humo-montaje/montaje/tramos.txt
  if [ ! -f "$TRF" ]; then si
  else
    TR=$(tr '\n' ' ' < "$TRF")
    case "$TR" in *02*|*07*|*11*) no "sobrevivieron las fronteras falsas: '$TR'";; *) si;; esac
  fi
  paso "el video final se ensamblo"
  FIN=$(ls -1t "$T"/humo-montaje-*.mp4 2>/dev/null | head -1)
  [ -n "$FIN" ] && [ -s "$FIN" ] && si || { no "sin fichero final"; tail -12 "$T/mont.log"; }
  if [ -n "${FIN:-}" ]; then
    paso "el nombre coincide con el fichero real"
    RWH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$FIN" 2>/dev/null)
    RS=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$FIN" 2>/dev/null)
    ESP="${RWH%,*}x${RWH#*,}-$(awk "BEGIN{printf \"%.0f\", $RS}")s"
    case "$(basename "$FIN")" in *"$ESP"*) si;; *) no "el nombre dice otra cosa que $ESP";; esac
    paso "decodifica entero sin errores"
    [ -z "$(ffmpeg -nostdin -v error -i "$FIN" -f null - 2>&1)" ] && si || no "hay errores de decodificacion"
  fi
  rm -rf "$OBRA/humo-montaje"
fi

echo
echo "═══ $OK pasan · $MAL fallan · $SALT saltados ═══"
[ $MAL -eq 0 ] || echo "    logs en $T"
[ $MAL -eq 0 ]
