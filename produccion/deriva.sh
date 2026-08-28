#!/bin/bash
# Diagnostico de una cadena encadenada:
#  UNION  = ultimo frame de pN vs primer frame de p(N+1)  -> fidelidad del enlace
#  DERIVA = histograma de color de pN vs p01              -> el personaje/escena muta?
MD=/home/stev/Modelos-IA/minimax-h3
OBRA=$MD/produccion/obra/${1:-existencialismo}
T=$(mktemp -d); trap 'rm -rf $T' EXIT
ult() { ffmpeg -y -v error -sseof -0.05 -i "$1" -frames:v 1 -update 1 "$2" 2>/dev/null; }
pri() { ffmpeg -y -v error -i "$1" -frames:v 1 -update 1 "$2" 2>/dev/null; }
psnr(){ ffmpeg -v info -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 | grep -oE "average:[0-9.]+" | head -1 | cut -d: -f2; }
# firma de color: medias RGB del frame (detecta cambio de iluminacion/paleta)
firma(){ ffmpeg -v info -i "$1" -vf "scale=8:8,format=rgb24" -f rawvideo - 2>/dev/null | od -An -tu1 | awk '{for(i=1;i<=NF;i++){s[(i-1)%3]+=$i;n[(i-1)%3]++}} END{printf "%.0f,%.0f,%.0f", s[0]/n[0], s[1]/n[1], s[2]/n[2]}'; }

echo "════ CADENA: $(basename $OBRA) ════"
mapfile -t AVIS < <(ls $OBRA/p*.avi 2>/dev/null)
[ ${#AVIS[@]} -eq 0 ] && { echo "sin planos"; exit 1; }
pri "${AVIS[0]}" $T/base.png; BASE=$(firma $T/base.png)
echo "  enlace          PSNR unión    firma RGB      Δ vs p01"
prev=""
for f in "${AVIS[@]}"; do
  b=$(basename "$f" .avi)
  pri "$f" $T/$b-i.png; ult "$f" $T/$b-u.png
  U="—"
  [ -n "$prev" ] && U=$(psnr $T/$prev-u.png $T/$b-i.png)
  FR=$(firma $T/$b-i.png)
  D=$(python3 -c "
a='$BASE'.split(','); b='$FR'.split(',')
print(f\"{sum(abs(int(x)-int(y)) for x,y in zip(a,b)):3d}\")" 2>/dev/null)
  printf "  %-6s %14s   %-13s  %s\n" "$b" "$U" "$FR" "${D:-?}"
  prev=$b
done
echo
echo "  PSNR unión: >36 dB imperceptible · 30-36 leve · <30 salto visible"
echo "  Δ firma RGB: <15 estable · 15-40 deriva leve · >40 la escena cambió"
