#!/usr/bin/env bash
set -euo pipefail
python3 -V
pip3 --version

ROOT="$PWD/.work"
PREFIX="$ROOT/prefix"
mkdir -p "$ROOT" "$PREFIX" dist "$ROOT/src"

python3 -m pip install -U pip wheel setuptools build packaging Cython numpy
python3 -m pip download --no-binary=:all: --no-deps shapely==2.1.2 -d "$ROOT/src"
python3 -m pip download --no-binary=:all: --no-deps numpy==2.4.4 -d "$ROOT/src"

cd "$ROOT"
if [ ! -d geos-src ]; then
  git clone --depth=1 --branch 3.12.2 https://github.com/libgeos/geos.git geos-src
fi

export ANDROID_NDK="${ANDROID_NDK:?}"
TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64"
export TARGET=aarch64-linux-android
export API="${ANDROID_API:-24}"
export CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export CFLAGS="-fPIC"
export CXXFLAGS="-fPIC"
export LDFLAGS=""

cd geos-src
cmake -S . -B build-android -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="${ANDROID_ABI:-arm64-v8a}" \
  -DANDROID_PLATFORM="android-${API}" \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_RPATH='\$ORIGIN' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DBUILD_TESTING=OFF
cmake --build build-android --parallel
cmake --install build-android

mkdir -p "$PREFIX/lib/shapely.libs"
cp -f "$PREFIX/lib/libgeos.so" "$PREFIX/lib/shapely.libs/libgeos.so"
cp -f "$PREFIX/lib/libgeos_c.so" "$PREFIX/lib/shapely.libs/libgeos_c.so"

export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,\$ORIGIN/.libs -Wl,-rpath,\$ORIGIN/shapely.libs -Wl,-rpath,\$ORIGIN"

cd "$ROOT"
rm -rf shapely-src
mkdir -p shapely-src
SHAPELY_TGZ=$(find "$ROOT/src" -maxdepth 1 -type f -name 'shapely-2.1.2*.tar.gz' | head -n1)
if [ -z "$SHAPELY_TGZ" ]; then
  echo 'Shapely source tar.gz not found' >&2
  exit 1
fi
tar -xzf "$SHAPELY_TGZ" -C shapely-src
cd shapely-src/shapely-2.1.2

test -f setup.py
test -f setup.cfg
test -f versioneer.py
grep -q '^\[versioneer\]' setup.cfg

python3 - <<PY
from pathlib import Path
cfg = Path('setup.cfg')
text = cfg.read_text()
if '[build_ext]' not in text:
    text += '\n[build_ext]\n'
for line in [
    'include_dirs=$PREFIX/include',
    'library_dirs=$PREFIX/lib',
    'rpath=$ORIGIN/.libs:$ORIGIN/shapely.libs:$ORIGIN',
]:
    if line not in text:
        text += line + '\n'
cfg.write_text(text)
PY

export GEOS_CONFIG="$PREFIX/bin/geos-config"
export GEOS_INCLUDE_PATH="$PREFIX/include"
export GEOS_LIBRARY_PATH="$PREFIX/lib/libgeos_c.so"
export SHAPELY_GEOS_LIBRARY_PATH="$PREFIX/lib/libgeos_c.so"
export SHAPELY_GEOS_INCLUDE_PATH="$PREFIX/include"

mkdir -p "$PWD/dist-host" "$PWD/wheel-fix"
python3 setup.py bdist_wheel --plat-name android_24_arm64_v8a -d "$PWD/dist-host"
ls -lah "$PWD/dist-host"
WHL=$(find "$PWD/dist-host" -maxdepth 1 -type f -name '*android_24_arm64_v8a.whl' -print -quit)
test -n "$WHL"
python3 - <<PY
import pathlib, shutil, zipfile
root = pathlib.Path("$PWD/wheel-fix")
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
whl = pathlib.Path("$WHL")
with zipfile.ZipFile(whl) as z:
    z.extractall(root)
for p in (root / 'shapely').glob('*.so'):
    if 'x86_64-linux-gnu' in p.name:
        p.rename(p.with_name(p.name.replace('x86_64-linux-gnu', 'aarch64-linux-android')))
libs_dir = root / 'shapely.libs'
libs_dir.mkdir(parents=True, exist_ok=True)
for lib in [pathlib.Path("$PREFIX/lib/libgeos.so"), pathlib.Path("$PREFIX/lib/libgeos_c.so")]:
    if lib.exists():
        shutil.copy2(lib, libs_dir / lib.name)
out = pathlib.Path("$GITHUB_WORKSPACE/dist") / whl.name
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for p in root.rglob('*'):
        if p.is_file():
            z.write(p, p.relative_to(root))
print(out)
PY
ls -lah "$GITHUB_WORKSPACE/dist"
test -n "$(find "$GITHUB_WORKSPACE/dist" -maxdepth 1 -type f -name '*android_24_arm64_v8a.whl' -print -quit)"
