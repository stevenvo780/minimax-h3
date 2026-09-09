#!/usr/bin/env python3
"""Construye el plan canonico y reproducible de una obra MiniMax-H3.

El plan es la frontera entre el guion humano y la ejecucion cara en GPU. Solo
contiene entradas efectivas: no consulta configuracion del entorno, no incluye
fechas y no descubre modelos por su cuenta. A igualdad de guion, motor de
prompts y parametros, la salida y sus huellas son identicas byte por byte.

Uso:
  planificar.py GUION --nombre OBRA --frames 345 --width 736 --height 416 \
    --steps 20 --fps 24 --seed 100 --model-id minimax-h3-pruned-q4

``model-id`` debe identificar la pila completa que puede cambiar el resultado
(modelos principal y auxiliares, CFG y receta/backend), no solo el nombre del
GGUF principal. El planificador lo trata como identificador opaco para no leer
rutas, configuracion ni secretos fuera de las entradas declaradas.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


SCHEMA = "minimax-h3.plan-obra/v1"
TAKE_SCHEMA = "minimax-h3.toma/v1"
VALID_TYPES = (
    "habla",
    "muda",
    "accion",
    "detalle",
    "paisaje",
    "camara",
    "informativo",
)
REQUIRED_HEADERS = ("ESCENA", "AMBIENTE", "MUSICA")
HEADER_RE = re.compile(r"^@(TIPO|ESCENA|AMBIENTE|MUSICA)\s+(.+?)\s*$")
LEGACY_ANCHOR_RE = re.compile(r"^ancla:anclas/[^/]+\.png$")
NUMERIC_ANCHOR_RE = re.compile(r"^ancla:([0-9]+)$")
INT32_MAX = (1 << 31) - 1
INT64_MAX = (1 << 63) - 1


class PlanError(Exception):
    """Error de entrada que debe salir sin traceback y con codigo 2."""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise PlanError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def fingerprint(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


def read_file(path: Path, description: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        detail = exc.strerror or str(exc)
        raise PlanError(f"no se puede leer {description}: {detail}") from exc


def decode_script(data: bytes) -> str:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise PlanError(
            f"el guion no es UTF-8 valido (byte {exc.start})"
        ) from exc
    if "\0" in text:
        raise PlanError("el guion contiene un byte NUL no representable por el runner")
    return text


def normalize_mode(raw_mode: str, index: int, line_number: int) -> tuple[str, int | None, list[str]]:
    """Devuelve modo canonico, toma fuente y avisos.

    ``ancla`` siempre se materializa como ``ancla:1``. Este runner acepta
    ``encadena`` por compatibilidad, pero deliberadamente lo ejecuta como
    ``ancla:1``: reinyectar el ultimo frame acumula degradacion medida. El campo
    anchor_source es deliberadamente solo el indice; el modo canonico expresa
    que clase de frame debe obtener el ejecutor.
    """

    warnings: list[str] = []
    implicit = not raw_mode.strip()
    mode = raw_mode.strip() or "ancla"
    legacy = bool(LEGACY_ANCHOR_RE.fullmatch(mode))
    shorthand = mode == "ancla"

    if legacy:
        legacy_target = "inicio" if index == 1 else "ancla:1"
        warnings.append(
            f"toma {index} (linea {line_number}): modo legacy '{mode}' "
            f"normalizado a '{legacy_target}'"
        )
        mode = "ancla:1"
    elif shorthand:
        mode = "ancla:1"

    # La primera toma no tiene una fuente posible. La forma historica vacia o
    # 'ancla' se corrige sin ruido; un modo explicitamente imposible se rechaza.
    if index == 1:
        if mode == "inicio":
            return "inicio", None, warnings
        if shorthand or implicit or legacy or mode == "encadena":
            if not implicit and not shorthand and not legacy:
                warnings.append(
                    f"toma 1 (linea {line_number}): modo '{raw_mode.strip()}' "
                    "normalizado a 'inicio' porque no hay toma previa"
                )
            return "inicio", None, warnings

    if mode == "inicio":
        return mode, None, warnings
    if mode == "encadena":
        # La toma 1 ya quedo cubierta arriba. Para el resto, conservar la
        # sintaxis historica pero planificar la operacion que de verdad ejecuta
        # producir-anclado.sh.
        warnings.append(
            f"toma {index} (linea {line_number}): modo 'encadena' "
            "normalizado a 'ancla:1' porque el encadenado real degrada"
        )
        return "ancla:1", 1, warnings

    match = NUMERIC_ANCHOR_RE.fullmatch(mode)
    if match:
        try:
            source = int(match.group(1), 10)
        except ValueError as exc:
            raise PlanError(
                f"toma {index} (linea {line_number}): referencia de ancla "
                "fuera del rango admitido"
            ) from exc
        if source < 1:
            raise PlanError(
                f"toma {index} (linea {line_number}): '{mode}' no referencia "
                "una toma existente"
            )
        if source >= index:
            raise PlanError(
                f"toma {index} (linea {line_number}): '{mode}' apunta hacia "
                "adelante; la referencia debe ser una toma previa"
            )
        return f"ancla:{source}", source, warnings

    raise PlanError(
        f"toma {index} (linea {line_number}): modo desconocido '{mode}' "
        "(validos: inicio, ancla, encadena, ancla:N)"
    )


def parse_script(text: str) -> tuple[dict[str, str], list[dict[str, Any]], list[str]]:
    headers: dict[str, str] = {}
    raw_takes: list[dict[str, Any]] = []

    for line_number, original in enumerate(text.splitlines(), 1):
        line = original.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("@"):
            match = HEADER_RE.fullmatch(line)
            if not match:
                raise PlanError(
                    f"linea {line_number}: cabecera desconocida o mal formada: "
                    f"'{line.split(None, 1)[0]}'"
                )
            key, value = match.groups()
            value = value.strip()
            if key in headers:
                raise PlanError(f"linea {line_number}: cabecera @{key} duplicada")
            if not value:
                raise PlanError(f"linea {line_number}: cabecera @{key} vacia")
            headers[key] = value
            continue

        if line.startswith("TOMA|") or line.startswith("HABLA|"):
            fields = line.split("|")
            if len(fields) < 2 or len(fields) > 6:
                raise PlanError(
                    f"linea {line_number}: {fields[0]} admite entre 2 y 6 "
                    f"campos, se recibieron {len(fields)}"
                )
            fields.extend([""] * (6 - len(fields)))
            record, content, mode, take_type, scene, ambience = (
                field.strip() for field in fields
            )
            if not content:
                raise PlanError(f"linea {line_number}: {record} sin contenido")
            raw_takes.append(
                {
                    "registro": record,
                    "contenido": content,
                    "modo_original": mode,
                    "tipo_propio": take_type,
                    "escena_propia": scene,
                    "ambiente_propio": ambience,
                    "linea": line_number,
                }
            )
            continue

        raise PlanError(
            f"linea {line_number}: se esperaba una cabecera, TOMA| o HABLA|"
        )

    missing = [key for key in REQUIRED_HEADERS if not headers.get(key)]
    if missing:
        formatted = ", ".join(f"@{key}" for key in missing)
        raise PlanError(f"faltan cabeceras requeridas: {formatted}")
    if not raw_takes:
        raise PlanError("el guion no contiene ninguna linea TOMA| ni HABLA|")

    default_type = headers.get("TIPO", "habla").strip()
    if default_type not in VALID_TYPES:
        raise PlanError(
            f"@TIPO desconocido '{default_type}' "
            f"(validos: {', '.join(VALID_TYPES)})"
        )

    warnings: list[str] = []
    takes: list[dict[str, Any]] = []
    for index, raw in enumerate(raw_takes, 1):
        take_type = raw["tipo_propio"]
        if not take_type:
            take_type = "habla" if raw["registro"] == "HABLA" else default_type
        if take_type not in VALID_TYPES:
            raise PlanError(
                f"toma {index} (linea {raw['linea']}): tipo desconocido "
                f"'{take_type}' (validos: {', '.join(VALID_TYPES)})"
            )

        mode, anchor_source, mode_warnings = normalize_mode(
            raw["modo_original"], index, raw["linea"]
        )
        warnings.extend(mode_warnings)
        takes.append(
            {
                "indice": index,
                "registro": raw["registro"],
                "contenido": raw["contenido"],
                "modo": mode,
                "tipo": take_type,
                "escena": raw["escena_propia"] or headers["ESCENA"],
                "ambiente": raw["ambiente_propio"] or headers["AMBIENTE"],
                "musica": headers["MUSICA"],
                "anchor_source": anchor_source,
            }
        )

    return headers, takes, warnings


def positive(name: str, value: int) -> None:
    if value <= 0:
        raise PlanError(f"--{name} debe ser un entero positivo (recibido: {value})")
    if value > INT32_MAX:
        raise PlanError(
            f"--{name} queda fuera del rango del runner (maximo: {INT32_MAX})"
        )


def validate_arguments(args: argparse.Namespace) -> None:
    if not args.nombre.strip():
        raise PlanError("--nombre no puede estar vacio")
    if not args.model_id.strip():
        raise PlanError("--model-id no puede estar vacio")
    positive("width", args.width)
    positive("height", args.height)
    positive("steps", args.steps)
    positive("fps", args.fps)
    if args.frames > INT32_MAX:
        raise PlanError(
            f"--frames queda fuera del rango del runner (maximo: {INT32_MAX})"
        )
    if args.frames < 5 or (args.frames - 5) % 17:
        raise PlanError(
            f"--frames debe cumplir 17k+5 (recibido: {args.frames})"
        )
    if args.seed < 0:
        raise PlanError(f"--seed debe ser cero o positivo (recibido: {args.seed})")


def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    validate_arguments(args)

    script_path = Path(args.guion)
    script_bytes = read_file(script_path, "el guion")
    script_sha256 = sha256_bytes(script_bytes)
    headers, parsed_takes, warnings = parse_script(decode_script(script_bytes))
    if args.seed > INT64_MAX - len(parsed_takes):
        raise PlanError(
            "--seed no deja margen para las semillas por toma dentro de int64"
        )

    prompt_engine_path = Path(__file__).resolve().parents[1] / "lib" / "prompt.sh"
    prompt_engine_sha256 = sha256_bytes(
        read_file(prompt_engine_path, "el motor de prompts lib/prompt.sh")
    )

    parameters = {
        "nombre": args.nombre.strip(),
        "frames": args.frames,
        "width": args.width,
        "height": args.height,
        "steps": args.steps,
        "fps": args.fps,
        "seed": args.seed,
        "model_id": args.model_id.strip(),
    }
    effective_header = {
        "tipo": headers.get("TIPO", "habla").strip(),
        "escena": headers["ESCENA"],
        "ambiente": headers["AMBIENTE"],
        "musica": headers["MUSICA"],
    }
    take_duration = round(args.frames / args.fps, 6)
    takes: list[dict[str, Any]] = []

    for parsed in parsed_takes:
        effective = {
            **parsed,
            "nombre": parameters["nombre"],
            "frames": parameters["frames"],
            "width": parameters["width"],
            "height": parameters["height"],
            "steps": parameters["steps"],
            "fps": parameters["fps"],
            "semilla": parameters["seed"] + parsed["indice"],
            "model_id": parameters["model_id"],
            "duracion_estimada_s": take_duration,
        }
        material = {
            "schema": TAKE_SCHEMA,
            "prompt_engine_sha256": prompt_engine_sha256,
            "toma": effective,
        }
        effective["fingerprint"] = fingerprint(material)
        takes.append(effective)

    plan: dict[str, Any] = {
        "schema": SCHEMA,
        "guion_sha256": script_sha256,
        "prompt_engine_sha256": prompt_engine_sha256,
        "cabecera": effective_header,
        "parametros": parameters,
        "tomas": takes,
        "warnings": warnings,
        "duracion_estimada_s": round(args.frames * len(takes) / args.fps, 6),
    }
    plan["run_fingerprint"] = fingerprint(plan)
    return plan


def parser() -> ArgumentParser:
    result = ArgumentParser(
        description="Emite el plan JSON canonico de un guion MiniMax-H3."
    )
    result.add_argument("guion", help="ruta al fichero .guion")
    result.add_argument("--nombre", "--name", required=True, dest="nombre")
    result.add_argument("--frames", required=True, type=int)
    result.add_argument("--width", "--w", required=True, type=int, dest="width")
    result.add_argument("--height", "--h", required=True, type=int, dest="height")
    result.add_argument("--steps", "--pasos", required=True, type=int, dest="steps")
    result.add_argument("--fps", required=True, type=int)
    result.add_argument("--seed", required=True, type=int)
    result.add_argument(
        "--model-id",
        required=True,
        help="identidad canonica de la pila completa de modelos y receta",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        plan = build_plan(args)
    except PlanError as exc:
        print(f"planificar: {exc}", file=sys.stderr)
        return 2

    json.dump(plan, sys.stdout, ensure_ascii=False, sort_keys=True, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
