#!/usr/bin/env python3
"""Evaluador fuerte V2 para obras MiniMax-H3.

La unidad de evaluacion es la toma descrita por ``plan.json``. Las medidas
temporales nunca usan como referencia otra toma: un cambio legitimo de escena
no puede convertirse en un falso defecto por comparar sus bordes con el plano
anterior.

Estados y codigos de salida:
  PASS=0, FAIL=1, ERROR=2, REVIEW=3.

``REVIEW`` es deliberado. ASR, deteccion facial e identidad son comprobaciones
semanticas; si son necesarias y su backend no esta disponible, el valor es
UNKNOWN y la obra no puede aprobar. El informe tampoco publica una nota total
cuando falta cobertura semantica.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import unicodedata
from array import array
from pathlib import Path
from typing import Any, Iterable


VERSION = "2.2.0"
SCHEMA = "minimax-h3.evaluacion-fuerte/v2"
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "calidad" / "perfiles" / "estricto-v2.json"
DEFAULT_YUNET = ROOT / "modelos" / "evaluacion" / "face_detection_yunet_2023mar.onnx"
DEFAULT_SFACE = ROOT / "modelos" / "evaluacion" / "face_recognition_sface_2021dec.onnx"
DEFAULT_WHISPER = ROOT / "modelos" / "evaluacion" / "ggml-small.bin"
DEFAULT_WHISPER_VAD = ROOT / "modelos" / "evaluacion" / "ggml-silero-v6.2.0.bin"
EXIT = {"PASS": 0, "FAIL": 1, "ERROR": 2, "REVIEW": 3}
ORDER = {"NA": -1, "PASS": 0, "UNKNOWN": 1, "REVIEW": 2, "FAIL": 3, "ERROR": 4}


class EvaluationError(RuntimeError):
    pass


def run(cmd: list[str], timeout: float = 180.0) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvaluationError(f"no se pudo ejecutar {cmd[0]}: {exc}") from exc


def text_run(cmd: list[str], timeout: float = 180.0) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvaluationError(f"no se pudo ejecutar {cmd[0]}: {exc}") from exc


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"{label} invalido ({path}): {exc}") from exc
    if not isinstance(value, dict):
        raise EvaluationError(f"{label} no es un objeto JSON: {path}")
    return value


def gate(gate_id: str, status: str, reason: str, **extra: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"id": gate_id, "status": status, "reason": reason}
    out.update({k: v for k, v in extra.items() if v is not None})
    return out


def worst_status(gates: Iterable[dict[str, Any]]) -> str:
    statuses = [g.get("status", "ERROR") for g in gates if not g.get("advisory", False)]
    if any(s == "ERROR" for s in statuses):
        return "ERROR"
    if any(s == "FAIL" for s in statuses):
        return "FAIL"
    if any(s in ("REVIEW", "UNKNOWN") for s in statuses):
        return "REVIEW"
    return "PASS"


def finite(value: float | None) -> float | None:
    return value if value is not None and math.isfinite(value) else None


def rounded(value: float | None, digits: int = 4) -> float | None:
    value = finite(value)
    return round(value, digits) if value is not None else None


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo = int(math.floor(pos)); hi = int(math.ceil(pos))
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)


def ratio(raw: str | None) -> float | None:
    if not raw or raw in ("N/A", "0/0"):
        return None
    try:
        if "/" in raw:
            a, b = raw.split("/", 1)
            return float(a) / float(b)
        return float(raw)
    except (ValueError, ZeroDivisionError):
        return None


def probe(path: Path) -> dict[str, Any]:
    cp = run([
        "ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format",
        "-of", "json", str(path),
    ], timeout=60)
    if cp.returncode:
        raise EvaluationError(cp.stderr.decode("utf-8", "replace").strip() or "ffprobe fallo")
    try:
        return json.loads(cp.stdout)
    except json.JSONDecodeError as exc:
        raise EvaluationError(f"ffprobe devolvio JSON invalido para {path}") from exc


def media_integrity(path: Path, take: dict[str, Any], profile: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cfg = profile["integridad"]
    gates: list[dict[str, Any]] = []
    try:
        info = probe(path)
    except EvaluationError as exc:
        return {"probe_error": str(exc)}, [gate("technical.probe", "ERROR", str(exc))]
    streams = info.get("streams") or []
    videos = [s for s in streams if s.get("codec_type") == "video"]
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    if not videos:
        return {"streams": len(streams)}, [gate("technical.video", "FAIL", "no hay stream de video")]
    v = videos[0]
    width = int(v.get("width") or 0); height = int(v.get("height") or 0)
    fps = ratio(v.get("avg_frame_rate")) or ratio(v.get("r_frame_rate"))
    raw_duration = v.get("duration") or (info.get("format") or {}).get("duration")
    try:
        duration = float(raw_duration)
    except (TypeError, ValueError):
        duration = None
    try:
        raw_frames = v.get("nb_read_frames") if v.get("nb_read_frames") not in (None, "N/A") else v.get("nb_frames")
        frames = int(raw_frames) if raw_frames not in (None, "N/A") else None
    except ValueError:
        frames = None
    expected_w = int(take.get("width") or 0); expected_h = int(take.get("height") or 0)
    expected_fps = float(take.get("fps") or 0)
    expected_frames = int(take.get("frames") or 0)
    expected_duration = expected_frames / expected_fps if expected_frames and expected_fps else None

    gates.append(gate(
        "technical.video", "PASS", "stream de video presente",
        codec=v.get("codec_name"), width=width, height=height, fps=rounded(fps),
    ))
    if expected_w and expected_h and (width, height) != (expected_w, expected_h):
        gates.append(gate("technical.geometry", "FAIL", "resolucion distinta del plan", value=[width, height], expected=[expected_w, expected_h]))
    else:
        gates.append(gate("technical.geometry", "PASS", "resolucion coincide con el plan", value=[width, height]))
    fps_tol = float(cfg["tolerancia_fps_relativa"])
    if expected_fps and (fps is None or abs(fps - expected_fps) / expected_fps > fps_tol):
        gates.append(gate("technical.fps", "FAIL", "fps distinto del plan", value=rounded(fps), expected=expected_fps))
    else:
        gates.append(gate("technical.fps", "PASS", "fps coincide con el plan", value=rounded(fps)))
    duration_tol = float(cfg["tolerancia_duracion_s"])
    if expected_duration is not None and (duration is None or abs(duration - expected_duration) > duration_tol):
        gates.append(gate("technical.duration", "FAIL", "duracion distinta del plan", value=rounded(duration), expected=rounded(expected_duration), tolerance=duration_tol))
    else:
        gates.append(gate("technical.duration", "PASS", "duracion coincide con el plan", value=rounded(duration)))
    if expected_frames and frames is not None and abs(frames - expected_frames) > 1:
        gates.append(gate("technical.frame_count", "FAIL", "cantidad de frames distinta del plan", value=frames, expected=expected_frames))
    elif frames is None:
        gates.append(gate("technical.frame_count", "REVIEW", "el contenedor no permitio contar frames"))
    else:
        gates.append(gate("technical.frame_count", "PASS", "cantidad de frames coincide con el plan", value=frames))
    if cfg.get("requiere_audio", True) and not audios:
        gates.append(gate("technical.audio_stream", "FAIL", "falta el stream de audio requerido"))
    else:
        gates.append(gate("technical.audio_stream", "PASS", "stream de audio presente" if audios else "audio no requerido", streams=len(audios)))
    audio_duration = None
    if audios:
        try:
            audio_duration = float(audios[0].get("duration"))
        except (TypeError, ValueError):
            audio_duration = None
    if duration is not None and audio_duration is not None and abs(audio_duration - duration) > duration_tol:
        gates.append(gate("technical.av_duration", "FAIL", "duraciones de audio y video no coinciden", video_s=rounded(duration), audio_s=rounded(audio_duration), tolerance=duration_tol))
    elif audios and audio_duration is not None:
        gates.append(gate("technical.av_duration", "PASS", "audio y video cubren la misma toma", video_s=rounded(duration), audio_s=rounded(audio_duration)))
    elif audios:
        gates.append(gate("technical.av_duration", "NA", "el stream no declara duracion; se comprobara sobre PCM decodificado"))

    decode = run([
        "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", str(path),
        "-map", "0:v:0", "-f", "null", "-",
    ], timeout=max(90.0, (duration or 5.0) * 8.0))
    if decode.returncode:
        msg = decode.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]
        gates.append(gate("technical.decode", "FAIL", "fallo al decodificar video", detail=msg[0] if msg else None))
    else:
        gates.append(gate("technical.decode", "PASS", "video decodifica completo"))
    return {
        "video_codec": v.get("codec_name"), "audio_codecs": [a.get("codec_name") for a in audios],
        "width": width, "height": height, "fps": rounded(fps), "duration_s": rounded(duration),
        "reported_frames": frames, "audio_duration_s": rounded(audio_duration),
    }, gates


def extract_gray_frames(path: Path, fps: float, width: int, height: int) -> list[bytes]:
    cp = run([
        "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", str(path), "-an",
        "-vf", f"fps={fps:.6f},scale={width}:{height}:flags=area,format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ], timeout=300)
    if cp.returncode:
        raise EvaluationError(cp.stderr.decode("utf-8", "replace").strip() or "no pude extraer frames")
    size = width * height
    if not cp.stdout or len(cp.stdout) < size:
        raise EvaluationError("ffmpeg no entrego frames para analisis temporal")
    if len(cp.stdout) % size:
        raise EvaluationError("ffmpeg entrego un frame crudo truncado")
    return [cp.stdout[i:i + size] for i in range(0, len(cp.stdout), size)]


def mean_abs_diff(a: bytes, b: bytes) -> float:
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def best_translation(a: bytes, b: bytes, width: int, height: int) -> tuple[int, int, float]:
    """Alineacion de traslacion gruesa para separar paneo de deformacion local."""
    best = (0, 0, float("inf"))
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            total = 0; count = 0
            y0 = 3 + max(0, -dy); y1 = height - 3 - max(0, dy)
            x0 = 3 + max(0, -dx); x1 = width - 3 - max(0, dx)
            for y in range(y0, y1, 3):
                oa = y * width; ob = (y + dy) * width
                for x in range(x0, x1, 3):
                    total += abs(a[oa + x] - b[ob + x + dx]); count += 1
            score = total / count if count else float("inf")
            if score < best[2]:
                best = (dx, dy, score)
    return best


def temporal_analysis(path: Path, take_type: str, profile: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]], list[tuple[str, float, str]]]:
    analysis = profile["analisis"]; cfg = profile["temporal"]
    fps = float(analysis["temporal_fps"]); width = int(analysis["temporal_width"]); height = int(analysis["temporal_height"])
    frames = extract_gray_frames(path, fps, width, height)
    means = [sum(frame) / len(frame) for frame in frames]
    diffs = [mean_abs_diff(a, b) for a, b in zip(frames, frames[1:])]
    luma_delta = [b - a for a, b in zip(means, means[1:])]
    black = [i for i, m in enumerate(means) if m <= float(cfg["negro_luma_max"])]
    cuts = [i + 1 for i, value in enumerate(diffs) if value >= float(cfg["corte_mad_min"])]
    delta_abs = [abs(v) for v in luma_delta]
    delta_med = statistics.median(delta_abs) if delta_abs else 0.0
    delta_mad = statistics.median([abs(v - delta_med) for v in delta_abs]) if delta_abs else 0.0
    flicker_threshold = max(float(cfg["flicker_delta_luma_min"]), delta_med + 6.0 * max(delta_mad, 0.25))
    flickers = [i + 1 for i, value in enumerate(delta_abs) if value >= flicker_threshold and (i + 1) not in cuts]

    frozen_threshold = float(cfg["congelacion_mad_max"])
    longest = 0; current = 0; freeze_end = 0
    for i, value in enumerate(diffs):
        if value <= frozen_threshold:
            current += 1
            if current > longest:
                longest = current; freeze_end = i + 1
        else:
            current = 0
    freeze_seconds = longest / fps

    # La traduccion se estima sobre hasta 72 pares distribuidos por toda la toma.
    if diffs:
        step = max(1, len(diffs) // 72)
        sample_indices = list(range(0, len(diffs), step))[:72]
    else:
        sample_indices = []
    shifts: list[tuple[int, int]] = []; residuals: list[float] = []
    for i in sample_indices:
        dx, dy, residual = best_translation(frames[i], frames[i + 1], width, height)
        shifts.append((dx, dy)); residuals.append(residual)
    jitter: list[float] = []
    for (ax, ay), (bx, by) in zip(shifts, shifts[1:]):
        jitter.append(math.hypot(bx - ax, by - ay))

    black_fraction = len(black) / len(frames)
    flicker_fraction = len(flickers) / max(1, len(diffs))
    motion_median = statistics.median(diffs) if diffs else 0.0
    jitter_p95 = percentile(jitter, 0.95) or 0.0
    residual_p95 = percentile(residuals, 0.95) or 0.0
    gates: list[dict[str, Any]] = []
    anomalies: list[tuple[str, float, str]] = []

    if black_fraction > float(cfg["negro_fraccion_max"]):
        gates.append(gate("temporal.black", "FAIL", "hay frames negros o casi negros", value=rounded(black_fraction), threshold=cfg["negro_fraccion_max"]))
        anomalies.extend(("black", i / fps, "luma casi negra") for i in black[:3])
    else:
        gates.append(gate("temporal.black", "PASS", "sin tramos negros", value=rounded(black_fraction)))
    if len(cuts) > int(cfg["cortes_maximos"]):
        gates.append(gate("temporal.cuts", "FAIL", "cortes internos no previstos", value=len(cuts), threshold=cfg["cortes_maximos"]))
        anomalies.extend(("cut", i / fps, "salto temporal interno") for i in cuts[:3])
    else:
        gates.append(gate("temporal.cuts", "PASS", "sin cortes internos", value=len(cuts)))
    if flicker_fraction >= float(cfg["flicker_fraccion_fail"]):
        fs = "FAIL"
    elif flicker_fraction >= float(cfg["flicker_fraccion_review"]):
        fs = "REVIEW"
    else:
        fs = "PASS"
    gates.append(gate("temporal.flicker", fs, "parpadeo medido dentro de la toma", value=rounded(flicker_fraction), threshold=rounded(flicker_threshold)))
    if fs != "PASS":
        anomalies.extend(("flicker", i / fps, "salto brusco de luminancia") for i in flickers[:3])

    moving_types = cfg.get("movimiento_mediana_min", {})
    static_types = cfg.get("movimiento_mediana_max", {})
    if take_type in moving_types and motion_median < float(moving_types[take_type]):
        gates.append(gate("temporal.motion", "FAIL", f"el tipo {take_type} exige movimiento", value=rounded(motion_median), threshold=moving_types[take_type]))
    elif take_type in static_types and motion_median > float(static_types[take_type]):
        gates.append(gate("temporal.motion", "REVIEW", f"movimiento alto para tipo {take_type}", value=rounded(motion_median), threshold=static_types[take_type]))
    else:
        gates.append(gate("temporal.motion", "PASS", f"movimiento compatible con tipo {take_type}", value=rounded(motion_median)))

    if take_type in moving_types and freeze_seconds >= float(cfg["congelacion_s_fail_movimiento"]):
        freeze_status = "FAIL"
    elif freeze_seconds >= float(cfg["congelacion_s_review"]):
        freeze_status = "REVIEW"
    else:
        freeze_status = "PASS"
    gates.append(gate("temporal.freeze", freeze_status, "racha maxima de frames congelados", value=rounded(freeze_seconds), unit="s"))
    if freeze_status != "PASS" and longest:
        anomalies.append(("freeze", max(0.0, (freeze_end - longest / 2) / fps), "racha congelada"))

    if jitter_p95 >= float(cfg["jitter_p95_fail"]):
        js = "FAIL"
    elif jitter_p95 >= float(cfg["jitter_p95_review"]):
        js = "REVIEW"
    else:
        js = "PASS"
    gates.append(gate("temporal.jitter", js, "cambio p95 de traslacion entre frames (proxy)", value=rounded(jitter_p95)))
    if residual_p95 >= float(cfg["warping_residuo_p95_fail"]):
        ws = "FAIL"
    elif residual_p95 >= float(cfg["warping_residuo_p95_review"]):
        ws = "REVIEW"
    else:
        ws = "PASS"
    gates.append(gate("temporal.warping_proxy", ws, "residuo p95 tras alinear traslacion; no sustituye revision anatomica", value=rounded(residual_p95)))

    metrics = {
        "sampling_fps": fps, "sampled_frames": len(frames), "coverage_s": rounded(len(frames) / fps),
        "luma_mean": rounded(statistics.mean(means)), "black_fraction": rounded(black_fraction),
        "motion_mad_median": rounded(motion_median), "motion_mad_p95": rounded(percentile(diffs, 0.95)),
        "internal_cuts": len(cuts), "flicker_events": len(flickers), "flicker_fraction": rounded(flicker_fraction),
        "longest_freeze_s": rounded(freeze_seconds), "translation_jitter_p95": rounded(jitter_p95),
        "aligned_residual_p95": rounded(residual_p95),
        "scope": "intra-take-only",
    }
    return metrics, gates, anomalies


def parse_last_number(pattern: str, text: str) -> float | None:
    found = re.findall(pattern, text, flags=re.IGNORECASE | re.MULTILINE)
    for raw in reversed(found):
        if str(raw).lower() not in ("inf", "-inf"):
            try:
                return float(raw)
            except ValueError:
                pass
    return None


def audio_analysis(path: Path, take_type: str, profile: dict[str, Any], has_audio: bool, video_duration: float | None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not has_audio:
        return {"available": False}, [gate("audio.metrics", "FAIL", "no hay audio que analizar")]
    cfg = profile["audio"]
    eb = text_run([
        "ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-i", str(path), "-vn",
        "-af", "ebur128=peak=true", "-f", "null", "-",
    ], timeout=300)
    log = eb.stderr
    lufs = parse_last_number(r"\bI:\s*(-?(?:inf|\d+(?:\.\d+)?))\s+LUFS", log)
    true_peak = parse_last_number(r"\bPeak:\s*(-?(?:inf|\d+(?:\.\d+)?))\s+dBFS", log)

    hf = text_run([
        "ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-i", str(path), "-vn",
        "-af", "highpass=f=6000,astats=metadata=1:reset=0", "-f", "null", "-",
    ], timeout=300)
    hf_rms = parse_last_number(r"RMS level dB:\s*(-?(?:inf|\d+(?:\.\d+)?))", hf.stderr)

    pcm = run([
        "ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vn", "-ac", "1", "-ar", "16000",
        "-f", "s16le", "-acodec", "pcm_s16le", "-",
    ], timeout=300)
    clipping_fraction: float | None = None
    peak_sample: float | None = None
    decoded_duration: float | None = None
    if pcm.returncode == 0 and pcm.stdout:
        samples = array("h"); samples.frombytes(pcm.stdout[:len(pcm.stdout) // 2 * 2])
        if sys.byteorder != "little":
            samples.byteswap()
        if samples:
            decoded_duration = len(samples) / 16000.0
            clipped = sum(1 for value in samples if abs(value) >= 32760)
            clipping_fraction = clipped / len(samples)
            peak_sample = max(abs(value) for value in samples) / 32768.0

    gates: list[dict[str, Any]] = []
    if eb.returncode or lufs is None or true_peak is None:
        gates.append(gate("audio.ebur128", "ERROR", "ebur128 no produjo loudness y true peak validos"))
    else:
        lufs_range = cfg["lufs_por_tipo"].get(take_type, cfg["lufs_por_tipo"]["default"])
        if lufs < float(lufs_range[0]) or lufs > float(lufs_range[1]):
            gates.append(gate("audio.loudness", "FAIL", f"loudness fuera del rango para tipo {take_type}", value=rounded(lufs), range=lufs_range))
        else:
            gates.append(gate("audio.loudness", "PASS", "loudness dentro del rango", value=rounded(lufs)))
        if true_peak > float(cfg["true_peak_max_dbtp"]):
            gates.append(gate("audio.true_peak", "FAIL", "true peak sin margen suficiente", value=rounded(true_peak), threshold=cfg["true_peak_max_dbtp"]))
        else:
            gates.append(gate("audio.true_peak", "PASS", "true peak con margen", value=rounded(true_peak)))
    if clipping_fraction is None:
        gates.append(gate("audio.clipping", "ERROR", "no se pudo decodificar PCM para medir clipping"))
    elif clipping_fraction > float(cfg["clipping_fraccion_max"]):
        gates.append(gate("audio.clipping", "FAIL", "muestras recortadas", value=rounded(clipping_fraction, 7), threshold=cfg["clipping_fraccion_max"]))
    else:
        gates.append(gate("audio.clipping", "PASS", "sin clipping material", value=rounded(clipping_fraction, 7)))
    duration_tol = float(profile["integridad"]["tolerancia_duracion_s"])
    if decoded_duration is None or video_duration is None:
        gates.append(gate("technical.av_duration_decoded", "ERROR", "no se pudo comprobar sincronizacion A/V sobre PCM"))
    elif abs(decoded_duration - video_duration) > duration_tol:
        gates.append(gate("technical.av_duration_decoded", "FAIL", "audio PCM y video tienen duraciones distintas", video_s=rounded(video_duration), audio_s=rounded(decoded_duration), tolerance=duration_tol))
    else:
        gates.append(gate("technical.av_duration_decoded", "PASS", "audio PCM y video cubren la misma toma", video_s=rounded(video_duration), audio_s=rounded(decoded_duration)))
    if hf_rms is None:
        gates.append(gate("audio.hf", "REVIEW", "no se pudo medir energia por encima de 6 kHz"))
    elif hf_rms > float(cfg["hf_rms_max_db"]):
        gates.append(gate("audio.hf", "REVIEW", "energia alta en banda de ruido; escuchar", value=rounded(hf_rms), threshold=cfg["hf_rms_max_db"]))
    else:
        gates.append(gate("audio.hf", "PASS", "banda alta bajo umbral provisional", value=rounded(hf_rms)))
    return {
        "available": True, "integrated_lufs": rounded(lufs), "true_peak_dbtp": rounded(true_peak),
        "clipping_fraction": rounded(clipping_fraction, 7), "sample_peak": rounded(peak_sample, 6),
        "hf_rms_db": rounded(hf_rms), "hf_band_hz": ">6000", "decoded_duration_s": rounded(decoded_duration),
    }, gates


def as_source_advisory(gates: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Conserva el diagnostico de nivel crudo sin darle autoridad de entrega.

    La sincronizacion tecnica A/V de cada toma sigue siendo un gate duro. Solo
    los controles que el ensamblador normaliza (audio.*) pasan a SOURCE.
    """
    marked: list[dict[str, Any]] = []
    for original in gates:
        current = dict(original)
        if str(current.get("id", "")).startswith("audio."):
            current["id"] = "source." + current["id"]
            current["scope"] = "SOURCE"
            current["advisory"] = True
        marked.append(current)
    return marked


def montage_audio_analysis(path: Path, profile: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Mide el audio que realmente oye el espectador y emite gates duros."""
    try:
        info = probe(path)
    except EvaluationError as exc:
        return {"scope": "DELIVERY", "available": False, "error": str(exc)}, [
            gate("delivery.audio.probe", "ERROR", str(exc), scope="DELIVERY")
        ]
    streams = info.get("streams") or []
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    gates: list[dict[str, Any]] = []
    if not videos:
        gates.append(gate("delivery.video_stream", "FAIL", "el montaje no contiene video", scope="DELIVERY"))
        video_duration = None
    else:
        raw_duration = videos[0].get("duration") or (info.get("format") or {}).get("duration")
        try:
            video_duration = float(raw_duration)
        except (TypeError, ValueError):
            video_duration = None
        if video_duration is None:
            gates.append(gate("delivery.video_duration", "ERROR", "no se pudo medir la duracion del montaje", scope="DELIVERY"))
        else:
            gates.append(gate("delivery.video_duration", "PASS", "duracion del montaje medible", value=rounded(video_duration), unit="s", scope="DELIVERY"))

    metrics, raw_gates = audio_analysis(path, "montage", profile, bool(audios), video_duration)
    silence_limit = float(profile["audio"].get("silence_sample_peak_max", 0.0001))
    is_silent = metrics.get("sample_peak") is not None and float(metrics["sample_peak"]) <= silence_limit
    for original in raw_gates:
        current = dict(original)
        original_id = str(current.get("id", ""))
        if original_id == "technical.av_duration_decoded":
            current["id"] = "delivery.audio.duration_alignment"
        elif original_id.startswith("audio."):
            current["id"] = "delivery." + original_id
        else:
            current["id"] = "delivery.audio." + original_id
        if is_silent and original_id == "audio.ebur128" and current.get("status") == "ERROR":
            current["status"] = "FAIL"
            current["reason"] = "el montaje es silencio digital; loudness no es finito"
        current["scope"] = "DELIVERY"
        gates.append(current)

    if is_silent:
        gates.append(gate(
            "delivery.audio.silence", "FAIL", "el montaje final esta silenciado",
            value=metrics.get("sample_peak"), threshold=silence_limit, scope="DELIVERY",
        ))
    elif metrics.get("sample_peak") is None:
        gates.append(gate(
            "delivery.audio.silence", "ERROR", "no se pudo descartar silencio en el montaje final",
            scope="DELIVERY",
        ))
    else:
        gates.append(gate(
            "delivery.audio.silence", "PASS", "el montaje final contiene senal de audio",
            value=metrics.get("sample_peak"), threshold=silence_limit, scope="DELIVERY",
        ))

    decoded_duration = metrics.get("decoded_duration_s")
    coverage_ratio = None
    if video_duration and decoded_duration is not None and video_duration > 0 and float(decoded_duration) > 0:
        coverage_ratio = min(video_duration, float(decoded_duration)) / max(video_duration, float(decoded_duration))
    coverage_min = float(profile["audio"]["montage_coverage_ratio_min"])
    if not audios:
        gates.append(gate("delivery.audio.coverage", "FAIL", "el montaje no contiene audio que pueda cubrir la entrega", scope="DELIVERY"))
    elif coverage_ratio is None:
        gates.append(gate("delivery.audio.coverage", "ERROR", "no se pudo calcular la cobertura A/V final", scope="DELIVERY"))
    elif coverage_ratio < coverage_min:
        gates.append(gate("delivery.audio.coverage", "FAIL", "el audio no cubre la duracion final", value=rounded(coverage_ratio), threshold=coverage_min, scope="DELIVERY"))
    else:
        gates.append(gate("delivery.audio.coverage", "PASS", "el audio cubre la duracion final", value=rounded(coverage_ratio), threshold=coverage_min, scope="DELIVERY"))
    metrics.update({
        "scope": "DELIVERY", "authoritative": True, "path": str(path),
        "video_duration_s": rounded(video_duration), "coverage_ratio": rounded(coverage_ratio),
        "video_codec": videos[0].get("codec_name") if videos else None,
        "audio_codecs": [stream.get("codec_name") for stream in audios],
        "status": worst_status(gates), "gates": gates,
    })
    return metrics, gates


def frame_similarity(a: bytes, b: bytes) -> float:
    """Similitud perceptual simple sobre luma reducida (1 = identico)."""
    if len(a) != len(b) or not a:
        return 0.0
    return max(0.0, 1.0 - mean_abs_diff(a, b) / 255.0)


def montage_visual_correspondence(
    path: Path,
    sources: list[tuple[int, Path]],
    profile: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Compara densamente un corte final con las fuentes, en el mismo orden.

    El escalado a luma pequena tolera recompresion. El radio de un frame de
    muestreo absorbe redondeos de timestamps, sin permitir reordenar tomas.
    """
    cfg = profile["integridad"]
    sample_fps = float(cfg.get("montage_correspondence_fps", 2.0))
    width = int(cfg.get("montage_correspondence_width", 96))
    height = int(cfg.get("montage_correspondence_height", 54))
    radius = int(cfg.get("montage_alignment_radius_frames", 1))
    pass_similarity = float(cfg.get("montage_similarity_pass", 0.94))
    fail_similarity = float(cfg.get("montage_similarity_fail", 0.82))
    pass_fraction = float(cfg.get("montage_match_fraction_pass", 0.95))
    fail_fraction = float(cfg.get("montage_match_fraction_fail", 0.80))

    expected: list[bytes] = []
    groups: list[tuple[int, int, int]] = []
    for take_index, source in sources:
        frames = extract_gray_frames(source, sample_fps, width, height)
        start = len(expected)
        expected.extend(frames)
        groups.append((take_index, start, len(expected)))
    actual = extract_gray_frames(path, sample_fps, width, height)
    if not expected:
        raise EvaluationError("no hay frames fuente para validar correspondencia del montaje")

    similarities: list[float] = []
    for index, reference in enumerate(expected):
        candidates = actual[max(0, index - radius):min(len(actual), index + radius + 1)]
        similarities.append(max((frame_similarity(reference, candidate) for candidate in candidates), default=0.0))
    matched = sum(value >= pass_similarity for value in similarities)
    match_fraction = matched / len(expected)
    count_coverage = min(len(expected), len(actual)) / max(len(expected), len(actual)) if actual else 0.0
    p05 = percentile(similarities, 0.05) or 0.0
    median = statistics.median(similarities) if similarities else 0.0

    per_take: list[dict[str, Any]] = []
    for take_index, start, end in groups:
        values = similarities[start:end]
        per_take.append({
            "take": take_index,
            "sampled_frames": len(values),
            "similarity_p05": rounded(percentile(values, 0.05)),
            "similarity_median": rounded(statistics.median(values) if values else None),
            "match_fraction": rounded(sum(value >= pass_similarity for value in values) / len(values) if values else None),
        })

    if count_coverage < fail_fraction or p05 < fail_similarity or match_fraction < fail_fraction:
        status = "FAIL"
    elif count_coverage < pass_fraction or p05 < pass_similarity or match_fraction < pass_fraction:
        status = "REVIEW"
    else:
        status = "PASS"
    reason = {
        "PASS": "el corte conserva densamente las fuentes en el orden del plan",
        "REVIEW": "la correspondencia visual del corte requiere revision",
        "FAIL": "el montaje no corresponde visualmente con las fuentes en el orden del plan",
    }[status]
    metrics = {
        "sampling_fps": sample_fps,
        "sample_size": [width, height],
        "expected_sampled_frames": len(expected),
        "montage_sampled_frames": len(actual),
        "count_coverage_ratio": rounded(count_coverage),
        "similarity_p05": rounded(p05),
        "similarity_median": rounded(median),
        "match_fraction": rounded(match_fraction),
        "per_take": per_take,
        "scope": "cut-order-and-content",
    }
    return metrics, gate(
        "technical.montage.visual_correspondence", status, reason,
        value=rounded(match_fraction), pass_threshold=pass_fraction,
        fail_threshold=fail_fraction, similarity_p05=rounded(p05),
        similarity_pass_threshold=pass_similarity,
    )


def montage_video_analysis(
    path: Path,
    plan: dict[str, Any],
    results: list[dict[str, Any]],
    style: str | None,
    transition_seconds: float,
    profile: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Valida el video entregable, no solo la declaracion de transicion."""
    cfg = profile["integridad"]
    gates: list[dict[str, Any]] = []
    try:
        info = probe(path)
    except EvaluationError as exc:
        return {"scope": "DELIVERY", "error": str(exc)}, [
            gate("technical.montage.probe", "ERROR", str(exc), scope="DELIVERY")
        ]
    videos = [stream for stream in info.get("streams") or [] if stream.get("codec_type") == "video"]
    if len(videos) != 1:
        return {"scope": "DELIVERY", "video_streams": len(videos)}, [
            gate("technical.montage.video_stream", "FAIL", "el montaje debe contener exactamente un stream de video", value=len(videos), scope="DELIVERY")
        ]
    video = videos[0]
    width = int(video.get("width") or 0); height = int(video.get("height") or 0)
    fps = ratio(video.get("avg_frame_rate")) or ratio(video.get("r_frame_rate"))
    raw_duration = video.get("duration") or (info.get("format") or {}).get("duration")
    try:
        duration = float(raw_duration)
    except (TypeError, ValueError):
        duration = None
    try:
        raw_frames = video.get("nb_read_frames") if video.get("nb_read_frames") not in (None, "N/A") else video.get("nb_frames")
        frames = int(raw_frames) if raw_frames not in (None, "N/A") else None
    except (TypeError, ValueError):
        frames = None

    takes = plan.get("tomas") or []
    geometries = {(int(t.get("width") or 0), int(t.get("height") or 0)) for t in takes}
    planned_fps = {float(t.get("fps") or 0.0) for t in takes}
    expected_geometry = next(iter(geometries)) if len(geometries) == 1 else None
    expected_fps = next(iter(planned_fps)) if len(planned_fps) == 1 else None
    if expected_geometry is None or 0 in expected_geometry:
        gates.append(gate("technical.montage.geometry", "ERROR", "el plan no define una geometria unica valida", scope="DELIVERY"))
    elif (width, height) != expected_geometry:
        gates.append(gate("technical.montage.geometry", "FAIL", "la geometria del montaje difiere del plan", value=[width, height], expected=list(expected_geometry), scope="DELIVERY"))
    else:
        gates.append(gate("technical.montage.geometry", "PASS", "la geometria del montaje coincide con el plan", value=[width, height], scope="DELIVERY"))
    fps_tol = float(cfg["tolerancia_fps_relativa"])
    if expected_fps is None or expected_fps <= 0:
        gates.append(gate("technical.montage.fps", "ERROR", "el plan no define FPS unico y valido", scope="DELIVERY"))
    elif fps is None or abs(fps - expected_fps) / expected_fps > fps_tol:
        gates.append(gate("technical.montage.fps", "FAIL", "los FPS del montaje difieren del plan", value=rounded(fps), expected=expected_fps, scope="DELIVERY"))
    else:
        gates.append(gate("technical.montage.fps", "PASS", "los FPS del montaje coinciden con el plan", value=rounded(fps), scope="DELIVERY"))

    source_durations = [r.get("technical", {}).get("duration_s") for r in results]
    effective_cut = style == "cut" or len(results) <= 1
    expected_duration: float | None = None
    if all(value is not None for value in source_durations):
        expected_duration = sum(float(value) for value in source_durations)
        if style and style.lower() in {"xfade", "crossfade", "cross-dissolve", "dissolve"}:
            expected_duration -= max(0, len(source_durations) - 1) * transition_seconds
        elif not effective_cut:
            expected_duration = None
    tolerance = float(cfg.get("montage_duration_tolerance_s", cfg["tolerancia_duracion_s"]))
    if expected_duration is None:
        gates.append(gate("technical.montage.duration", "UNKNOWN", "sin estilo verificable no se puede derivar la duracion esperada", value=rounded(duration), scope="DELIVERY"))
    elif duration is None:
        gates.append(gate("technical.montage.duration", "ERROR", "no se pudo medir la duracion del montaje", expected=rounded(expected_duration), scope="DELIVERY"))
    elif abs(duration - expected_duration) > tolerance:
        gates.append(gate("technical.montage.duration", "FAIL", "la duracion del montaje no coincide con las fuentes y la transicion", value=rounded(duration), expected=rounded(expected_duration), tolerance=tolerance, scope="DELIVERY"))
    else:
        gates.append(gate("technical.montage.duration", "PASS", "la duracion del montaje coincide con las fuentes y la transicion", value=rounded(duration), expected=rounded(expected_duration), tolerance=tolerance, scope="DELIVERY"))

    expected_frames: int | None = None
    if effective_cut:
        source_frames = [r.get("technical", {}).get("reported_frames") for r in results]
        if all(value is not None for value in source_frames):
            expected_frames = sum(int(value) for value in source_frames)
    if not effective_cut:
        gates.append(gate("technical.montage.frame_count", "NA", "conteo exacto reservado para corte directo", value=frames, scope="DELIVERY"))
    elif expected_frames is None or frames is None:
        gates.append(gate("technical.montage.frame_count", "ERROR", "no se pudo demostrar el conteo completo de frames del corte", value=frames, expected=expected_frames, scope="DELIVERY"))
    elif abs(frames - expected_frames) > 1:
        gates.append(gate("technical.montage.frame_count", "FAIL", "el montaje perdio o agrego frames", value=frames, expected=expected_frames, scope="DELIVERY"))
    else:
        gates.append(gate("technical.montage.frame_count", "PASS", "el montaje conserva el conteo de frames", value=frames, expected=expected_frames, scope="DELIVERY"))

    try:
        decoded = run([
            "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", str(path),
            "-map", "0:v:0", "-f", "null", "-",
        ], timeout=max(90.0, (duration or 5.0) * 8.0))
    except EvaluationError as exc:
        gates.append(gate("technical.montage.decode", "ERROR", str(exc), scope="DELIVERY"))
    else:
        if decoded.returncode:
            tail = decoded.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]
            gates.append(gate("technical.montage.decode", "FAIL", "el montaje no decodifica completo", detail=tail[0] if tail else None, scope="DELIVERY"))
        else:
            gates.append(gate("technical.montage.decode", "PASS", "el montaje decodifica completo", scope="DELIVERY"))

    correspondence: dict[str, Any] = {}
    sources: list[tuple[int, Path]] = []
    for result in results:
        candidate = Path(str(result.get("path", "")))
        if candidate.is_file():
            sources.append((int(result["index"]), candidate))
    if not effective_cut:
        gates.append(gate("technical.montage.visual_correspondence", "UNKNOWN", "la equivalencia visual densa solo esta implementada para corte directo", scope="DELIVERY"))
    elif len(sources) != len(results):
        gates.append(gate("technical.montage.visual_correspondence", "ERROR", "faltan fuentes para comprobar el contenido y orden del montaje", scope="DELIVERY"))
    else:
        try:
            correspondence, correspondence_gate = montage_visual_correspondence(path, sources, profile)
        except EvaluationError as exc:
            gates.append(gate("technical.montage.visual_correspondence", "ERROR", str(exc), scope="DELIVERY"))
        else:
            correspondence_gate["scope"] = "DELIVERY"
            gates.append(correspondence_gate)

    return {
        "scope": "DELIVERY", "authoritative": True, "path": str(path),
        "codec": video.get("codec_name"), "width": width, "height": height,
        "fps": rounded(fps), "duration_s": rounded(duration), "reported_frames": frames,
        "expected_duration_s": rounded(expected_duration), "expected_frames": expected_frames,
        "correspondence": correspondence, "status": worst_status(gates), "gates": gates,
    }, gates


def normalize_words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return re.findall(r"[a-z0-9]+", text)


def spoken_words(text: str) -> list[str]:
    """Quita etiquetas no verbales conocidas sin borrar acotaciones reales."""
    non_speech_labels = {
        "musica", "music", "aplausos", "applause", "silencio", "silence",
        "blank audio", "inaudible", "motor", "ruido", "noise", "risas", "laughter",
        "musica suave", "soft music", "background music", "music playing",
    }
    pieces: list[str] = []
    cursor = 0
    for match in re.finditer(r"\[[^\]]*\]|\([^)]*\)|<[^>]*>", text):
        pieces.append(text[cursor:match.start()])
        label = " ".join(normalize_words(match.group(0)))
        if label not in non_speech_labels:
            pieces.append(match.group(0))
        cursor = match.end()
    pieces.append(text[cursor:])
    return normalize_words(" ".join(pieces))


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    prev = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        cur = [i]
        for j, hyp in enumerate(hypothesis, 1):
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + (ref != hyp)))
        prev = cur
    return prev[-1] / len(reference)


def collect_transcript(value: Any) -> str:
    texts: list[str] = []
    def visit(item: Any) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                if key.lower() in ("text", "transcription") and isinstance(child, str):
                    texts.append(child)
                else:
                    visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    # Algunos formatos repiten el texto agregado y los segmentos. Se prefiere
    # el fragmento mas largo para no duplicar palabras.
    return max(texts, key=len, default="").strip()


def ffmpeg_filter_escape(path: Path) -> str:
    return str(path).replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")


def transcribe_segments(
    path: Path,
    model: Path,
    vad_model: Path | None,
    *,
    queue_seconds: float | None = None,
    vad_min_silence_seconds: float | None = None,
) -> tuple[str | None, list[dict[str, Any]], str | None]:
    with tempfile.TemporaryDirectory(prefix="calidad-v2-asr-") as tmp:
        destination = Path(tmp) / "asr.json"
        filt = (
            f"whisper=model='{ffmpeg_filter_escape(model)}':language=es:use_gpu=false:"
            f"destination='{ffmpeg_filter_escape(destination)}':format=json"
        )
        if vad_model is not None:
            filt += f":vad_model='{ffmpeg_filter_escape(vad_model)}'"
        if queue_seconds is not None:
            filt += f":queue={queue_seconds:g}"
        if vad_min_silence_seconds is not None:
            filt += f":vad_min_silence_duration={vad_min_silence_seconds:g}"
        cp = text_run([
            "ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-i", str(path), "-vn",
            "-af", filt, "-f", "null", "-",
        ], timeout=900)
        if cp.returncode or not destination.exists():
            tail = cp.stderr.strip().splitlines()[-1:] or ["sin salida JSON"]
            return None, [], tail[0]
        try:
            payload = destination.read_text(encoding="utf-8")
            try:
                documents = [json.loads(payload)]
            except json.JSONDecodeError:
                # El filtro whisper de FFmpeg escribe JSON Lines: un objeto
                # por segmento, no un unico array JSON.
                documents = [json.loads(line) for line in payload.splitlines() if line.strip()]
        except (OSError, json.JSONDecodeError) as exc:
            return None, [], f"salida ASR invalida: {exc}"
        segments = [collect_transcript(document) for document in documents]
        transcript = " ".join(segment for segment in segments if segment).strip()
        timed: list[dict[str, Any]] = []
        invalid_verbal: list[str] = []
        for document, segment_text in zip(documents, segments):
            if not segment_text or not isinstance(document, dict):
                continue
            try:
                # El filtro whisper de FFmpeg expresa start/end en ms.
                start_s = float(document["start"]) / 1000.0
                end_s = float(document["end"]) / 1000.0
            except (KeyError, TypeError, ValueError):
                if spoken_words(segment_text):
                    invalid_verbal.append(segment_text)
                continue
            if math.isfinite(start_s) and math.isfinite(end_s) and end_s >= start_s >= 0:
                timed.append({"start_s": start_s, "end_s": end_s, "text": segment_text})
            elif spoken_words(segment_text):
                invalid_verbal.append(segment_text)
        if invalid_verbal:
            return transcript, timed, (
                f"ASR devolvio {len(invalid_verbal)} segmento(s) verbales sin timestamps validos"
            )
        return transcript, timed, None


def transcribe(path: Path, model: Path, vad_model: Path | None) -> tuple[str | None, str | None]:
    transcript, _, error = transcribe_segments(path, model, vad_model)
    return transcript, error


def timed_transcript_error(
    transcript: str | None,
    segments: list[dict[str, Any]],
    *,
    duration_s: float | None = None,
    tolerance_s: float = 0.25,
) -> str | None:
    """Demuestra que ninguna palabra verbal quedo fuera de la linea temporal."""
    transcript_words = spoken_words(transcript or "")
    timed_words: list[str] = []
    for segment in segments:
        words = spoken_words(str(segment.get("text") or ""))
        if not words:
            continue
        try:
            start_s = float(segment.get("start_s")); end_s = float(segment.get("end_s"))
        except (TypeError, ValueError):
            return "hay un segmento verbal sin timestamps numericos"
        if not math.isfinite(start_s) or not math.isfinite(end_s) or start_s < 0 or end_s < start_s:
            return "hay un segmento verbal con timestamps invalidos"
        if duration_s is not None and end_s > duration_s + tolerance_s:
            return "hay un segmento verbal fuera de la duracion del archivo"
        timed_words.extend(words)
    if transcript_words != timed_words:
        return "la transcripcion contiene palabras sin cobertura temporal exacta"
    return None


def speech_tail_from_segments(
    duration_s: float,
    segments: list[dict[str, Any]],
    profile: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Mide la cola limpia usando segmentos cortos de Whisper+Silero.

    El ASR principal favorece fidelidad textual y puede publicar ventanas de
    varios segundos. Para ubicar el final de la voz se usa una segunda pasada
    de cola corta. Las etiquetas no verbales no cuentan como habla. Sigue
    siendo un proxy de actividad vocal: no certifica que los labios cierren.
    """
    cfg = profile["semantica"]
    spoken_ends: list[float] = []
    for segment in segments:
        if not spoken_words(str(segment.get("text") or "")):
            continue
        try:
            end_s = float(segment.get("end_s"))
        except (TypeError, ValueError):
            continue
        if finite(end_s) is not None and end_s >= 0:
            spoken_ends.append(end_s)
    if not spoken_ends:
        metrics = {
            "available": True,
            "duration_s": rounded(duration_s),
            "last_speech_end_s": None,
            "clean_tail_s": None,
            "segments": segments,
            "method": "whisper-silero-short-queue",
            "certifies_lip_closure": False,
        }
        return metrics, [gate(
            "semantic.speech_tail", "FAIL",
            "la pasada temporal no encontro habla en una toma hablada",
        )]
    last_end = max(spoken_ends)
    clean_tail = max(0.0, duration_s - last_end)
    pass_s = float(cfg["cola_habla_pass_s"])
    fail_s = float(cfg["cola_habla_fail_s"])
    if clean_tail < fail_s:
        status = "FAIL"
        reason = "la voz llega demasiado cerca del corte final"
    elif clean_tail < pass_s:
        status = "REVIEW"
        reason = "la cola vocal es marginal y requiere revision visual"
    else:
        status = "PASS"
        reason = "hay cola vocal limpia antes del corte"
    metrics = {
        "available": True,
        "duration_s": rounded(duration_s),
        "last_speech_end_s": rounded(last_end),
        "clean_tail_s": rounded(clean_tail),
        "spoken_segments": len(spoken_ends),
        "segments": segments,
        "method": "whisper-silero-short-queue",
        "certifies_lip_closure": False,
    }
    return metrics, [gate(
        "semantic.speech_tail", status, reason,
        value=rounded(clean_tail), unit="s",
        pass_threshold=pass_s, fail_threshold=fail_s,
    )]


def speech_tail_analysis(
    path: Path,
    take: dict[str, Any],
    duration_s: float | None,
    profile: dict[str, Any],
    model: Path | None,
    vad_model: Path | None,
    capability_error: str | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cfg = profile["semantica"]
    if str(take.get("tipo") or "") not in cfg["requiere_asr_tipos"]:
        return {"required": False}, [gate(
            "semantic.speech_tail", "NA", "cola vocal no aplica a este tipo",
        )]
    if model is None or vad_model is None:
        missing = capability_error or (
            "la cola vocal exige Whisper y Silero VAD locales"
            if model is not None else "backend ASR no configurado"
        )
        return {"required": True, "available": False}, [gate(
            "semantic.speech_tail", "UNKNOWN", missing,
            capability="ffmpeg-whisper+silero-vad",
        )]
    if duration_s is None or duration_s <= 0:
        return {"required": True, "available": True}, [gate(
            "semantic.speech_tail", "ERROR", "duracion invalida para medir la cola vocal",
        )]
    transcript, segments, error = transcribe_segments(
        path, model, vad_model,
        queue_seconds=float(cfg["cola_habla_queue_s"]),
        vad_min_silence_seconds=float(cfg["cola_habla_vad_silencio_s"]),
    )
    if error is not None:
        return {
            "required": True, "available": True, "error": error,
        }, [gate(
            "semantic.speech_tail", "ERROR",
            f"fallo la pasada temporal de voz: {error}",
        )]
    coverage_error = timed_transcript_error(
        transcript, segments, duration_s=duration_s,
        tolerance_s=float(cfg["cola_habla_timestamp_tolerancia_s"]),
    )
    if coverage_error is not None:
        return {
            "required": True, "available": True, "error": coverage_error,
            "transcript": transcript, "segments": segments,
        }, [gate(
            "semantic.speech_tail", "ERROR",
            f"linea temporal de voz incompleta: {coverage_error}",
        )]
    metrics, gates = speech_tail_from_segments(duration_s, segments, profile)
    metrics.update({
        "required": True,
        "transcript": transcript,
        "queue_s": float(cfg["cola_habla_queue_s"]),
        "vad_min_silence_s": float(cfg["cola_habla_vad_silencio_s"]),
    })
    return metrics, gates


def asr_analysis(path: Path, take: dict[str, Any], profile: dict[str, Any], model: Path | None, vad_model: Path | None, capability_error: str | None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cfg = profile["semantica"]; take_type = str(take.get("tipo", ""))
    required = take_type in cfg["requiere_asr_tipos"]
    forbidden = take_type in cfg["prohibe_habla_tipos"]
    if not required and not forbidden:
        return {"required": False}, [gate("semantic.asr", "NA", "ASR no aplica a este tipo")]
    if model is None:
        reason = capability_error or "backend ASR no configurado"
        return {"required": True, "available": False}, [gate("semantic.asr", "UNKNOWN", reason, capability="ffmpeg-whisper")]
    transcript, error = transcribe(path, model, vad_model)
    if error is not None:
        return {"required": True, "available": True, "error": error}, [gate("semantic.asr", "ERROR", f"fallo el ASR solicitado: {error}")]
    content_words = spoken_words(transcript or "")
    if forbidden:
        limit = int(cfg["asr_palabras_prohibidas_max"])
        status = "FAIL" if len(content_words) > limit else "PASS"
        return {
            "required": True, "available": True, "transcript": transcript,
            "detected_words": len(content_words),
        }, [gate("semantic.forbidden_speech", status, "habla detectada en toma que la prohibe" if status == "FAIL" else "sin habla detectada", value=len(content_words), threshold=limit)]
    reference = normalize_words(str(take.get("contenido", "")))
    wer = word_error_rate(reference, content_words)
    if wer > float(cfg["asr_wer_fail"]):
        status = "FAIL"
    elif wer > float(cfg["asr_wer_pass"]):
        status = "REVIEW"
    else:
        status = "PASS"
    return {
        "required": True, "available": True, "transcript": transcript,
        "reference_words": len(reference), "detected_words": len(content_words), "wer": rounded(wer),
    }, [gate("semantic.asr_fidelity", status, "comparacion palabra a palabra contra el plan", value=rounded(wer), pass_threshold=cfg["asr_wer_pass"], fail_threshold=cfg["asr_wer_fail"])]


def as_source_semantic_advisory(gates: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Mantiene ASR de fuentes como diagnostico cuando manda la entrega final."""
    marked: list[dict[str, Any]] = []
    for original in gates:
        current = dict(original)
        if str(current.get("id", "")).startswith("semantic.asr") or current.get("id") == "semantic.forbidden_speech":
            current["id"] = "source." + str(current["id"])
            current["scope"] = "SOURCE"
            current["advisory"] = True
        marked.append(current)
    return marked


def as_source_tail_advisory(gates: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Con montaje, la cola de la fuente orienta; la entrega tiene la autoridad."""
    marked: list[dict[str, Any]] = []
    for original in gates:
        current = dict(original)
        if current.get("id") == "semantic.speech_tail":
            current["id"] = "source.semantic.speech_tail"
            current["scope"] = "SOURCE"
            current["advisory"] = True
        marked.append(current)
    return marked


def best_phrase_location(reference: list[str], hypothesis: list[str]) -> tuple[int | None, float]:
    """Localiza aproximadamente una frase para verificar el orden del guion."""
    if not reference or not hypothesis:
        return None, 1.0
    wiggle = max(2, int(math.ceil(len(reference) * 0.30)))
    shortest = max(1, len(reference) - wiggle)
    longest = min(len(hypothesis), len(reference) + wiggle)
    best_start: int | None = None; best_wer = float("inf")
    for start in range(len(hypothesis)):
        for length in range(shortest, longest + 1):
            if start + length > len(hypothesis):
                break
            value = word_error_rate(reference, hypothesis[start:start + length])
            if value < best_wer:
                best_start = start; best_wer = value
    return best_start, best_wer if math.isfinite(best_wer) else 1.0


def montage_speech_tail_windows(
    plan: dict[str, Any],
    results: list[dict[str, Any]],
    segments: list[dict[str, Any]],
    profile: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Mide cola vocal en las ventanas reales de una entrega a corte."""
    takes = plan.get("tomas") or []
    if len(results) != len(takes):
        return {"windows": []}, [gate(
            "semantic.delivery.speech_tail", "ERROR",
            "no se pueden construir ventanas de cola: fuentes y plan difieren",
            scope="DELIVERY",
        )]
    required_types = set(profile["semantica"]["requiere_asr_tipos"])
    elapsed = 0.0
    windows: list[dict[str, Any]] = []
    window_gates: list[dict[str, Any]] = []
    for position, (take, result) in enumerate(zip(takes, results), 1):
        raw_duration = result.get("technical", {}).get("duration_s")
        take_index = int(take.get("indice") or position)
        if raw_duration is None:
            if str(take.get("tipo") or "") in required_types:
                window_gates.append(gate(
                    f"semantic.delivery.speech_tail.t{take_index:02d}", "ERROR",
                    "duracion fuente desconocida", scope="DELIVERY",
                ))
            continue
        duration = float(raw_duration)
        start = elapsed; end = elapsed + duration; elapsed = end
        if str(take.get("tipo") or "") not in required_types:
            continue
        local_segments: list[dict[str, Any]] = []
        for segment in segments:
            midpoint = (float(segment["start_s"]) + float(segment["end_s"])) / 2.0
            if start <= midpoint < end or (position == len(takes) and midpoint == end):
                local_segments.append({
                    "start_s": float(segment["start_s"]) - start,
                    "end_s": float(segment["end_s"]) - start,
                    "text": str(segment.get("text") or ""),
                })
        metrics, gates = speech_tail_from_segments(duration, local_segments, profile)
        source_gate = gates[0]
        window_gate = dict(source_gate)
        window_gate["id"] = f"semantic.delivery.speech_tail.t{take_index:02d}"
        window_gate["scope"] = "DELIVERY"
        window_gates.append(window_gate)
        windows.append({
            "take": take_index,
            "start_s": rounded(start), "end_s": rounded(end),
            "last_speech_end_s": rounded(
                start + float(metrics["last_speech_end_s"])
                if metrics.get("last_speech_end_s") is not None else None
            ),
            "clean_tail_s": metrics.get("clean_tail_s"),
            "status": source_gate["status"],
        })
    aggregate_status = worst_status(window_gates)
    aggregate = gate(
        "semantic.delivery.speech_tail", aggregate_status,
        "cola vocal autoritativa por ventana del montaje final",
        windows=windows, scope="DELIVERY",
    )
    return {
        "scope": "DELIVERY", "authoritative": True,
        "method": "whisper-silero-short-queue", "windows": windows,
        "status": aggregate_status,
    }, [*window_gates, aggregate]


def montage_asr_analysis(
    path: Path,
    plan: dict[str, Any],
    results: list[dict[str, Any]],
    style: str | None,
    profile: dict[str, Any],
    model: Path | None,
    vad_model: Path | None,
    capability_error: str | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """ASR autoritativo del archivo final contra los dialogos, en orden."""
    cfg = profile["semantica"]
    required_types = set(cfg["requiere_asr_tipos"])
    forbidden_types = set(cfg["prohibe_habla_tipos"])
    dialogues = [
        (int(take.get("indice") or position), normalize_words(str(take.get("contenido", ""))))
        for position, take in enumerate(plan.get("tomas") or [], 1)
        if str(take.get("tipo", "")) in required_types
    ]
    has_forbidden_windows = any(
        str(take.get("tipo", "")) in forbidden_types for take in plan.get("tomas") or []
    )
    if not dialogues and not has_forbidden_windows:
        return {"scope": "DELIVERY", "required": False}, [
            gate("semantic.delivery.asr", "NA", "ASR no aplica al montaje", scope="DELIVERY")
        ]
    if model is None:
        reason = capability_error or "backend ASR no configurado"
        return {"scope": "DELIVERY", "required": True, "available": False}, [
            gate("semantic.delivery.asr", "UNKNOWN", reason, capability="ffmpeg-whisper", scope="DELIVERY")
        ]
    transcript, timed_segments, error = transcribe_segments(path, model, vad_model)
    if error is not None:
        return {"scope": "DELIVERY", "required": True, "available": True, "error": error}, [
            gate("semantic.delivery.asr", "ERROR", f"fallo el ASR del montaje final: {error}", scope="DELIVERY")
        ]
    content_words: list[str] = []
    if timed_segments:
        for segment in timed_segments:
            content_words.extend(spoken_words(str(segment["text"])))
    else:
        content_words = spoken_words(transcript or "")
    gates: list[dict[str, Any]] = []
    if not dialogues:
        limit = int(cfg["asr_palabras_prohibidas_max"])
        status = "FAIL" if len(content_words) > limit else "PASS"
        gates.append(gate(
            "semantic.delivery.forbidden_speech", status,
            "habla detectada en un montaje que la prohibe" if status == "FAIL" else "sin habla detectada en el montaje",
            value=len(content_words), threshold=limit, scope="DELIVERY",
        ))
        return {
            "scope": "DELIVERY", "authoritative": True, "required": True, "available": True,
            "transcript": transcript, "segments": timed_segments,
            "detected_words": len(content_words), "status": worst_status(gates), "gates": gates,
        }, gates

    reference = [word for _, phrase in dialogues for word in phrase]
    wer = word_error_rate(reference, content_words)
    if wer > float(cfg["asr_wer_fail"]):
        fidelity_status = "FAIL"
    elif wer > float(cfg["asr_wer_pass"]):
        fidelity_status = "REVIEW"
    else:
        fidelity_status = "PASS"
    gates.append(gate(
        "semantic.delivery.asr_fidelity", fidelity_status,
        "ASR del montaje final contra todos los dialogos del plan",
        value=rounded(wer), pass_threshold=cfg["asr_wer_pass"], fail_threshold=cfg["asr_wer_fail"], scope="DELIVERY",
    ))

    locations: list[dict[str, Any]] = []
    for take_index, phrase in dialogues:
        position, phrase_wer = best_phrase_location(phrase, content_words)
        locations.append({"take": take_index, "word_offset": position, "wer": rounded(phrase_wer)})
    usable = [item for item in locations if item["word_offset"] is not None and float(item["wer"]) <= float(cfg["asr_wer_fail"])]
    if len(usable) != len(locations):
        order_status = "FAIL" if fidelity_status == "FAIL" else "REVIEW"
        order_reason = "no se pudieron localizar todos los dialogos en la entrega"
    elif any(int(left["word_offset"]) >= int(right["word_offset"]) for left, right in zip(usable, usable[1:])):
        order_status = "FAIL"; order_reason = "los dialogos aparecen fuera del orden del plan"
    elif any(float(item["wer"]) > float(cfg["asr_wer_pass"]) for item in usable):
        order_status = "REVIEW"; order_reason = "el orden parece correcto, pero una frase tiene alineacion dudosa"
    else:
        order_status = "PASS"; order_reason = "los dialogos aparecen en el orden del plan"
    gates.append(gate(
        "semantic.delivery.dialogue_order", order_status, order_reason,
        positions=locations, scope="DELIVERY",
    ))

    effective_cut = style == "cut" or len(results) <= 1
    tail_report: dict[str, Any]
    if not effective_cut:
        tail_report = {"scope": "DELIVERY", "authoritative": True, "available": False}
        gates.append(gate(
            "semantic.delivery.speech_tail", "UNKNOWN",
            "la cola vocal por ventanas solo esta implementada para corte directo",
            scope="DELIVERY",
        ))
    elif vad_model is None:
        tail_report = {"scope": "DELIVERY", "authoritative": True, "available": False}
        gates.append(gate(
            "semantic.delivery.speech_tail", "UNKNOWN",
            "la cola vocal del montaje exige Silero VAD",
            capability="ffmpeg-whisper+silero-vad", scope="DELIVERY",
        ))
    else:
        tail_transcript, tail_segments, tail_error = transcribe_segments(
            path, model, vad_model,
            queue_seconds=float(cfg["cola_habla_queue_s"]),
            vad_min_silence_seconds=float(cfg["cola_habla_vad_silencio_s"]),
        )
        durations = [result.get("technical", {}).get("duration_s") for result in results]
        delivery_duration = (
            sum(float(value) for value in durations)
            if durations and all(value is not None for value in durations) else None
        )
        if tail_error is not None:
            tail_report = {
                "scope": "DELIVERY", "authoritative": True,
                "available": True, "error": tail_error,
            }
            gates.append(gate(
                "semantic.delivery.speech_tail", "ERROR",
                f"fallo la pasada temporal del montaje: {tail_error}", scope="DELIVERY",
            ))
        else:
            coverage_error = timed_transcript_error(
                tail_transcript, tail_segments, duration_s=delivery_duration,
                tolerance_s=float(cfg["cola_habla_timestamp_tolerancia_s"]),
            )
            if coverage_error is not None:
                tail_report = {
                    "scope": "DELIVERY", "authoritative": True,
                    "available": True, "error": coverage_error,
                    "transcript": tail_transcript, "segments": tail_segments,
                }
                gates.append(gate(
                    "semantic.delivery.speech_tail", "ERROR",
                    f"linea temporal del montaje incompleta: {coverage_error}", scope="DELIVERY",
                ))
            else:
                tail_report, tail_gates = montage_speech_tail_windows(
                    plan, results, tail_segments, profile,
                )
                tail_report.update({
                    "available": True, "transcript": tail_transcript,
                    "segments": tail_segments,
                    "queue_s": float(cfg["cola_habla_queue_s"]),
                    "vad_min_silence_s": float(cfg["cola_habla_vad_silencio_s"]),
                    "certifies_lip_closure": False,
                })
                gates.extend(tail_gates)
    timeline: list[dict[str, Any]] = []
    if not effective_cut:
        gates.append(gate(
            "semantic.delivery.speech_timeline", "UNKNOWN",
            "la validacion de voz por ventanas solo esta implementada para corte directo",
            scope="DELIVERY",
        ))
    elif not timed_segments:
        gates.append(gate(
            "semantic.delivery.speech_timeline", "UNKNOWN",
            "Whisper no devolvio timestamps para validar las ventanas del montaje",
            scope="DELIVERY",
        ))
    elif len(results) != len(plan.get("tomas") or []):
        gates.append(gate(
            "semantic.delivery.speech_timeline", "ERROR",
            "no se pueden construir ventanas: fuentes y plan tienen distinta cantidad de tomas",
            scope="DELIVERY",
        ))
    else:
        elapsed = 0.0
        timeline_statuses: list[str] = []
        forbidden_detected = 0
        for take, result in zip(plan.get("tomas") or [], results):
            duration_value = result.get("technical", {}).get("duration_s")
            if duration_value is None:
                timeline_statuses.append("ERROR")
                timeline.append({"take": int(take.get("indice") or len(timeline) + 1), "status": "ERROR", "reason": "duracion fuente desconocida"})
                continue
            duration = float(duration_value)
            start = elapsed; end = elapsed + duration; elapsed = end
            window_words: list[str] = []
            for segment in timed_segments:
                midpoint = (float(segment["start_s"]) + float(segment["end_s"])) / 2.0
                if start <= midpoint < end or (end == elapsed and midpoint == end):
                    window_words.extend(spoken_words(str(segment["text"])))
            take_type = str(take.get("tipo", ""))
            take_index = int(take.get("indice") or len(timeline) + 1)
            if take_type in required_types:
                take_reference = normalize_words(str(take.get("contenido", "")))
                take_wer = word_error_rate(take_reference, window_words)
                if take_wer > float(cfg["asr_wer_fail"]):
                    window_status = "FAIL"
                elif take_wer > float(cfg["asr_wer_pass"]):
                    window_status = "REVIEW"
                else:
                    window_status = "PASS"
                timeline.append({
                    "take": take_index, "type": take_type, "start_s": rounded(start), "end_s": rounded(end),
                    "reference_words": len(take_reference), "detected_words": len(window_words),
                    "wer": rounded(take_wer), "status": window_status,
                })
                timeline_statuses.append(window_status)
            elif take_type in forbidden_types:
                forbidden_detected += len(window_words)
                limit = int(cfg["asr_palabras_prohibidas_max"])
                window_status = "FAIL" if len(window_words) > limit else "PASS"
                timeline.append({
                    "take": take_index, "type": take_type, "start_s": rounded(start), "end_s": rounded(end),
                    "detected_words": len(window_words), "status": window_status,
                })
                timeline_statuses.append(window_status)
            else:
                timeline.append({
                    "take": take_index, "type": take_type, "start_s": rounded(start), "end_s": rounded(end),
                    "detected_words": len(window_words), "status": "NA",
                })
        if "ERROR" in timeline_statuses:
            timeline_status = "ERROR"
        elif "FAIL" in timeline_statuses:
            timeline_status = "FAIL"
        elif "REVIEW" in timeline_statuses:
            timeline_status = "REVIEW"
        else:
            timeline_status = "PASS"
        gates.append(gate(
            "semantic.delivery.speech_timeline", timeline_status,
            "voz y dialogos comprobados por ventanas del montaje final",
            windows=timeline, forbidden_words=forbidden_detected, scope="DELIVERY",
        ))
    return {
        "scope": "DELIVERY", "authoritative": True, "required": True, "available": True,
        "transcript": transcript, "reference_words": len(reference), "detected_words": len(content_words),
        "wer": rounded(wer), "dialogue_locations": locations, "segments": timed_segments,
        "timeline": timeline, "speech_tail": tail_report,
        "status": worst_status(gates), "gates": gates,
    }, gates


class FaceBackend:
    def __init__(self, detector_path: Path | None, recognizer_path: Path | None):
        self.error: str | None = None
        self.cv2: Any = None; self.detector: Any = None; self.recognizer: Any = None
        self.detector_path = detector_path; self.recognizer_path = recognizer_path
        if detector_path is None:
            return
        try:
            import cv2  # type: ignore
            self.cv2 = cv2
            self.detector = cv2.FaceDetectorYN_create(str(detector_path), "", (320, 320), 0.8, 0.3, 5000)
            if recognizer_path is not None:
                self.recognizer = cv2.FaceRecognizerSF_create(str(recognizer_path), "")
        except Exception as exc:  # backend opcional: se informa, no se oculta
            self.error = f"backend OpenCV no inicializable: {exc}"
            self.cv2 = None; self.detector = None; self.recognizer = None

    @property
    def detection_available(self) -> bool:
        return self.detector is not None

    @property
    def recognition_available(self) -> bool:
        return self.recognizer is not None

    def analyze(self, path: Path, sampling_fps: float) -> tuple[dict[str, Any], list[Any], list[tuple[str, float, str]]]:
        if not self.detection_available:
            return {}, [], []
        cv2 = self.cv2
        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            cap.release()
            return {
                "sampling_fps_target": sampling_fps,
                "capture_opened": False,
                "capture_complete": False,
                "capture_error": "OpenCV no pudo abrir el video",
                "sampled_frames": 0,
            }, [], [("face-capture", 0.0, "OpenCV no pudo abrir el video")]
        source_fps = float(cap.get(cv2.CAP_PROP_FPS) or 24.0)
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        step = max(1, int(round(source_fps / sampling_fps)))
        sampled = 0; detected_frames = 0; multiple_frames = 0
        shapes: list[list[float]] = []; mouth_widths: list[float] = []; features: list[Any] = []
        anomalies: list[tuple[str, float, str]] = []
        index = 0
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            if index % step:
                index += 1; continue
            sampled += 1
            height, width = frame.shape[:2]
            self.detector.setInputSize((width, height))
            _, faces = self.detector.detect(frame)
            count = 0 if faces is None else len(faces)
            if count:
                detected_frames += 1
                if count > 1:
                    multiple_frames += 1
                # Se usa la cara de mayor confianza.
                face = max(faces, key=lambda row: float(row[-1]))
                x, y, w, h = [float(v) for v in face[:4]]
                if w > 1 and h > 1:
                    landmarks = [(float(face[j]), float(face[j + 1])) for j in range(4, 14, 2)]
                    shape: list[float] = []
                    for lx, ly in landmarks:
                        shape.extend([(lx - x) / w, (ly - y) / h])
                    shapes.append(shape)
                    # YuNet entrega las dos comisuras como landmarks 3 y 4.
                    mouth_widths.append(math.hypot(landmarks[4][0] - landmarks[3][0], landmarks[4][1] - landmarks[3][1]) / w)
                if self.recognition_available:
                    try:
                        aligned = self.recognizer.alignCrop(frame, face)
                        feature = self.recognizer.feature(aligned).reshape(-1)
                        norm = float((feature @ feature) ** 0.5)
                        if norm:
                            features.append(feature / norm)
                    except Exception:
                        anomalies.append(("face-align", index / source_fps, "no se pudo alinear una deteccion"))
            index += 1
        cap.release()
        decoded_frames = index
        if frame_count > 0:
            decode_coverage = decoded_frames / frame_count
            capture_complete: bool | None = decoded_frames >= max(1, frame_count - 1)
            capture_error = None if capture_complete else (
                f"OpenCV solo decodifico {decoded_frames} de {frame_count} frames declarados"
            )
        else:
            decode_coverage = None
            capture_complete = None
            capture_error = "OpenCV no informo el total de frames; cobertura no demostrable"
        shape_deltas: list[float] = []
        for a, b in zip(shapes, shapes[1:]):
            shape_deltas.append(math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)))
        coverage = detected_frames / sampled if sampled else 0.0
        metrics = {
            "sampling_fps_target": sampling_fps,
            "source_fps": rounded(source_fps),
            "source_frames": frame_count,
            "capture_opened": True,
            "decoded_frames": decoded_frames,
            "decode_coverage_ratio": rounded(decode_coverage),
            "capture_complete": capture_complete,
            "capture_error": capture_error,
            "sampled_frames": sampled,
            "frames_with_face": detected_frames,
            "face_coverage": rounded(coverage),
            "frames_with_multiple_faces": multiple_frames,
            "landmark_shape_delta_p95": rounded(percentile(shape_deltas, 0.95)),
            "mouth_width_median_normalized": rounded(statistics.median(mouth_widths) if mouth_widths else None),
            "mouth_width_p05_normalized": rounded(percentile(mouth_widths, 0.05)),
            "mouth_width_p95_normalized": rounded(percentile(mouth_widths, 0.95)),
            "identity_feature_frames": len(features),
        }
        if capture_complete is not True:
            anomalies.append(("face-capture", max(0.0, decoded_frames / source_fps), capture_error or "cobertura facial incompleta"))
            # Una identidad parcial no debe parecer valida si el decodificador
            # facial abandono antes del final de la toma.
            features = []
        return metrics, features, anomalies


def face_gates(metrics: dict[str, Any], take_type: str, profile: dict[str, Any], backend: FaceBackend) -> list[dict[str, Any]]:
    cfg = profile["semantica"]
    required = take_type in cfg["requiere_rostro_tipos"]
    forbidden = take_type in cfg["prohibe_rostro_tipos"]
    if not required and not forbidden:
        return [gate("semantic.face", "NA", "deteccion facial no aplica a este tipo")]
    if not backend.detection_available:
        status = "ERROR" if backend.error else "UNKNOWN"
        return [gate("semantic.face", status, backend.error or "backend facial no disponible", capability="opencv-yunet")]
    capture_complete = metrics.get("capture_complete")
    if capture_complete is False:
        return [gate(
            "semantic.face_capture", "ERROR",
            str(metrics.get("capture_error") or "OpenCV no cubrio la toma completa"),
            decoded_frames=metrics.get("decoded_frames"), expected_frames=metrics.get("source_frames"),
            coverage=metrics.get("decode_coverage_ratio"),
        )]
    if capture_complete is not True:
        return [gate(
            "semantic.face_capture", "UNKNOWN",
            str(metrics.get("capture_error") or "no se pudo demostrar cobertura facial completa"),
            decoded_frames=metrics.get("decoded_frames"), expected_frames=metrics.get("source_frames"),
        )]
    coverage = float(metrics.get("face_coverage") or 0.0)
    detected = int(metrics.get("frames_with_face") or 0)
    if forbidden:
        limit = int(cfg["rostro_prohibido_frames_fail"])
        if detected >= limit:
            return [gate("semantic.forbidden_face", "FAIL", "rostro persistente en una toma que lo prohibe", value=detected, threshold=limit)]
        if detected:
            return [gate("semantic.forbidden_face", "REVIEW", "deteccion facial aislada; revisar evidencia", value=detected, threshold=limit)]
        return [gate("semantic.forbidden_face", "PASS", "sin rostros en muestreo denso", value=0)]
    if coverage < float(cfg["rostro_cobertura_fail"]):
        status = "FAIL"
    elif coverage < float(cfg["rostro_cobertura_pass"]):
        status = "REVIEW"
    else:
        status = "PASS"
    out = [gate("semantic.face_presence", status, "cobertura facial densa en toma hablada", value=rounded(coverage), pass_threshold=cfg["rostro_cobertura_pass"], fail_threshold=cfg["rostro_cobertura_fail"])]
    shape_delta = metrics.get("landmark_shape_delta_p95")
    if shape_delta is None:
        out.append(gate("semantic.landmark_stability", "REVIEW", "sin suficientes landmarks consecutivos"))
    elif shape_delta >= float(cfg["landmarks_delta_p95_fail"]):
        out.append(gate("semantic.landmark_stability", "FAIL", "salto facial geometrico alto (proxy de warping)", value=shape_delta))
    elif shape_delta >= float(cfg["landmarks_delta_p95_review"]):
        out.append(gate("semantic.landmark_stability", "REVIEW", "variacion facial geometrica que requiere inspeccion", value=shape_delta))
    else:
        out.append(gate("semantic.landmark_stability", "PASS", "landmarks estables dentro del umbral provisional", value=shape_delta))
    return out


def centroid(features: list[Any]) -> Any | None:
    if not features:
        return None
    total = features[0].copy()
    for feature in features[1:]:
        total += feature
    total /= len(features)
    norm = float((total @ total) ** 0.5)
    return total / norm if norm else None


def extract_evidence(source: Path, destination: Path, second: float) -> bool:
    destination.parent.mkdir(parents=True, exist_ok=True)
    cp = run([
        "ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", f"{max(0.0, second):.3f}",
        "-i", str(source), "-frames:v", "1", "-update", "1", "-q:v", "2", str(destination),
    ], timeout=60)
    return cp.returncode == 0 and destination.exists()


def safe_slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-") or "evidence"


def score_from_gates(gates: Iterable[dict[str, Any]], prefix: str | tuple[str, ...]) -> float | None:
    selected = [
        g for g in gates
        if str(g.get("id", "")).startswith(prefix)
        and g.get("status") != "NA"
        and not g.get("advisory", False)
    ]
    if not selected or any(g.get("status") in ("UNKNOWN", "ERROR") for g in selected):
        return None
    points = {"PASS": 100.0, "REVIEW": 65.0, "FAIL": 0.0}
    value = sum(points.get(g.get("status"), 0.0) for g in selected) / len(selected)
    # Un veto no se puede lavar promediandolo con veinte checks faciles.
    if any(g.get("status") == "FAIL" for g in selected):
        value = min(value, 49.0)
    elif any(g.get("status") == "REVIEW" for g in selected):
        value = min(value, 79.0)
    return round(max(0.0, value), 1)


def locate_take(obra: Path, index: int) -> Path | None:
    for ext in ("avi", "mp4", "mov", "mkv", "webm"):
        for stem in (f"t{index:02d}", f"p{index:02d}"):
            candidate = obra / f"{stem}.{ext}"
            if candidate.is_file():
                return candidate
    return None


def transition_report(takes: list[dict[str, Any]], style: str | None, duration: float, profile: dict[str, Any], montage: Path | None, evidence_dir: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    cfg = profile["transiciones"]
    reports: list[dict[str, Any]] = []; global_gates: list[dict[str, Any]] = []
    elapsed = 0.0
    double_styles = {str(v).lower() for v in cfg["estilos_doble_exposicion"]}
    for position, (left, right) in enumerate(zip(takes, takes[1:]), 1):
        elapsed += float(left.get("technical", {}).get("duration_s") or 0.0)
        left_role = "rostro" if left["type"] in profile["semantica"]["requiere_rostro_tipos"] else "sin-rostro"
        right_role = "rostro" if right["type"] in profile["semantica"]["requiere_rostro_tipos"] else "sin-rostro"
        transition_gate: dict[str, Any]
        risk = False
        if style is None:
            transition_gate = gate(f"transition.{position}", "UNKNOWN", "estilo de transicion no declarado")
        elif style.lower() in double_styles and duration >= float(cfg["duracion_min_veto_s"]) and left_role != right_role and cfg.get("veta_doble_exposicion_entre_roles", True):
            risk = True
            transition_gate = gate(f"transition.{position}", "FAIL", "fundido mezcla durante varios frames un rostro con una toma que lo prohibe", style=style, duration_s=duration)
        elif style.lower() in double_styles and duration >= float(cfg["duracion_min_veto_s"]):
            transition_gate = gate(f"transition.{position}", "REVIEW", "fundido con doble exposicion potencial; inspeccionar", style=style, duration_s=duration)
        else:
            transition_gate = gate(f"transition.{position}", "PASS", "transicion sin doble exposicion prolongada", style=style, duration_s=duration)
        evidence: list[dict[str, Any]] = []
        # En una cadena de xfade, el centro del solape i esta en esta posicion.
        center = elapsed - position * duration + duration / 2 if style and style.lower() in double_styles else elapsed
        if montage is not None and montage.is_file() and transition_gate["status"] in ("FAIL", "REVIEW"):
            out = evidence_dir / f"transition-{position:02d}-{safe_slug(transition_gate['status'].lower())}.jpg"
            if extract_evidence(montage, out, center):
                evidence.append({"kind": "transition", "time_s": rounded(center), "path": str(out)})
        report = {
            "index": position, "from_take": left["index"], "to_take": right["index"],
            "from_role": left_role, "to_role": right_role, "declared_style": style,
            "declared_duration_s": duration if style else None, "double_exposure_risk": risk,
            "gate": transition_gate, "status": worst_status([transition_gate]), "evidence": evidence,
        }
        reports.append(report); global_gates.append(transition_gate)
    return reports, global_gates


def make_error_report(message: str, profile_path: str | None = None) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "evaluator": {"version": VERSION, "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()},
        "profile": {"path": profile_path}, "input": {}, "capabilities": {}, "coverage": {},
        "takes": [], "transitions": [], "montage_video": None, "montage_audio": None,
        "montage_semantic": None, "global_gates": [], "advisories": [],
        "scores": {"technical": None, "temporal": None, "audio": None, "semantic": None},
        "semantic_complete": False, "status": "ERROR", "reasons": [message],
    }


def evaluate(args: argparse.Namespace) -> dict[str, Any]:
    obra = args.obra.resolve()
    plan_path = (args.plan or obra / "plan.json").resolve()
    profile_path = args.profile.resolve()
    if not obra.is_dir():
        raise EvaluationError(f"no existe el directorio de obra: {obra}")
    plan = load_json(plan_path, "plan")
    profile = load_json(profile_path, "perfil")
    if plan.get("schema") != "minimax-h3.plan-obra/v1" or not isinstance(plan.get("tomas"), list):
        raise EvaluationError("el plan no cumple minimax-h3.plan-obra/v1")
    if profile.get("schema") != "minimax-h3.perfil-calidad/v2":
        raise EvaluationError("el perfil no cumple minimax-h3.perfil-calidad/v2")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise EvaluationError("ffmpeg y ffprobe son obligatorios")
    montage = args.montage.resolve() if args.montage else None
    if montage is not None and not montage.is_file():
        raise EvaluationError(f"no existe el montaje: {montage}")

    detector = args.face_detector
    recognizer = args.face_recognizer
    if not args.no_face_backend and detector is None and DEFAULT_YUNET.is_file():
        detector = DEFAULT_YUNET
    if not args.no_face_backend and recognizer is None and DEFAULT_SFACE.is_file():
        recognizer = DEFAULT_SFACE
    if args.no_face_backend:
        detector = None; recognizer = None
    if detector is not None and not detector.is_file():
        raise EvaluationError(f"no existe el modelo YuNet: {detector}")
    if recognizer is not None and not recognizer.is_file():
        raise EvaluationError(f"no existe el modelo SFace: {recognizer}")
    backend = FaceBackend(detector, recognizer)

    whisper_model = args.whisper_model
    whisper_vad_model = args.whisper_vad_model
    if not args.no_asr_backend and whisper_model is None and DEFAULT_WHISPER.is_file():
        whisper_model = DEFAULT_WHISPER
    if not args.no_asr_backend and whisper_vad_model is None and DEFAULT_WHISPER_VAD.is_file():
        whisper_vad_model = DEFAULT_WHISPER_VAD
    if args.no_asr_backend:
        whisper_model = None; whisper_vad_model = None
    whisper_filter = text_run(["ffmpeg", "-hide_banner", "-filters"], timeout=30)
    whisper_available = bool(re.search(r"\bwhisper\b", whisper_filter.stdout + whisper_filter.stderr))
    asr_error: str | None = None
    if whisper_model is not None and not whisper_model.is_file():
        raise EvaluationError(f"no existe el modelo whisper: {whisper_model}")
    if whisper_vad_model is not None and not whisper_vad_model.is_file():
        raise EvaluationError(f"no existe el modelo VAD de whisper: {whisper_vad_model}")
    if whisper_model is not None and not whisper_available:
        asr_error = "este ffmpeg no incluye el filtro whisper"
        whisper_model = None

    if args.evidence_dir:
        evidence_dir = args.evidence_dir.resolve()
    elif args.output and str(args.output) != "-":
        evidence_dir = args.output.resolve().parent / f"{args.output.stem}-evidencias"
    else:
        evidence_dir = obra / "evidencias-calidad-v2"

    capabilities = {
        "ffmpeg": {"status": "available", "path": shutil.which("ffmpeg")},
        "ffprobe": {"status": "available", "path": shutil.which("ffprobe")},
        "temporal_dense": {"status": "available", "backend": "ffmpeg+python"},
        "ebur128": {"status": "available", "backend": "ffmpeg"},
        "asr": {
            "status": "available" if whisper_model is not None else "unavailable",
            "backend": "ffmpeg-whisper", "model": str(whisper_model) if whisper_model else None,
            "vad_model": str(whisper_vad_model) if whisper_vad_model else None,
            "reason": asr_error or (None if whisper_model else "modelo no configurado"),
        },
        "speech_tail": {
            "status": "available" if whisper_model is not None and whisper_vad_model is not None else "unavailable",
            "backend": "ffmpeg-whisper+silero-vad",
            "reason": asr_error or (
                None if whisper_model is not None and whisper_vad_model is not None
                else "requiere Whisper y Silero VAD"
            ),
        },
        "face_detection": {
            "status": "available" if backend.detection_available else ("error" if backend.error else "unavailable"),
            "backend": "OpenCV-YuNet", "model": str(detector) if detector else None,
            "reason": backend.error or (None if detector else "modelo no encontrado"),
        },
        "face_recognition": {
            "status": "available" if backend.recognition_available else ("error" if backend.error else "unavailable"),
            "backend": "OpenCV-SFace", "model": str(recognizer) if recognizer else None,
            "reason": backend.error or (None if recognizer else "modelo no encontrado"),
        },
    }

    results: list[dict[str, Any]] = []
    face_features: dict[int, list[Any]] = {}
    max_evidence = int(profile["analisis"]["max_evidencias_por_toma"])
    for take in plan["tomas"]:
        index = int(take.get("indice") or len(results) + 1)
        take_type = str(take.get("tipo") or plan.get("cabecera", {}).get("tipo") or "desconocido")
        path = locate_take(obra, index)
        base = {
            "index": index, "name": f"t{index:02d}", "type": take_type,
            "path": str(path) if path else str(obra / f"t{index:02d}.avi"),
            "technical": {}, "temporal": {}, "audio": {}, "semantic": {},
            "gates": [], "status": "ERROR", "evidence": [],
        }
        if path is None:
            base["gates"] = [gate("technical.file", "ERROR", "no se encontro el fichero de la toma")]
            results.append(base); continue
        technical, technical_gates = media_integrity(path, take, profile)
        base["technical"] = technical; base["gates"].extend(technical_gates)
        if worst_status(technical_gates) == "ERROR":
            base["status"] = "ERROR"; results.append(base); continue
        try:
            temporal, temporal_gates, anomalies = temporal_analysis(path, take_type, profile)
        except EvaluationError as exc:
            temporal = {"error": str(exc)}; temporal_gates = [gate("temporal.analysis", "ERROR", str(exc))]; anomalies = []
        base["temporal"] = temporal; base["gates"].extend(temporal_gates)
        has_audio = bool(technical.get("audio_codecs"))
        audio, audio_gates = audio_analysis(path, take_type, profile, has_audio, technical.get("duration_s"))
        source_audio_status = worst_status(audio_gates)
        if montage is not None:
            audio_gates = as_source_advisory(audio_gates)
            audio.update({"scope": "SOURCE", "authoritative": False, "diagnostic_status": source_audio_status})
        else:
            audio.update({"scope": "TAKE", "authoritative": True, "diagnostic_status": source_audio_status})
        base["audio"] = audio; base["gates"].extend(audio_gates)

        asr, asr_gates = asr_analysis(path, take, profile, whisper_model, whisper_vad_model, asr_error)
        if montage is not None:
            source_asr_status = worst_status(asr_gates)
            asr_gates = as_source_semantic_advisory(asr_gates)
            asr.update({"scope": "SOURCE", "authoritative": False, "diagnostic_status": source_asr_status})
        else:
            asr.update({"scope": "TAKE", "authoritative": True, "diagnostic_status": worst_status(asr_gates)})
        speech_tail, speech_tail_gates = speech_tail_analysis(
            path, take, technical.get("duration_s"), profile,
            whisper_model, whisper_vad_model, asr_error,
        )
        if montage is not None:
            source_tail_status = worst_status(speech_tail_gates)
            speech_tail_gates = as_source_tail_advisory(speech_tail_gates)
            speech_tail.update({
                "scope": "SOURCE", "authoritative": False,
                "diagnostic_status": source_tail_status,
            })
        else:
            speech_tail.update({
                "scope": "TAKE", "authoritative": True,
                "diagnostic_status": worst_status(speech_tail_gates),
            })
        face_metrics, features, face_anomalies = backend.analyze(path, float(profile["analisis"]["face_fps"])) if backend.detection_available else ({}, [], [])
        fg = face_gates(face_metrics, take_type, profile, backend)
        base["semantic"] = {"asr": asr, "speech_tail": speech_tail, "face": face_metrics}
        base["gates"].extend(asr_gates); base["gates"].extend(speech_tail_gates); base["gates"].extend(fg)
        if features:
            face_features[index] = features
        anomalies.extend(face_anomalies)
        # Cobertura o detecciones faciales anormales se convierten en evidencia dirigida.
        if any(g["status"] in ("FAIL", "REVIEW") and g["id"].startswith(("semantic.face", "semantic.landmark")) for g in fg):
            anomalies.append(("face", float(technical.get("duration_s") or 0.0) / 2, "anomalia de cobertura o geometria facial"))
        if any(g["status"] in ("FAIL", "REVIEW") and g["id"] == "semantic.forbidden_face" for g in fg):
            anomalies.append(("forbidden-face", float(technical.get("duration_s") or 0.0) / 2, "rostro en plano que lo prohibe"))
        if any(g["status"] in ("FAIL", "REVIEW") for g in speech_tail_gates):
            duration = float(technical.get("duration_s") or 0.0)
            last_end = float(speech_tail.get("last_speech_end_s") or max(0.0, duration - 0.05))
            anomalies.append(("speech-tail-last", min(max(0.0, duration - 0.05), last_end), "ultimo segmento vocal detectado"))
            anomalies.append(("speech-tail-final", max(0.0, duration - 0.05), "fotograma final para comprobar cierre labial manual"))
        for evidence_index, (kind, second, detail) in enumerate(anomalies[:max_evidence], 1):
            destination = evidence_dir / f"t{index:02d}-{evidence_index:02d}-{safe_slug(kind)}.jpg"
            if extract_evidence(path, destination, second):
                base["evidence"].append({"kind": kind, "time_s": rounded(second), "detail": detail, "path": str(destination)})
        base["status"] = worst_status(base["gates"])
        results.append(base)

    # Identidad global: cada toma se resume con el centroide de sus muestras.
    speaking = [r for r in results if r["type"] in profile["semantica"]["requiere_rostro_tipos"]]
    if len(speaking) > 1:
        centroids = {r["index"]: centroid(face_features.get(r["index"], [])) for r in speaking}
        reference_index = next((r["index"] for r in speaking if centroids[r["index"]] is not None), None)
        for result in speaking:
            if not backend.recognition_available:
                identity_gate = gate("semantic.identity", "ERROR" if backend.error else "UNKNOWN", backend.error or "SFace no disponible", capability="opencv-sface")
                similarity = None; pairwise_min = None; frame_p05 = None
            elif reference_index is None or centroids[result["index"]] is None:
                identity_gate = gate("semantic.identity", "REVIEW", "sin suficientes crops faciales para comparar identidad")
                similarity = None; pairwise_min = None; frame_p05 = None
            else:
                similarity = float(centroids[reference_index] @ centroids[result["index"]])
                pairwise = [
                    float(centroids[result["index"]] @ other)
                    for other_index, other in centroids.items()
                    if other_index != result["index"] and other is not None
                ]
                pairwise_min = min(pairwise) if pairwise else similarity
                frame_similarities = [
                    float(feature @ centroids[reference_index])
                    for feature in face_features.get(result["index"], [])
                ]
                frame_p05 = percentile(frame_similarities, 0.05)
                # El centroide solo puede ocultar outliers. El gate usa tambien
                # el peor par entre tomas y el p05 de los crops densos.
                quality = min(v for v in (similarity, pairwise_min, frame_p05) if v is not None)
                cfg = profile["semantica"]
                if quality < float(cfg["identidad_coseno_fail"]):
                    identity_status = "FAIL"
                elif quality < float(cfg["identidad_coseno_pass"]):
                    identity_status = "REVIEW"
                else:
                    identity_status = "PASS"
                identity_gate = gate("semantic.identity", identity_status, f"identidad SFace densa contra t{reference_index:02d} y entre tomas", value=rounded(quality), pass_threshold=cfg["identidad_coseno_pass"], fail_threshold=cfg["identidad_coseno_fail"])
            result["semantic"]["identity"] = {
                "reference_take": reference_index,
                "centroid_cosine_similarity": rounded(similarity),
                "pairwise_centroid_min_cosine": rounded(pairwise_min),
                "frame_to_reference_p05_cosine": rounded(frame_p05),
            }
            result["gates"].append(identity_gate)
            result["status"] = worst_status(result["gates"])

    global_gates: list[dict[str, Any]] = []
    for role, subset in (
        ("habla", [r for r in results if r["type"] in profile["semantica"]["requiere_asr_tipos"]]),
        ("sin-habla", [r for r in results if r["type"] in profile["semantica"]["prohibe_habla_tipos"]]),
    ):
        levels = [float(r["audio"]["integrated_lufs"]) for r in subset if r["audio"].get("integrated_lufs") is not None]
        if len(levels) < 2:
            continue
        spread = max(levels) - min(levels)
        acfg = profile["audio"]
        if spread >= float(acfg["lufs_spread_fail_db"]):
            status = "FAIL"
        elif spread >= float(acfg["lufs_spread_review_db"]):
            status = "REVIEW"
        else:
            status = "PASS"
        consistency_gate = gate(
            f"audio.loudness_consistency.{role}", status,
            f"dispersion de loudness entre tomas del rol {role}", value=rounded(spread), unit="dB",
            review_threshold=acfg["lufs_spread_review_db"], fail_threshold=acfg["lufs_spread_fail_db"],
        )
        if montage is not None:
            consistency_gate["id"] = "source." + consistency_gate["id"]
            consistency_gate["scope"] = "SOURCE"
            consistency_gate["advisory"] = True
        global_gates.append(consistency_gate)

    if montage is not None:
        montage_video, montage_video_gates = montage_video_analysis(
            montage, plan, results, args.transition_style, args.transition_seconds, profile,
        )
        montage_audio, montage_audio_gates = montage_audio_analysis(montage, profile)
        montage_semantic, montage_semantic_gates = montage_asr_analysis(
            montage, plan, results, args.transition_style, profile,
            whisper_model, whisper_vad_model, asr_error,
        )
    else:
        montage_video, montage_video_gates = None, []
        montage_audio, montage_audio_gates = None, []
        montage_semantic, montage_semantic_gates = None, []
    transitions, transition_gates = transition_report(results, args.transition_style, args.transition_seconds, profile, montage, evidence_dir)
    all_gates = (
        [g for result in results for g in result["gates"]] + global_gates +
        montage_video_gates + montage_audio_gates + montage_semantic_gates + transition_gates
    )
    semantic_relevant = [g for g in all_gates if str(g.get("id", "")).startswith("semantic.") or str(g.get("id", "")).startswith("transition.")]
    semantic_unknown = [g for g in semantic_relevant if g.get("status") in ("UNKNOWN", "ERROR")]
    semantic_complete = not semantic_unknown

    overall_status = worst_status(all_gates)
    technical_score = score_from_gates(all_gates, "technical.")
    temporal_score = score_from_gates(all_gates, "temporal.")
    audio_score = score_from_gates(all_gates, ("audio.", "delivery.audio."))
    semantic_score = None if not semantic_complete else score_from_gates(all_gates, ("semantic.", "transition."))
    if semantic_complete and semantic_score is None and not any(g.get("status") != "NA" for g in semantic_relevant):
        semantic_score = 100.0
    scores: dict[str, Any] = {
        "technical": technical_score, "temporal": temporal_score,
        "audio": audio_score, "semantic": semantic_score,
    }
    if semantic_complete and all(value is not None for value in scores.values()):
        weights = profile["pesos"]
        total = (
            technical_score * float(weights["tecnica"]) +
            temporal_score * float(weights["temporal"]) +
            audio_score * float(weights["audio"]) +
            semantic_score * float(weights["semantica"])
        )
        if overall_status == "FAIL":
            total = min(total, 59.0)
        elif overall_status == "REVIEW":
            total = min(total, 79.0)
        scores["total"] = round(total, 1)
    reasons = [
        f"{g['id']}: {g['reason']}" for g in all_gates
        if g.get("status") in ("ERROR", "FAIL", "REVIEW", "UNKNOWN") and not g.get("advisory", False)
    ]
    advisories = [g for g in all_gates if g.get("advisory", False) and g.get("status") not in ("PASS", "NA")]
    expected_semantic = len([g for g in semantic_relevant if g.get("status") != "NA"])
    completed_semantic = len([g for g in semantic_relevant if g.get("status") not in ("NA", "UNKNOWN", "ERROR")])
    coverage = {
        "planned_takes": len(plan["tomas"]), "located_takes": sum(Path(r["path"]).is_file() for r in results),
        "temporal_sampled_frames": sum(int(r["temporal"].get("sampled_frames") or 0) for r in results),
        "face_sampled_frames": sum(int(r["semantic"].get("face", {}).get("sampled_frames") or 0) for r in results),
        "montage_visual_sampled_frames": int((montage_video or {}).get("correspondence", {}).get("montage_sampled_frames") or 0),
        "semantic_checks_expected": expected_semantic, "semantic_checks_completed": completed_semantic,
        "semantic_checks_unknown": len(semantic_unknown),
    }
    return {
        "schema": SCHEMA,
        "evaluator": {"version": VERSION, "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()},
        "profile": {"name": profile["nombre"], "path": str(profile_path), "thresholds_provisional": True},
        "input": {"obra": str(obra), "plan": str(plan_path), "montage": str(montage) if montage else None, "transition_style": args.transition_style, "transition_seconds": args.transition_seconds if args.transition_style else None},
        "capabilities": capabilities, "coverage": coverage, "takes": results, "transitions": transitions,
        "montage_video": montage_video, "montage_audio": montage_audio,
        "montage_semantic": montage_semantic, "global_gates": global_gates, "advisories": advisories,
        "scores": scores, "semantic_complete": semantic_complete, "status": overall_status, "reasons": reasons,
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Evaluador fuerte V2, plan-aware y conservador")
    p.add_argument("obra", type=Path, help="directorio con plan.json y tNN.avi/pNN.avi")
    p.add_argument("--plan", type=Path, help="plan v1; por defecto OBRA/plan.json")
    p.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    p.add_argument("--output", type=Path, help="informe JSON; '-' escribe a stdout")
    p.add_argument("--evidence-dir", type=Path, help="directorio de fotogramas dirigidos por anomalías")
    p.add_argument("--montage", type=Path, help="montaje final para evidencia de transiciones")
    p.add_argument("--transition-style", choices=("cut", "xfade", "crossfade", "cross-dissolve", "dissolve"))
    p.add_argument("--transition-seconds", type=float, default=0.0)
    p.add_argument("--whisper-model", type=Path, help="modelo ggml de whisper.cpp; nunca se descarga automaticamente")
    p.add_argument("--whisper-vad-model", type=Path, help="modelo VAD opcional de whisper.cpp")
    p.add_argument("--no-asr-backend", action="store_true", help="desactiva la autodeteccion local de Whisper")
    p.add_argument("--face-detector", type=Path, help="modelo YuNet; se autodetecta modelos/evaluacion si existe")
    p.add_argument("--face-recognizer", type=Path, help="modelo SFace; se autodetecta modelos/evaluacion si existe")
    p.add_argument("--no-face-backend", action="store_true", help="desactiva autodeteccion facial (util para comprobar modo degradado)")
    return p


def write_report(report: dict[str, Any], output: Path | None) -> None:
    payload = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if output is None or str(output) == "-":
        sys.stdout.write(payload)
        return
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + f".tmp.{os.getpid()}")
    temporary.write_text(payload, encoding="utf-8")
    os.replace(temporary, output)
    sys.stderr.write(f"{report['status']} {output}\n")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.transition_seconds < 0:
        report = make_error_report("--transition-seconds no puede ser negativo", str(args.profile))
    else:
        try:
            report = evaluate(args)
        except Exception as exc:
            report = make_error_report(str(exc), str(args.profile))
    try:
        write_report(report, args.output)
    except OSError as exc:
        sys.stderr.write(f"ERROR no pude escribir el informe: {exc}\n")
        return EXIT["ERROR"]
    return EXIT[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
