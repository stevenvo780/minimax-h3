#!/bin/bash
set -euo pipefail
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$RAIZ"
python3 -m unittest discover -s pruebas -p 'test_imagenes.py'
python3 -m unittest discover -s pruebas -p 'test_carruseles.py'
