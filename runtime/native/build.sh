#!/bin/sh
# Compila los componentes nativos (x86) de Creador de Películas 3D Runtime desde Linux / Steam Deck, sin Visual Studio.
# Usa el compilador cruzado de Zig (trae los encabezados de MinGW para Windows de 32 bits).
#
# Uso:  native/build.sh            (salida en runtime/native/bin)
#
# Si no hay «zig» en el PATH, se instala en un entorno de Python temporal (pip install ziglang).
# La compilación oficial para publicar sigue siendo build.cmd (MSVC), que usa build.ps1 en Windows.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/bin"
obj="$here/obj"
mkdir -p "$out" "$obj"

if command -v zig >/dev/null 2>&1; then
  ZIG="zig"
else
  venv="$obj/zig-venv"
  if [ ! -x "$venv/bin/python" ]; then
    echo "=== Instalando Zig (pip install ziglang) en $venv"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q ziglang
  fi
  ZIG="$venv/bin/python -m ziglang"
fi

CC="$ZIG cc -target x86-windows-gnu -O2 -s"

echo "=== cphook.dll"
$CC -shared -o "$out/cphook.dll" "$here/cphook/cphook.c" -lgdi32 -luser32 -lkernel32 -lshell32 -lwinmm
echo "=== cplaunch.exe"
$CC -Wl,--subsystem,windows -o "$out/cplaunch.exe" "$here/cplaunch/cplaunch.c" -luser32 -lkernel32

rm -f "$out"/*.lib "$out"/*.pdb "$out"/*.exp
echo "OK: binarios en $out"
