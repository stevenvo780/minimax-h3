#!/bin/bash
# EXPERIMENTO DE UN SOLO USO: atado a la toma concreta en $MD/old/toma-larga-aberracion-*
# NO es parte de la pipeline reutilizable. Se ejecuta una sola vez contra un archivo específico.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib/comun.sh"

# Comprobación de argumento de salida
if [ -z "${1:-}" ]; then
  echo "Uso: $0 <fichero_salida.mp4>" >&2
  exit 1
fi

AR=$(ls -d $MD/old/toma-larga-aberracion-* 2>/dev/null | head -1)
if [ -z "$AR" ] || [ ! -d "$AR" ]; then
  echo "Error: no se encontró directorio $MD/old/toma-larga-aberracion-*" >&2
  exit 1
fi

T=/tmp/g4; rm -rf $T; mkdir -p $T
# vídeo: ITER2 (sin grano en p01) pero con gblur real en vez de unsharp saturado
# Valores calibrados por iteraciones medidas del autor — NO cambiar
declare -A N=( [p01]=4 [p02]=6    [p03]=9    [p04]=12   [p05]=15   [p06]=18 )
declare -A L=( [p01]=0 [p02]=0.20 [p03]=0.45 [p04]=0.75 [p05]=1.35 [p06]=2.20 )
declare -A C=( [p01]=0 [p02]=0.45 [p03]=0.85 [p04]=1.30 [p05]=1.90 [p06]=2.60 )
for b in p01 p02 p03 p04 p05 p06; do
  n="${N[$b]}"; l="${L[$b]}"; c="${C[$b]}"
  if [ "$l" = "0" ] && [ "$n" = "0" ]; then F="null"
  elif [ "$l" = "0" ]; then F="noise=c0s=${n}:c0f=t+u"
  else F="gblur=sigma=${l}:planes=1,gblur=sigma=${c}:planes=6,noise=c0s=${n}:c0f=t+u"; fi
  ff -y -v error -i "$AR/$b.avi" -vf "$F" \
    -c:v libx264 -preset slow -crf 15 -pix_fmt yuv420p -c:a aac -b:a 192k "$T/$b.mp4" || exit 1
  echo "file '$T/$b.mp4'" >> "$T/lista.txt"
done
ff -y -v error -f concat -safe 0 -i "$T/lista.txt" -c copy "$T/base.mp4"
# audio: el de ITER3, que dio 4.85 dB
IN="$T/base.mp4"; DUR=$(ffp -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$IN")
ff -y -v error -i "$IN" -vn \
  -af "highpass=f=230,acompressor=threshold=-30dB:ratio=12:attack=10:release=180,loudnorm=I=-21:TP=-2:LRA=1" \
  -c:a pcm_s16le "$T/voz.wav"
ff -y -v error \
  -f lavfi -t "$DUR" -i "sine=frequency=98:sample_rate=32000" \
  -f lavfi -t "$DUR" -i "sine=frequency=147:sample_rate=32000" \
  -f lavfi -t "$DUR" -i "anoisesrc=color=brown:sample_rate=32000:amplitude=0.30" \
  -f lavfi -t "$DUR" -i "anoisesrc=color=white:sample_rate=32000:amplitude=0.042" \
  -filter_complex "[0:a]volume=0.34[a];[1:a]volume=0.17[b];[2:a]volume=1.0[c];[3:a]volume=1.0[d];\
[a][b][c][d]amix=inputs=4:normalize=0,afade=t=in:st=0:d=2,afade=t=out:st=$(awk "BEGIN{print $DUR-2}"):d=2,aformat=channel_layouts=stereo" \
  -c:a pcm_s16le "$T/lecho.wav"
ff -y -v error -i "$T/voz.wav" -i "$T/lecho.wav" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-17:TP=-1.5:LRA=3" -c:a pcm_s16le "$T/mix.wav"
ff -y -v error -i "$IN" -i "$T/mix.wav" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k "$1"
