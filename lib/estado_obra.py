#!/usr/bin/env python3
"""Estado durable y validacion de artefactos para la pipeline anclada.

Este modulo es deliberadamente pequeno y usa solo la libreria estandar. La
shell sigue ejecutando MiniMax y ffmpeg; aqui se concentran las operaciones que
deben ser atomicas o estructuradas: estado JSON, huellas y comprobacion de AVI.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "minimax-h3.estado-obra/v1"


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def _atomic_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(
        value, ensure_ascii=False, indent=2, sort_keys=True
    ).encode("utf-8") + b"\n"
    _atomic_bytes(path, payload)


def command_state(args: argparse.Namespace) -> int:
    path = Path(args.path)
    state = _read_json(path)
    if not state:
        state = {"schema": SCHEMA, "created_at": _utc_now()}

    state.update(
        {
            "schema": SCHEMA,
            "phase": args.phase,
            "updated_at": _utc_now(),
        }
    )
    if args.phase == "planned":
        # Una corrida nueva no puede heredar la entrega ni el mensaje de la
        # anterior. Si luego falla, la UI debe mostrar ese fallo sin apuntar a
        # un MP4 viejo como si perteneciera al plan actual.
        state.pop("final", None)
        state.pop("message", None)
    optional = {
        "name": args.name,
        "run_fingerprint": args.run_fingerprint,
        "plan": args.plan,
        "message": args.message,
        "final": args.final,
    }
    for key, value in optional.items():
        if value is not None:
            state[key] = value
    if args.pid is not None:
        state["pid"] = args.pid
    if args.completed is not None:
        state["completed"] = args.completed
    if args.total is not None:
        state["total"] = args.total
    _atomic_json(path, state)
    return 0


def _metadata_from_stat(details: os.stat_result, path: Path) -> dict[str, int]:
    if not stat.S_ISREG(details.st_mode):
        raise ValueError(f"no es un archivo regular: {path}")
    return {
        "device": details.st_dev,
        "inode": details.st_ino,
        "size": details.st_size,
        "mtime_ns": details.st_mtime_ns,
        "ctime_ns": details.st_ctime_ns,
    }


def _open_regular(path: Path) -> int:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        _metadata_from_stat(os.fstat(fd), path)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _metadata(path: Path) -> dict[str, int]:
    fd = _open_regular(path)
    try:
        return _metadata_from_stat(os.fstat(fd), path)
    finally:
        os.close(fd)


def _sha256_stable(path: Path) -> tuple[str, dict[str, int]]:
    """Hashea un unico descriptor y demuestra que ruta e inode no cambiaron."""
    for _attempt in range(3):
        fd = _open_regular(path)
        try:
            before = _metadata_from_stat(os.fstat(fd), path)
            digest = hashlib.sha256()
            with os.fdopen(fd, "rb", closefd=False) as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            after = _metadata_from_stat(os.fstat(fd), path)
        finally:
            os.close(fd)
        # La segunda apertura comprueba que el nombre sigue apuntando al inode
        # que acabamos de leer. No se acepta un path sustituido durante el hash.
        current = _metadata(path)
        if before == after == current:
            return digest.hexdigest(), after
    raise ValueError(f"{path} cambio mientras se calculaba su SHA-256")


def _sha256_file(path: Path) -> str:
    digest, _metadata_value = _sha256_stable(path)
    return digest


def _pares(values: list[str], description: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in values:
        label, separator, value = raw.partition("=")
        if not separator or not re.fullmatch(r"[a-z][a-z0-9_]*", label):
            raise ValueError(f"{description} invalido: {raw!r}")
        if label in result:
            raise ValueError(f"{description} duplicado: {label}")
        if not value:
            raise ValueError(f"{description} vacio: {label}")
        result[label] = value
    return result


def command_recipe_fingerprint(args: argparse.Namespace) -> int:
    """Hashea la pila real y reutiliza hashes sólo si el inode sigue intacto."""
    components = _pares(args.component, "componente")
    settings = _pares(args.setting, "ajuste")
    if not components:
        raise ValueError("se requiere al menos un --component")

    cache_path = Path(args.cache)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = cache_path.with_name(cache_path.name + ".lock")
    digests: dict[str, str] = {}
    records: dict[str, dict[str, Any]] = {}
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        cache = _read_json(cache_path)
        entries = cache.get("entries")
        if not isinstance(entries, dict):
            entries = {}

        for label, raw_path in components.items():
            source_path = Path(raw_path).absolute()
            try:
                path = source_path.resolve(strict=True)
            except OSError as exc:
                raise ValueError(f"no se puede resolver {label}: {exc}") from exc
            metadata = _metadata(path)
            key = str(path)
            previous = entries.get(key)
            digest = previous.get("sha256") if isinstance(previous, dict) else None
            valid_digest = isinstance(digest, str) and bool(
                re.fullmatch(r"[0-9a-f]{64}", digest)
            )
            if not valid_digest or previous.get("metadata") != metadata:
                digest, metadata = _sha256_stable(path)
                entries[key] = {"metadata": metadata, "sha256": digest}
            digests[label] = digest
            records[label] = {
                "source_path": str(source_path),
                "path": key,
                "metadata": metadata,
                "sha256": digest,
            }

        _atomic_json(
            cache_path,
            {
                "schema": "minimax-h3.hash-cache/v1",
                "entries": entries,
                "updated_at": _utc_now(),
            },
        )

    material = {
        "schema": "minimax-h3.recipe/v1",
        "components": digests,
        "settings": settings,
    }
    canonical = json.dumps(material, sort_keys=True, separators=(",", ":"))
    fingerprint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if args.manifest:
        _atomic_json(
            Path(args.manifest),
            {
                "schema": "minimax-h3.recipe-manifest/v1",
                "fingerprint": fingerprint,
                "components": records,
                "settings": settings,
                "created_at": _utc_now(),
            },
        )
    print(fingerprint)
    return 0


def command_verify_recipe(args: argparse.Namespace) -> int:
    """Verifica por descriptor que la receta aun es la que se identifico."""
    manifest = _read_json(Path(args.manifest))
    if manifest.get("schema") != "minimax-h3.recipe-manifest/v1":
        raise ValueError("manifiesto de receta ausente o incompatible")
    fingerprint = manifest.get("fingerprint")
    components = manifest.get("components")
    settings = manifest.get("settings")
    if not isinstance(fingerprint, str) or not re.fullmatch(
        r"[0-9a-f]{64}", fingerprint
    ):
        raise ValueError("huella de receta invalida")
    if not isinstance(components, dict) or not components:
        raise ValueError("componentes de receta invalidos")
    if not isinstance(settings, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in settings.items()
    ):
        raise ValueError("ajustes de receta invalidos")

    digests: dict[str, str] = {}
    for label, record in components.items():
        if not isinstance(label, str) or not isinstance(record, dict):
            raise ValueError("registro de componente invalido")
        raw_path = record.get("path")
        source_path = record.get("source_path")
        expected_metadata = record.get("metadata")
        digest = record.get("sha256")
        if (
            not isinstance(raw_path, str)
            or not isinstance(source_path, str)
            or not isinstance(expected_metadata, dict)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise ValueError(f"registro invalido para {label}")
        path = Path(raw_path)
        try:
            resolved = path.resolve(strict=True)
            source_resolved = Path(source_path).resolve(strict=True)
        except OSError as exc:
            raise ValueError(f"no se puede resolver {label}: {exc}") from exc
        if (
            str(resolved) != raw_path
            or source_resolved != resolved
            or _metadata(resolved) != expected_metadata
        ):
            raise ValueError(f"{label} cambio despues de identificar la receta")
        digests[label] = digest

    material = {
        "schema": "minimax-h3.recipe/v1",
        "components": digests,
        "settings": settings,
    }
    canonical = json.dumps(material, sort_keys=True, separators=(",", ":"))
    current = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if current != fingerprint:
        raise ValueError("el manifiesto no corresponde a su huella de receta")
    return 0


def command_shot_fingerprint(args: argparse.Namespace) -> int:
    plan = _read_json(Path(args.plan))
    shots = plan.get("tomas")
    if not isinstance(shots, list):
        raise ValueError("el plan no contiene una lista 'tomas'")
    if args.index < 1 or args.index > len(shots):
        raise ValueError(f"toma {args.index} fuera del plan (1..{len(shots)})")
    shot = shots[args.index - 1]
    if not isinstance(shot, dict) or not isinstance(shot.get("fingerprint"), str):
        raise ValueError(f"la toma {args.index} no tiene fingerprint")
    material: dict[str, str] = {"shot": shot["fingerprint"]}
    if args.anchor:
        anchor = Path(args.anchor)
        if anchor.is_symlink() or not anchor.is_file():
            raise ValueError(f"no existe el ancla: {anchor}")
        material["anchor_sha256"] = _sha256_file(anchor)
    canonical = json.dumps(material, sort_keys=True, separators=(",", ":"))
    print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
    return 0


def command_write_fingerprint(args: argparse.Namespace) -> int:
    if not re.fullmatch(r"[0-9a-f]{64}", args.fingerprint):
        raise ValueError("fingerprint invalido")
    path = Path(args.path)
    if args.artifact:
        artifact = Path(args.artifact)
        if artifact.is_symlink() or not artifact.is_file():
            raise ValueError("el artefacto de la huella no es un archivo regular")
        _atomic_json(
            path,
            {
                "schema": "minimax-h3.artifact-fingerprint/v1",
                "fingerprint": args.fingerprint,
                "artifact_sha256": _sha256_file(artifact),
            },
        )
    else:
        _atomic_bytes(path, (args.fingerprint + "\n").encode("ascii"))
    return 0


def command_match_fingerprint(args: argparse.Namespace) -> int:
    path = Path(args.path)
    if path.is_symlink():
        return 1
    try:
        raw = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return 1
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError:
        manifest = None
    if isinstance(manifest, dict):
        recorded = manifest.get("fingerprint")
    else:
        recorded = raw
    if recorded != args.fingerprint:
        return 1
    if not args.artifact:
        return 0
    if not isinstance(manifest, dict):
        return 1
    expected_sha = manifest.get("artifact_sha256")
    if not isinstance(expected_sha, str) or not re.fullmatch(
        r"[0-9a-f]{64}", expected_sha
    ):
        return 1
    artifact = Path(args.artifact)
    if artifact.is_symlink() or not artifact.is_file():
        return 1
    return 0 if _sha256_file(artifact) == expected_sha else 1


def command_verify_artifact(args: argparse.Namespace) -> int:
    """Valida un sidecar de procedencia y los bytes del artefacto asociado."""
    sidecar = Path(args.manifest)
    artifact = Path(args.artifact)
    if sidecar.is_symlink() or artifact.is_symlink() or not artifact.is_file():
        return 1
    manifest = _read_json(sidecar)
    fingerprint = manifest.get("fingerprint")
    expected_sha = manifest.get("artifact_sha256")
    if (
        manifest.get("schema") != "minimax-h3.artifact-fingerprint/v1"
        or not isinstance(fingerprint, str)
        or not re.fullmatch(r"[0-9a-f]{64}", fingerprint)
        or not isinstance(expected_sha, str)
        or not re.fullmatch(r"[0-9a-f]{64}", expected_sha)
    ):
        return 1
    return 0 if _sha256_file(artifact) == expected_sha else 1


def _probe(path: Path, ffprobe: str, count_frames: bool = False) -> dict[str, Any]:
    command = [ffprobe, "-v", "error"]
    if count_frames:
        command.append("-count_frames")
    command.extend(
        [
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ]
    )
    process = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise ValueError(f"ffprobe fallo (rc={process.returncode}){suffix}")
    try:
        result = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError("ffprobe no devolvio JSON valido") from exc
    if not isinstance(result, dict):
        raise ValueError("respuesta inesperada de ffprobe")
    return result


def command_check_video(args: argparse.Namespace) -> int:
    path = Path(args.path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("no es un archivo regular")
    size = path.stat().st_size
    if size < args.min_bytes:
        raise ValueError(f"archivo demasiado pequeno ({size} bytes)")

    if args.frames is not None and (args.frames <= 0 or not args.fps or args.fps <= 0):
        raise ValueError("--frames requiere --fps positivo")
    probe = _probe(path, args.ffprobe, count_frames=args.frames is not None)
    streams = probe.get("streams")
    if not isinstance(streams, list):
        raise ValueError("ffprobe no encontro streams")
    videos = [s for s in streams if isinstance(s, dict) and s.get("codec_type") == "video"]
    audios = [s for s in streams if isinstance(s, dict) and s.get("codec_type") == "audio"]
    if not videos:
        raise ValueError("falta stream de video")
    video = videos[0]
    if args.width is not None and video.get("width") != args.width:
        raise ValueError(f"ancho {video.get('width')}, esperado {args.width}")
    if args.height is not None and video.get("height") != args.height:
        raise ValueError(f"alto {video.get('height')}, esperado {args.height}")
    if args.require_audio and not audios:
        raise ValueError("falta stream de audio")

    frame_count: int | None = None
    if args.frames is not None:
        raw_count = video.get("nb_read_frames") or video.get("nb_frames")
        try:
            frame_count = int(raw_count)
        except (TypeError, ValueError) as exc:
            raise ValueError("ffprobe no pudo contar los fotogramas") from exc
        if frame_count != args.frames:
            raise ValueError(
                f"fotogramas {frame_count}, esperados {args.frames}"
            )
        raw_rate = video.get("avg_frame_rate") or video.get("r_frame_rate")
        try:
            actual_rate = float(Fraction(str(raw_rate)))
        except (ValueError, ZeroDivisionError) as exc:
            raise ValueError("fps ausente o invalido") from exc
        if abs(actual_rate - args.fps) > 0.01:
            raise ValueError(f"fps {actual_rate:g}, esperados {args.fps}")

    raw_duration = (probe.get("format") or {}).get("duration")
    try:
        duration = float(raw_duration)
    except (TypeError, ValueError) as exc:
        raise ValueError("duracion ausente o invalida") from exc
    if duration <= 0:
        raise ValueError("duracion no positiva")
    if args.frames is not None:
        expected_duration = args.frames / args.fps
        tolerance = max(0.05, 1 / args.fps)
        if abs(duration - expected_duration) > tolerance:
            raise ValueError(
                f"duracion {duration:.3f}s, esperada {expected_duration:.3f}s"
            )

    if args.decode:
        process = subprocess.run(
            [args.ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-f", "null", "-"],
            capture_output=True,
            timeout=args.decode_timeout,
            check=False,
        )
        if process.returncode != 0:
            detail = process.stderr.decode(errors="replace").strip().splitlines()
            suffix = f": {detail[-1]}" if detail else ""
            raise ValueError(f"decodificacion fallo (rc={process.returncode}){suffix}")

    if args.json:
        print(
            json.dumps(
                {
                    "path": str(path),
                    "size": size,
                    "width": video.get("width"),
                    "height": video.get("height"),
                    "audio": bool(audios),
                    "duration": duration,
                    "frames": frame_count,
                },
                sort_keys=True,
            )
        )
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    state = commands.add_parser("state", help="actualiza estado JSON atomicamente")
    state.add_argument("path")
    state.add_argument("--phase", required=True)
    state.add_argument("--name")
    state.add_argument("--run-fingerprint")
    state.add_argument("--plan")
    state.add_argument("--message")
    state.add_argument("--final")
    state.add_argument("--pid", type=int)
    state.add_argument("--completed", type=int)
    state.add_argument("--total", type=int)
    state.set_defaults(function=command_state)

    recipe = commands.add_parser(
        "recipe-fingerprint", help="huella de contenido de modelos, binario y receta"
    )
    recipe.add_argument("--cache", required=True)
    recipe.add_argument("--manifest")
    recipe.add_argument("--component", action="append", default=[])
    recipe.add_argument("--setting", action="append", default=[])
    recipe.set_defaults(function=command_recipe_fingerprint)

    verify_recipe = commands.add_parser(
        "verify-recipe", help="comprueba que los componentes no fueron sustituidos"
    )
    verify_recipe.add_argument("manifest")
    verify_recipe.set_defaults(function=command_verify_recipe)

    shot = commands.add_parser("shot-fingerprint", help="huella efectiva de una toma")
    shot.add_argument("plan")
    shot.add_argument("index", type=int)
    shot.add_argument("--anchor")
    shot.set_defaults(function=command_shot_fingerprint)

    write = commands.add_parser("write-fingerprint", help="escribe una huella atomicamente")
    write.add_argument("path")
    write.add_argument("fingerprint")
    write.add_argument("--artifact")
    write.set_defaults(function=command_write_fingerprint)

    match = commands.add_parser("match-fingerprint", help="compara una huella registrada")
    match.add_argument("path")
    match.add_argument("fingerprint")
    match.add_argument("--artifact")
    match.set_defaults(function=command_match_fingerprint)

    verify_artifact = commands.add_parser(
        "verify-artifact", help="valida sidecar de procedencia y artefacto"
    )
    verify_artifact.add_argument("manifest")
    verify_artifact.add_argument("artifact")
    verify_artifact.set_defaults(function=command_verify_artifact)

    check = commands.add_parser("check-video", help="valida un artefacto de video")
    check.add_argument("path")
    check.add_argument("--width", type=int)
    check.add_argument("--height", type=int)
    check.add_argument("--frames", type=int)
    check.add_argument("--fps", type=int)
    check.add_argument("--min-bytes", type=int, default=1024)
    check.add_argument("--require-audio", action="store_true")
    check.add_argument("--decode", action="store_true")
    check.add_argument("--decode-timeout", type=int, default=3600)
    check.add_argument("--ffprobe", default="ffprobe")
    check.add_argument("--ffmpeg", default="ffmpeg")
    check.add_argument("--json", action="store_true")
    check.set_defaults(function=command_check_video)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"estado_obra: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
