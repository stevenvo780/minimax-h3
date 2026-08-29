#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  PROMPT — construccion del prompt segun el TIPO de plano.
#
#  El pipeline nacio para un unico formato: una persona hablando de frente.
#  El prompt estaba escrito a mano dentro del script de produccion, con
#  "He speaks with calm deliberation... Subject 1 (S1) says <d>[Spanish]...",
#  lo que hacia imposible cualquier plano sin dialogo.
#
#  Aqui el tipo de plano es un parametro. El modelo espera tres secciones
#  (detailed_description, overall_soundscape, non_diegetic_music); lo que
#  cambia entre formatos es el cuerpo de la primera.
#
#  Uso:  construir_prompt <tipo> <escena> <contenido> <ambiente> <musica>
# ═══════════════════════════════════════════════════════════════════════════

# Tipos disponibles. Añadir uno es añadir un case aqui y nada mas.
PROMPT_TIPOS="habla muda accion detalle paisaje camara"

_cuerpo_prompt() {   # $1=tipo  $2=escena  $3=contenido
  local tipo=$1 escena=$2 cont=$3
  case "$tipo" in
    habla)
      # Retrato hablado. El <d>[Spanish]...</d> es lo que dispara el habla
      # sincronizada; sin esa marca el modelo no genera voz.
      printf '%s He speaks with calm deliberation, unhurried, pausing naturally between sentences. Subject 1 (S1) says, <d>[Spanish] %s</d> When his voice stops, his lips settle closed and he holds the gaze, breathing slowly.' \
        "$escena" "$cont" ;;
    muda)
      # Persona en plano, sin hablar. Util para reaccion, escucha, silencio.
      printf '%s %s He does not speak. Only breathing and small involuntary movements.' \
        "$escena" "$cont" ;;
    accion)
      # Algo ocurre. El sujeto puede estar o no.
      printf '%s %s' "$escena" "$cont" ;;
    detalle)
      # Primerisimo plano de un objeto o parte del cuerpo. Sin rostro.
      printf 'Extreme close-up. %s %s Shallow depth of field, the subject fills the frame, no face visible.' \
        "$escena" "$cont" ;;
    paisaje)
      # Sin personas. Atmosfera, espacio, luz.
      printf 'A wide static shot with no people in frame. %s %s Nothing enters or leaves the frame.' \
        "$escena" "$cont" ;;
    camara)
      # El movimiento es el sujeto. El contenido describe la trayectoria.
      printf '%s The camera %s' "$escena" "$cont" ;;
    *)
      echo "construir_prompt: tipo desconocido '$tipo' (validos: $PROMPT_TIPOS)" >&2
      return 1 ;;
  esac
}

construir_prompt() {  # tipo escena contenido ambiente musica
  local tipo=$1 escena=$2 cont=$3 amb=$4 mus=$5
  local cuerpo; cuerpo=$(_cuerpo_prompt "$tipo" "$escena" "$cont") || return 1
  printf 'detailed_description:\nThe target video is in realistic photographic style. [Shot 1] %s\n\noverall_soundscape:\n%s\n\nnon_diegetic_music:\n%s' \
    "$cuerpo" "$amb" "$mus"
}

# Valida que un tipo exista antes de gastar 20 minutos de GPU en el.
tipo_valido() {
  case " $PROMPT_TIPOS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
