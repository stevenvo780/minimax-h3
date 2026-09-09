#!/usr/bin/env python3
"""Selecciona un fotograma facial neutral para usarlo como ancla.

La seleccion no usa un instante prefijado: decodifica y evalua todos los
fotogramas. En produccion requiere OpenCV y un detector YuNet local. El PNG de
salida es el fotograma original, sin recortes ni anotaciones; el JSON lateral
explica por que fue elegido y permite comprobar exactamente sus insumos.

Uso:
  .venv-calidad/bin/python calidad/seleccionar-ancla.py TOMA.avi \
      --salida ancla.png

Opciones principales:
  --modelo RUTA             YuNet ONNX explicito. Si se omite, se busca bajo
                            modelos/evaluacion/.
  --json RUTA               Sidecar; por defecto, ANCLA.png.json.
  --confianza-min N         Confianza minima de deteccion (default: 0.85).
  --persistencia-min N      Fraccion minima con exactamente una cara (0.90).
  --margen-temporal N       Fraccion no elegible en cada extremo (0.08).
  --nitidez-min N           Varianza Laplaciana normalizada minima (35).

El backend simulado existe exclusivamente para la prueba reproducible del
repositorio. Requiere SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1 y nunca se activa
automaticamente.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, Iterable


SCHEMA = "seleccionar-ancla/v1"
MODELO_PREFERIDO = "face_detection_yunet_2023mar.onnx"
CODIGO_CONFIG = 2
CODIGO_RECHAZADO = 3


class ErrorConfiguracion(RuntimeError):
    pass


def sha256_fichero(ruta: Path) -> str:
    digest = hashlib.sha256()
    with ruta.open("rb") as fichero:
        for bloque in iter(lambda: fichero.read(1024 * 1024), b""):
            digest.update(bloque)
    return digest.hexdigest()


def sha256_frame(frame: Any) -> str:
    """SHA estable de dimensiones, dtype y pixeles BGR decodificados."""
    digest = hashlib.sha256()
    digest.update(str(tuple(frame.shape)).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(frame.dtype).encode("ascii"))
    digest.update(b"\0")
    digest.update(frame.tobytes(order="C"))
    return digest.hexdigest()


def limitar(valor: float, minimo: float = 0.0, maximo: float = 1.0) -> float:
    return max(minimo, min(maximo, valor))


def redondear(valor: Any, decimales: int = 6) -> Any:
    if valor is None:
        return None
    return round(float(valor), decimales)


def importar_cv2() -> Any:
    try:
        import cv2  # type: ignore
    except (ImportError, ModuleNotFoundError) as exc:
        raise ErrorConfiguracion(
            "falta el backend OpenCV; ejecuta calidad/preparar-modelos-evaluacion.sh "
            "y usa .venv-calidad/bin/python"
        ) from exc
    if not hasattr(cv2, "FaceDetectorYN") and not hasattr(cv2, "FaceDetectorYN_create"):
        raise ErrorConfiguracion("OpenCV no incluye el backend FaceDetectorYN requerido")
    return cv2


def resolver_modelo(explicito: str | None, raiz: Path) -> Path:
    if explicito:
        modelo = Path(explicito).expanduser().resolve()
        if not modelo.is_file():
            raise ErrorConfiguracion(f"modelo YuNet ausente: {modelo}")
        return modelo

    carpeta = raiz / "modelos" / "evaluacion"
    preferido = carpeta / MODELO_PREFERIDO
    if preferido.is_file():
        return preferido.resolve()
    candidatos = sorted(carpeta.glob("face_detection_yunet*.onnx"))
    if not candidatos:
        raise ErrorConfiguracion(
            f"modelo YuNet ausente bajo {carpeta}; ejecuta "
            "calidad/preparar-modelos-evaluacion.sh"
        )
    return candidatos[0].resolve()


def validar_numero(nombre: str, valor: float, minimo: float, maximo: float) -> None:
    if not math.isfinite(valor) or not minimo <= valor <= maximo:
        raise ErrorConfiguracion(f"{nombre} debe estar entre {minimo} y {maximo}")


def fila_a_cara(fila: Iterable[float]) -> dict[str, Any]:
    valores = [float(v) for v in fila]
    if len(valores) < 15:
        raise ErrorConfiguracion("YuNet devolvio una deteccion incompleta")
    return {
        "bbox": valores[0:4],
        "ojos": [valores[4:6], valores[6:8]],
        "nariz": valores[8:10],
        "boca": [valores[10:12], valores[12:14]],
        "confianza": valores[14],
    }


class DetectorYuNet:
    def __init__(self, cv2: Any, modelo: Path, confianza: float) -> None:
        clase = getattr(cv2, "FaceDetectorYN", None)
        crear = getattr(clase, "create", None)
        if crear is not None:
            self.detector = crear(str(modelo), "", (320, 320), confianza, 0.3, 5000)
        else:
            self.detector = cv2.FaceDetectorYN_create(
                str(modelo), "", (320, 320), confianza, 0.3, 5000
            )
        self.tamano: tuple[int, int] | None = None

    def detectar(self, frame: Any, indice: int) -> list[dict[str, Any]]:
        del indice
        alto, ancho = frame.shape[:2]
        tamano = (ancho, alto)
        if tamano != self.tamano:
            self.detector.setInputSize(tamano)
            self.tamano = tamano
        _resultado, filas = self.detector.detect(frame)
        if filas is None:
            return []
        return [fila_a_cara(fila) for fila in filas]


class DetectorSimulado:
    """Backend inyectable para tests; jamas se selecciona como fallback."""

    def __init__(self, ruta: Path) -> None:
        try:
            datos = json.loads(ruta.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ErrorConfiguracion(f"fixture de detecciones invalido: {exc}") from exc
        self.predeterminado = datos.get("default", [])
        self.frames = datos.get("frames", {})
        if not isinstance(self.predeterminado, list) or not isinstance(self.frames, dict):
            raise ErrorConfiguracion("fixture: 'default' debe ser lista y 'frames' un objeto")
        self.ruta = ruta

    @staticmethod
    def _normalizar(cara: dict[str, Any]) -> dict[str, Any]:
        try:
            bbox = [float(x) for x in cara["bbox"]]
            landmarks = [[float(x), float(y)] for x, y in cara["landmarks"]]
            confianza = float(cara["confianza"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ErrorConfiguracion(f"deteccion simulada invalida: {cara!r}") from exc
        if len(bbox) != 4 or len(landmarks) != 5:
            raise ErrorConfiguracion("cada deteccion simulada requiere bbox[4] y landmarks[5]")
        return {
            "bbox": bbox,
            "ojos": landmarks[0:2],
            "nariz": landmarks[2],
            "boca": landmarks[3:5],
            "confianza": confianza,
        }

    def detectar(self, frame: Any, indice: int) -> list[dict[str, Any]]:
        del frame
        caras = self.frames.get(str(indice), self.predeterminado)
        if not isinstance(caras, list):
            raise ErrorConfiguracion(f"fixture: frames.{indice} debe ser una lista")
        return [self._normalizar(cara) for cara in caras]


def recortar_cara(cv2: Any, gris: Any, bbox: list[float], tamano: int = 96) -> Any | None:
    alto, ancho = gris.shape[:2]
    x, y, w, h = bbox
    x0 = max(0, int(math.floor(x)))
    y0 = max(0, int(math.floor(y)))
    x1 = min(ancho, int(math.ceil(x + w)))
    y1 = min(alto, int(math.ceil(y + h)))
    if x1 - x0 < 8 or y1 - y0 < 8:
        return None
    return cv2.resize(gris[y0:y1, x0:x1], (tamano, tamano), interpolation=cv2.INTER_AREA)


def nitidez_normalizada(cv2: Any, gris: Any, bbox: list[float]) -> float:
    recorte = recortar_cara(cv2, gris, bbox, 256)
    if recorte is None:
        return 0.0
    return float(cv2.Laplacian(recorte, cv2.CV_64F, ksize=3).var())


def angulo_linea(a: list[float], b: list[float]) -> float:
    angulo = abs(math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])))
    return min(angulo, abs(180.0 - angulo))


def medir_pose(cara: dict[str, Any]) -> dict[str, float]:
    ojo_a, ojo_b = cara["ojos"]
    boca_a, boca_b = cara["boca"]
    nariz = cara["nariz"]
    ojo_medio = [(ojo_a[0] + ojo_b[0]) / 2, (ojo_a[1] + ojo_b[1]) / 2]
    boca_media = [(boca_a[0] + boca_b[0]) / 2, (boca_a[1] + boca_b[1]) / 2]
    d_a = math.hypot(nariz[0] - ojo_a[0], nariz[1] - ojo_a[1])
    d_b = math.hypot(nariz[0] - ojo_b[0], nariz[1] - ojo_b[1])
    asimetria = abs(d_a - d_b) / max(1e-6, d_a + d_b)
    tramo_vertical = boca_media[1] - ojo_medio[1]
    razon_nariz = (nariz[1] - ojo_medio[1]) / max(1e-6, tramo_vertical)
    ojos_grados = angulo_linea(ojo_a, ojo_b)
    boca_grados = angulo_linea(boca_a, boca_b)

    penalizacion = (
        0.34 * limitar(ojos_grados / 14.0)
        + 0.14 * limitar(boca_grados / 18.0)
        + 0.36 * limitar(asimetria / 0.30)
        + 0.16 * limitar(abs(razon_nariz - 0.55) / 0.30)
    )
    return {
        "ojos_desnivel_grados": ojos_grados,
        "boca_desnivel_grados": boca_grados,
        "yaw_asimetria_proxy": asimetria,
        "nariz_razon_vertical": razon_nariz,
        "frontal_score": limitar(1.0 - penalizacion),
    }


def mayor_tramo_verdadero(valores: Any) -> int:
    mejor = actual = 0
    for valor in valores.tolist():
        actual = actual + 1 if bool(valor) else 0
        mejor = max(mejor, actual)
    return mejor


def medir_boca(gris: Any, cara: dict[str, Any]) -> dict[str, Any]:
    """Aproxima apertura por la cavidad oscura bajo la linea de las comisuras.

    YuNet solo entrega las dos comisuras, no el contorno labial. Por eso esta
    magnitud se informa expresamente como proxy, no como una medicion anatomica.
    La ROI ignora casi todo lo que queda sobre las comisuras para no confundir
    barba o bigote con una boca abierta.
    """
    import numpy as np

    alto, ancho = gris.shape[:2]
    boca_a, boca_b = cara["boca"]
    _x, _y, _w, h_cara = cara["bbox"]
    izquierda, derecha = sorted((boca_a, boca_b), key=lambda punto: punto[0])
    x_izq, x_der = izquierda[0], derecha[0]
    distancia = max(4.0, x_der - x_izq)

    x0 = max(0, int(round(x_izq - 0.08 * distancia)))
    x1 = min(ancho, int(round(x_der + 0.08 * distancia)))
    y0 = max(0, int(round(min(izquierda[1], derecha[1]) - 0.020 * h_cara)))
    y1 = min(alto, int(round(max(izquierda[1], derecha[1]) + 0.045 * h_cara)))
    roi = gris[y0:y1, x0:x1]
    if roi.size < 32 or roi.shape[0] < 4 or roi.shape[1] < 4:
        return {
            "roi": [x0, y0, max(0, x1 - x0), max(0, y1 - y0)],
            "apertura_proxy": 1.0,
            "labios_cerrados_score": 0.0,
            "oscuridad_fraccion": 1.0,
            "tramo_oscuro_vertical": 1.0,
        }

    # Referencia de piel tomada en la mitad inferior de la cara y fuera de la
    # ROI bucal. Si no hay suficientes pixeles, se usa la mediana de la ROI.
    bx, by, bw, bh = cara["bbox"]
    rx0 = max(0, int(round(bx + 0.25 * bw)))
    rx1 = min(ancho, int(round(bx + 0.75 * bw)))
    ry0 = max(0, int(round(by + 0.52 * bh)))
    ry1 = min(alto, int(round(by + 0.92 * bh)))
    referencia = gris[ry0:ry1, rx0:rx1]
    if referencia.size:
        mascara = np.ones(referencia.shape, dtype=bool)
        ix0, ix1 = max(0, x0 - rx0), min(referencia.shape[1], x1 - rx0)
        iy0, iy1 = max(0, y0 - ry0), min(referencia.shape[0], y1 - ry0)
        if ix1 > ix0 and iy1 > iy0:
            mascara[iy0:iy1, ix0:ix1] = False
        piel = referencia[mascara]
    else:
        piel = referencia.reshape(-1)
    mediana_piel = float(np.median(piel)) if piel.size else float(np.median(roi))
    # La cavidad bucal es mucho mas oscura que los labios y que la barba. Un
    # umbral cercano al tono de piel confundiria bigote/barba con apertura.
    umbral_oscuro = max(10.0, min(38.0, mediana_piel * 0.22))

    # Enderezar virtualmente la linea entre comisuras evita que una leve
    # inclinacion convierta un labio cerrado en una mancha vertical ancha. Se
    # inspecciona desde apenas encima de la linea hasta 4.5% de la altura facial
    # por debajo: suficiente para una cavidad abierta, antes de llegar a la barba.
    cantidad_x = max(8, int(round(distancia * 0.68)))
    xs = np.linspace(x_izq + 0.16 * distancia, x_der - 0.16 * distancia, cantidad_x)
    proporcion = (xs - x_izq) / distancia
    bases_y = izquierda[1] + proporcion * (derecha[1] - izquierda[1])
    offsets = np.arange(
        int(math.floor(-0.015 * h_cara)),
        int(math.ceil(0.045 * h_cara)) + 1,
    )
    matriz_x = np.clip(np.rint(xs).astype(int), 0, ancho - 1)[None, :]
    matriz_y = np.clip(np.rint(bases_y[None, :] + offsets[:, None]).astype(int), 0, alto - 1)
    interior = gris[matriz_y, np.broadcast_to(matriz_x, matriz_y.shape)]
    oscuros = interior < umbral_oscuro
    fraccion = float(oscuros.mean()) if oscuros.size else 1.0
    filas_fuertes = oscuros.mean(axis=1) >= 0.35 if oscuros.size else np.ones(1, bool)
    tramo = mayor_tramo_verdadero(filas_fuertes) / max(1, interior.shape[0])

    apertura = limitar(
        0.72 * limitar((tramo - 0.07) / 0.36)
        + 0.28 * limitar((fraccion - 0.015) / 0.20)
    )
    return {
        "roi": [x0, y0, x1 - x0, y1 - y0],
        "apertura_proxy": apertura,
        "labios_cerrados_score": 1.0 - apertura,
        "oscuridad_fraccion": fraccion,
        "tramo_oscuro_vertical": tramo,
        "mediana_piel": mediana_piel,
        "umbral_oscuro": umbral_oscuro,
    }


def bbox_extrema(bbox: list[float], ancho: int, alto: int) -> tuple[bool, float]:
    x, y, w, h = bbox
    area = max(0.0, w) * max(0.0, h) / max(1.0, ancho * alto)
    margen_x = 0.01 * ancho
    margen_y = 0.01 * alto
    cortada = x < margen_x or y < margen_y or x + w > ancho - margen_x or y + h > alto - margen_y
    tamano_extremo = area < 0.025 or area > 0.80
    return cortada or tamano_extremo, area


def velocidad_entre(a: dict[str, Any], b: dict[str, Any]) -> float | None:
    import numpy as np

    if a["recorte"] is None or b["recorte"] is None:
        return None
    ax, ay, aw, ah = a["cara"]["bbox"]
    bx, by, bw, bh = b["cara"]["bbox"]
    centro = math.hypot((ax + aw / 2) - (bx + bw / 2), (ay + ah / 2) - (by + bh / 2))
    diagonal = (math.hypot(aw, ah) + math.hypot(bw, bh)) / 2
    traslado = centro / max(1e-6, diagonal)

    ra = a["recorte"].astype("float32")
    rb = b["recorte"].astype("float32")
    # Quitar el cambio de luminancia global evita llamar movimiento a un leve
    # pulso de exposicion del generador.
    ra -= float(np.median(ra))
    rb -= float(np.median(rb))
    cambio_local = float(np.mean(np.abs(ra - rb)) / 255.0)
    return traslado + 0.55 * cambio_local


def score_nitidez(valor: float) -> float:
    inferior, superior = math.log1p(35.0), math.log1p(700.0)
    return limitar((math.log1p(max(0.0, valor)) - inferior) / (superior - inferior))


def timestamp_humano(segundos: float) -> str:
    milisegundos = max(0, int(round(segundos * 1000)))
    horas, resto = divmod(milisegundos, 3_600_000)
    minutos, resto = divmod(resto, 60_000)
    seg, ms = divmod(resto, 1000)
    return f"{horas:02d}:{minutos:02d}:{seg:02d}.{ms:03d}"


def resumen_candidato(registro: dict[str, Any]) -> dict[str, Any]:
    cara = registro["cara"]
    pose = registro["pose"]
    boca = registro["boca"]
    return {
        "frame_index": registro["indice"],
        "timestamp_s": redondear(registro["timestamp_s"]),
        "timestamp": timestamp_humano(registro["timestamp_s"]),
        "sha256_frame_bgr": registro["sha256_frame_bgr"],
        "score": redondear(registro["score"]),
        "confianza": redondear(cara["confianza"]),
        "bbox": [redondear(v, 3) for v in cara["bbox"]],
        "landmarks": {
            "ojos": [[redondear(v, 3) for v in punto] for punto in cara["ojos"]],
            "nariz": [redondear(v, 3) for v in cara["nariz"]],
            "boca": [[redondear(v, 3) for v in punto] for punto in cara["boca"]],
        },
        "metricas": {
            "labios_cerrados_score": redondear(boca["labios_cerrados_score"]),
            "apertura_boca_proxy": redondear(boca["apertura_proxy"]),
            "oscuridad_boca_fraccion": redondear(boca["oscuridad_fraccion"]),
            "frontal_score": redondear(pose["frontal_score"]),
            "ojos_desnivel_grados": redondear(pose["ojos_desnivel_grados"]),
            "boca_desnivel_grados": redondear(pose["boca_desnivel_grados"]),
            "yaw_asimetria_proxy": redondear(pose["yaw_asimetria_proxy"]),
            "nariz_razon_vertical": redondear(pose["nariz_razon_vertical"]),
            "nitidez_laplaciana": redondear(registro["nitidez"]),
            "velocidad_local_proxy": redondear(registro["velocidad"]),
            "area_rostro_fraccion": redondear(registro["area"]),
        },
    }


def analizar_video(
    cv2: Any,
    video: Path,
    detector: Any,
    confianza_min: float,
    persistencia_min: float,
    margen_temporal: float,
    nitidez_min: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    captura = cv2.VideoCapture(str(video))
    if not captura.isOpened():
        raise ErrorConfiguracion(f"no se pudo abrir el video: {video}")
    fps = float(captura.get(cv2.CAP_PROP_FPS))
    if not math.isfinite(fps) or fps <= 0:
        captura.release()
        raise ErrorConfiguracion("el video no informa un FPS valido")

    registros: list[dict[str, Any]] = []
    conteo_crudo = conteo_descartadas_confianza = 0
    ancho = alto = 0
    try:
        indice = 0
        while True:
            ok, frame = captura.read()
            if not ok:
                break
            alto, ancho = frame.shape[:2]
            gris = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            caras_crudas = detector.detectar(frame, indice)
            conteo_crudo += len(caras_crudas)
            caras = [c for c in caras_crudas if c["confianza"] >= confianza_min]
            conteo_descartadas_confianza += len(caras_crudas) - len(caras)
            registro: dict[str, Any] = {
                "indice": indice,
                "timestamp_s": indice / fps,
                "cantidad_caras": len(caras),
                "sha256_frame_bgr": sha256_frame(frame),
            }
            if len(caras) == 1:
                cara = caras[0]
                registro.update(
                    cara=cara,
                    recorte=recortar_cara(cv2, gris, cara["bbox"]),
                    nitidez=nitidez_normalizada(cv2, gris, cara["bbox"]),
                    pose=medir_pose(cara),
                    boca=medir_boca(gris, cara),
                )
            registros.append(registro)
            indice += 1
    finally:
        captura.release()

    total = len(registros)
    if total == 0:
        raise ErrorConfiguracion("el video no contiene fotogramas decodificables")

    unicas = sum(r["cantidad_caras"] == 1 for r in registros)
    multiples = sum(r["cantidad_caras"] > 1 for r in registros)
    ausentes = total - unicas - multiples
    persistencia = unicas / total
    fraccion_multiple = multiples / total

    transiciones = saltos = 0
    anterior: dict[str, Any] | None = None
    for registro in registros:
        if registro["cantidad_caras"] != 1:
            anterior = None
            continue
        if anterior is not None and registro["indice"] == anterior["indice"] + 1:
            transiciones += 1
            ax, ay, aw, ah = anterior["cara"]["bbox"]
            bx, by, bw, bh = registro["cara"]["bbox"]
            distancia = math.hypot((ax + aw / 2) - (bx + bw / 2), (ay + ah / 2) - (by + bh / 2))
            escala = (math.hypot(aw, ah) + math.hypot(bw, bh)) / 2
            if distancia / max(1e-6, escala) > 0.35:
                saltos += 1
        anterior = registro
    continuidad = 1.0 - saltos / transiciones if transiciones else 0.0
    minimo_frames = max(8, int(math.ceil(fps * 0.5)))
    gate_aprobado = (
        total >= minimo_frames
        and persistencia >= persistencia_min
        and fraccion_multiple <= 0.05
        and continuidad >= 0.90
    )

    # La velocidad de un candidato usa sus dos vecindades cuando existen. No
    # se asigna cero a una medida ausente: ese frame se descarta.
    velocidades_arista: dict[tuple[int, int], float] = {}
    for previo, actual in zip(registros, registros[1:]):
        if previo["cantidad_caras"] == actual["cantidad_caras"] == 1:
            velocidad = velocidad_entre(previo, actual)
            if velocidad is not None:
                velocidades_arista[(previo["indice"], actual["indice"])] = velocidad

    rechazos: dict[str, int] = {}
    candidatos: list[dict[str, Any]] = []

    def rechazar(motivo: str) -> None:
        rechazos[motivo] = rechazos.get(motivo, 0) + 1

    for pos, registro in enumerate(registros):
        fraccion_tiempo = pos / max(1, total - 1)
        if fraccion_tiempo < margen_temporal or fraccion_tiempo > 1.0 - margen_temporal:
            rechazar("extremo_temporal")
            continue
        if registro["cantidad_caras"] == 0:
            rechazar("sin_rostro_confiable")
            continue
        if registro["cantidad_caras"] > 1:
            rechazar("varios_rostros")
            continue

        extremo, area = bbox_extrema(registro["cara"]["bbox"], ancho, alto)
        registro["area"] = area
        if extremo:
            rechazar("rostro_recortado_o_tamano_extremo")
            continue
        if registro["nitidez"] < nitidez_min:
            rechazar("blur")
            continue
        pose = registro["pose"]
        if pose["ojos_desnivel_grados"] > 14.0:
            rechazar("pose_ojos_extrema")
            continue
        if pose["boca_desnivel_grados"] > 18.0:
            rechazar("pose_boca_extrema")
            continue
        if pose["yaw_asimetria_proxy"] > 0.30:
            rechazar("pose_yaw_extrema")
            continue
        if not 0.25 <= pose["nariz_razon_vertical"] <= 0.85:
            rechazar("pose_pitch_extrema")
            continue

        vecinas = []
        if (registro["indice"] - 1, registro["indice"]) in velocidades_arista:
            vecinas.append(velocidades_arista[(registro["indice"] - 1, registro["indice"])])
        if (registro["indice"], registro["indice"] + 1) in velocidades_arista:
            vecinas.append(velocidades_arista[(registro["indice"], registro["indice"] + 1)])
        if not vecinas:
            rechazar("velocidad_no_disponible")
            continue
        vecinas.sort()
        velocidad = vecinas[len(vecinas) // 2] if len(vecinas) == 1 else sum(vecinas) / len(vecinas)
        registro["velocidad"] = velocidad
        if velocidad > 0.18:
            rechazar("movimiento_extremo")
            continue

        boca_score = registro["boca"]["labios_cerrados_score"]
        velocidad_score = math.exp(-velocidad / 0.030)
        confianza_score = limitar((registro["cara"]["confianza"] - confianza_min) / (1 - confianza_min))
        registro["score"] = (
            0.36 * boca_score
            + 0.22 * pose["frontal_score"]
            + 0.18 * score_nitidez(registro["nitidez"])
            + 0.18 * velocidad_score
            + 0.06 * confianza_score
        )
        candidatos.append(registro)

    candidatos.sort(
        key=lambda r: (
            -r["score"],
            r["boca"]["apertura_proxy"],
            r["velocidad"],
            -r["nitidez"],
            abs(r["indice"] / max(1, total - 1) - 0.5),
            r["indice"],
        )
    )

    informe = {
        "video": {
            "ancho": ancho,
            "alto": alto,
            "fps": redondear(fps),
            "frames": total,
            "duracion_s": redondear(total / fps),
        },
        "muestreo": {
            "estrategia": "todos_los_frames",
            "frames_analizados": total,
            "margen_temporal_fraccion": margen_temporal,
        },
        "gate_rostro_persistente": {
            "aprobado": gate_aprobado,
            "frames_con_un_rostro": unicas,
            "frames_sin_rostro": ausentes,
            "frames_con_varios_rostros": multiples,
            "persistencia_unica": redondear(persistencia),
            "persistencia_minima": persistencia_min,
            "fraccion_varios_rostros": redondear(fraccion_multiple),
            "fraccion_varios_maxima": 0.05,
            "continuidad_espacial": redondear(continuidad),
            "continuidad_minima": 0.90,
            "saltos_espaciales": saltos,
            "transiciones_observadas": transiciones,
            "frames_minimos": minimo_frames,
            "detecciones_crudas": conteo_crudo,
            "detecciones_descartadas_confianza": conteo_descartadas_confianza,
        },
        "filtros_candidatos": {
            "confianza_minima": confianza_min,
            "nitidez_laplaciana_minima": nitidez_min,
            "movimiento_extremo_maximo": 0.18,
            "rechazos": dict(sorted(rechazos.items())),
            "aceptados": len(candidatos),
        },
    }
    return informe, candidatos


def extraer_frame(cv2: Any, video: Path, indice_objetivo: int) -> Any:
    """Decodifica desde el inicio para evitar seeks aproximados entre keyframes."""
    captura = cv2.VideoCapture(str(video))
    if not captura.isOpened():
        raise ErrorConfiguracion(f"no se pudo reabrir el video: {video}")
    frame = None
    try:
        for indice in range(indice_objetivo + 1):
            ok, frame = captura.read()
            if not ok:
                raise ErrorConfiguracion(
                    f"no se pudo reextraer el frame seleccionado {indice_objetivo}; fallo en {indice}"
                )
    finally:
        captura.release()
    return frame


def escribir_json_atomico(ruta: Path, datos: dict[str, Any]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporal_nombre = tempfile.mkstemp(prefix=f".{ruta.name}.", suffix=".tmp", dir=ruta.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as fichero:
            json.dump(datos, fichero, ensure_ascii=False, indent=2, sort_keys=True)
            fichero.write("\n")
            fichero.flush()
            os.fsync(fichero.fileno())
        os.replace(temporal_nombre, ruta)
    except BaseException:
        try:
            os.unlink(temporal_nombre)
        except FileNotFoundError:
            pass
        raise


def escribir_png_atomico(cv2: Any, ruta: Path, frame: Any) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporal_nombre = tempfile.mkstemp(prefix=f".{ruta.stem}.", suffix=".png", dir=ruta.parent)
    os.close(descriptor)
    temporal = Path(temporal_nombre)
    try:
        if not cv2.imwrite(str(temporal), frame, [cv2.IMWRITE_PNG_COMPRESSION, 6]):
            raise ErrorConfiguracion(f"OpenCV no pudo escribir el PNG: {ruta}")
        os.replace(temporal, ruta)
    finally:
        try:
            temporal.unlink()
        except FileNotFoundError:
            pass


def parser_cli() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", help="toma de video que se analizara completa")
    parser.add_argument("--salida", required=True, help="PNG limpio que se publicara")
    parser.add_argument("--json", dest="salida_json", help="sidecar JSON (default: SALIDA.png.json)")
    parser.add_argument("--modelo", help="ruta explicita al ONNX YuNet")
    parser.add_argument("--confianza-min", type=float, default=0.85)
    parser.add_argument("--persistencia-min", type=float, default=0.90)
    parser.add_argument("--margen-temporal", type=float, default=0.08)
    parser.add_argument("--nitidez-min", type=float, default=35.0)
    parser.add_argument(
        "--detecciones-simuladas",
        help=argparse.SUPPRESS,
    )
    return parser


def ejecutar(argv: list[str] | None = None) -> int:
    args = parser_cli().parse_args(argv)
    video = Path(args.video).expanduser().resolve()
    salida = Path(args.salida).expanduser().resolve()
    salida_json = (
        Path(args.salida_json).expanduser().resolve()
        if args.salida_json
        else Path(str(salida) + ".json")
    )
    if salida.suffix.lower() != ".png":
        raise ErrorConfiguracion("--salida debe terminar en .png")
    if not video.is_file():
        raise ErrorConfiguracion(f"video ausente: {video}")
    if salida == video or salida_json == video or salida_json == salida:
        raise ErrorConfiguracion("video, PNG y sidecar JSON deben ser rutas distintas")
    validar_numero("--confianza-min", args.confianza_min, 0.50, 0.999)
    validar_numero("--persistencia-min", args.persistencia_min, 0.50, 1.0)
    validar_numero("--margen-temporal", args.margen_temporal, 0.01, 0.25)
    validar_numero("--nitidez-min", args.nitidez_min, 0.0, 100000.0)

    cv2 = importar_cv2()
    raiz = Path(__file__).resolve().parents[1]
    if args.detecciones_simuladas:
        if os.environ.get("SELECCIONAR_ANCLA_PERMITIR_SIMULACION") != "1":
            raise ErrorConfiguracion(
                "el backend simulado solo se permite con "
                "SELECCIONAR_ANCLA_PERMITIR_SIMULACION=1"
            )
        fixture = Path(args.detecciones_simuladas).expanduser().resolve()
        if not fixture.is_file():
            raise ErrorConfiguracion(f"fixture de detecciones ausente: {fixture}")
        detector = DetectorSimulado(fixture)
        modelo = fixture
        backend = "simulado_explicito"
    else:
        modelo = resolver_modelo(args.modelo, raiz)
        try:
            detector = DetectorYuNet(cv2, modelo, args.confianza_min)
        except Exception as exc:
            raise ErrorConfiguracion(f"no se pudo inicializar YuNet con {modelo}: {exc}") from exc
        backend = "opencv_yunet"
    if modelo == salida or modelo == salida_json:
        raise ErrorConfiguracion("las salidas no pueden sobrescribir el modelo o fixture")

    informe_medidas, candidatos = analizar_video(
        cv2,
        video,
        detector,
        args.confianza_min,
        args.persistencia_min,
        args.margen_temporal,
        args.nitidez_min,
    )
    informe: dict[str, Any] = {
        "schema": SCHEMA,
        "estado": "analizado",
        "video": {
            "ruta": str(video),
            "sha256": sha256_fichero(video),
            **informe_medidas["video"],
        },
        "modelo": {
            "backend": backend,
            "ruta": str(modelo),
            "sha256": sha256_fichero(modelo),
        },
        "muestreo": informe_medidas["muestreo"],
        "gate_rostro_persistente": informe_medidas["gate_rostro_persistente"],
        "filtros_candidatos": informe_medidas["filtros_candidatos"],
        "top_candidatos": [resumen_candidato(r) for r in candidatos[:12]],
        "seleccion": None,
    }

    if not informe["gate_rostro_persistente"]["aprobado"]:
        informe["estado"] = "rechazado_gate_rostro"
        escribir_json_atomico(salida_json, informe)
        print(
            "ERROR: la toma no contiene exactamente un rostro persistente; "
            f"diagnostico: {salida_json}",
            file=sys.stderr,
        )
        return CODIGO_RECHAZADO
    if not candidatos:
        informe["estado"] = "rechazado_sin_candidatos_neutrales"
        escribir_json_atomico(salida_json, informe)
        print(
            "ERROR: ningun frame supero nitidez, pose, extremos y movimiento; "
            f"diagnostico: {salida_json}",
            file=sys.stderr,
        )
        return CODIGO_RECHAZADO

    ganador = candidatos[0]
    frame = extraer_frame(cv2, video, ganador["indice"])
    if sha256_frame(frame) != ganador["sha256_frame_bgr"]:
        raise ErrorConfiguracion("la reextraccion no coincide con el frame medido; no se publica")
    escribir_png_atomico(cv2, salida, frame)
    seleccion = resumen_candidato(ganador)
    seleccion["sha256_png"] = sha256_fichero(salida)
    seleccion["salida_png"] = str(salida)
    informe["seleccion"] = seleccion
    informe["estado"] = "seleccionado"
    escribir_json_atomico(salida_json, informe)
    print(
        f"OK ancla={salida} frame={ganador['indice']} "
        f"t={ganador['timestamp_s']:.3f}s score={ganador['score']:.4f} json={salida_json}"
    )
    return 0


def main() -> None:
    try:
        raise SystemExit(ejecutar())
    except ErrorConfiguracion as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(CODIGO_CONFIG)


if __name__ == "__main__":
    main()
