#!/bin/sh
# Empaqueta Creador de Películas 3D Runtime desde Linux / Steam Deck (equivalente a build.ps1).
#
# Uso:  runtime/build.sh [--native] [--skip-tests] [--version X.Y.Z]
#
#   --native      recompila los componentes nativos con native/build.sh (Zig); si no, usa native/bin
#   --skip-tests  no ejecuta las pruebas de Python
#   --version     versión del paquete (por defecto, la del archivo VERSION)
#
# Genera dist/CreadorPeliculasRuntime-<versión>.zip, el mismo paquete que build.ps1
# (rutas con / y permisos de Unix: creador.sh queda ejecutable al descomprimir en Linux).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
version=$(tr -d '[:space:]' < "$here/VERSION")
native=0
tests=1
while [ $# -gt 0 ]; do
  case "$1" in
    --native) native=1 ;;
    --skip-tests) tests=0 ;;
    --version) version=$2; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

if [ $native = 1 ]; then
  step 'Compilando componentes nativos (x86, Zig)'
  "$here/native/build.sh"
fi
for f in cplaunch.exe cphook.dll; do
  [ -f "$here/native/bin/$f" ] || { echo "Falta native/bin/$f. Ejecutá build.sh --native." >&2; exit 1; }
done

if [ $tests = 1 ]; then
  step 'Ejecutando pruebas (Python)'
  python3 -I -m unittest discover -s "$here/tests" -p 'test_*.py'
fi

step 'Armando el paquete'
python3 -I - "$here" "$version" <<'PY'
import os, sys, zipfile
here, version = sys.argv[1], sys.argv[2]
name = 'CreadorPeliculasRuntime-%s' % version
dist = os.path.join(here, 'dist')
os.makedirs(dist, exist_ok=True)
out = os.path.join(dist, name + '.zip')
# El documento de usuario es README.md en la raíz del repositorio; en el paquete va como LEEME.txt.
items = ['src', 'linux', 'native/bin', 'CreadorPeliculas.cmd', 'creador.sh', 'LEEME.txt', 'VERSION']
sources = {'LEEME.txt': os.path.join(os.path.dirname(here), 'README.md')}
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for item in items:
        src = sources.get(item, os.path.join(here, item))
        files = [src] if os.path.isfile(src) else [os.path.join(d, f) for d, ds, fs in os.walk(src) for f in fs if '__pycache__' not in d]
        for f in sorted(files):
            if f.endswith(('.pyc', '.lib', '.exp', '.pdb')):
                continue
            arc = name + '/' + (item if item in sources else os.path.relpath(f, here).replace(os.sep, '/'))
            info = zipfile.ZipInfo.from_file(f, arc)
            info.create_system = 3                                   # Unix: se respetan los permisos
            info.external_attr = (0o100755 if f.endswith('.sh') else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(f, 'rb') as fh:
                z.writestr(info, fh.read())
print('Listo: %s (%.1f MB)' % (out, os.path.getsize(out) / 1e6))
PY
