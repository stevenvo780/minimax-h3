#!/bin/bash
RAIZ=${RAIZ:-/workspace/GeneracionDeVideos/minimax-h3}

nombre="nostdin"
# RAIZ = arbol bajo prueba. REPO = repo git de donde se lee el control
# historico 478960b (por defecto el propio RAIZ). Se separan para poder
# apuntar RAIZ a una copia volcada fuera del repo sin perder el control.
REPO=${REPO:-$RAIZ}
exec 0</dev/null   # el check nunca debe comerse el stdin de quien lo llama

[ -f "$RAIZ/produccion/producir.sh" ] || { echo "FALLA $nombre: no existe $RAIZ/produccion/producir.sh"; exit 1; }
[ -f "$RAIZ/produccion/preview.sh" ]  || { echo "FALLA $nombre: no existe $RAIZ/produccion/preview.sh"; exit 1; }

CHK_TMP=$(mktemp -d /tmp/chk-nostdin.XXXXXX) || { echo "FALLA $nombre: no pude crear tmpdir"; exit 1; }
trap 'rm -rf "$CHK_TMP"' EXIT

# ── ffmpeg falso ─────────────────────────────────────────────────────────
# Imita el rasgo peligroso del ffmpeg real: sin -nostdin, ffmpeg deja un hilo
# de control de teclado leyendo del stdin heredado, y eso le roba lineas al
# "while read" que lo invoca cuando ese stdin es el pipe de una process
# substitution. El stub reproduce el efecto observable: sin -nostdin consume
# una linea del stdin heredado; con -nostdin no toca stdin. En ambos casos
# crea el fichero de salida (ultimo argumento), como hace ffmpeg de verdad.
mkdir -p "$CHK_TMP/bin"
cat > "$CHK_TMP/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
nostdin=0; last=""
for a in "$@"; do
  [ "$a" = "-nostdin" ] && nostdin=1
  last=$a
done
[ "$nostdin" -eq 1 ] || IFS= read -r -t 2 _eaten <&0 2>/dev/null
[ -n "$last" ] && : > "$last"
exit 0
STUB
chmod +x "$CHK_TMP/bin/ffmpeg"
export PATH="$CHK_TMP/bin:$PATH"

FRAMES=107   # lo usa el fallback de ultimo_frame: -vf select=eq(n,FRAMES-1)

# comun.sh define ff(). Si falta, ff queda indefinido a proposito: la asercion
# "cada vuelta produjo su fichero" lo caza (un ff inexistente no genera nada).
COMUN_AVISO=""
if [ -f "$RAIZ/lib/comun.sh" ]; then
  . "$RAIZ/lib/comun.sh" 2>/dev/null || COMUN_AVISO=" [aviso: lib/comun.sh no se pudo sourcear]"
else
  COMUN_AVISO=" [aviso: no existe $RAIZ/lib/comun.sh, ff() sin definir]"
fi

# extrae_fn <fichero> <nombre_fn>  -> cuerpo de la funcion tal cual esta hoy
extrae_fn() { awk -v fn="^$2\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f{print} f && /^}/{exit}' "$1"; }

# ═══ A) producir.sh :: ultimo_frame() dentro del while-read ═══════════════
guion_sintetico() {
  printf 'HABLA|dialogo uno||\n'
  printf 'HABLA|dialogo dos||\n'
  printf 'HABLA|dialogo tres||\n'
  printf 'HABLA|dialogo cuatro||\n'
  printf 'HABLA|dialogo cinco||\n'
}

# Reproduce el patron de producir.sh: while-read sobre process substitution
# llamando a ultimo_frame() en cada vuelta. Devuelve "<lineas> <ficheros>":
# lineas del guion que sobrevivieron, y salidas realmente producidas (si
# ultimo_frame no genera nada, no vale como "no perdio lineas").
correr_bucle() {
  local n=0 hechos=0 i
  rm -f "$CHK_TMP"/out_*.png
  while IFS='|' read -r TIPO CONT MODO ENCU; do
    n=$((n+1))
    ultimo_frame "$CHK_TMP/in_$n.avi" "$CHK_TMP/out_$n.png"
  done < <(guion_sintetico)
  for i in "$CHK_TMP"/out_*.png; do [ -f "$i" ] && hechos=$((hechos+1)); done
  echo "$n $hechos"
}

POST_SRC=$(extrae_fn "$RAIZ/produccion/producir.sh" ultimo_frame)
[ -n "$POST_SRC" ] || { echo "FALLA $nombre: no encontre ultimo_frame() en produccion/producir.sh"; exit 1; }
eval "$POST_SRC" || { echo "FALLA $nombre: ultimo_frame() de producir.sh no es bash valido"; exit 1; }
read -r N_POST F_POST <<<"$(correr_bucle)"

# Control negativo: la ultimo_frame() PRE-arreglo (478960b), leida de solo
# lectura con `git show`. Prueba que el arnes detecta el bug cuando esta.
PRE_SRC=$(git -C "$REPO" show 478960b:produccion/producir.sh 2>/dev/null | extrae_fn /dev/stdin ultimo_frame)
[ -n "$PRE_SRC" ] || { echo "FALLA $nombre: no pude leer ultimo_frame() de 478960b en el repo $REPO"; exit 1; }
eval "$PRE_SRC"
read -r N_PRE F_PRE <<<"$(correr_bucle)"

# ═══ B) preview.sh :: publicar() y su while-read sobre el guion ═══════════
PV_SRC=$(extrae_fn "$RAIZ/produccion/preview.sh" publicar)
[ -n "$PV_SRC" ] || { echo "FALLA $nombre: no encontre publicar() en produccion/preview.sh"; exit 1; }
eval "$PV_SRC" || { echo "FALLA $nombre: publicar() de preview.sh no es bash valido"; exit 1; }

MD=$CHK_TMP/md; OBRA=$CHK_TMP/obra; V=$CHK_TMP/v; G=$CHK_TMP/preview.guion
mkdir -p "$MD/proyecto-minuto" "$OBRA" "$V"
: > "$OBRA/p01.avi"                        # un plano nuevo -> publicar() no sale antes de tiempo
for k in 1 2 3 4 5; do : > "$MD/proyecto-minuto/b$k.avi"; printf 'BROLL|b%s.avi|\n' "$k" >> "$G"; done
publicar </dev/null >"$CHK_TMP/preview.log" 2>&1
N_PV=$(grep -c "^file " "$V/.lista.txt" 2>/dev/null); N_PV=${N_PV:-0}

# ═══ Veredicto ════════════════════════════════════════════════════════════
ERR=""
N_POST=${N_POST:-0}; F_POST=${F_POST:-0}; N_PRE=${N_PRE:-9}
[ "$N_POST" -eq 5 ] || ERR="$ERR producir.sh/ultimo_frame: el while-read solo proceso $N_POST/5 planos (se comio $((5-N_POST)) lineas del guion);"
[ "$F_POST" -eq "$N_POST" ] || ERR="$ERR producir.sh/ultimo_frame: no genero salida en $((N_POST-F_POST)) de $N_POST vueltas (ffmpeg no llego a ejecutarse: ff() rota o sin definir);"
[ "$N_PV"   -eq 5 ] || ERR="$ERR preview.sh/publicar: el while-read solo proceso $N_PV/5 planos del guion;"
[ "$N_PRE" -lt 5 ]  || ERR="$ERR control negativo INVALIDO: la ultimo_frame() de 478960b proceso $N_PRE/5 (deberia perder lineas); el arnes no esta detectando el bug;"

if [ -z "$ERR" ]; then
  echo "PASA $nombre (producir.sh 5/5 planos y 5/5 salidas, preview.sh 5/5 planos, control 478960b $N_PRE/5)"
  exit 0
else
  echo "FALLA $nombre:$ERR control pre-arreglo 478960b proceso $N_PRE/5 (referencia del bug presente)$COMUN_AVISO"
  exit 1
fi