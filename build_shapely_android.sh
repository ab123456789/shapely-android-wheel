#!/usr/bin/env bash
set -euo pipefail
python3 -V
pip3 --version
python3 -m pip install -U pip wheel setuptools build packaging Cython numpy
python3 -m pip wheel --no-deps --wheel-dir dist Shapely==2.1.2
ls -lah dist
