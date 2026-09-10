"""Contrato del módulo sin invocar servicios externos."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from harness.imagenes import generar, preparar


class ImagenesTest(unittest.TestCase):
    def test_validacion(self):
        for titular in (" ", "a" * 401, None):
            with self.assertRaises(ValueError):
                preparar(titular)
        with self.assertRaises(ValueError):
            preparar("Noticia", formato="otro")

    def test_cli_solo_prompt_sin_motor(self):
        ruta = Path(__file__).resolve().parents[1] / "harness/imagenes.py"
        with tempfile.TemporaryDirectory() as tmp:
            noticia = Path(tmp) / "noticia.txt"
            noticia.write_text("TITULAR: Biblioteca nueva\nFUENTE: Diario local\nSala infantil.")
            resultado = subprocess.run([sys.executable, str(ruta), "--fichero", str(noticia),
                                        "--codex", "no-existe", "--solo-prompt"],
                                       cwd=tmp, capture_output=True, text=True)
            self.assertEqual(resultado.returncode, 0, resultado.stderr)
            datos = json.loads(resultado.stdout)
            self.assertEqual(datos["noticia"]["fuente"], "Diario local")
            self.assertEqual(datos["estado"], "preparado")
            self.assertEqual(len(list(Path(tmp).iterdir())), 1)

    @unittest.skipUnless(shutil.which("ffmpeg"), "requiere ffmpeg")
    def test_generacion_y_fallos(self):
        with tempfile.TemporaryDirectory() as tmp:
            destino = Path(tmp)

            def motor(comando, prompt, carpeta, timeout):
                trabajo = Path(comando[comando.index("--cd") + 1])
                self.assertIn("image_gen", prompt)
                self.assertIn("workspace-write", comando)
                (trabajo / "respuesta.json").write_text('{"estado":"ok","error":""}')
                subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi",
                                "-i", "color=s=32x48", "-frames:v", "1", "-threads", "1",
                                str(trabajo / "imagen.png")], check=True)

            solicitud = preparar("Biblioteca", "Sala infantil")
            with patch("harness.imagenes._ejecutar", side_effect=motor):
                resultado = generar(solicitud, "prueba", destino, codex=sys.executable)
                self.assertEqual(resultado["estado"], "review_pending")
                self.assertEqual((resultado["ancho"], resultado["alto"]), (32, 48))
                self.assertEqual(len(resultado["sha256"]), 64)
                with self.assertRaises(FileExistsError):
                    generar(solicitud, "prueba", destino, codex=sys.executable)
                with self.assertRaises(ValueError):
                    generar(solicitud, "../escape", destino, codex=sys.executable)
                with self.assertRaises(ValueError):
                    generar(solicitud, "nan", destino, codex=sys.executable, timeout=float("nan"))

            def invalido(comando, *args):
                trabajo = Path(comando[comando.index("--cd") + 1])
                (trabajo / "respuesta.json").write_text('{"estado":"ok","error":""}')
                (trabajo / "imagen.png").write_text("esto no es una imagen")

            for nombre, efecto in (("fallo", RuntimeError("sin image_gen")),
                                    ("invalida", invalido)):
                with patch("harness.imagenes._ejecutar", side_effect=efecto):
                    with self.assertRaises(RuntimeError):
                        generar(solicitud, nombre, destino, codex=sys.executable)
                estado = json.loads((destino / nombre / "manifiesto.json").read_text())
                self.assertEqual(estado["estado"], "error")
                self.assertFalse((destino / nombre / "imagen.png").exists())


if __name__ == "__main__":
    unittest.main()
