#!/usr/bin/env python3
"""Banco direccionado por contenido para comparar tomas sin tocar una obra.

Los comandos internos ``identificar`` y ``finalizar`` los usa
``produccion/generar-candidato.sh``. Los comandos publicos permiten verificar,
listar, comparar, seleccionar y copiar de forma segura un candidato ya creado.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


REQUEST_SCHEMA = "minimax-h3.candidate-request/v1"
MANIFEST_SCHEMA = "minimax-h3.candidate-manifest/v1"
SELECTION_SCHEMA = "minimax-h3.candidate-selection/v1"
STAGED_SCHEMA = "minimax-h3.staged-candidate/v1"
STAGED_ANCHOR_SCHEMA = "minimax-h3.staged-anchor/v1"
DEFAULT_ARTIFACT_VERSION = "h3-candidate-video/v1"
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class CandidateError(ValueError):
    """Error de contrato, integridad o procedencia del banco."""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _regular_stat(path: Path) -> os.stat_result:
    try:
        details = path.lstat()
    except OSError as exc:
        raise CandidateError(f"no se puede abrir {path}: {exc}") from exc
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISREG(details.st_mode):
        raise CandidateError(f"no es un archivo regular sin symlink: {path}")
    return details


def _stat_identity(details: os.stat_result) -> dict[str, int]:
    return {
        "device": details.st_dev,
        "inode": details.st_ino,
        "size": details.st_size,
        "mtime_ns": details.st_mtime_ns,
        "ctime_ns": details.st_ctime_ns,
    }


def sha256_regular_record(path: Path) -> tuple[str, dict[str, int]]:
    """Hashea con O_NOFOLLOW y devuelve la identidad estable del archivo."""
    _regular_stat(path)
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise CandidateError(f"no se puede abrir de forma segura {path}: {exc}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise CandidateError(f"no es un archivo regular: {path}")
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    current = _regular_stat(path)
    if _stat_identity(before) != _stat_identity(after) or _stat_identity(
        after
    ) != _stat_identity(current):
        raise CandidateError(f"{path} cambio mientras se calculaba su SHA-256")
    return digest.hexdigest(), _stat_identity(after)


def sha256_regular(path: Path) -> str:
    return sha256_regular_record(path)[0]


def read_json_regular(path: Path) -> dict[str, Any]:
    _regular_stat(path)
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CandidateError(f"JSON invalido en {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"se esperaba un objeto JSON en {path}")
    return value


def atomic_json(path: Path, value: Any, *, replace: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise CandidateError(f"la salida es un symlink: {path}")
    if path.exists() and not replace:
        raise CandidateError(f"la salida ya existe: {path}")
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if replace:
            os.replace(tmp, path)
        else:
            try:
                os.link(tmp, path)
            except FileExistsError as exc:
                raise CandidateError(
                    f"la salida aparecio durante la escritura: {path}"
                ) from exc
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def positive(value: int, label: str) -> int:
    if value <= 0:
        raise CandidateError(f"{label} debe ser positivo")
    return value


def _metadata_matches(record: Any, details: os.stat_result) -> bool:
    return isinstance(record, dict) and record == _stat_identity(details)


def _load_take(plan_path: Path, take_index: int) -> tuple[dict[str, Any], dict[str, Any]]:
    plan = read_json_regular(plan_path)
    if plan.get("schema") != "minimax-h3.plan-obra/v1":
        raise CandidateError("plan.json ausente o de version incompatible")
    takes = plan.get("tomas")
    if not isinstance(takes, list) or not takes:
        raise CandidateError("el plan no contiene tomas")
    if take_index < 1 or take_index > len(takes):
        raise CandidateError(f"toma {take_index} fuera del plan (1..{len(takes)})")
    take = takes[take_index - 1]
    if not isinstance(take, dict):
        raise CandidateError(f"la toma {take_index} no es un objeto")
    if take.get("indice") != take_index:
        raise CandidateError(f"la toma {take_index} tiene indice incoherente")
    for key in ("tipo", "escena", "contenido", "ambiente", "musica"):
        if not isinstance(take.get(key), str) or not take[key].strip():
            raise CandidateError(f"la toma {take_index} no tiene {key} valido")
    return plan, dict(take)


def command_extract(args: argparse.Namespace) -> int:
    """Emite campos NUL para Bash sin volver a parsear el guion original."""
    plan, take = _load_take(Path(args.plan), args.take)
    defaults = plan.get("parametros")
    if not isinstance(defaults, dict):
        raise CandidateError("el plan no contiene parametros")
    values = [
        take["tipo"],
        take["escena"],
        take["contenido"],
        take["ambiente"],
        take["musica"],
        str(take.get("width", defaults.get("width", ""))),
        str(take.get("height", defaults.get("height", ""))),
        str(take.get("frames", defaults.get("frames", ""))),
        str(take.get("fps", defaults.get("fps", ""))),
        str(take.get("steps", defaults.get("steps", ""))),
        str(take.get("semilla", defaults.get("seed", ""))),
        str(defaults.get("nombre", take.get("nombre", "obra"))),
    ]
    if any("\x00" in item for item in values):
        raise CandidateError("un campo de la toma contiene NUL")
    sys.stdout.buffer.write(b"\0".join(item.encode("utf-8") for item in values) + b"\0")
    return 0


def command_identify(args: argparse.Namespace) -> int:
    plan_path = Path(args.plan)
    recipe_path = Path(args.recipe)
    model_path = Path(args.model)
    prompt_path = Path(args.prompt_file)
    plan, take = _load_take(plan_path, args.take)
    recipe = read_json_regular(recipe_path)
    if recipe.get("schema") != "minimax-h3.recipe-manifest/v1":
        raise CandidateError("manifiesto de receta incompatible")
    recipe_fp = recipe.get("fingerprint")
    if not isinstance(recipe_fp, str) or not SHA256_RE.fullmatch(recipe_fp):
        raise CandidateError("huella de receta invalida")
    components = recipe.get("components")
    if not isinstance(components, dict) or not isinstance(components.get("diffusion"), dict):
        raise CandidateError("la receta no identifica el modelo de difusion")

    model_record = components["diffusion"]
    model_sha = model_record.get("sha256")
    try:
        model_resolved = model_path.resolve(strict=True)
    except OSError as exc:
        raise CandidateError(f"no se puede resolver el modelo: {exc}") from exc
    if (
        not isinstance(model_sha, str)
        or not SHA256_RE.fullmatch(model_sha)
        or model_record.get("path") != str(model_resolved)
        or Path(str(model_record.get("source_path", ""))).absolute()
        != model_path.absolute()
        or not _metadata_matches(model_record.get("metadata"), _regular_stat(model_path))
    ):
        raise CandidateError("el modelo elegido no coincide con la receta")
    prompt_sha = sha256_regular(prompt_path)
    if args.anchor:
        anchor_sha, anchor_metadata = sha256_regular_record(Path(args.anchor))
    else:
        anchor_sha, anchor_metadata = None, None

    for value, label in (
        (args.width, "width"),
        (args.height, "height"),
        (args.frames, "frames"),
        (args.fps, "fps"),
        (args.steps, "steps"),
    ):
        positive(value, label)
    if args.seed < 0:
        raise CandidateError("seed no puede ser negativo")

    source_take_fp = take.pop("fingerprint", None)
    take.pop("model_id", None)
    take.update(
        {
            "width": args.width,
            "height": args.height,
            "frames": args.frames,
            "fps": args.fps,
            "steps": args.steps,
            "semilla": args.seed,
            "duracion_estimada_s": round(args.frames / args.fps, 6),
        }
    )
    material = {
        "schema": REQUEST_SCHEMA,
        "artifact_version": args.artifact_version,
        "effective_take": take,
        "recipe_fingerprint": recipe_fp,
        "model_sha256": model_sha,
        "anchor_sha256": anchor_sha,
        "prompt_sha256": prompt_sha,
    }
    candidate_fp = fingerprint(material)

    work_name = (plan.get("parametros") or {}).get("nombre") or take.get("nombre") or "obra"
    if not isinstance(work_name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", work_name):
        raise CandidateError("nombre de obra invalido en el plan")
    candidate_dir = None
    if args.bank:
        candidate_dir = str(
            Path(args.bank).absolute()
            / work_name
            / f"t{args.take:02d}"
            / candidate_fp
        )

    result = {
        "schema": REQUEST_SCHEMA,
        "fingerprint": candidate_fp,
        "artifact_version": args.artifact_version,
        "candidate_dir": candidate_dir,
        "source": {
            "plan_path": str(plan_path.absolute()),
            "plan_sha256": sha256_regular(plan_path),
            "plan_run_fingerprint": plan.get("run_fingerprint"),
            "take_index": args.take,
            "take_fingerprint": source_take_fp,
        },
        "effective_take": take,
        "recipe": {
            "fingerprint": recipe_fp,
            "source_manifest_sha256": sha256_regular(recipe_path),
        },
        "inputs": {
            "model_path": str(model_path.absolute()),
            "model_sha256": model_sha,
            "anchor_path": str(Path(args.anchor).absolute()) if args.anchor else None,
            "anchor_sha256": anchor_sha,
            "anchor_source_metadata": anchor_metadata,
            "prompt_sha256": prompt_sha,
        },
        "created_at": utc_now(),
    }
    atomic_json(Path(args.output), result)
    if args.print_json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def _anchor_contract(
    request_path: Path, source_path: Path
) -> tuple[dict[str, Any], str, dict[str, int]]:
    request = read_json_regular(request_path)
    if request.get("schema") != REQUEST_SCHEMA:
        raise CandidateError("solicitud de candidato incompatible")
    inputs = request.get("inputs")
    if not isinstance(inputs, dict):
        raise CandidateError("la solicitud no contiene entradas validas")
    expected_sha = inputs.get("anchor_sha256")
    expected_metadata = inputs.get("anchor_source_metadata")
    recorded_path = inputs.get("anchor_path")
    if not isinstance(expected_sha, str) or not SHA256_RE.fullmatch(expected_sha):
        raise CandidateError("la solicitud no identifica un ancla")
    if not isinstance(expected_metadata, dict):
        raise CandidateError("la solicitud no conserva la identidad inicial del ancla")
    if recorded_path != str(source_path.absolute()):
        raise CandidateError("la ruta del ancla no coincide con la solicitud")
    current_sha, current_metadata = sha256_regular_record(source_path)
    if current_sha != expected_sha or current_metadata != expected_metadata:
        raise CandidateError("el ancla fuente cambio despues de identificar el candidato")
    return request, expected_sha, expected_metadata


def _unlink_same_inode(path: Path, identity: dict[str, int] | None) -> None:
    """Quita solo el inode creado por esta operacion."""
    if identity is None:
        return
    try:
        current = path.lstat()
        if (
            current.st_dev == identity.get("device")
            and current.st_ino == identity.get("inode")
        ):
            path.unlink()
    except OSError:
        pass


def _copy_anchor_nofollow_exclusive(
    source: Path,
    destination: Path,
    *,
    expected_sha: str,
    expected_source_metadata: dict[str, int],
) -> dict[str, int]:
    """Copia un ancla por descriptor a un archivo nuevo y de solo lectura."""
    parent = destination.parent
    try:
        parent_details = parent.lstat()
    except OSError as exc:
        raise CandidateError(f"no se puede abrir el staging del ancla: {exc}") from exc
    if stat.S_ISLNK(parent_details.st_mode) or not stat.S_ISDIR(parent_details.st_mode):
        raise CandidateError("el staging del ancla no es un directorio real")
    if parent.resolve(strict=True) != parent.absolute():
        raise CandidateError("el staging del ancla atraviesa un symlink")
    if destination.exists() or destination.is_symlink():
        raise CandidateError(f"la copia staged del ancla ya existe: {destination}")

    source_flags = os.O_RDONLY | os.O_CLOEXEC
    target_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        source_flags |= os.O_NOFOLLOW
        target_flags |= os.O_NOFOLLOW
    try:
        source_fd = os.open(source, source_flags)
    except OSError as exc:
        raise CandidateError(f"no se puede abrir de forma segura {source}: {exc}") from exc

    target_fd: int | None = None
    created_identity: dict[str, int] | None = None
    try:
        source_before = os.fstat(source_fd)
        if not stat.S_ISREG(source_before.st_mode):
            raise CandidateError(f"el ancla no es un archivo regular: {source}")
        if _stat_identity(source_before) != expected_source_metadata:
            raise CandidateError("el ancla fuente cambio antes de copiarla al staging")
        try:
            target_fd = os.open(destination, target_flags, 0o400)
        except OSError as exc:
            raise CandidateError(
                f"no se puede crear de forma exclusiva el staging del ancla: {exc}"
            ) from exc
        created_identity = _stat_identity(os.fstat(target_fd))

        digest = hashlib.sha256()
        while True:
            block = os.read(source_fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            pending = memoryview(block)
            while pending:
                written = os.write(target_fd, pending)
                if written <= 0:
                    raise CandidateError("escritura incompleta del staging del ancla")
                pending = pending[written:]
        os.fchmod(target_fd, 0o400)
        os.fsync(target_fd)

        source_after = os.fstat(source_fd)
        source_current = _regular_stat(source)
        if (
            _stat_identity(source_before) != _stat_identity(source_after)
            or _stat_identity(source_after) != _stat_identity(source_current)
            or _stat_identity(source_after) != expected_source_metadata
        ):
            raise CandidateError("el ancla fuente cambio mientras se copiaba")
        if digest.hexdigest() != expected_sha:
            raise CandidateError("el SHA-256 del ancla ya no coincide con la solicitud")
    except BaseException:
        if target_fd is not None:
            os.close(target_fd)
            target_fd = None
        _unlink_same_inode(destination, created_identity)
        raise
    finally:
        os.close(source_fd)
        if target_fd is not None:
            os.close(target_fd)

    staged_sha, staged_metadata = sha256_regular_record(destination)
    if staged_sha != expected_sha:
        _unlink_same_inode(destination, staged_metadata)
        raise CandidateError("la copia staged no conserva el SHA-256 del ancla")
    if _regular_stat(destination).st_mode & 0o222:
        _unlink_same_inode(destination, staged_metadata)
        raise CandidateError("la copia staged del ancla quedo escribible")
    return staged_metadata


def command_prepare_anchor(args: argparse.Namespace) -> int:
    request_path = Path(args.request)
    source = Path(args.source)
    destination = Path(args.output).absolute()
    record_path = Path(args.record)
    request, expected_sha, expected_source_metadata = _anchor_contract(
        request_path, source
    )
    staged_metadata = _copy_anchor_nofollow_exclusive(
        source,
        destination,
        expected_sha=expected_sha,
        expected_source_metadata=expected_source_metadata,
    )
    record = {
        "schema": STAGED_ANCHOR_SCHEMA,
        "request_fingerprint": request["fingerprint"],
        "source_path": str(source.absolute()),
        "source_sha256": expected_sha,
        "source_metadata": expected_source_metadata,
        "staged_path": str(destination),
        "staged_sha256": expected_sha,
        "staged_metadata": staged_metadata,
    }
    try:
        atomic_json(record_path, record, replace=False)
    except BaseException:
        _unlink_same_inode(destination, staged_metadata)
        raise
    return 0


def command_verify_anchor(args: argparse.Namespace) -> int:
    source = Path(args.source)
    staged = Path(args.staged).absolute()
    request, expected_sha, expected_source_metadata = _anchor_contract(
        Path(args.request), source
    )
    record = read_json_regular(Path(args.record))
    if (
        record.get("schema") != STAGED_ANCHOR_SCHEMA
        or record.get("request_fingerprint") != request.get("fingerprint")
        or record.get("source_path") != str(source.absolute())
        or record.get("source_sha256") != expected_sha
        or record.get("source_metadata") != expected_source_metadata
        or record.get("staged_path") != str(staged)
        or record.get("staged_sha256") != expected_sha
    ):
        raise CandidateError("el registro del staging del ancla no coincide")
    staged_sha, staged_metadata = sha256_regular_record(staged)
    if staged_sha != expected_sha or staged_metadata != record.get("staged_metadata"):
        raise CandidateError("la copia staged del ancla cambio")
    if _regular_stat(staged).st_mode & 0o222:
        raise CandidateError("la copia staged del ancla dejo de ser inmutable")
    return 0


def command_finalize(args: argparse.Namespace) -> int:
    request = read_json_regular(Path(args.request))
    if request.get("schema") != REQUEST_SCHEMA:
        raise CandidateError("solicitud de candidato incompatible")
    candidate_fp = request.get("fingerprint")
    if not isinstance(candidate_fp, str) or not SHA256_RE.fullmatch(candidate_fp):
        raise CandidateError("huella de candidato invalida")

    video_path = Path(args.video)
    video_sha = sha256_regular(video_path)
    sidecar = read_json_regular(Path(args.artifact_sidecar))
    if (
        sidecar.get("schema") != "minimax-h3.artifact-fingerprint/v1"
        or sidecar.get("fingerprint") != candidate_fp
        or sidecar.get("artifact_sha256") != video_sha
    ):
        raise CandidateError("el sidecar no liga el video con el candidato")
    probe = read_json_regular(Path(args.technical_json))
    probe.pop("path", None)
    recipe_sha = sha256_regular(Path(args.recipe))
    prompt_sha = sha256_regular(Path(args.prompt_file))
    if recipe_sha != request.get("recipe", {}).get("source_manifest_sha256"):
        raise CandidateError("la receta cambio durante la generacion")
    if prompt_sha != request.get("inputs", {}).get("prompt_sha256"):
        raise CandidateError("el prompt cambio durante la generacion")

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "fingerprint": candidate_fp,
        "artifact_version": request["artifact_version"],
        "created_at": request["created_at"],
        "completed_at": utc_now(),
        "source": request["source"],
        "effective_take": request["effective_take"],
        "recipe": {
            **request["recipe"],
            "path": "recipe.json",
            "sha256": recipe_sha,
        },
        "inputs": {
            **request["inputs"],
            "prompt_path": "prompt.txt",
        },
        "artifact": {
            "path": "video.avi",
            "sha256": video_sha,
            "size": video_path.stat().st_size,
            "fingerprint_sidecar": "video.fingerprint.json",
        },
        "technical_validation": {"validator": "lib/estado_obra.py", **probe},
    }
    atomic_json(Path(args.output), manifest)
    return 0


def _safe_child(directory: Path, name: Any, expected: str) -> Path:
    if name != expected:
        raise CandidateError(f"ruta interna inesperada: {name!r}")
    return directory / expected


def verify_candidate(directory: Path, *, technical: bool = False) -> dict[str, Any]:
    try:
        details = directory.lstat()
    except OSError as exc:
        raise CandidateError(f"no existe el candidato {directory}: {exc}") from exc
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISDIR(details.st_mode):
        raise CandidateError(f"el candidato no es un directorio real: {directory}")
    if directory.resolve(strict=True) != directory.absolute():
        raise CandidateError(f"la ruta del candidato atraviesa un symlink: {directory}")
    manifest_path = directory / "manifest.json"
    manifest = read_json_regular(manifest_path)
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise CandidateError(f"manifiesto de candidato incompatible: {manifest_path}")
    candidate_fp = manifest.get("fingerprint")
    if not isinstance(candidate_fp, str) or not SHA256_RE.fullmatch(candidate_fp):
        raise CandidateError("huella de candidato invalida")
    if directory.name != candidate_fp:
        raise CandidateError("el directorio no coincide con la huella del candidato")

    artifact = manifest.get("artifact")
    recipe = manifest.get("recipe")
    inputs = manifest.get("inputs")
    if not isinstance(artifact, dict) or not isinstance(recipe, dict) or not isinstance(inputs, dict):
        raise CandidateError("manifiesto incompleto")
    material = {
        "schema": REQUEST_SCHEMA,
        "artifact_version": manifest.get("artifact_version"),
        "effective_take": manifest.get("effective_take"),
        "recipe_fingerprint": recipe.get("fingerprint"),
        "model_sha256": inputs.get("model_sha256"),
        "anchor_sha256": inputs.get("anchor_sha256"),
        "prompt_sha256": inputs.get("prompt_sha256"),
    }
    if fingerprint(material) != candidate_fp:
        raise CandidateError("la huella no corresponde a la toma y receta efectivas")
    video = _safe_child(directory, artifact.get("path"), "video.avi")
    recipe_path = _safe_child(directory, recipe.get("path"), "recipe.json")
    prompt_path = _safe_child(directory, inputs.get("prompt_path"), "prompt.txt")
    sidecar_path = _safe_child(
        directory, artifact.get("fingerprint_sidecar"), "video.fingerprint.json"
    )
    if sha256_regular(video) != artifact.get("sha256"):
        raise CandidateError("SHA-256 del video no coincide")
    if video.stat().st_size != artifact.get("size"):
        raise CandidateError("tamano del video no coincide")
    if sha256_regular(recipe_path) != recipe.get("sha256"):
        raise CandidateError("SHA-256 de recipe.json no coincide")
    if sha256_regular(prompt_path) != inputs.get("prompt_sha256"):
        raise CandidateError("SHA-256 de prompt.txt no coincide")
    sidecar = read_json_regular(sidecar_path)
    if (
        sidecar.get("schema") != "minimax-h3.artifact-fingerprint/v1"
        or sidecar.get("fingerprint") != candidate_fp
        or sidecar.get("artifact_sha256") != artifact.get("sha256")
    ):
        raise CandidateError("sidecar de video invalido")
    recipe_document = read_json_regular(recipe_path)
    recipe_components = recipe_document.get("components")
    if (
        recipe_document.get("schema") != "minimax-h3.recipe-manifest/v1"
        or recipe_document.get("fingerprint") != recipe.get("fingerprint")
        or not isinstance(recipe_components, dict)
        or not isinstance(recipe_components.get("diffusion"), dict)
        or recipe_components["diffusion"].get("sha256") != inputs.get("model_sha256")
    ):
        raise CandidateError("recipe.json no demuestra el modelo declarado")

    if technical:
        take = manifest.get("effective_take")
        if not isinstance(take, dict):
            raise CandidateError("faltan parametros efectivos de la toma")
        state_tool = Path(__file__).resolve().parents[1] / "lib" / "estado_obra.py"
        command = [
            sys.executable,
            str(state_tool),
            "check-video",
            str(video),
            "--width",
            str(take.get("width")),
            "--height",
            str(take.get("height")),
            "--frames",
            str(take.get("frames")),
            "--fps",
            str(take.get("fps")),
            "--require-audio",
        ]
        process = subprocess.run(command, capture_output=True, text=True, check=False)
        if process.returncode:
            detail = process.stderr.strip() or process.stdout.strip()
            raise CandidateError(f"validacion tecnica fallo: {detail}")
    return manifest


def command_verify(args: argparse.Namespace) -> int:
    manifest = verify_candidate(Path(args.candidate), technical=args.technical)
    if args.json:
        print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"OK {manifest['fingerprint']} {Path(args.candidate)}")
    return 0


def _candidate_directories(bank: Path) -> Iterable[Path]:
    if bank.is_symlink() or not bank.is_dir():
        raise CandidateError(f"el banco no es un directorio real: {bank}")
    for manifest in sorted(bank.glob("*/t[0-9][0-9]/[0-9a-f]*/manifest.json")):
        if manifest.is_symlink():
            continue
        yield manifest.parent


def _summary(directory: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    take = manifest["effective_take"]
    inputs = manifest["inputs"]
    artifact = manifest["artifact"]
    return {
        "fingerprint": manifest["fingerprint"],
        "take": take.get("indice"),
        "type": take.get("tipo"),
        "model": Path(str(inputs.get("model_path", ""))).name,
        "model_sha256": inputs.get("model_sha256"),
        "steps": take.get("steps"),
        "width": take.get("width"),
        "height": take.get("height"),
        "frames": take.get("frames"),
        "fps": take.get("fps"),
        "seed": take.get("semilla"),
        "anchored": bool(inputs.get("anchor_sha256")),
        "artifact_sha256": artifact.get("sha256"),
        "bytes": artifact.get("size"),
        "path": str(directory.absolute()),
    }


def _print_summaries(summaries: list[dict[str, Any]], as_json: bool) -> None:
    if as_json:
        print(json.dumps(summaries, ensure_ascii=False, indent=2, sort_keys=True))
        return
    print("huella\ttoma\ttipo\tmodelo\treceta\tframes\tseed\tancla\truta")
    for item in summaries:
        print(
            "\t".join(
                [
                    item["fingerprint"][:12],
                    str(item["take"]),
                    str(item["type"]),
                    str(item["model"]),
                    f"{item['width']}x{item['height']}@{item['fps']}/{item['steps']}p",
                    str(item["frames"]),
                    str(item["seed"]),
                    "si" if item["anchored"] else "no",
                    item["path"],
                ]
            )
        )


def command_list(args: argparse.Namespace) -> int:
    summaries: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    for directory in _candidate_directories(Path(args.bank)):
        try:
            manifest = verify_candidate(directory, technical=args.technical)
            summary = _summary(directory, manifest)
            if args.take is None or summary["take"] == args.take:
                summaries.append(summary)
        except CandidateError as exc:
            errors.append({"path": str(directory), "error": str(exc)})
    if args.json:
        print(json.dumps({"candidates": summaries, "errors": errors}, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        _print_summaries(summaries, False)
        for error in errors:
            print(f"INVALIDO\t{error['path']}\t{error['error']}", file=sys.stderr)
    return 1 if errors and args.fail_invalid else 0


def command_compare(args: argparse.Namespace) -> int:
    if len(args.candidates) < 2:
        raise CandidateError("comparar requiere al menos dos candidatos")
    summaries = [
        _summary(Path(raw), verify_candidate(Path(raw), technical=args.technical))
        for raw in args.candidates
    ]
    _print_summaries(summaries, args.json)
    return 0


def command_select(args: argparse.Namespace) -> int:
    directory = Path(args.candidate).absolute()
    manifest = verify_candidate(directory, technical=True)
    manifest_path = directory / "manifest.json"
    selection = {
        "schema": SELECTION_SCHEMA,
        "selected_at": utc_now(),
        "candidate": {
            "directory": str(directory),
            "fingerprint": manifest["fingerprint"],
            "manifest_sha256": sha256_regular(manifest_path),
            "artifact_sha256": manifest["artifact"]["sha256"],
        },
        "effective_take": manifest["effective_take"],
        "note": args.note,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.resolve(strict=True) != output.parent.absolute():
        raise CandidateError("la ruta de seleccion atraviesa un symlink")
    atomic_json(output, selection, replace=args.replace)
    print(args.output)
    return 0


def _copy_nofollow_exclusive(source: Path, destination: Path) -> None:
    """Copia bytes regulares y publica con link(2), que nunca reemplaza."""
    expected = sha256_regular(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise CandidateError(f"la salida ya existe: {destination}")
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    tmp = Path(raw_tmp)
    try:
        source_flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            source_flags |= os.O_NOFOLLOW
        source_fd = os.open(source, source_flags)
        with os.fdopen(fd, "wb") as target, os.fdopen(source_fd, "rb") as origin:
            shutil.copyfileobj(origin, target, length=1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
        if sha256_regular(tmp) != expected:
            raise CandidateError("la copia temporal no conserva el SHA-256")
        try:
            os.link(tmp, destination)
        except FileExistsError as exc:
            raise CandidateError(f"la salida aparecio durante la copia: {destination}") from exc
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def command_stage(args: argparse.Namespace) -> int:
    selection_path = Path(args.selection)
    selection = read_json_regular(selection_path)
    if selection.get("schema") != SELECTION_SCHEMA:
        raise CandidateError("manifiesto de seleccion incompatible")
    chosen = selection.get("candidate")
    if not isinstance(chosen, dict):
        raise CandidateError("seleccion incompleta")
    directory = Path(str(chosen.get("directory", "")))
    manifest = verify_candidate(directory, technical=True)
    if (
        manifest["fingerprint"] != chosen.get("fingerprint")
        or sha256_regular(directory / "manifest.json") != chosen.get("manifest_sha256")
        or manifest["artifact"]["sha256"] != chosen.get("artifact_sha256")
    ):
        raise CandidateError("el candidato cambio despues de seleccionarlo")

    output = Path(args.output)
    sidecar = Path(str(output) + ".candidate.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.resolve(strict=True) != output.parent.absolute():
        raise CandidateError("la ruta de staging atraviesa un symlink")
    if output.exists() or output.is_symlink() or sidecar.exists() or sidecar.is_symlink():
        raise CandidateError("la salida o su manifiesto ya existen")
    _copy_nofollow_exclusive(directory / "video.avi", output)
    published = output.lstat()
    staged = {
        "schema": STAGED_SCHEMA,
        "staged_at": utc_now(),
        "selection_path": str(selection_path.absolute()),
        "selection_sha256": sha256_regular(selection_path),
        "candidate": chosen,
        "artifact": {"path": output.name, "sha256": sha256_regular(output)},
    }
    try:
        atomic_json(sidecar, staged, replace=False)
    except BaseException:
        # Solo quitamos el inode que esta funcion acaba de publicar.
        try:
            current = output.lstat()
            if current.st_dev == published.st_dev and current.st_ino == published.st_ino:
                output.unlink()
        except OSError:
            pass
        raise
    print(output)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    extract = commands.add_parser("extraer", help=argparse.SUPPRESS)
    extract.add_argument("--plan", required=True)
    extract.add_argument("--take", type=int, required=True)
    extract.set_defaults(function=command_extract)

    identify = commands.add_parser("identificar", help=argparse.SUPPRESS)
    identify.add_argument("--plan", required=True)
    identify.add_argument("--take", type=int, required=True)
    identify.add_argument("--recipe", required=True)
    identify.add_argument("--model", required=True)
    identify.add_argument("--prompt-file", required=True)
    identify.add_argument("--anchor")
    identify.add_argument("--width", type=int, required=True)
    identify.add_argument("--height", type=int, required=True)
    identify.add_argument("--frames", type=int, required=True)
    identify.add_argument("--fps", type=int, required=True)
    identify.add_argument("--steps", type=int, required=True)
    identify.add_argument("--seed", type=int, required=True)
    identify.add_argument("--artifact-version", default=DEFAULT_ARTIFACT_VERSION)
    identify.add_argument("--bank")
    identify.add_argument("--output", required=True)
    identify.add_argument("--print-json", action="store_true")
    identify.set_defaults(function=command_identify)

    prepare_anchor = commands.add_parser("preparar-ancla", help=argparse.SUPPRESS)
    prepare_anchor.add_argument("--request", required=True)
    prepare_anchor.add_argument("--source", required=True)
    prepare_anchor.add_argument("--output", required=True)
    prepare_anchor.add_argument("--record", required=True)
    prepare_anchor.set_defaults(function=command_prepare_anchor)

    verify_anchor = commands.add_parser("verificar-ancla", help=argparse.SUPPRESS)
    verify_anchor.add_argument("--request", required=True)
    verify_anchor.add_argument("--source", required=True)
    verify_anchor.add_argument("--staged", required=True)
    verify_anchor.add_argument("--record", required=True)
    verify_anchor.set_defaults(function=command_verify_anchor)

    finalize = commands.add_parser("finalizar", help=argparse.SUPPRESS)
    finalize.add_argument("--request", required=True)
    finalize.add_argument("--video", required=True)
    finalize.add_argument("--artifact-sidecar", required=True)
    finalize.add_argument("--technical-json", required=True)
    finalize.add_argument("--recipe", required=True)
    finalize.add_argument("--prompt-file", required=True)
    finalize.add_argument("--output", required=True)
    finalize.set_defaults(function=command_finalize)

    verify = commands.add_parser("verificar", help="verifica integridad y procedencia")
    verify.add_argument("candidate")
    verify.add_argument("--technical", action="store_true")
    verify.add_argument("--json", action="store_true")
    verify.set_defaults(function=command_verify)

    listing = commands.add_parser("listar", help="lista candidatos validos del banco")
    listing.add_argument("bank")
    listing.add_argument("--take", type=int)
    listing.add_argument("--technical", action="store_true")
    listing.add_argument("--fail-invalid", action="store_true")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(function=command_list)

    compare = commands.add_parser("comparar", help="compara recetas de candidatos")
    compare.add_argument("candidates", nargs="+")
    compare.add_argument("--technical", action="store_true")
    compare.add_argument("--json", action="store_true")
    compare.set_defaults(function=command_compare)

    select = commands.add_parser("seleccionar", help="fija una seleccion por SHA-256")
    select.add_argument("candidate")
    select.add_argument("--output", required=True)
    select.add_argument("--note")
    select.add_argument("--replace", action="store_true")
    select.set_defaults(function=command_select)

    stage = commands.add_parser("preparar", help="copia una seleccion sin symlinks ni reemplazos")
    stage.add_argument("selection")
    stage.add_argument("--output", required=True)
    stage.set_defaults(function=command_stage)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (CandidateError, OSError, subprocess.SubprocessError) as exc:
        print(f"candidatos: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
