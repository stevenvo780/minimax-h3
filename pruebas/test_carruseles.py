import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from harness.carruseles import preparar_carrusel, empaquetar, RAIZ


class CarruselesTest(unittest.TestCase):
    def setUp(self):
        self.noticia = json.loads((RAIZ / "imagenes/ejemplos-ia.json").read_text())[0]

    def test_contenido_y_orden(self):
        plan = preparar_carrusel(self.noticia)
        self.assertEqual(len(plan["diapositivas"]), 3)
        self.assertEqual(plan["serie"], "Archivo 2024")
        self.assertIn(self.noticia["url"], plan["caption"])
        self.assertEqual([s["archivo"] for s in plan["diapositivas"]], ["01.jpg", "02.jpg", "03.jpg"])
        for n, slide in enumerate(plan["diapositivas"]):
            self.assertEqual(slide["textos"]["titulo"], self.noticia["diapositivas"][n]["titulo"])
        with self.assertRaises(ValueError):
            preparar_carrusel({**self.noticia, "diapositivas": []})
        with self.assertRaises(ValueError):
            preparar_carrusel({**self.noticia, "nombre": "../escape"})

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "requiere ffmpeg/ffprobe")
    def test_exportar_dimensiones_zip_y_no_sobrescribir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            original = tmp / "original.png"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                            "color=s=1122x1402", "-frames:v", "1", "-threads", "1", str(original)], check=True)
            plan = preparar_carrusel(self.noticia)
            salida = tmp / "entrega"
            estado = empaquetar(plan, [original] * 3, salida)
            self.assertEqual(estado["estado"], "review_pending")
            for i in range(1, 4):
                probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                                 "-show_entries", "stream=width,height", "-of", "csv=p=0",
                                                 str(salida / f"{i:02d}.jpg")], text=True)
                self.assertEqual(probe.strip(), "1080,1350")
            with zipfile.ZipFile(salida / "publicar.zip") as paquete:
                self.assertIn("caption.txt", paquete.namelist())
                self.assertIn("03.jpg", paquete.namelist())
            with self.assertRaises(FileExistsError):
                empaquetar(plan, [original] * 3, salida)
            with self.assertRaises(ValueError):
                empaquetar(plan, [original], tmp / "incompleto")
            self.assertFalse((tmp / "incompleto").exists())
