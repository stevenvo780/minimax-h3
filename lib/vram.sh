#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  VRAM — presupuesto ADAPTATIVO, recalculado en caliente.
#
#  Por que sobre lo LIBRE y no sobre el total: el escritorio del usuario ocupa
#  ~3.4 GB de la 5070 Ti. Un techo calculado sobre los 16 GB totales se come su
#  margen y provoca OOM — es exactamente lo que tumbo p05 y p10 en produccion.
#  Y la sobrecorreccion tampoco vale: los scripts quedaron en --max-vram cuda0=2,
#  usando 2 GB de 16.
#
#  Uso:  . lib/vram.sh
#        vram_arg 0          -> "cuda0=9"   para --max-vram
#        vram_esperar 0 6000 -> espera a que haya 6 GB libres
# ═══════════════════════════════════════════════════════════════════════════

VRAM_FRACCION=${VRAM_FRACCION:-0.80}   # del hueco libre, no del total
# MiB que nunca se piden, pase lo que pase. TIENE QUE SER >= el umbral del
# guardian de VRAM, o los dos se pelean: el presupuesto apunta a dejar libre el
# colchon, el guardian exige mas, y mata la generacion que el propio presupuesto
# habia autorizado. Paso de verdad el 2026-08-29: el guardian corto la toma 2 en
# el paso 13/20 (893s de GPU) al ver 1155 MiB libres, con el colchon en 1024.
VRAM_COLCHON=${VRAM_COLCHON:-2048}

_vram_q() {  # $1=idx  $2=campo
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local v; v=$(nvidia-smi -i "$1" --query-gpu="$2" --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  echo "$v"
}

vram_libre() { _vram_q "$1" memory.free  || { echo "vram: no puedo leer la GPU $1" >&2; return 1; }; }
vram_total() { _vram_q "$1" memory.total || { echo "vram: no puedo leer la GPU $1" >&2; return 1; }; }

# MiB que podemos pedir sin comernos el margen del usuario.
vram_techo() {
  local idx=$1 frac=${2:-$VRAM_FRACCION} libre techo
  libre=$(vram_libre "$idx") || return 1
  techo=$(awk -v l="$libre" -v f="$frac" -v c="$VRAM_COLCHON" '
    BEGIN{ t=int(l*f); if (t > l-c) t=l-c; if (t<0) t=0; print t }')
  echo "$techo"
}

# Cadena para --max-vram. sd-cli espera GIGAS: se redondea A LA BAJA.
# Si algo falla devuelve un valor conservador en vez de una cadena vacia, que
# le llegaria a sd-cli como "--max-vram cuda0=" y reventaria de forma opaca.
vram_arg() {
  local idx=$1 techo g
  techo=$(vram_techo "$idx" "${2:-$VRAM_FRACCION}") || { echo "cuda${idx}=2"; return 0; }
  g=$(( techo / 1024 ))
  [ "$g" -lt 1 ] && g=1
  [ "$g" -gt "$VRAM_TOPE_GB" ] && g=$VRAM_TOPE_GB
  echo "cuda${idx}=${g}"
}

# Espera a que se libere sitio en vez de reventar con OOM.
vram_esperar() {
  local idx=$1 need=$2 max=${3:-900} t=0 libre
  while [ "$t" -lt "$max" ]; do
    libre=$(vram_libre "$idx") || return 1
    [ "$libre" -ge "$need" ] && return 0
    sleep 15; t=$((t+15))
  done
  echo "vram: tras ${max}s la GPU $idx sigue sin $need MiB libres" >&2
  return 1
}

vram_informe() {
  local i
  for i in 0 1; do
    local t l h
    t=$(vram_total "$i" 2>/dev/null) || continue
    l=$(vram_libre "$i"); h=$(vram_techo "$i")
    printf "  GPU%d  total %5d  libre %5d  techo %5d MiB  (--max-vram %s)\n" \
      "$i" "$t" "$l" "$h" "$(vram_arg "$i")"
  done
}

# ── Techo consciente del tamaño del trabajo ────────────────────────────────
# Con --stream-layers, --max-vram dice cuanto MODELO se queda en la tarjeta.
# El buffer de computo necesita el resto, y ese buffer crece con frames x pixeles.
# Por eso pedir MAS puede hacer que NO quepa: paso de verdad, 685 frames a
# 736x416 fallaron con cuda0=9 ("alloc compute buffer failed") mientras que el
# material del propio proyecto, 345 frames a la misma resolucion, funcionaba con
# cuda0=2.
#
# Constante calibrada con las corridas medidas:
#   512x288 x  685f  cabe con 8 GB de modelo  -> al buffer le quedaban ~4.5 GB
#   512x288 x 1020f  NO cabe con 8
#   736x416 x  685f  NO cabe con 9
# => el buffer pide del orden de 4.5e-5 MiB por (pixel x frame).
# RECALIBRADO 2026-08-29 con dos corridas medidas de 345f a 736x416 (=105.6 M
# pixel-frame), leyendo el consumo real con nvidia-smi durante la generacion:
#   toma LIMPIA   con cuda0=4 -> 9906 MiB en total => buffer ~5.9 GB => 5.6e-5
#   toma ANCLADA  con cuda0=4 -> ~11.6 GB          => buffer ~7.6 GB => 7.2e-5
# El 4.5e-5 anterior venia de inferir el buffer a partir de que cabia o no cabia,
# no de medirlo, y se quedaba un 25% corto. Con el, el presupuesto autorizaba mas
# modelo del que cabia junto al escritorio.
# MEDIDO 2026-08-29 sobre 12 tomas de 345f a 736x416, cronometradas de verdad:
#   toma limpia   (cuda0=3 y 4) -> 1274, 1276, 1278, 1315 s   media ~1286 s
#   toma anclada  (cuda0=1, 2 y 4) -> 1329, 1338, 1342, 1343 s media ~1338 s
# Es decir: el presupuesto de VRAM NO afecta a la velocidad en esta carga. Pasar
# de cuda0=1 a cuda0=4 no gana un segundo; lo que cuesta es ANCLAR, un ~4%.
# Con --stream-layers el cuello es el computo, no donde vivan los pesos.
#
# Consecuencia practica: pedir poca VRAM sale GRATIS. Ante la duda, pedir menos
# y dejarle mas margen al usuario, que era su unica condicion.
VRAM_MIB_POR_PXFRAME=${VRAM_MIB_POR_PXFRAME:-0.000056}

# Anclar con --init-img engorda el buffer ~1.7 GB sobre la ruta limpia: el frame
# de partida se codifica y se mantiene durante todo el muestreo. No es opcional
# tenerlo en cuenta — es justo lo que tumbo la toma 2.
VRAM_MIB_POR_PXFRAME_ANCLA=${VRAM_MIB_POR_PXFRAME_ANCLA:-0.000072}

# Tope duro del modelo residente. NO es por VRAM: es por RAM.
#
# Con --stream-layers los pesos viven en RAM y --max-vram dice cuanto se cachea
# en la tarjeta. Un presupuesto alto no acelera nada —medido sobre 12 tomas: de
# cuda0=1 a cuda0=4 no se gana un segundo, porque el cuello es el computo— pero
# el cgroup de 24 GB va justo: sd-cli solo necesita ~17 GB y lleva 12 OOM
# acumulados. Con clips CORTOS el buffer es pequeño y la formula llegaba a pedir
# cuda0=7-8, justo cuando aparecieron dos OOM seguidos en la misma toma.
#
# No esta PROBADO que ese cuda0 alto sea la causa: los datos de RSS que tengo se
# contradicen (cuda0=1 dio 16.9 GB y cuda0=4 dio 12.0 GB, pero no eran corridas
# comparables). Como pedir menos NO cuesta velocidad, el tope es un seguro
# gratis: si era eso, lo arregla; si no, no se pierde nada.
# REVERTIDO 2026-08-30. Se descontaba este valor del presupuesto, leyendo del log
# de sd-cli "total params memory size = 35398.76MB (VRAM 5558.09MB, RAM ...)" y
# suponiendo que eran 5.5 GB ADICIONALES al buffer y a la cache. Los datos dicen
# que no:
#   - con el descuento el presupuesto cae a cuda0=1, y con tan poca cache los
#     pesos fluyen por RAM: dos OOM de RAM seguidos en la misma toma a 209
#     fotogramas, que es MENOS trabajo del que ayer salio bien
#   - sin el descuento daba cuda0=2-3 y salieron 16 tomas seguidas a 345
#     fotogramas sin un solo reintento
#   - y si esos 5558 MB fueran de verdad adicionales, lo de ayer no habria
#     cabido nunca: 5558 + 7605 de buffer + 2048 de cache pasan de los 16.3 GB
#     de la tarjeta
# Lo mas plausible es que ese numero YA incluya la cache de --max-vram y yo lo
# estuviera contando dos veces. Se deja la constante definida y documentada, pero
# NO se resta.
VRAM_FIJA_MODELO=${VRAM_FIJA_MODELO:-5558}

VRAM_TOPE_GB=${VRAM_TOPE_GB:-4}

# vram_arg_trabajo <idx> <frames> <W> <H> [anclada]
# Igual que vram_arg pero reservando antes lo que se va a llevar el buffer.
# El quinto argumento, si es 1, usa la constante de la ruta anclada.
vram_arg_trabajo() {
  local idx=$1 frames=$2 w=$3 h=$4 anclada=${5:-0}
  local libre techo buffer modelo g k
  k=$VRAM_MIB_POR_PXFRAME
  [ "$anclada" = 1 ] && k=$VRAM_MIB_POR_PXFRAME_ANCLA
  libre=$(vram_libre "$idx") || { echo "cuda${idx}=2"; return 0; }
  techo=$(vram_techo "$idx") || { echo "cuda${idx}=2"; return 0; }
  buffer=$(awk -v f="$frames" -v w="$w" -v h="$h" -v k="$k" \
           'BEGIN{printf "%d", f*w*h*k}')
  modelo=$(( techo - buffer ))
  g=$(( modelo / 1024 ))
  # Nunca por debajo de 1 GB ni por encima del techo normal: con 1 GB el modelo
  # va casi todo en streaming, que es lento pero cabe siempre.
  [ "$g" -lt 1 ] && g=1
  [ "$g" -gt "$VRAM_TOPE_GB" ] && g=$VRAM_TOPE_GB
  echo "cuda${idx}=${g}"
}
