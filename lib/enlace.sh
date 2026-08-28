#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  ENLACE — rompe la realimentacion que acartona la imagen.
#
#  El ultimo frame de un plano se pasa como --init-img del siguiente. Ese frame
#  ya lleva el realce que el modelo aplico, y el modelo vuelve a realzar encima:
#  fotocopiar una fotocopia. Medido sobre existencialismo-4p, el exceso de
#  energia de borde sobre el primer frame del primer plano crece monotono:
#      last01 +3.2%   last02 +8.5%   last03 +13.5%   last04 +21.1%
#  y con el, la nota del montaje cae de 95 (un plano) a 68.8 (cuatro).
#
#  LIMITE MEDIDO MIRANDO LA IMAGEN, no solo el numero. Escalera de sigma sobre
#  last04 (+21.1%), recorte del ojo y la barba:
#      0.20 -> +20.8%  detalle intacto
#      0.35 -> +19.5%  ULTIMO PUNTO SANO
#      0.50 -> +17.2%  la barba empieza a fundirse
#      0.80 -> +12.0%  masa borrosa
#      1.47 ->  -0.1%  papilla: clava el numero y destruye la imagen
#  Igualar la energia de borde contra OTRA imagen distinta no es deshacer el
#  realce: se lleva por delante el detalle legitimo. Por eso SIGMA_MAX=0.35 y
#  la funcion se NIEGA a corregir mas, devolviendo 2 para que quien llama sepa
#  que ahi la respuesta es reanclar, no desenfocar.
#
#  Uso:  . lib/enlace.sh
#        enlace_bordes  <png>
#        enlace_sigma   <png> <bordes_referencia> [tolerancia_%]
#        enlace_limpiar <png_in> <png_out> <bordes_referencia> [tolerancia_%]
# ═══════════════════════════════════════════════════════════════════════════

# Energia de borde estructural. MISMA medida que evaluar2.bordes_estr(), para
# que el numero sea comparable con el que produce el auditor.
enlace_bordes() {
  ffmpeg -nostdin -v error -i "$1" -vf "format=gray,gblur=sigma=1.3,sobel" \
         -f rawvideo - 2>/dev/null \
    | od -An -tu1 -v | awk '{for(i=1;i<=NF;i++){s+=$i;n++}} END{if(n)printf "%.4f", s/n; else print "0"}'
}

# Filtro de correccion. UN solo sitio, para que la biseccion y la aplicacion
# usen exactamente el mismo, o el resultado no coincide con lo buscado.
# OJO: en un PNG el espacio es RGB, donde planes=1 es el canal ROJO, no la luma.
# Hay que pasar por yuv444p para que planes=1 sea Y y planes=6 sean U+V.
# El croma se corrige 1.6x mas: la aberracion cromatica es el artefacto visible
# y desenfocar croma es imperceptible, mientras que pasarse con la luma acartona
# en la direccion contraria (blando).
_enlace_filtro() {
  awk -v s="$1" 'BEGIN{printf "format=yuv444p,gblur=sigma=%.4f:planes=1,gblur=sigma=%.4f:planes=6,format=rgb24", s, s*1.6}'
}

# Busca por biseccion el sigma que deja los bordes dentro de la tolerancia.
# Devuelve 0 si el frame ya esta limpio: nunca emborrona de mas.
# Tope duro: por encima de esto el desenfoque destruye detalle real (ver cabecera).
ENLACE_SIGMA_MAX=${ENLACE_SIGMA_MAX:-0.35}

enlace_sigma() {
  local png=$1 ref=$2 tol=${3:-5}
  local b0; b0=$(enlace_bordes "$png")
  awk -v b="$b0" -v r="$ref" -v t="$tol" 'BEGIN{exit !(r>0 && 100*(b-r)/r <= t)}' && { echo "0"; return 0; }
  local lo=0 hi=3 mid tmp bm i
  tmp=$(mktemp --suffix=.png)
  for i in 1 2 3 4 5 6 7 8; do
    mid=$(awk -v l="$lo" -v h="$hi" 'BEGIN{printf "%.4f",(l+h)/2}')
    ffmpeg -nostdin -v error -y -i "$png" -vf "$(_enlace_filtro "$mid")" "$tmp" 2>/dev/null
    bm=$(enlace_bordes "$tmp")
    # demasiados bordes todavia -> mas desenfoque; ya por debajo -> menos
    if awk -v b="$bm" -v r="$ref" 'BEGIN{exit !(b>r)}'; then lo=$mid; else hi=$mid; fi
  done
  rm -f "$tmp"
  awk -v l="$lo" -v h="$hi" 'BEGIN{printf "%.3f",(l+h)/2}'
}

# Aplica la correccion. El croma se corrige MAS que la luma: la aberracion
# cromatica es el artefacto visible y desenfocar croma es imperceptible al ojo,
# mientras que pasarse con la luma acartona en la direccion contraria (blando).
enlace_limpiar() {
  local in=$1 out=$2 ref=$3 tol=${4:-5}
  local s b0 b1
  b0=$(enlace_bordes "$in")
  s=$(enlace_sigma "$in" "$ref" "$tol")
  if [ "$s" = "0" ]; then
    cp "$in" "$out"
    echo "  enlace: bordes $b0 ya dentro del ${tol}% de $ref, no se toca" >&2
    return 0
  fi
  # Si hace falta mas desenfoque del sano, NO se aplica: se avisa y se devuelve 2.
  # Desenfocar hasta clavar el numero deja la cara sin poro ni pelo de barba.
  if awk -v s="$s" -v m="$ENLACE_SIGMA_MAX" 'BEGIN{exit !(s>m)}'; then
    cp "$in" "$out"
    echo "  enlace: harian falta sigma $s (>$ENLACE_SIGMA_MAX) para bajar bordes $b0 a $ref." >&2
    echo "          NO se aplica: destruiria detalle real. Aqui toca REANCLAR." >&2
    return 2
  fi
  ffmpeg -nostdin -v error -y -i "$in" -vf "$(_enlace_filtro "$s")" "$out" 2>/dev/null || return 1
  b1=$(enlace_bordes "$out")
  echo "  enlace: bordes $b0 -> $b1 (referencia $ref, sigma $s)" >&2
}
