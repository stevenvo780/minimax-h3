#!/usr/bin/env python3
"""Crea y verifica un plano estatico reproducible a partir de un video.

No evalua voz ni contenido semantico. Su contrato es mas acotado: reemplaza
la imagen temporal por un unico fotograma fuente y grano luma determinista,
conservando exactamente la linea de tiempo y el audio decodificado.
"""

from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
from fractions import Fraction
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, BinaryIO


SCHEMA = "minimax-h3.estabilizar-plano/v1"
MAX_SEED = 2_147_483_647
GRAIN_DEFAULT = 2
GRAIN_MIN = 1
GRAIN_MAX = 5


class ErrorEstabilizacion(RuntimeError):
    """Fallo esperado que debe cerrar la operacion sin publicar."""


def fallar(mensaje: str) -> "None":
    raise ErrorEstabilizacion(mensaje)


def canonical(datos: Any) -> bytes:
    return (json.dumps(datos, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode(
        "utf-8"
    )


def sha_bytes(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


def sha_archivo_objeto(archivo: BinaryIO) -> str:
    h = hashlib.sha256()
    archivo.seek(0)
    while bloque := archivo.read(1024 * 1024):
        h.update(bloque)
    archivo.seek(0)
    return h.hexdigest()


def sha_ruta(ruta: Path) -> str:
    h = hashlib.sha256()
    try:
        with ruta.open("rb") as archivo:
            while bloque := archivo.read(1024 * 1024):
                h.update(bloque)
    except OSError as exc:
        fallar(f"no se pudo calcular SHA-256 de '{ruta}': {exc}")
    return h.hexdigest()


def ruta_absoluta_sin_symlinks(valor: str, *, debe_existir: bool, descripcion: str) -> Path:
    ruta = Path(os.path.abspath(valor))
    partes = ruta.parts
    actual = Path(partes[0])
    for parte in partes[1:]:
        actual /= parte
        try:
            modo = actual.lstat().st_mode
        except FileNotFoundError:
            if debe_existir or actual != ruta:
                fallar(f"{descripcion} no existe o su padre no existe: '{ruta}'")
            break
        except OSError as exc:
            fallar(f"no se pudo inspeccionar {descripcion} '{ruta}': {exc}")
        if stat.S_ISLNK(modo):
            fallar(f"{descripcion} no puede contener symlinks: '{actual}'")
    return ruta


def abrir_regular_sin_symlink(ruta: Path, descripcion: str) -> BinaryIO:
    banderas = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        banderas |= os.O_NOFOLLOW
    try:
        fd = os.open(ruta, banderas)
    except OSError as exc:
        fallar(f"no se pudo abrir {descripcion} regular '{ruta}': {exc}")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            fallar(f"{descripcion} debe ser un archivo regular: '{ruta}'")
        return os.fdopen(fd, "rb", closefd=True)
    except BaseException:
        os.close(fd)
        raise


def ejecutar(
    comando: list[str],
    accion: str,
    *,
    pass_fds: tuple[int, ...] = (),
    stdout: int | None = subprocess.PIPE,
) -> subprocess.CompletedProcess[bytes]:
    try:
        resultado = subprocess.run(
            comando,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=subprocess.PIPE,
            pass_fds=pass_fds,
            check=False,
        )
    except FileNotFoundError:
        fallar(f"falta la herramienta '{comando[0]}' para {accion}")
    except OSError as exc:
        fallar(f"no se pudo {accion}: {exc}")
    if resultado.returncode != 0:
        detalle = resultado.stderr.decode("utf-8", "replace").strip()
        if len(detalle) > 1200:
            detalle = detalle[-1200:]
        fallar(
            f"fallo al {accion} (returncode {resultado.returncode})"
            + (f": {detalle}" if detalle else "")
        )
    return resultado


def version_herramienta(nombre: str) -> str:
    salida = ejecutar([nombre, "-version"], f"consultar version de {nombre}").stdout
    primera = salida.decode("utf-8", "replace").splitlines()
    if not primera:
        fallar(f"'{nombre} -version' no devolvio version")
    return primera[0].strip()


def fraccion(valor: Any, campo: str) -> Fraction:
    try:
        numero = Fraction(str(valor))
    except (ValueError, ZeroDivisionError):
        fallar(f"metadato racional invalido en {campo}: {valor!r}")
    if numero <= 0:
        fallar(f"metadato no positivo en {campo}: {valor!r}")
    return numero


def entero_positivo(valor: Any, campo: str) -> int:
    try:
        numero = int(str(valor))
    except (TypeError, ValueError):
        fallar(f"metadato entero invalido en {campo}: {valor!r}")
    if numero <= 0:
        fallar(f"metadato no positivo en {campo}: {valor!r}")
    return numero


def sondear(entrada: str, *, pass_fds: tuple[int, ...] = ()) -> dict[str, Any]:
    resultado = ejecutar(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-show_entries",
            (
                "format=format_name,duration:"
                "stream=index,codec_type,codec_name,width,height,pix_fmt,"
                "r_frame_rate,avg_frame_rate,time_base,duration,duration_ts,"
                "nb_frames,nb_read_frames,sample_fmt,sample_rate,channels,channel_layout"
            ),
            "-of",
            "json",
            entrada,
        ],
        f"inspeccionar '{entrada}' con ffprobe",
        pass_fds=pass_fds,
    )
    try:
        datos = json.loads(resultado.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fallar(f"ffprobe devolvio JSON invalido: {exc}")
    if not isinstance(datos, dict) or not isinstance(datos.get("streams"), list):
        fallar("ffprobe devolvio una estructura incompleta")
    streams = datos["streams"]
    videos = [x for x in streams if isinstance(x, dict) and x.get("codec_type") == "video"]
    audios = [x for x in streams if isinstance(x, dict) and x.get("codec_type") == "audio"]
    otros = [x for x in streams if isinstance(x, dict) and x.get("codec_type") not in {"video", "audio"}]
    if len(videos) != 1 or len(audios) != 1 or otros:
        fallar(
            "se exige exactamente un stream de video y uno de audio, sin extras; "
            f"encontrados video={len(videos)}, audio={len(audios)}, otros={len(otros)}"
        )
    video, audio = videos[0], audios[0]
    ancho = entero_positivo(video.get("width"), "video.width")
    alto = entero_positivo(video.get("height"), "video.height")
    fps = fraccion(video.get("r_frame_rate"), "video.r_frame_rate")
    fps_promedio = fraccion(video.get("avg_frame_rate"), "video.avg_frame_rate")
    if fps != fps_promedio:
        fallar(f"la fuente debe ser CFR; r_frame_rate={fps}, avg_frame_rate={fps_promedio}")
    cuadros = entero_positivo(video.get("nb_read_frames"), "video.nb_read_frames")
    if video.get("nb_frames") not in (None, "N/A"):
        declarados = entero_positivo(video.get("nb_frames"), "video.nb_frames")
        if declarados != cuadros:
            fallar(f"conteo de cuadros inconsistente: declarado={declarados}, decodificado={cuadros}")
    tb_video = fraccion(video.get("time_base"), "video.time_base")
    duracion_ts_video = entero_positivo(video.get("duration_ts"), "video.duration_ts")
    duracion_video = tb_video * duracion_ts_video
    duracion_por_cuadros = Fraction(cuadros, 1) / fps
    if duracion_video != duracion_por_cuadros:
        fallar(
            "linea de tiempo de video no exacta: "
            f"duration_ts*time_base={duracion_video}, frames/fps={duracion_por_cuadros}"
        )
    frecuencia = entero_positivo(audio.get("sample_rate"), "audio.sample_rate")
    canales = entero_positivo(audio.get("channels"), "audio.channels")
    tb_audio = fraccion(audio.get("time_base"), "audio.time_base")
    duracion_ts_audio_raw = audio.get("duration_ts")
    if duracion_ts_audio_raw in (None, "N/A"):
        duracion_ts_audio = None
        duracion_audio = None
    else:
        duracion_ts_audio = entero_positivo(duracion_ts_audio_raw, "audio.duration_ts")
        duracion_audio = tb_audio * duracion_ts_audio
    formato = datos.get("format")
    if not isinstance(formato, dict) or formato.get("duration") in (None, "N/A"):
        fallar("ffprobe no devolvio duracion del contenedor")
    try:
        duracion_contenedor = Decimal(str(formato["duration"]))
    except InvalidOperation:
        fallar(f"duracion de contenedor invalida: {formato.get('duration')!r}")
    if not duracion_contenedor.is_finite() or duracion_contenedor <= 0:
        fallar(f"duracion de contenedor no positiva: {duracion_contenedor}")
    return {
        "raw": datos,
        "video": video,
        "audio": audio,
        "width": ancho,
        "height": alto,
        "fps": fps,
        "frames": cuadros,
        "video_duration": duracion_video,
        "audio_duration": duracion_audio,
        "container_duration": duracion_contenedor,
        "sample_rate": frecuencia,
        "channels": canales,
    }


def asignar_duracion_pcm(info: dict[str, Any], pcm_bytes: int) -> None:
    bytes_por_muestra = 2 * info["channels"]
    if pcm_bytes <= 0 or pcm_bytes % bytes_por_muestra:
        fallar(
            "la decodificacion pcm_s16le no contiene un numero entero de muestras "
            f"por canal: bytes={pcm_bytes}, canales={info['channels']}"
        )
    duracion = Fraction(pcm_bytes // bytes_por_muestra, info["sample_rate"])
    declarada = info.get("audio_duration")
    if declarada is not None and declarada != duracion:
        fallar(
            "duracion de audio declarada no coincide con las muestras decodificadas: "
            f"declarada={declarada}, PCM={duracion}"
        )
    info["audio_duration"] = duracion


def resumen_sondeo(info: dict[str, Any]) -> dict[str, Any]:
    return {
        "width": info["width"],
        "height": info["height"],
        "fps": str(info["fps"]),
        "frames": info["frames"],
        "video_duration": str(info["video_duration"]),
        "audio_duration": str(info["audio_duration"]),
        "container_duration": str(info["container_duration"]),
        "video_time_base": str(fraccion(info["video"]["time_base"], "video.time_base")),
        "video_duration_ts": entero_positivo(info["video"]["duration_ts"], "video.duration_ts"),
        "audio_time_base": str(fraccion(info["audio"]["time_base"], "audio.time_base")),
        "audio_duration_ts": (
            None
            if info["audio"].get("duration_ts") in (None, "N/A")
            else entero_positivo(info["audio"]["duration_ts"], "audio.duration_ts")
        ),
        "sample_rate": info["sample_rate"],
        "channels": info["channels"],
        "video_codec": info["video"].get("codec_name"),
        "audio_codec": info["audio"].get("codec_name"),
        "pixel_format": info["video"].get("pix_fmt"),
        "sample_format": info["audio"].get("sample_fmt"),
        "channel_layout": info["audio"].get("channel_layout", ""),
    }


def validar_contrato_salida(fuente: dict[str, Any], salida: dict[str, Any]) -> None:
    iguales = (
        "width",
        "height",
        "fps",
        "frames",
        "video_duration",
        "audio_duration",
        "container_duration",
        "sample_rate",
        "channels",
    )
    diferencias = [campo for campo in iguales if fuente[campo] != salida[campo]]
    if diferencias:
        detalle = ", ".join(f"{x}: {fuente[x]} != {salida[x]}" for x in diferencias)
        fallar(f"la salida no conservo exactamente geometria/FPS/conteo/duracion/audio: {detalle}")
    if salida["video"].get("codec_name") != "mjpeg":
        fallar(f"codec de video de salida inesperado: {salida['video'].get('codec_name')!r}")
    if salida["audio"].get("codec_name") != "pcm_s16le":
        fallar(f"codec de audio de salida inesperado: {salida['audio'].get('codec_name')!r}")


def hash_pcm(entrada: str, *, pass_fds: tuple[int, ...] = ()) -> tuple[str, int]:
    comando = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-v",
        "error",
        "-xerror",
        "-i",
        entrada,
        "-map",
        "0:a:0",
        "-c:a",
        "pcm_s16le",
        "-f",
        "s16le",
        "-",
    ]
    try:
        proceso = subprocess.Popen(
            comando,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=pass_fds,
        )
    except (FileNotFoundError, OSError) as exc:
        fallar(f"no se pudo iniciar ffmpeg para verificar audio PCM: {exc}")
    assert proceso.stdout is not None
    h = hashlib.sha256()
    cantidad = 0
    while bloque := proceso.stdout.read(1024 * 1024):
        h.update(bloque)
        cantidad += len(bloque)
    _, stderr = proceso.communicate()
    if proceso.returncode != 0:
        fallar(
            "fallo la decodificacion PCM de audio: "
            + stderr.decode("utf-8", "replace").strip()[-1200:]
        )
    if cantidad <= 0:
        fallar("la decodificacion PCM no produjo muestras")
    return h.hexdigest(), cantidad


def decodificar_completo(entrada: str, *, pass_fds: tuple[int, ...] = ()) -> None:
    ejecutar(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-v",
            "error",
            "-xerror",
            "-i",
            entrada,
            "-map",
            "0:v:0",
            "-map",
            "0:a:0",
            "-f",
            "null",
            "-",
        ],
        f"decodificar completamente '{entrada}'",
        pass_fds=pass_fds,
    )


def filtro_grano(seed: int, fuerza: int) -> str:
    return (
        "format=yuvj420p,"
        f"noise=c0_seed={seed}:c0_strength={fuerza}:c0_flags=t+u"
    )


def numero_decimal(valor: str, nombre: str) -> Decimal:
    try:
        numero = Decimal(valor)
    except InvalidOperation:
        fallar(f"{nombre} debe ser un numero decimal finito no negativo")
    if not numero.is_finite() or numero < 0:
        fallar(f"{nombre} debe ser un numero decimal finito no negativo")
    return numero


def validar_invariantes_fuente(
    ruta: Path,
    descriptor: BinaryIO,
    stat_inicial: os.stat_result,
    sha_inicial: str,
) -> None:
    stat_final = os.fstat(descriptor.fileno())
    campos = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(stat_inicial, x) != getattr(stat_final, x) for x in campos):
        fallar("la fuente cambio mientras se procesaba; no se publica")
    if sha_archivo_objeto(descriptor) != sha_inicial:
        fallar("los bytes de la fuente cambiaron mientras se procesaba; no se publica")
    try:
        stat_ruta = ruta.stat(follow_symlinks=False)
    except OSError as exc:
        fallar(f"la ruta fuente dejo de ser verificable durante el proceso: {exc}")
    if (stat_ruta.st_dev, stat_ruta.st_ino) != (stat_inicial.st_dev, stat_inicial.st_ino):
        fallar("la ruta fuente fue sustituida mientras se procesaba; no se publica")


def fsync_ruta(ruta: Path) -> None:
    try:
        fd = os.open(ruta, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        fallar(f"no se pudo sincronizar '{ruta}': {exc}")


def publicar_sin_pisar(video_stage: Path, manifest_stage: Path, salida: Path, manifest: Path) -> None:
    video_publicado = False
    try:
        os.link(video_stage, salida, follow_symlinks=False)
        video_publicado = True
        os.link(manifest_stage, manifest, follow_symlinks=False)
        fsync_ruta(salida.parent)
    except FileExistsError as exc:
        if video_publicado:
            try:
                actual = salida.stat(follow_symlinks=False)
                staged = video_stage.stat(follow_symlinks=False)
                if (actual.st_dev, actual.st_ino) == (staged.st_dev, staged.st_ino):
                    salida.unlink()
            except OSError:
                pass
        fallar(f"publicacion rechazada: la salida o manifiesto ya existe ({exc.filename})")
    except OSError as exc:
        if video_publicado:
            try:
                actual = salida.stat(follow_symlinks=False)
                staged = video_stage.stat(follow_symlinks=False)
                if (actual.st_dev, actual.st_ino) == (staged.st_dev, staged.st_ino):
                    salida.unlink()
            except OSError:
                pass
        fallar(f"no se pudo publicar atomicamente sin sobreescribir: {exc}")


def fingerprint_manifest(cuerpo: dict[str, Any]) -> str:
    return sha_bytes(canonical(cuerpo))


def construir_manifest(
    *,
    fuente: Path,
    salida: Path,
    sha_fuente: str,
    sha_salida: str,
    sha_frame: str,
    info_fuente: dict[str, Any],
    info_salida: dict[str, Any],
    at_input: str,
    frame_index: int,
    seed: int,
    grain: int,
    filtro: str,
    pcm_sha: str,
    pcm_bytes: int,
) -> dict[str, Any]:
    cuerpo: dict[str, Any] = {
        "schema": SCHEMA,
        "source": {
            "path": str(fuente),
            "sha256": sha_fuente,
            "probe": resumen_sondeo(info_fuente),
        },
        "output": {
            "path": str(salida),
            "sha256": sha_salida,
            "probe": resumen_sondeo(info_salida),
        },
        "parameters": {
            "at_seconds": at_input,
            "selected_frame_index_zero_based": frame_index,
            "selected_frame_timestamp": str(Fraction(frame_index, 1) / info_fuente["fps"]),
            "selected_frame_sha256": sha_frame,
            "seed": seed,
            "grain_luma_strength": grain,
        },
        "audio": {
            "policy": "source decoded to pcm_s16le without resampling or channel remix",
            "decoded_pcm_s16le_sha256": pcm_sha,
            "decoded_pcm_s16le_bytes": pcm_bytes,
            "voice_analysis": "not_performed",
        },
        "render": {
            "video_codec": "mjpeg",
            "audio_codec": "pcm_s16le",
            "pixel_format": "yuvj420p",
            "filter": filtro,
            "command_template": (
                "ffmpeg -loop 1 -framerate FPS -i FRAME -i SOURCE -map 0:v:0 "
                "-map 1:a:0 -vf FILTER -frames:v N -fps_mode cfr -c:v mjpeg "
                "-q:v 2 -pix_fmt yuvj420p -threads:v 1 -c:a pcm_s16le -f avi OUTPUT"
            ),
            "ffmpeg_version": version_herramienta("ffmpeg"),
            "ffprobe_version": version_herramienta("ffprobe"),
        },
        "validation": {
            "full_av_decode": True,
            "exact_geometry_fps_frame_count_duration": True,
            "source_output_decoded_audio_equal": True,
            "semantic_or_voice_quality_assessed": False,
        },
    }
    cuerpo["manifest_fingerprint"] = fingerprint_manifest(cuerpo)
    return cuerpo


def crear(args: argparse.Namespace) -> None:
    if args.source is None or args.at is None or args.seed is None or args.output is None:
        fallar("crear exige --source, --at, --seed y --output")
    if not (0 <= args.seed <= MAX_SEED):
        fallar(f"--seed debe estar entre 0 y {MAX_SEED}")
    if not (GRAIN_MIN <= args.grain <= GRAIN_MAX):
        fallar(f"--grain debe estar entre {GRAIN_MIN} y {GRAIN_MAX}")
    at = numero_decimal(args.at, "--at")
    fuente = ruta_absoluta_sin_symlinks(args.source, debe_existir=True, descripcion="la fuente")
    salida = ruta_absoluta_sin_symlinks(args.output, debe_existir=False, descripcion="la salida")
    if salida.suffix.lower() != ".avi":
        fallar("--output debe terminar en .avi para declarar el contenedor compatible")
    padre = ruta_absoluta_sin_symlinks(
        str(salida.parent), debe_existir=True, descripcion="el directorio de salida"
    )
    if not padre.is_dir():
        fallar(f"el directorio de salida no es un directorio regular: '{padre}'")
    manifest = Path(str(salida) + ".manifest.json")
    if os.path.lexists(salida) or os.path.lexists(manifest):
        fallar("la salida o su manifiesto ya existe; nunca se sobreescribe")

    with abrir_regular_sin_symlink(fuente, "la fuente") as archivo_fuente:
        fd = archivo_fuente.fileno()
        stat_inicial = os.fstat(fd)
        sha_fuente = sha_archivo_objeto(archivo_fuente)
        entrada_fd = f"/proc/self/fd/{fd}"
        info_fuente = sondear(entrada_fd, pass_fds=(fd,))
        instante = Fraction(at)
        if instante >= info_fuente["video_duration"]:
            fallar(
                f"--at={at} cae fuera de la duracion de video "
                f"({float(info_fuente['video_duration']):.6f}s)"
            )
        frame_index = math.floor(instante * info_fuente["fps"])
        if frame_index < 0 or frame_index >= info_fuente["frames"]:
            fallar(f"--at seleccionaria un cuadro inexistente: indice {frame_index}")
        pcm_sha_fuente, pcm_bytes_fuente = hash_pcm(entrada_fd, pass_fds=(fd,))
        asignar_duracion_pcm(info_fuente, pcm_bytes_fuente)
        filtro = filtro_grano(args.seed, args.grain)

        stage_dir = Path(tempfile.mkdtemp(prefix=f".{salida.name}.tmp.", dir=padre))
        try:
            frame = stage_dir / "frame.png"
            video_stage = stage_dir / "video.avi"
            manifest_stage = stage_dir / "manifest.json"
            expresion = f"select=eq(n\\,{frame_index})"
            ejecutar(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-hide_banner",
                    "-v",
                    "error",
                    "-xerror",
                    "-i",
                    entrada_fd,
                    "-map",
                    "0:v:0",
                    "-vf",
                    expresion,
                    "-fps_mode",
                    "vfr",
                    "-frames:v",
                    "1",
                    "-c:v",
                    "png",
                    str(frame),
                ],
                f"extraer el cuadro {frame_index}",
                pass_fds=(fd,),
            )
            if not frame.is_file() or frame.stat().st_size <= 0:
                fallar("ffmpeg no produjo el fotograma seleccionado")
            sha_frame = sha_ruta(frame)

            fps_texto = f"{info_fuente['fps'].numerator}/{info_fuente['fps'].denominator}"
            ejecutar(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-hide_banner",
                    "-v",
                    "error",
                    "-xerror",
                    "-loop",
                    "1",
                    "-framerate",
                    fps_texto,
                    "-i",
                    str(frame),
                    "-i",
                    entrada_fd,
                    "-map",
                    "0:v:0",
                    "-map",
                    "1:a:0",
                    "-vf",
                    filtro,
                    "-frames:v",
                    str(info_fuente["frames"]),
                    "-fps_mode",
                    "cfr",
                    "-c:v",
                    "mjpeg",
                    "-q:v",
                    "2",
                    "-pix_fmt",
                    "yuvj420p",
                    "-threads:v",
                    "1",
                    "-c:a",
                    "pcm_s16le",
                    "-map_metadata",
                    "-1",
                    "-map_chapters",
                    "-1",
                    "-fflags",
                    "+bitexact",
                    "-flags:v",
                    "+bitexact",
                    "-flags:a",
                    "+bitexact",
                    "-f",
                    "avi",
                    str(video_stage),
                ],
                "renderizar el plano estatico",
                pass_fds=(fd,),
            )
            if not video_stage.is_file() or video_stage.stat().st_size <= 0:
                fallar("ffmpeg no produjo un video de salida regular")
            decodificar_completo(str(video_stage))
            info_salida = sondear(str(video_stage))
            pcm_sha_salida, pcm_bytes_salida = hash_pcm(str(video_stage))
            asignar_duracion_pcm(info_salida, pcm_bytes_salida)
            validar_contrato_salida(info_fuente, info_salida)
            if (pcm_sha_salida, pcm_bytes_salida) != (pcm_sha_fuente, pcm_bytes_fuente):
                fallar(
                    "el audio PCM de salida difiere de la fuente: "
                    f"sha/bytes fuente={pcm_sha_fuente}/{pcm_bytes_fuente}, "
                    f"salida={pcm_sha_salida}/{pcm_bytes_salida}"
                )
            validar_invariantes_fuente(fuente, archivo_fuente, stat_inicial, sha_fuente)
            sha_salida = sha_ruta(video_stage)
            datos_manifest = construir_manifest(
                fuente=fuente,
                salida=salida,
                sha_fuente=sha_fuente,
                sha_salida=sha_salida,
                sha_frame=sha_frame,
                info_fuente=info_fuente,
                info_salida=info_salida,
                at_input=str(at),
                frame_index=frame_index,
                seed=args.seed,
                grain=args.grain,
                filtro=filtro,
                pcm_sha=pcm_sha_fuente,
                pcm_bytes=pcm_bytes_fuente,
            )
            try:
                with manifest_stage.open("xb") as archivo_manifest:
                    archivo_manifest.write(canonical(datos_manifest))
                    archivo_manifest.flush()
                    os.fsync(archivo_manifest.fileno())
            except OSError as exc:
                fallar(f"no se pudo crear el manifiesto staged: {exc}")
            fsync_ruta(video_stage)
            publicar_sin_pisar(video_stage, manifest_stage, salida, manifest)
        finally:
            shutil.rmtree(stage_dir, ignore_errors=True)
    sys.stdout.write(f"plano estabilizado publicado: {salida}\nmanifiesto: {manifest}\n")


def cargar_manifest(ruta: Path) -> dict[str, Any]:
    ruta_absoluta_sin_symlinks(str(ruta), debe_existir=True, descripcion="el manifiesto")
    with abrir_regular_sin_symlink(ruta, "el manifiesto") as archivo:
        try:
            datos = json.load(archivo)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fallar(f"manifiesto JSON invalido: {exc}")
    if not isinstance(datos, dict) or datos.get("schema") != SCHEMA:
        fallar(f"schema de manifiesto invalido; se esperaba '{SCHEMA}'")
    fingerprint = datos.get("manifest_fingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        fallar("manifest_fingerprint ausente o invalido")
    cuerpo = dict(datos)
    del cuerpo["manifest_fingerprint"]
    esperado = fingerprint_manifest(cuerpo)
    if not hmac.compare_digest(fingerprint, esperado):
        fallar("manifiesto alterado: manifest_fingerprint no coincide")
    return datos


def verificar(args: argparse.Namespace) -> None:
    if args.output is None:
        fallar("--verify exige --output")
    if args.source is not None or args.at is not None or args.seed is not None:
        fallar("--verify no acepta --source, --at ni --seed")
    salida = ruta_absoluta_sin_symlinks(args.output, debe_existir=True, descripcion="la salida")
    manifest_ruta = Path(str(salida) + ".manifest.json")
    datos = cargar_manifest(manifest_ruta)
    try:
        salida_manifest = datos["output"]["path"]
        fuente_manifest = datos["source"]["path"]
        sha_salida_esperado = datos["output"]["sha256"]
        sha_fuente_esperado = datos["source"]["sha256"]
        parametros = datos["parameters"]
        filtro = datos["render"]["filter"]
        pcm_sha_esperado = datos["audio"]["decoded_pcm_s16le_sha256"]
        pcm_bytes_esperado = datos["audio"]["decoded_pcm_s16le_bytes"]
    except (KeyError, TypeError):
        fallar("manifiesto incompleto")
    if salida_manifest != str(salida):
        fallar(f"el manifiesto pertenece a otra salida: '{salida_manifest}'")
    if not all(isinstance(x, str) and len(x) == 64 for x in (sha_salida_esperado, sha_fuente_esperado, pcm_sha_esperado)):
        fallar("uno de los SHA-256 del manifiesto es invalido")
    try:
        seed = int(parametros["seed"])
        grain = int(parametros["grain_luma_strength"])
    except (KeyError, TypeError, ValueError):
        fallar("parametros seed/grain invalidos en manifiesto")
    if filtro != filtro_grano(seed, grain):
        fallar("el filtro registrado no corresponde a seed/grain")
    fuente = ruta_absoluta_sin_symlinks(
        str(fuente_manifest), debe_existir=True, descripcion="la fuente registrada"
    )
    if sha_ruta(salida) != sha_salida_esperado:
        fallar("SHA-256 de salida no coincide con el manifiesto")
    if sha_ruta(fuente) != sha_fuente_esperado:
        fallar("SHA-256 de fuente no coincide con el manifiesto")
    with abrir_regular_sin_symlink(fuente, "la fuente registrada") as archivo_fuente:
        fd = archivo_fuente.fileno()
        entrada_fd = f"/proc/self/fd/{fd}"
        info_fuente = sondear(entrada_fd, pass_fds=(fd,))
        pcm_sha_fuente, pcm_bytes_fuente = hash_pcm(entrada_fd, pass_fds=(fd,))
    decodificar_completo(str(salida))
    info_salida = sondear(str(salida))
    pcm_sha_salida, pcm_bytes_salida = hash_pcm(str(salida))
    asignar_duracion_pcm(info_fuente, pcm_bytes_fuente)
    asignar_duracion_pcm(info_salida, pcm_bytes_salida)
    validar_contrato_salida(info_fuente, info_salida)
    esperado = (pcm_sha_esperado, int(pcm_bytes_esperado))
    if (pcm_sha_fuente, pcm_bytes_fuente) != esperado or (pcm_sha_salida, pcm_bytes_salida) != esperado:
        fallar("el audio PCM ya no coincide entre fuente, salida y manifiesto")
    if datos["source"].get("probe") != resumen_sondeo(info_fuente):
        fallar("los metadatos de fuente ya no coinciden con el manifiesto")
    if datos["output"].get("probe") != resumen_sondeo(info_salida):
        fallar("los metadatos de salida ya no coinciden con el manifiesto")
    sys.stdout.write(f"verificacion OK: {salida}\n")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Deriva B-roll estatico reproducible (MJPEG+PCM) desde un fotograma fuente; "
            "no evalua voz ni semantica."
        )
    )
    p.add_argument("--source", help="video fuente regular, sin symlinks")
    p.add_argument("--at", help="segundo del que tomar el cuadro (incluyente)")
    p.add_argument("--output", required=True, help="salida .avi; nunca se sobreescribe")
    p.add_argument("--seed", type=int, help="semilla explicita del grano temporal")
    p.add_argument(
        "--grain",
        type=int,
        default=GRAIN_DEFAULT,
        help=f"fuerza de grano luma, {GRAIN_MIN}-{GRAIN_MAX} (default: {GRAIN_DEFAULT})",
    )
    p.add_argument("--verify", action="store_true", help="verifica salida y manifiesto existentes")
    return p


def main() -> int:
    args = parser().parse_args()
    try:
        if args.verify:
            verificar(args)
        else:
            crear(args)
    except ErrorEstabilizacion as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
