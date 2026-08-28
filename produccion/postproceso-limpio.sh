#!/bin/bash
set -u
F=/home/stev/Vídeos/existencialismo-4p-736x416-58s-20260827-231735.mp4
T=/tmp/f6; rm -rf $T; mkdir -p $T
SEG=14.375
# croma: corrección progresiva fuerte (imperceptible al ojo)
# luma: MUY conservadora, para no acartonar
declare -a C=(0 0.4 0.9 1.5)
declare -a L=(0 0.18 0.45 0.78)
for i in 0 1 2 3; do
  c="${C[$i]}"; l="${L[$i]}"
  if [ "$c" = "0" ] && [ "$l" = "0" ]; then VF="null"
  elif [ "$l" = "0" ]; then VF="gblur=sigma=${c}:planes=6"
  else VF="gblur=sigma=${l}:planes=1,gblur=sigma=${c}:planes=6"; fi
  ffmpeg -nostdin -y -v error -ss $(awk "BEGIN{print $i*$SEG}") -t $SEG -i "$F" -vf "$VF" \
    -c:v libx264 -preset slow -crf 15 -pix_fmt yuv420p -c:a aac -b:a 192k "$T/s$i.mp4"
done
python3 - "$T" > "$T/cmd.sh" <<'PY'
import sys,subprocess
T=sys.argv[1]; TR=0.25
def d(f): return float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
    "-of","default=noprint_wrappers=1:nokey=1",f],capture_output=True,text=True).stdout)
ds=[d(f"{T}/s{i}.mp4") for i in range(4)]
ins=" ".join(f"-i {T}/s{i}.mp4" for i in range(4))
v,a,off,parts="[0:v]","[0:a]",0.0,[]
for i in range(1,4):
    off+=ds[i-1]-TR
    parts.append(f"{v}[{i}:v]xfade=transition=fade:duration={TR}:offset={off:.4f}[v{i}]")
    parts.append(f"{a}[{i}:a]acrossfade=d={TR}[a{i}]")
    v,a=f"[v{i}]",f"[a{i}]"
print(f'ffmpeg -nostdin -y -v error {ins} -filter_complex "{";".join(parts)}" -map "{v}" -map "{a}" '
      f'-c:v libx264 -preset slow -crf 15 -pix_fmt yuv420p -c:a aac -b:a 192k {T}/base.mp4')
PY
bash "$T/cmd.sh"
ffmpeg -nostdin -y -v error -i "$T/base.mp4" -vn \
  -af "highpass=f=85,acompressor=threshold=-26dB:ratio=2.5:attack=30:release=450,loudnorm=I=-18:TP=-2:LRA=5" \
  -c:a pcm_s16le "$T/a.wav"
ffmpeg -nostdin -y -v error -i "$T/base.mp4" -i "$T/a.wav" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k "$1"
