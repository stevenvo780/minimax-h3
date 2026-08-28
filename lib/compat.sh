#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  COMPAT — hace ejecutable sd-cli en contenedores con userland distinto al
#  de la maquina donde se compilo.
#
#  Dos problemas, dos arreglos, ninguno destructivo:
#
#  1. CUDA 13 no esta instalado en el contenedor, pero SI en los venv de otros
#     proyectos del disco. Se localiza y se añade a LD_LIBRARY_PATH.
#
#  2. sd-cli se compilo contra glibc 2.43 (host Arch) y el contenedor tiene
#     2.39 (Ubuntu 24.04). De 2.43 solo necesita DOS simbolos: atan2f y sqrtf,
#     que existen en glibc desde hace decadas — en 2.43 solo se les asigno una
#     etiqueta de version nueva, sin cambiar su semantica IEEE.
#     Se genera UNA COPIA del binario sin esa exigencia de version. El binario
#     original NUNCA se modifica.
#
#  Uso:  . lib/compat.sh  &&  SDCLI=$(compat_sdcli)
# ═══════════════════════════════════════════════════════════════════════════

compat_cuda() {   # imprime el directorio con libcudart.so.13, o vacio
  # Cacheado: el find es caro y la respuesta no cambia entre corridas.
  local cache=${COMPAT_DIR:-${TMPDIR:-/tmp}/h3-compat}/cuda.path
  if [ -s "$cache" ] && [ -e "$(cat "$cache")/libcudart.so.13" ]; then cat "$cache"; return 0; fi
  local d
  d=$(find /workspace /opt /usr/local -name 'libcudart.so.13' -not -path '*/proc/*' 2>/dev/null | head -1)
  [ -n "$d" ] || return 1
  mkdir -p "$(dirname "$cache")" && dirname "$d" | tee "$cache"
}

compat_sdcli() {  # imprime la ruta al sd-cli utilizable (parcheado si hace falta)
  local orig=${1:-$MD/bin/sd-cli}
  local cache=${COMPAT_DIR:-${TMPDIR:-/tmp}/h3-compat}
  local pat=$cache/sd-cli

  # ¿arranca tal cual? entonces no hay nada que hacer
  if "$orig" --help >/dev/null 2>&1; then echo "$orig"; return 0; fi

  # ¿ya lo parcheamos antes y sigue siendo del mismo binario?
  if [ -x "$pat" ] && [ "$pat" -nt "$orig" ] && "$pat" --help >/dev/null 2>&1; then
    echo "$pat"; return 0
  fi

  mkdir -p "$cache" && cp "$orig" "$pat" || return 1
  python3 - "$pat" >&2 <<'PY' || return 1
import sys, struct
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
if b[:4]!=b'\x7fELF' or b[4]!=2: sys.exit("compat: no es ELF64")
e_shoff,=struct.unpack_from('<Q',b,0x28)
e_shentsize,=struct.unpack_from('<H',b,0x3a); e_shnum,=struct.unpack_from('<H',b,0x3c)
secs=[]
for i in range(e_shnum):
    o=e_shoff+i*e_shentsize
    _,typ,_,_,off,size,link,info,_,_ = struct.unpack_from('<IIQQQQIIQQ',b,o)
    secs.append(dict(type=typ,off=off,link=link,info=info))
vr=[s for s in secs if s['type']==0x6ffffffe]
if not vr: sys.exit("compat: sin .gnu.version_r")
vr=vr[0]; ds=secs[vr['link']]
def s_(x):
    e=b.index(b'\0',ds['off']+x); return b[ds['off']+x:e].decode()
# quita toda exigencia de version glibc mas nueva que la que tiene el sistema
import subprocess,re
have=subprocess.run(['ldd','--version'],capture_output=True,text=True).stdout
mx=tuple(int(v) for v in re.search(r'(\d+)\.(\d+)',have).groups())
quitados=[]; pos=vr['off']
for _ in range(vr['info']):
    _,cnt,file_off,aux_off,next_off = struct.unpack_from('<HHIII',b,pos)
    a=pos+aux_off; prev=None; i=0
    while i<cnt:
        _,_,_,name,anext = struct.unpack_from('<IHHII',b,a)
        nm=s_(name); m=re.fullmatch(r'GLIBC_(\d+)\.(\d+)',nm)
        if m and tuple(int(v) for v in m.groups())>mx:
            if prev is None: struct.pack_into('<I',b,pos+8,(aux_off+anext) if anext else 0)
            else:            struct.pack_into('<I',b,prev+12,(a+anext-prev) if anext else 0)
            cnt-=1; struct.pack_into('<H',b,pos+2,cnt); quitados.append(nm)
            if not anext: break
            a+=anext; continue
        prev=a
        if not anext: break
        a+=anext; i+=1
    if not next_off: break
    pos+=next_off
open(p,'wb').write(b)
print(f"compat: exigencias de version eliminadas del binario copiado: {', '.join(quitados) or 'ninguna'}")
PY
  chmod +x "$pat"; echo "$pat"
}

# Al sourcear, deja el entorno listo.
_cu=$(compat_cuda) && export LD_LIBRARY_PATH="$_cu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset _cu
