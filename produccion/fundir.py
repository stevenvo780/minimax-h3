#!/usr/bin/env python3
"""Monta clips con una transición explícita y verificable.

Configuración por entorno:

* ``TRANSICION=corte`` (predeterminado): corte directo, sin solapamiento.
* ``TRANSICION=fundido``: xfade/acrossfade heredado, opt-in.
* ``TRANSICION=negro``: salida y entrada por negro alrededor de un corte.
* ``DURACION_TRANSICION=0.5``: segundos totales de la transición. En ``negro``
  se reparte por mitades a ambos lados del corte.

``tramos.txt`` contiene el nombre de dos dígitos del primer clip de cada tramo
nuevo. Dentro de un tramo siempre se concatena sin transición.
"""

from __future__ import annotations

import glob
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from fractions import Fraction
from typing import Any, Iterable


TRANSICIONES = {"corte", "fundido", "negro"}
OBJETIVO_LUFS = -19.0
TOLERANCIA_LUFS = 0.5
PICO_REAL_MAX_DBTP = -1.5
PICO_MUESTRA_MAX_DBFS = -0.1
INTENTOS_AUDIO = 3


def error(mensaje: str) -> "None":
    sys.stderr.write(f"ERROR: {mensaje}\n")
    raise SystemExit(1)


def ejecutar(comando: list[str], accion: str) -> subprocess.CompletedProcess[str]:
    try:
        resultado = subprocess.run(comando, capture_output=True, text=True)
    except FileNotFoundError:
        error(f"no se encontro '{comando[0]}' al {accion}")
    except OSError as exc:
        error(f"no se pudo {accion}: {exc}")
    if resultado.returncode != 0:
        detalle = resultado.stderr.strip() or resultado.stdout.strip()
        sufijo = f": {detalle}" if detalle else ""
        error(f"fallo al {accion} (returncode {resultado.returncode}){sufijo}")
    return resultado


def numero_positivo(valor: str, nombre: str) -> float:
    try:
        numero = float(valor)
    except ValueError:
        error(f"{nombre} debe ser un numero positivo; recibido: '{valor}'")
    if not math.isfinite(numero) or numero <= 0:
        error(f"{nombre} debe ser finito y mayor que cero; recibido: '{valor}'")
    return numero


def fraccion_positiva(valor: object, descripcion: str, archivo: Path) -> Fraction:
    try:
        numero = Fraction(str(valor))
    except (ValueError, ZeroDivisionError):
        error(f"{descripcion} invalido en '{archivo}': '{valor}'")
    if numero <= 0:
        error(f"{descripcion} debe ser positivo en '{archivo}': '{valor}'")
    return numero


def sondear(archivo: Path) -> dict[str, Any]:
    resultado = ejecutar(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            (
                "format=duration:"
                "stream=index,codec_type,codec_name,width,height,pix_fmt,"
                "r_frame_rate,time_base,sample_fmt,sample_rate,channels,channel_layout"
            ),
            "-of",
            "json",
            str(archivo),
        ],
        f"inspeccionar '{archivo}' con ffprobe",
    )
    try:
        datos = json.loads(resultado.stdout)
    except json.JSONDecodeError as exc:
        error(f"ffprobe devolvio JSON invalido para '{archivo}': {exc.msg}")

    if not isinstance(datos, dict):
        error(f"ffprobe devolvio una estructura invalida para '{archivo}'")
    streams = datos.get("streams")
    formato = datos.get("format")
    if not isinstance(streams, list) or not isinstance(formato, dict):
        error(f"ffprobe no devolvio streams y formato completos para '{archivo}'")

    videos = [s for s in streams if isinstance(s, dict) and s.get("codec_type") == "video"]
    audios = [s for s in streams if isinstance(s, dict) and s.get("codec_type") == "audio"]
    if len(videos) != 1 or len(audios) != 1:
        error(
            f"'{archivo}' debe tener exactamente un stream de video y uno de audio; "
            f"encontrados: video={len(videos)}, audio={len(audios)}"
        )

    video, audio = videos[0], audios[0]
    requeridos_video = ("codec_name", "width", "height", "pix_fmt", "r_frame_rate", "time_base")
    requeridos_audio = ("codec_name", "sample_rate", "channels", "time_base")
    faltan = [f"video.{k}" for k in requeridos_video if video.get(k) in (None, "")]
    faltan += [f"audio.{k}" for k in requeridos_audio if audio.get(k) in (None, "")]
    if faltan:
        error(f"metadatos incompletos en '{archivo}': {', '.join(faltan)}")

    duracion = numero_positivo(str(formato.get("duration", "")), f"duracion de '{archivo}'")
    fps = fraccion_positiva(video["r_frame_rate"], "r_frame_rate", archivo)
    fraccion_positiva(video["time_base"], "time_base de video", archivo)
    fraccion_positiva(audio["time_base"], "time_base de audio", archivo)
    fraccion_positiva(audio["sample_rate"], "sample_rate", archivo)

    try:
        ancho = int(video["width"])
        alto = int(video["height"])
        canales = int(audio["channels"])
    except (TypeError, ValueError):
        error(f"dimensiones o canales invalidos en '{archivo}'")
    if ancho <= 0 or alto <= 0 or canales <= 0:
        error(f"dimensiones o canales no positivos en '{archivo}'")

    return {
        "archivo": archivo,
        "duracion": duracion,
        "fps": fps,
        "video": video,
        "audio": audio,
    }


def firma_video(info: dict[str, Any]) -> tuple[object, ...]:
    v = info["video"]
    return (
        v["codec_name"],
        int(v["width"]),
        int(v["height"]),
        v["pix_fmt"],
        Fraction(str(v["r_frame_rate"])),
        Fraction(str(v["time_base"])),
    )


def firma_audio(info: dict[str, Any]) -> tuple[object, ...]:
    a = info["audio"]
    return (
        a["codec_name"],
        int(a["sample_rate"]),
        int(a["channels"]),
        a.get("channel_layout", ""),
        a.get("sample_fmt", ""),
        Fraction(str(a["time_base"])),
    )


def validar_compatibilidad(infos: list[dict[str, Any]]) -> None:
    referencia = infos[0]
    for info in infos[1:]:
        diferencias: list[str] = []
        if firma_video(info) != firma_video(referencia):
            diferencias.append("video (codec/resolucion/pix_fmt/fps/time_base)")
        if firma_audio(info) != firma_audio(referencia):
            diferencias.append("audio (codec/frecuencia/canales/formato/time_base)")
        if diferencias:
            error(
                f"clips incompatibles para concatenacion: '{referencia['archivo']}' y "
                f"'{info['archivo']}' difieren en {' y '.join(diferencias)}"
            )


def escribir_lista(ruta: Path, archivos: Iterable[Path]) -> None:
    try:
        with ruta.open("w", encoding="utf-8") as fichero:
            for archivo in archivos:
                absoluto = str(archivo.resolve()).replace("'", "'\\''")
                fichero.write(f"file '{absoluto}'\n")
    except OSError as exc:
        error(f"no se pudo escribir la lista de concat '{ruta}': {exc}")


def tolerancia_duracion(info: dict[str, Any], cantidad: int) -> float:
    # Tres cuadros cubren el redondeo de timestamps; 30 ms por clip cubren el
    # priming AAC sin permitir que desaparezca una cola audible completa.
    return max(3.0 / float(info["fps"]), 0.03 * cantidad, 0.08)


def validar_salida(
    archivo: Path,
    referencia: dict[str, Any],
    duracion_esperada: float,
    cantidad_fuentes: int,
    corte_sin_recodificar: bool,
) -> dict[str, Any]:
    salida = sondear(archivo)
    vr, vs = referencia["video"], salida["video"]
    ar, audio_salida = referencia["audio"], salida["audio"]
    if (
        int(vr["width"]) != int(vs["width"])
        or int(vr["height"]) != int(vs["height"])
        or Fraction(str(vr["r_frame_rate"])) != Fraction(str(vs["r_frame_rate"]))
        or int(ar["sample_rate"]) != int(audio_salida["sample_rate"])
        or int(ar["channels"]) != int(audio_salida["channels"])
    ):
        error(f"la salida '{archivo}' cambio dimensiones, FPS o formato basico de audio")
    if corte_sin_recodificar and (
        vs["codec_name"] != vr["codec_name"]
        or audio_salida["codec_name"] != ar["codec_name"]
    ):
        error(f"el corte directo de '{archivo}' cambio codecs pese a usar copia de streams")

    diferencia = abs(float(salida["duracion"]) - duracion_esperada)
    tolerancia = tolerancia_duracion(referencia, cantidad_fuentes)
    if diferencia > tolerancia:
        error(
            f"duracion final invalida en '{archivo}': medida={salida['duracion']:.4f}s, "
            f"esperada={duracion_esperada:.4f}s, tolerancia={tolerancia:.4f}s"
        )
    return salida


def analizar_para_loudnorm(
    archivo: Path, objetivo_lufs: float, objetivo_pico: float
) -> dict[str, float]:
    filtro = (
        f"loudnorm=I={objetivo_lufs:.3f}:TP={objetivo_pico:.3f}:LRA=7:"
        "print_format=json"
    )
    resultado = ejecutar(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-nostats",
            "-v",
            "info",
            "-i",
            str(archivo),
            "-map",
            "0:a:0",
            "-af",
            filtro,
            "-f",
            "null",
            "-",
        ],
        f"analizar loudness de '{archivo}'",
    )
    bloques = re.findall(r"\{\s*\"input_i\".*?\}", resultado.stderr, flags=re.DOTALL)
    if not bloques:
        error(f"loudnorm no devolvio su medicion JSON para '{archivo}'")
    try:
        datos = json.loads(bloques[-1])
    except json.JSONDecodeError as exc:
        error(f"loudnorm devolvio JSON invalido para '{archivo}': {exc.msg}")
    campos = ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")
    medicion: dict[str, float] = {}
    for campo in campos:
        try:
            valor = float(datos[campo])
        except (KeyError, TypeError, ValueError):
            error(f"loudnorm no devolvio '{campo}' valido para '{archivo}'")
        if not math.isfinite(valor):
            error(f"loudnorm devolvio '{campo}' no finito para '{archivo}'")
        medicion[campo] = valor
    return medicion


def medir_audio_final(archivo: Path) -> dict[str, float]:
    resultado = ejecutar(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-nostats",
            "-v",
            "info",
            "-i",
            str(archivo),
            "-map",
            "0:a:0",
            "-af",
            "ebur128=peak=sample+true:framelog=quiet",
            "-f",
            "null",
            "-",
        ],
        f"medir el audio final de '{archivo}' con ebur128",
    )
    if "Summary:" not in resultado.stderr:
        error(f"ebur128 no devolvio un resumen para '{archivo}'")
    resumen = resultado.stderr.rsplit("Summary:", 1)[-1]
    patrones = {
        "lufs": r"Integrated loudness:\s*I:\s*([+-]?(?:\d+(?:\.\d+)?|inf))\s+LUFS",
        "pico_muestra": r"Sample peak:\s*Peak:\s*([+-]?(?:\d+(?:\.\d+)?|inf))\s+dBFS",
        "pico_real": r"True peak:\s*Peak:\s*([+-]?(?:\d+(?:\.\d+)?|inf))\s+dBFS",
    }
    medicion: dict[str, float] = {}
    for nombre, patron in patrones.items():
        coincidencia = re.search(patron, resumen, flags=re.IGNORECASE)
        if not coincidencia:
            error(f"ebur128 no devolvio '{nombre}' para '{archivo}'")
        valor = float(coincidencia.group(1))
        if not math.isfinite(valor):
            error(f"ebur128 devolvio '{nombre}' no finito para '{archivo}'")
        medicion[nombre] = valor
    return medicion


def audio_dentro_de_objetivo(medicion: dict[str, float]) -> bool:
    return (
        abs(medicion["lufs"] - OBJETIVO_LUFS) <= TOLERANCIA_LUFS
        and medicion["pico_real"] <= PICO_REAL_MAX_DBTP
        and medicion["pico_muestra"] <= PICO_MUESTRA_MAX_DBFS
    )


def masterizar_audio(
    bruto: Path,
    final: Path,
    duracion_esperada: float,
    cantidad_fuentes: int,
) -> tuple[Path, dict[str, float], int]:
    referencia = sondear(bruto)
    sample_rate = int(referencia["audio"]["sample_rate"])
    objetivo_lufs = OBJETIVO_LUFS
    objetivo_pico = -2.5
    limite_db = -2.5
    ultima: dict[str, float] | None = None

    for intento in range(1, INTENTOS_AUDIO + 1):
        analisis = analizar_para_loudnorm(bruto, objetivo_lufs, objetivo_pico)
        limite_lineal = 10.0 ** (limite_db / 20.0)
        filtro = (
            f"loudnorm=I={objetivo_lufs:.3f}:TP={objetivo_pico:.3f}:LRA=7:"
            f"measured_I={analisis['input_i']:.3f}:"
            f"measured_TP={analisis['input_tp']:.3f}:"
            f"measured_LRA={analisis['input_lra']:.3f}:"
            f"measured_thresh={analisis['input_thresh']:.3f}:"
            f"offset={analisis['target_offset']:.3f}:linear=true:print_format=summary,"
            f"aresample={sample_rate},"
            f"alimiter=limit={limite_lineal:.8f}:attack=5:release=50:"
            "level=false:latency=true"
        )
        candidato = final.parent / (
            f".{final.stem}.audio-{intento}-{os.getpid()}{final.suffix or '.mp4'}"
        )
        ejecutar(
            [
                "ffmpeg",
                "-nostdin",
                "-y",
                "-v",
                "error",
                "-i",
                str(bruto),
                "-map",
                "0:v:0",
                "-map",
                "0:a:0",
                "-c:v",
                "copy",
                "-af",
                filtro,
                "-c:a",
                "aac",
                "-b:a",
                "256k",
                "-ar",
                str(sample_rate),
                "-movflags",
                "+faststart",
                str(candidato),
            ],
            f"masterizar el audio final (intento {intento}/{INTENTOS_AUDIO})",
        )
        validar_salida(
            candidato, referencia, duracion_esperada, cantidad_fuentes, False
        )
        ultima = medir_audio_final(candidato)
        if audio_dentro_de_objetivo(ultima):
            return candidato, ultima, intento

        try:
            candidato.unlink()
        except OSError as exc:
            error(f"no se pudo descartar el master de audio rechazado '{candidato}': {exc}")

        # La correccion es acotada y siempre se recalcula desde el bruto, no
        # desde un AAC ya degradado. Compensa error de loudness y deja margen
        # adicional si el encoder produjo overshoot de pico verdadero.
        correccion_lufs = OBJETIVO_LUFS - ultima["lufs"]
        objetivo_lufs = min(-16.0, max(-23.0, objetivo_lufs + correccion_lufs))
        if ultima["pico_real"] > -2.0 or ultima["pico_muestra"] > -0.5:
            exceso = max(ultima["pico_real"] + 2.0, ultima["pico_muestra"] + 0.5, 0.0)
            margen = exceso + 0.5
            objetivo_pico = max(-8.0, objetivo_pico - margen)
            limite_db = max(-8.0, limite_db - margen)

    assert ultima is not None
    error(
        "audio final fuera de especificacion tras "
        f"{INTENTOS_AUDIO} intentos: I={ultima['lufs']:.1f} LUFS "
        f"(objetivo {OBJETIVO_LUFS:.1f}+-{TOLERANCIA_LUFS:.1f}), "
        f"TP={ultima['pico_real']:.1f} dBTP (max {PICO_REAL_MAX_DBTP:.1f}), "
        f"sample_peak={ultima['pico_muestra']:.1f} dBFS"
    )


def grupos_desde_fronteras(clips: list[Path], fronteras: set[str]) -> list[list[Path]]:
    grupos: list[list[Path]] = []
    actual: list[Path] = []
    for clip in clips:
        numero = clip.stem
        if numero in fronteras and actual:
            grupos.append(actual)
            actual = []
        actual.append(clip)
    if actual:
        grupos.append(actual)
    return grupos


def aplicar_punch(clips: list[Path], factor: float) -> list[Path]:
    """Cierra el encuadre de las tomas PARES un `factor`, dejando las impares.

    Por que existe: dos tomas seguidas del mismo plano, con el mismo encuadre
    y la boca abierta a ambos lados, no se pueden unir bien. El corte duro se
    lee como salto y el fundido superpone dos bocas distintas, que es peor:
    parece un fallo, no una transicion. Medido sobre la primera tanda, ninguna
    toma tiene cola muda —el modelo estira la locucion hasta llenar la toma
    que se le pide— asi que no hay forma de llegar al corte con la boca quieta.

    Lo que si funciona es que el corte PAREZCA intencionado. Un cambio de
    tamano claro entre toma y toma es el lenguaje normal de un reel, y el ojo
    lo acepta como edicion. Se alterna en vez de acumular para que el recorte
    no crezca con el numero de tomas: la quinta toma de una pieza se veria
    notablemente mas blanda que la primera.

    El clip punchado sustituye al original en el montaje; el fichero de la
    obra no se toca.
    """
    if factor <= 1.0:
        return clips
    salida = []
    for indice, clip in enumerate(clips):
        if indice % 2 == 0:
            salida.append(clip)
            continue
        destino = clip.with_name(f"{clip.stem}-punch{clip.suffix}")
        ejecutar(
            [
                "ffmpeg", "-nostdin", "-y", "-v", "error",
                "-i", str(clip),
                "-vf", f"scale=iw*{factor:.4f}:ih*{factor:.4f},crop=iw/{factor:.4f}:ih/{factor:.4f}",
                "-c:v", "libx264", "-preset", "slow", "-crf", "17",
                "-pix_fmt", "yuv420p", "-c:a", "copy",
                str(destino),
            ],
            f"cerrar el encuadre de '{clip.name}' a {factor:.2f}x",
        )
        salida.append(destino)
    return salida


def leer_fronteras(montaje: Path, clips: list[Path]) -> set[str]:
    ruta = montaje / "tramos.txt"
    if not ruta.exists():
        return set()
    try:
        lineas = [
            linea.strip()
            for linea in ruta.read_text(encoding="utf-8").splitlines()
            if linea.strip()
        ]
    except OSError as exc:
        error(f"no se pudo leer '{ruta}': {exc}")
    if len(lineas) != len(set(lineas)):
        error(f"'{ruta}' contiene fronteras duplicadas")
    nombres = {clip.stem for clip in clips}
    primera = clips[0].stem
    for frontera in lineas:
        if len(frontera) != 2 or not frontera.isdigit():
            error(f"frontera invalida '{frontera}' en '{ruta}'; se esperaba NN")
        if frontera not in nombres:
            error(f"frontera '{frontera}' de '{ruta}' no corresponde a ningun clip")
        if frontera == primera:
            error(f"frontera '{frontera}' de '{ruta}' no puede preceder al primer clip")
    return set(lineas)


def limpiar_intermedios(montaje: Path) -> None:
    candidatos = glob.glob(str(montaje / "l[0-9]*.txt"))
    candidatos += glob.glob(str(montaje / "tramo[0-9]*.mp4"))
    for nombre in candidatos:
        try:
            Path(nombre).unlink()
        except OSError as exc:
            error(f"no se pudo limpiar el intermedio '{nombre}': {exc}")


def crear_tramos(
    montaje: Path,
    grupos: list[list[Path]],
    infos_por_clip: dict[Path, dict[str, Any]],
) -> tuple[list[Path], list[dict[str, Any]]]:
    tramos: list[Path] = []
    infos: list[dict[str, Any]] = []
    for indice, grupo in enumerate(grupos):
        salida = montaje / f"tramo{indice}.mp4"
        lista = montaje / f"l{indice}.txt"
        escribir_lista(lista, grupo)
        ejecutar(
            [
                "ffmpeg",
                "-nostdin",
                "-y",
                "-v",
                "error",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(lista),
                "-map",
                "0:v:0",
                "-map",
                "0:a:0",
                "-c",
                "copy",
                str(salida),
            ],
            f"concatenar el tramo {indice}",
        )
        esperada = sum(infos_por_clip[clip]["duracion"] for clip in grupo)
        info = validar_salida(salida, infos_por_clip[grupo[0]], esperada, len(grupo), True)
        tramos.append(salida)
        infos.append(info)
    return tramos, infos


def validar_duracion_transicion(
    modo: str, duracion: float, infos: list[dict[str, Any]]
) -> None:
    if len(infos) < 2:
        return
    cuadro = 1.0 / float(infos[0]["fps"])
    minimo = cuadro if modo == "fundido" else 2.0 * cuadro
    if duracion + 1e-9 < minimo:
        error(
            f"DURACION_TRANSICION={duracion:g}s es demasiado corta para {modo} a "
            f"{float(infos[0]['fps']):g} FPS; minimo={minimo:.6f}s"
        )

    if modo == "fundido":
        for indice in range(1, len(infos)):
            limite = min(infos[indice - 1]["duracion"], infos[indice]["duracion"])
            if duracion >= limite:
                error(
                    f"DURACION_TRANSICION={duracion:g}s debe ser menor que ambos tramos "
                    f"en la frontera {indice} (minimo disponible={limite:.4f}s)"
                )
        return

    mitad = duracion / 2.0
    for indice, info in enumerate(infos):
        lados = int(indice > 0) + int(indice < len(infos) - 1)
        necesaria = mitad * lados
        if info["duracion"] + 1e-9 < necesaria:
            error(
                f"DURACION_TRANSICION={duracion:g}s no cabe alrededor del tramo {indice} "
                f"({info['duracion']:.4f}s disponibles, {necesaria:.4f}s necesarios)"
            )


def argumentos_entrada(tramos: list[Path]) -> list[str]:
    argumentos: list[str] = []
    for tramo in tramos:
        argumentos.extend(("-i", str(tramo)))
    return argumentos


def montar_fundido(
    tramos: list[Path], infos: list[dict[str, Any]], duracion: float, salida: Path
) -> float:
    partes = [
        "[0:v]settb=AVTB,setpts=PTS-STARTPTS[v0]",
        "[0:a]asetpts=PTS-STARTPTS[a0]",
    ]
    video, audio = "[v0]", "[a0]"
    duracion_acumulada = infos[0]["duracion"]
    for indice in range(1, len(tramos)):
        partes.append(f"[{indice}:v]settb=AVTB,setpts=PTS-STARTPTS[vin{indice}]")
        partes.append(f"[{indice}:a]asetpts=PTS-STARTPTS[ain{indice}]")
        offset = duracion_acumulada - duracion
        partes.append(
            f"{video}[vin{indice}]xfade=transition=fade:duration={duracion:.6f}:"
            f"offset={offset:.6f}[v{indice}]"
        )
        partes.append(f"{audio}[ain{indice}]acrossfade=d={duracion:.6f}[a{indice}]")
        video, audio = f"[v{indice}]", f"[a{indice}]"
        duracion_acumulada += infos[indice]["duracion"] - duracion

    ejecutar(
        ["ffmpeg", "-nostdin", "-y", "-v", "error"]
        + argumentos_entrada(tramos)
        + [
            "-filter_complex",
            ";".join(partes),
            "-map",
            video,
            "-map",
            audio,
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "17",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            str(salida),
        ],
        "aplicar los fundidos",
    )
    return duracion_acumulada


def montar_negro(
    tramos: list[Path], infos: list[dict[str, Any]], duracion: float, salida: Path
) -> float:
    mitad = duracion / 2.0
    partes: list[str] = []
    entradas_concat: list[str] = []
    for indice, info in enumerate(infos):
        filtros_video = ["settb=AVTB", "setpts=PTS-STARTPTS"]
        filtros_audio = ["asetpts=PTS-STARTPTS"]
        if indice > 0:
            filtros_video.append(f"fade=t=in:st=0:d={mitad:.6f}:color=black")
            filtros_audio.append(f"afade=t=in:st=0:d={mitad:.6f}")
        if indice < len(infos) - 1:
            inicio = info["duracion"] - mitad
            filtros_video.append(f"fade=t=out:st={inicio:.6f}:d={mitad:.6f}:color=black")
            filtros_audio.append(f"afade=t=out:st={inicio:.6f}:d={mitad:.6f}")
        partes.append(f"[{indice}:v]{','.join(filtros_video)}[v{indice}]")
        partes.append(f"[{indice}:a]{','.join(filtros_audio)}[a{indice}]")
        entradas_concat.extend((f"[v{indice}]", f"[a{indice}]"))
    partes.append(
        f"{''.join(entradas_concat)}concat=n={len(tramos)}:v=1:a=1[vfinal][afinal]"
    )

    ejecutar(
        ["ffmpeg", "-nostdin", "-y", "-v", "error"]
        + argumentos_entrada(tramos)
        + [
            "-filter_complex",
            ";".join(partes),
            "-map",
            "[vfinal]",
            "-map",
            "[afinal]",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "17",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            str(salida),
        ],
        "aplicar los pasos por negro",
    )
    return sum(info["duracion"] for info in infos)


def principal(argumentos: list[str]) -> int:
    if len(argumentos) != 3:
        error("uso: fundir.py DIRECTORIO_MONTAJE VIDEO_FINAL")
    montaje = Path(argumentos[1])
    final = Path(argumentos[2])
    if not montaje.is_dir():
        error(f"el directorio de montaje no existe: '{montaje}'")

    modo = os.environ.get("TRANSICION", "corte").strip().lower()
    if modo not in TRANSICIONES:
        error(
            f"TRANSICION invalida '{modo}'; opciones: "
            + ", ".join(sorted(TRANSICIONES))
        )
    duracion = 0.5
    if modo != "corte":
        duracion = numero_positivo(
            os.environ.get("DURACION_TRANSICION", "0.5"), "DURACION_TRANSICION"
        )

    punch = float(os.environ.get("PUNCH_ALTERNO", "1.0"))
    if punch < 1.0 or punch > 1.5:
        error(f"PUNCH_ALTERNO fuera de rango: {punch} (1.0 = sin punch)")

    clips = sorted(Path(nombre) for nombre in glob.glob(str(montaje / "[0-9][0-9].mp4")))
    if not clips:
        error(f"no se encontraron clips NN.mp4 en '{montaje}'")
    fronteras = leer_fronteras(montaje, clips)
    if punch > 1.0:
        originales = list(clips)
        clips = aplicar_punch(clips, punch)
        # Las tomas punchadas cambian de nombre, asi que las fronteras de
        # tramo tienen que seguirlas.
        renombre = {viejo.stem: nuevo.stem for viejo, nuevo in zip(originales, clips)}
        fronteras = {renombre.get(f, f) for f in fronteras}
        print(f"  encuadre: tomas pares cerradas a {punch:.2f}x (punch alterno)")
    infos_clips = [sondear(clip) for clip in clips]
    validar_compatibilidad(infos_clips)
    infos_por_clip = {info["archivo"]: info for info in infos_clips}

    # Un corte directo no necesita conservar grupos artificiales: una sola
    # concatenación evita una segunda pasada y conserva todas las colas.
    grupos = [clips] if modo == "corte" else grupos_desde_fronteras(clips, fronteras)
    limpiar_intermedios(montaje)
    tramos, infos_tramos = crear_tramos(montaje, grupos, infos_por_clip)

    try:
        final.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        error(f"no se pudo preparar el destino '{final.parent}': {exc}")
    bruto = final.parent / f".{final.stem}.fundiendo-{os.getpid()}{final.suffix or '.mp4'}"
    candidato_audio: Path | None = None
    try:
        if len(tramos) == 1:
            try:
                shutil.copyfile(tramos[0], bruto)
            except OSError as exc:
                error(f"no se pudo copiar el montaje directo a '{bruto}': {exc}")
            esperada = sum(info["duracion"] for info in infos_clips)
            validar_salida(bruto, infos_clips[0], esperada, len(clips), True)
            resumen = f"corte directo entre {len(clips)} clips; sin solapamiento"
        elif modo == "fundido":
            validar_duracion_transicion(modo, duracion, infos_tramos)
            esperada = montar_fundido(tramos, infos_tramos, duracion, bruto)
            validar_salida(bruto, infos_tramos[0], esperada, len(clips), False)
            resumen = (
                f"fundido opt-in de {duracion:g}s entre {len(tramos)} tramos; "
                "video y audio solapados"
            )
        else:
            validar_duracion_transicion(modo, duracion, infos_tramos)
            esperada = montar_negro(tramos, infos_tramos, duracion, bruto)
            validar_salida(bruto, infos_tramos[0], esperada, len(clips), False)
            resumen = (
                f"paso por negro de {duracion:g}s entre {len(tramos)} tramos; "
                "corte sin doble exposicion"
            )

        candidato_audio, audio_final, intento_audio = masterizar_audio(
            bruto, final, esperada, len(clips)
        )
        try:
            os.replace(candidato_audio, final)
        except OSError as exc:
            error(f"no se pudo publicar atomicamente '{final}': {exc}")
    finally:
        temporales = [bruto]
        if candidato_audio is not None:
            temporales.append(candidato_audio)
        for temporal in temporales:
            if temporal.exists():
                try:
                    temporal.unlink()
                except OSError:
                    pass

    print(f"  montaje: {resumen}")
    print(
        f"  audio final: I={audio_final['lufs']:.1f} LUFS, "
        f"TP={audio_final['pico_real']:.1f} dBTP, "
        f"sample_peak={audio_final['pico_muestra']:.1f} dBFS, "
        f"clipping=0, intento={intento_audio}/{INTENTOS_AUDIO}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(principal(sys.argv))
