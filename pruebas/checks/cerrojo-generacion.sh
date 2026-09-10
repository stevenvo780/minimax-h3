#!/bin/bash
set -u
NOMBRE="cerrojo-generacion"
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

fallar() { echo "FALLA $NOMBRE: $1"; exit 1; }
command -v flock >/dev/null 2>&1 || fallar "falta flock"

WORK=$(mktemp -d /tmp/cerrojo-generacion.XXXXXX) || fallar "no se pudo crear tmpdir"
PIDS=()
limpiar() {
  local pid
  [ ! -d "$WORK/estado" ] || : > "$WORK/estado/libera-uno"
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap limpiar EXIT

mkdir -p "$WORK/bin" "$WORK/compat" "$WORK/cuda" "$WORK/estado" \
  "$WORK/salidas con espacios"
: > "$WORK/cuda/libcudart.so.13"
printf '%s\n' "$WORK/cuda" > "$WORK/compat/cuda.path"

# Stub estricto: valida que la CLI publica llegue intacta, comprueba que stdin
# sea /dev/null y usa mkdir como detector atomico de solapamiento.
cat > "$WORK/bin/sd-cli" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--help" ] && exit 0

esperados=(
  -M vid_gen
  --diffusion-model "$STUB_ROOT/modelos/diffusion_models/minimax_h3_fl2va_pruned-Q4_K_M.gguf"
  --vae "$STUB_ROOT/modelos/vae/minimax_h3_video_vae_fp16.safetensors"
  --audio-vae "$STUB_ROOT/modelos/vae/minimax_h3_audio_vae_fp32.safetensors"
  --llm "$STUB_ROOT/modelos/text_encoders/qwen3vl_32b_minimax_h3-Q4_K_M.gguf"
  -p "$STUB_EXPECT_PROMPT"
  --cfg-scale 1.0 -W 1376 -H 768 --fps 24
  --video-frames 107 --steps 20
  --diffusion-fa --rng cpu
  --backend 'diffusion=CUDA0,te=cpu,vae=CUDA0'
  --params-backend diffusion=cpu
  --max-vram cuda0=2 --stream-layers
  -o "$STUB_EXPECT_OUT"
  -s "$STUB_EXPECT_SEED" --init-img "$STUB_EXPECT_IMG"
)
actuales=("$@")
[ "${#actuales[@]}" -eq "${#esperados[@]}" ] || {
  echo "stub: argc=${#actuales[@]}, esperado=${#esperados[@]}" >&2
  exit 61
}
for i in "${!esperados[@]}"; do
  [ "${actuales[$i]}" = "${esperados[$i]}" ] || {
    printf 'stub: argv[%s]=%q, esperado=%q\n' \
      "$i" "${actuales[$i]}" "${esperados[$i]}" >&2
    exit 62
  }
done
if IFS= read -r inesperada; then
  echo "stub: sd-cli recibio stdin: '$inesperada'" >&2
  exit 65
fi

if ! mkdir "$STUB_STATE/activo" 2>/dev/null; then
  printf '%s\n' "$STUB_ID" > "$STUB_STATE/SOLAPAMIENTO"
  exit 90
fi
trap 'rmdir "$STUB_STATE/activo" 2>/dev/null || true' EXIT
printf 'inicio:%s\n' "$STUB_ID" >> "$STUB_STATE/eventos"
printf 'stdout:%s\n' "$STUB_ID"
printf 'stderr:%s\n' "$STUB_ID" >&2
: > "$STUB_STATE/entro-$STUB_ID"

if [ "$STUB_ID" = uno ]; then
  n=0
  while [ ! -e "$STUB_STATE/libera-uno" ] && [ "$n" -lt 1000 ]; do
    sleep 0.01
    n=$((n+1))
  done
  [ -e "$STUB_STATE/libera-uno" ] || exit 66
fi

printf 'fin:%s\n' "$STUB_ID" >> "$STUB_STATE/eventos"
exit "$STUB_RC"
STUB
chmod +x "$WORK/bin/sd-cli"

esperar_archivo() {
  local archivo=$1 n=0
  while [ ! -e "$archivo" ] && [ "$n" -lt 500 ]; do
    sleep 0.01
    n=$((n+1))
  done
  [ -e "$archivo" ]
}

esperar_patron() {
  local archivo=$1 patron=$2 n=0
  while ! grep -qF "$patron" "$archivo" 2>/dev/null && [ "$n" -lt 500 ]; do
    sleep 0.01
    n=$((n+1))
  done
  grep -qF "$patron" "$archivo" 2>/dev/null
}

lanza() { # <id> <rc> <seed>
  local id=$1 rc_stub=$2 seed=$3
  (
    prompt=$(printf 'prompt %s con espacios\nsegunda linea' "$id")
    salida="$WORK/salidas con espacios/$id clip.mp4"
    export MD="$WORK" COMPAT_DIR="$WORK/compat" CERROJO="$WORK/generacion.lock"
    export STUB_STATE="$WORK/estado" STUB_ID="$id" STUB_RC="$rc_stub"
    export STUB_ROOT="$WORK" STUB_EXPECT_PROMPT="$prompt" STUB_EXPECT_OUT="$salida"
    export STUB_EXPECT_SEED="$seed" STUB_EXPECT_IMG="$WORK/imagen inicial.png"
    unset COMPAT_LISTO H3_LIB_LISTA SDCLI SD_VID_GEN_ESPERA W H FRAMES STEPS
    unset FPS CFG BACKEND PARAMS_BACKEND MAXVRAM MODELO_DIFF
    . "$RAIZ/lib/comun.sh"
    printf 'esto no debe llegar a sd-cli\n' |
      sd_vid_gen "$prompt" "$salida" -s "$seed" --init-img "$STUB_EXPECT_IMG" \
        > "$WORK/$id.stdout" 2> "$WORK/$id.stderr"
    printf '%s\n' "$?" > "$WORK/$id.rc"
  ) &
  PIDS+=("$!")
}

# El primero mantiene el runner dentro del tramo critico. El segundo llega al
# flock antes de liberarlo: asi la concurrencia no depende de tiempos casuales.
lanza uno 0 101
PID_UNO=${PIDS[0]}
esperar_archivo "$WORK/estado/entro-uno" || fallar "el primer proceso no entro al stub"

lanza dos 37 202
PID_DOS=${PIDS[1]}
esperar_patron "$WORK/dos.stderr" "cerrojo: hay otra generacion en curso" || \
  fallar "el segundo proceso no llego a esperar el cerrojo"
kill -0 "$PID_UNO" 2>/dev/null || fallar "el primero termino antes de la liberacion controlada"
kill -0 "$PID_DOS" 2>/dev/null || fallar "el segundo no permanecio bloqueado"
[ ! -e "$WORK/estado/entro-dos" ] || fallar "el segundo entro antes de liberar el primero"

: > "$WORK/estado/libera-uno"
wait "$PID_UNO" || fallar "fallo el proceso contenedor uno"
wait "$PID_DOS" || fallar "fallo el proceso contenedor dos"
PIDS=()

[ ! -e "$WORK/estado/SOLAPAMIENTO" ] || fallar "dos sd-cli se solaparon"
EVENTOS=$(cat "$WORK/estado/eventos")
ESPERADOS=$(printf 'inicio:uno\nfin:uno\ninicio:dos\nfin:dos')
[ "$EVENTOS" = "$ESPERADOS" ] || fallar "orden no serial: $(printf '%s' "$EVENTOS" | tr '\n' ' ')"
[ "$(cat "$WORK/uno.rc")" = 0 ] || fallar "rc del primer sd-cli no se conservo"
[ "$(cat "$WORK/dos.rc")" = 37 ] || fallar "rc=37 del segundo sd-cli no se conservo"
[ "$(cat "$WORK/uno.stdout")" = "stdout:uno" ] || fallar "stdout del primero cambio"
[ "$(cat "$WORK/uno.stderr")" = "stderr:uno" ] || fallar "stderr del primero cambio"
[ "$(cat "$WORK/dos.stdout")" = "stdout:dos" ] || fallar "stdout del segundo cambio"
ERR_DOS=$(printf 'cerrojo: hay otra generacion en curso, espero mi turno\nstderr:dos')
[ "$(cat "$WORK/dos.stderr")" = "$ERR_DOS" ] || fallar "stderr del segundo cambio"

# Una envoltura externa existente o futura no debe auto-bloquearse: el con_cerrojo
# interior reconoce que este mismo BASHPID ya posee exactamente la misma ruta.
mkdir -p "$WORK/anidado"
(
  export MD="$WORK" COMPAT_DIR="$WORK/compat" CERROJO="$WORK/anidado.lock"
  export STUB_STATE="$WORK/anidado" STUB_ID=anidado STUB_RC=23
  export STUB_ROOT="$WORK" STUB_EXPECT_PROMPT=$'prompt anidado\nsegunda linea'
  export STUB_EXPECT_OUT="$WORK/salidas con espacios/anidado clip.mp4"
  export STUB_EXPECT_SEED=303 STUB_EXPECT_IMG="$WORK/imagen inicial.png"
  unset COMPAT_LISTO H3_LIB_LISTA SDCLI W H FRAMES STEPS FPS CFG BACKEND
  unset PARAMS_BACKEND MAXVRAM MODELO_DIFF
  . "$RAIZ/lib/comun.sh"
  SD_VID_GEN_ESPERA=0
  printf 'esto tampoco debe llegar\n' |
    con_cerrojo 2 sd_vid_gen "$STUB_EXPECT_PROMPT" "$STUB_EXPECT_OUT" \
      -s 303 --init-img "$STUB_EXPECT_IMG" \
      > "$WORK/anidado.stdout" 2> "$WORK/anidado.stderr"
  printf '%s\n' "$?" > "$WORK/anidado.rc"
)
[ "$(cat "$WORK/anidado.rc")" = 23 ] || fallar "el cerrojo anidado altero rc=23 o se autobloqueo"
[ "$(cat "$WORK/anidado.stdout")" = "stdout:anidado" ] || fallar "stdout anidado cambio"
[ "$(cat "$WORK/anidado.stderr")" = "stderr:anidado" ] || fallar "stderr anidado cambio"

# El timeout configurable falla cerrado: con cero segundos no entra al stub.
mkdir -p "$WORK/timeout"
exec {FD_OCUPADO}>"$WORK/timeout.lock" || fallar "no se pudo abrir el lock de timeout"
flock "$FD_OCUPADO" || fallar "no se pudo ocupar el lock de timeout"
(
  export MD="$WORK" COMPAT_DIR="$WORK/compat" CERROJO="$WORK/timeout.lock"
  export STUB_STATE="$WORK/timeout" STUB_ID=timeout STUB_RC=0
  export STUB_EXPECT_OUT="$WORK/timeout.mp4" STUB_EXPECT_SEED=404
  unset COMPAT_LISTO H3_LIB_LISTA SDCLI
  . "$RAIZ/lib/comun.sh"
  SD_VID_GEN_ESPERA=0
  sd_vid_gen prompt-timeout "$WORK/timeout.mp4" -s 404 \
    > "$WORK/timeout.stdout" 2> "$WORK/timeout.stderr"
  printf '%s\n' "$?" > "$WORK/timeout.rc"
)
# El escalado usa exactamente el mismo recurso; no puede entrar por una API
# secundaria mientras vid_gen u otra obra retienen el lock global.
(
  export MD="$WORK" COMPAT_DIR="$WORK/compat" CERROJO="$WORK/timeout.lock"
  unset COMPAT_LISTO H3_LIB_LISTA SDCLI
  . "$RAIZ/lib/comun.sh"
  SD_UPSCALE_ESPERA=0
  sd_upscale "$WORK/entrada.png" "$WORK/salida.png" CUDA1 \
    > "$WORK/upscale-timeout.stdout" 2> "$WORK/upscale-timeout.stderr"
  printf '%s\n' "$?" > "$WORK/upscale-timeout.rc"
)
# El escalador paralelo usa llamadas internas directas, pero antes reserva el
# trabajo completo. Con el recurso ocupado debe fallar antes incluso de probar
# el fichero con ffprobe o tocar una GPU.
: > "$WORK/video-falso.mp4"
MD="$RAIZ" CERROJO="$WORK/timeout.lock" \
  bash "$RAIZ/produccion/escalar.sh" "$WORK/video-falso.mp4" \
  > "$WORK/escalar-timeout.stdout" 2> "$WORK/escalar-timeout.stderr"
printf '%s\n' "$?" > "$WORK/escalar-timeout.rc"
flock -u "$FD_OCUPADO" || true
exec {FD_OCUPADO}>&- || true
[ "$(cat "$WORK/timeout.rc")" = 1 ] || fallar "timeout=0 no devolvio rc=1"
[ "$(cat "$WORK/upscale-timeout.rc")" = 1 ] \
  || fallar "sd_upscale no respeto el mismo cerrojo global"
[ "$(cat "$WORK/escalar-timeout.rc")" = 1 ] \
  || fallar "escalar.sh no reservo el cerrojo antes de su paralelismo interno"
[ ! -e "$WORK/timeout/entro-timeout" ] || fallar "timeout=0 lanzo sd-cli sin poseer el cerrojo"
ERR_TIMEOUT=$(printf '%s\n%s' \
  "cerrojo: hay otra generacion en curso, espero mi turno" \
  "cerrojo: otra generacion lleva mas de 0s ocupando el turno")
[ "$(cat "$WORK/timeout.stderr")" = "$ERR_TIMEOUT" ] || fallar "diagnostico de timeout inesperado"

# Una configuracion mal escrita tampoco puede degradar a ejecucion sin lock.
mkdir -p "$WORK/invalido"
(
  export MD="$WORK" COMPAT_DIR="$WORK/compat" CERROJO="$WORK/invalido.lock"
  export STUB_STATE="$WORK/invalido" STUB_ID=invalido STUB_RC=0
  export STUB_EXPECT_OUT="$WORK/invalido.mp4" STUB_EXPECT_SEED=505
  unset COMPAT_LISTO H3_LIB_LISTA SDCLI
  . "$RAIZ/lib/comun.sh"
  SD_VID_GEN_ESPERA=no-es-un-numero
  sd_vid_gen prompt-invalido "$WORK/invalido.mp4" -s 505 \
    > "$WORK/invalido.stdout" 2> "$WORK/invalido.stderr"
  printf '%s\n' "$?" > "$WORK/invalido.rc"
)
[ "$(cat "$WORK/invalido.rc")" = 2 ] || fallar "un timeout invalido no devolvio rc=2"
[ ! -e "$WORK/invalido/entro-invalido" ] || fallar "un timeout invalido lanzo sd-cli"
ERR_INVALIDO="cerrojo: el tiempo de espera debe ser un entero no negativo (recibido: 'no-es-un-numero')"
[ "$(cat "$WORK/invalido.stderr")" = "$ERR_INVALIDO" ] || fallar "diagnostico de timeout invalido inesperado"

# El runner sin lock es una pieza interna, no una segunda API de generacion.
FUGAS=$(grep -rIl --include='*.sh' '_sd_vid_gen_ejecutar' "$RAIZ" 2>/dev/null \
  | grep -vFx "$RAIZ/lib/comun.sh" \
  | grep -vFx "$RAIZ/pruebas/checks/cerrojo-generacion.sh" || true)
[ -z "$FUGAS" ] || fallar "el runner privado se usa fuera de comun.sh: $(printf '%s' "$FUGAS" | tr '\n' ' ')"

# Las únicas tandas que necesitan saltar el wrapper por su paralelismo interno
# tienen que demostrar una reserva de obra completa en el mismo script.
while IFS= read -r candidato; do
  [ "$candidato" = "$RAIZ/lib/comun.sh" ] && continue
  [ "$candidato" = "$RAIZ/pruebas/checks/cerrojo-generacion.sh" ] && continue
  grep -q 'reservar_generacion_completa' "$candidato" \
    || fallar "entrada upscale directa sin reserva global: $candidato"
done < <(grep -rIl --include='*.sh' -e '_sd_upscale_ejecutar' -e '-M upscale' \
  "$RAIZ/produccion" "$RAIZ/herramientas" 2>/dev/null || true)

echo "PASA $NOMBRE (exclusion, CLI, rc, redirecciones, reentrada y timeout)"
