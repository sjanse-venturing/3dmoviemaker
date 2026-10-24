# iso.py — lector mínimo de imágenes ISO 9660 con extensión Joliet (port de src/Core/CpIso.cs).
# Permite validar los discos y copiar su contenido sin montarlos (montar requiere root en SteamOS).

import datetime
import os
import struct

from .errors import Cancelled

SECTOR = 2048


class IsoEntry:
    __slots__ = ('path', 'is_dir', 'lba', 'size', 'modified')

    def __init__(self, path, is_dir, lba, size, modified=None):
        self.path = path          # ruta con '\' relativa a la raíz, sin barra inicial (como en Windows)
        self.is_dir = is_dir
        self.lba = lba
        self.size = size
        self.modified = modified

    @property
    def name(self):
        return self.path.rsplit('\\', 1)[-1]


class Iso:
    def __init__(self, path):
        self.file_path = path
        self._f = open(path, 'rb')
        try:
            pvd = svd = None
            for i in range(16, 64):
                d = self._read(i, 1)
                if d[1:6] != b'CD001':
                    raise ValueError('No es una imagen ISO 9660 válida.')
                if d[0] == 1 and pvd is None:
                    pvd = d
                elif d[0] == 2 and d[88] == 0x25 and d[89] == 0x2F and d[90] in (0x40, 0x43, 0x45):
                    svd = d
                elif d[0] == 255:
                    break
            if pvd is None:
                raise ValueError('La imagen no tiene descriptor de volumen primario.')
            vd = svd or pvd
            self.joliet = svd is not None
            raw = vd[40:72]
            self.volume_label = (raw.decode('utf-16-be', 'replace') if self.joliet else raw.decode('ascii', 'replace')).rstrip(' \0')
            self._root_lba = struct.unpack_from('<I', vd, 156 + 2)[0]
            self._root_size = struct.unpack_from('<I', vd, 156 + 10)[0]
        except Exception:
            self._f.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def close(self):
        self._f.close()

    def _read(self, lba, count):
        self._f.seek(lba * SECTOR)
        buf = self._f.read(count * SECTOR)
        if len(buf) < count * SECTOR:
            raise EOFError('La imagen ISO está truncada.')
        return buf

    def _read_dir(self, lba, size, prefix):
        data = self._read(lba, (size + SECTOR - 1) // SECTOR)
        pos = 0
        while pos < size:
            ln = data[pos]
            if ln == 0:
                pos = (pos // SECTOR + 1) * SECTOR
                continue
            name_len = data[pos + 32]
            is_dir = bool(data[pos + 25] & 2)
            if name_len == 1 and data[pos + 33] in (0, 1):
                pos += ln
                continue
            raw = data[pos + 33:pos + 33 + name_len]
            name = raw.decode('utf-16-be', 'replace') if self.joliet else raw.decode('ascii', 'replace')
            name = name.split(';', 1)[0]
            if not is_dir and name.endswith('.'):
                name = name[:-1]
            try:
                y, mo, d, h, mi, s = data[pos + 18:pos + 24]
                mod = datetime.datetime(1900 + y, mo, d, h, mi, s)
            except ValueError:
                mod = None
            yield IsoEntry(name if not prefix else prefix + '\\' + name, is_dir,
                           struct.unpack_from('<I', data, pos + 2)[0], struct.unpack_from('<I', data, pos + 10)[0], mod)
            pos += ln

    def list(self, subdir=''):
        """Recorre todo el árbol (o el subárbol indicado)."""
        result = []
        if not subdir:
            stack = [IsoEntry('', True, self._root_lba, self._root_size)]
        else:
            d = self.find(subdir)
            if d is None or not d.is_dir:
                return result
            stack = [d]
        while stack:
            d = stack.pop()
            for e in self._read_dir(d.lba, d.size, d.path):
                result.append(e)
                if e.is_dir:
                    stack.append(e)
        return result

    def find(self, path):
        """Busca una ruta (sin distinguir mayúsculas). Devuelve None si no existe."""
        parts = path.replace('/', '\\').strip('\\').split('\\')
        lba, size, prefix, found = self._root_lba, self._root_size, '', None
        for part in parts:
            found = None
            for e in self._read_dir(lba, size, prefix):
                if e.name.lower() == part.lower():
                    found = e
                    break
            if found is None:
                return None
            lba, size, prefix = found.lba, found.size, found.path
        return found

    def extract(self, e, destination, cancel=None):
        """Copia un archivo de la imagen a disco. Devuelve los bytes copiados."""
        remaining = e.size
        self._f.seek(e.lba * SECTOR)
        with open(destination, 'wb') as out:
            while remaining > 0:
                if cancel is not None and cancel.is_set():
                    raise Cancelled()
                chunk = self._f.read(min(1 << 20, remaining))
                if not chunk:
                    raise EOFError('La imagen ISO está truncada (%s).' % e.path)
                out.write(chunk)
                remaining -= len(chunk)
        if e.modified:
            t = e.modified.timestamp()
            os.utime(destination, (t, t))
        return e.size
