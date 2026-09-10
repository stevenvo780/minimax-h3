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

# Se pregunta por el sd-cli QUE USA LA PIPELINE, no por el binario en crudo.
# El de bin/ no arranca en este contenedor (le falta libcudart.so.13); el que
# corre es la copia que prepara lib/compat.sh. Preguntando por el crudo, el
# humo declaraba "sin sd-cli" y SALTABA el bloque de generacion en la unica
# maquina donde si se puede generar.
HAY_SDCLI=0
# La sonda tiene que correr DENTRO del entorno que prepara comun.sh: sd-cli se
# enlaza contra libcudart.so.13, que compat.sh localiza y mete en
# LD_LIBRARY_PATH. Capturando solo la ruta y ejecutando el binario fuera del
# subshell se pierde esa variable, y el humo decia "sin CUDA en esta maquina"
# en una maquina con la 5070 Ti delante y sd-cli funcionando.
SDCLI_REAL=$(cd "$RAIZ" && bash -c '. lib/comun.sh 2>/dev/null; echo "$SDCLI"' 2>/dev/null)
(cd "$RAIZ" && bash -c '. lib/comun.sh 2>/dev/null; "$SDCLI" --help' >/dev/null 2>&1) \
  && HAY_SDCLI=1
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

echo "═══ D. LA COLA DEL REEL (sin GPU) ═══"
# Montaje + subtitulos + export sobre clips fabricados aqui. Es el tramo que
# convierte tomas en producto, y el que se ha roto de verdad: una vez porque
# el AAC redondea y el concat salia con una linea de tiempo irregular, otra
# porque el subtitulo se rasterizaba a 416 y se ampliaba 2,6x. Antes este
# bloque montaba con produccion/producir.sh, el runner anterior, que ya no
# existe: probaba un camino que nadie recorria.
if [ $HAY_FF -eq 0 ]; then
  paso "la cola del reel"; salta "requiere ffmpeg"
else
  MONT=$T/montaje
  mkdir -p "$MONT"
  # Dos clips de duraciones DISTINTAS y una que no cae en tramas AAC enteras:
  # 90 f = 3,75 s es el caso exacto que rompio el montaje de kyiv.
  for par in "01 90" "02 192"; do
    set -- $par
    ffmpeg -nostdin -y -v error \
      -f lavfi -i "testsrc2=s=416x736:d=$(awk -v f=$2 'BEGIN{print f/24}'):r=24" \
      -f lavfi -i "sine=frequency=440:duration=$(awk -v f=$2 'BEGIN{print f/24}')" \
      -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 \
      "$MONT/$1.mp4" 2>/dev/null
  done
  printf '02\n' > "$MONT/tramos.txt"
  GUION=$T/cola.guion
  {
    echo "@TIPO informativo"; echo "@ESCENA e"; echo "@AMBIENTE a"; echo "@MUSICA m"
    echo "TOMA|El congreso aprueba hoy la ley de vivienda.|inicio|informativo|frames=90"
    echo "TOMA|El texto fija un tope al alquiler en zonas tensionadas y entra en vigor.|ancla|informativo|frames=192"
  } > "$GUION"

  paso "fundir monta clips de duracion desigual"
  if PUNCH_ALTERNO=1.09 TRANSICION=corte python3 "$RAIZ/produccion/fundir.py" \
       "$MONT" "$T/montado.mp4" > "$T/fundir.log" 2>&1
  then si; else no "$(tail -1 "$T/fundir.log")"; fi

  if [ -s "$T/montado.mp4" ]; then
    paso "el montaje conserva 24 fps"
    FR=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$T/montado.mp4")
    [ "$FR" = "24/1" ] && si || no "r_frame_rate=$FR (el concat dejo una linea de tiempo irregular)"

    paso "los subtitulos se queman al exportar a 1080x1920"
    CUES=$T/cues; mkdir -p "$CUES"
    if VF=$(python3 "$RAIZ/produccion/subtitular.py" "$T/montado.mp4" --guion "$GUION" \
              --salida /dev/null --solo-filtro --dir-textos "$CUES" --alto 1920 2>"$T/subs.err") \
       && SUBS_VF="$VF" bash "$RAIZ/produccion/exportar-reel.sh" "$T/montado.mp4" "$T/reel.mp4" \
              >"$T/export.log" 2>&1
    then si; else no "$(tail -1 "$T/subs.err" "$T/export.log" 2>/dev/null | tail -1)"; fi

    if [ -s "$T/reel.mp4" ]; then
      paso "el reel sale 1080x1920 a 48 kHz"
      WH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T/reel.mp4")
      SR=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$T/reel.mp4")
      [ "$WH" = "1080,1920" ] && [ "$SR" = "48000" ] && si || no "$WH a $SR Hz"
      paso "decodifica entero sin errores"
      [ -z "$(ffmpeg -nostdin -v error -i "$T/reel.mp4" -f null - 2>&1)" ] && si || no "hay errores de decodificacion"
    fi
  fi
fi

echo
echo "═══ $OK pasan · $MAL fallan · $SALT saltados ═══"
[ $MAL -eq 0 ] || echo "    logs en $T"
[ $MAL -eq 0 ]
