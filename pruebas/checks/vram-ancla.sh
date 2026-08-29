#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}
nombre="vram-ancla"
exec 0</dev/null

# ── Por que existe ────────────────────────────────────────────────────────
# El guardian de VRAM corto una toma en el paso 13/20 —893s de GPU— porque el
# presupuesto le habia autorizado mas modelo residente del que cabia. Dos
# causas, las dos aqui fijadas:
#
#  1. vram_arg_trabajo ignoraba si la toma iba ANCLADA. Anclar con --init-img
#     engorda el buffer de computo ~1.7 GB (medido: 9906 MiB la toma limpia
#     contra ~11.6 GB la anclada, ambas con cuda0=4). Pedir lo mismo en los dos
#     casos garantiza que el caso anclado se pase.
#  2. VRAM_COLCHON valia 1024 mientras el guardian exigia mas margen. El
#     presupuesto apuntaba a dejar libre menos de lo que el guardian tolera, asi
#     que el sistema se mataba a si mismo la generacion que el mismo autorizaba.

T=$(mktemp -d /tmp/chk-vram.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# GPU falsa con 20000 MiB libres. Antes eran 12760, pero desde que el
# presupuesto descuenta los 5558 MB que el modelo fija en VRAM, con ese hueco
# ambos casos caen al suelo de 1 GB y el check dejaba de probar la aritmetica:
# solo comprobaba que existe un suelo. Con 20000 los dos valores quedan por
# encima del suelo y la comparacion vuelve a significar algo.
cat > "$T/bin/nvidia-smi" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in
  --query-gpu=memory.free)  echo "20000"; exit 0;;
  --query-gpu=memory.total) echo "24000"; exit 0;;
esac; done
echo "20000"
STUB
chmod +x "$T/bin/nvidia-smi"

fallos=0
lee() { echo "${1#*=}"; }

res=$(PATH="$T/bin:$PATH" bash -c ". '$RAIZ/lib/vram.sh'
  echo \"limpia=\$(vram_arg_trabajo 0 345 736 416 0)\"
  echo \"anclada=\$(vram_arg_trabajo 0 345 736 416 1)\"
  echo \"colchon=\$VRAM_COLCHON\"" 2>&1)

lim=$(printf '%s' "$res" | sed -n 's/^limpia=cuda0=//p')
anc=$(printf '%s' "$res" | sed -n 's/^anclada=cuda0=//p')
col=$(printf '%s' "$res" | sed -n 's/^colchon=//p')

if ! [[ "$lim" =~ ^[0-9]+$ ]] || ! [[ "$anc" =~ ^[0-9]+$ ]]; then
  echo "FALLA $nombre: no pude leer el presupuesto. Salida:"; printf '%s\n' "$res" | sed 's/^/    /'
  exit 1
fi

# 1. La ruta anclada tiene que pedir ESTRICTAMENTE menos modelo residente.
# Anclar engorda el buffer ~1.7 GB, asi que tiene que pedir MENOS modelo
# residente. Unica excepcion legitima: que las dos hayan tocado el suelo de 1 GB,
# porque por debajo de ahi no se puede bajar.
if [ "$anc" -gt "$lim" ]; then
  echo "FALLA $nombre: anclada pide cuda0=$anc y limpia cuda0=$lim: anclar no puede pedir MAS."
  fallos=1
elif [ "$anc" -eq "$lim" ] && [ "$anc" -ne 1 ]; then
  echo "FALLA $nombre: anclada y limpia piden lo mismo (cuda0=$anc) sin estar en el suelo."
  echo "    Anclar engorda el buffer ~1.7 GB: tiene que pedir menos."
  fallos=1
fi

# 1b. El presupuesto tiene que descontar lo que el modelo fija en VRAM.
# sd-cli reserva ~5558 MB pase lo que pase (lo dice su log: "total params memory
# size = 35398.76MB (VRAM 5558.09MB, ...)"). Ignorarlo hacia repartir memoria que
# no existe: pedia cuda0=4 con sitio para cero y sd-cli abortaba con
# "cudaMalloc failed: out of memory". Con 20000 libres, techo 0.80 -> 16000, y
# un buffer de 345f a 736x416 de ~5.9 GB, el modelo NO puede superar
# (16000 - 5915 - 5558)/1024 = 4 GB. Sin el descuento saldrian 9.
techo_esperado=$(( (16000 - 5915 - 5558) / 1024 ))
if [ "$lim" -gt "$techo_esperado" ]; then
  echo "FALLA $nombre: limpia pide cuda0=$lim, mas de $techo_esperado."
  echo "    Parece que no se descuentan los ~5558 MB que el modelo fija en VRAM."
  fallos=1
fi

# 2. El colchon no puede quedarse por debajo del margen que exige el guardian.
#    1536 MiB es el suelo: el guardian corto al ver 1155 libres.
if [ "${col:-0}" -lt 1536 ]; then
  echo "FALLA $nombre: VRAM_COLCHON=$col es menor que el margen del guardian."
  echo "    Con un colchon por debajo del umbral, el guardian mata la generacion"
  echo "    que el propio presupuesto autorizo."
  fallos=1
fi

# 3. Ninguno de los dos puede ser absurdo (0 o negativo colado como cadena).
for v in "$lim" "$anc"; do
  [ "$v" -ge 1 ] || { echo "FALLA $nombre: presupuesto invalido '$v'"; fallos=1; }
done

[ $fallos -eq 0 ] && echo "ok $nombre (limpia=$lim anclada=$anc colchon=$col)"
exit $fallos
