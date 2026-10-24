# icons.py — extrae el ícono de un ejecutable de Windows (PE) y lo guarda como PNG,
# sin bibliotecas externas (para la biblioteca Tk, los accesos de Steam y los .desktop).

import struct
import zlib

RT_ICON, RT_GROUP_ICON = 3, 14


def _pe_resources(data):
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    opt = pe + 24
    opt_size = struct.unpack_from('<H', data, pe + 20)[0]
    magic = struct.unpack_from('<H', data, opt)[0]
    dd = opt + (96 if magic == 0x10B else 112)
    res_rva = struct.unpack_from('<I', data, dd + 2 * 8)[0]
    if not res_rva:
        return None
    sections = []
    for i in range(nsec):
        h = opt + opt_size + 40 * i
        vsize, va, rsize, raw = struct.unpack_from('<IIII', data, h + 8)
        sections.append((va, max(vsize, rsize), raw))

    def off(rva):
        for va, size, raw in sections:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError('RVA fuera de las secciones')

    base = off(res_rva)

    def entries(dir_off):
        named, ids = struct.unpack_from('<HH', data, dir_off + 12)
        for i in range(named + ids):
            name, target = struct.unpack_from('<II', data, dir_off + 16 + 8 * i)
            yield name, target

    def leaf(target):
        while target & 0x80000000:
            target = next(entries(base + (target & 0x7FFFFFFF)))[1]
        rva, size = struct.unpack_from('<II', data, base + target)
        o = off(rva)
        return data[o:o + size]

    out = {}
    for typ, t1 in entries(base):
        if typ in (RT_ICON, RT_GROUP_ICON) and t1 & 0x80000000:
            for name, t2 in entries(base + (t1 & 0x7FFFFFFF)):
                out[(typ, name)] = leaf(t2)
    return out


def _png(width, height, rgba_rows):
    def chunk(tag, payload):
        c = struct.pack('>I', len(payload)) + tag + payload
        return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF)
    raw = b''.join(b'\0' + bytes(r) for r in rgba_rows)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def _dib_to_png(dib):
    if dib[:8] == b'\x89PNG\r\n\x1a\n':
        return dib
    hsize, w, h2, planes, bpp, comp = struct.unpack_from('<IiiHHI', dib, 0)
    if comp not in (0, 3):
        return None
    h = h2 // 2
    ncolors = struct.unpack_from('<I', dib, 32)[0] if hsize >= 36 else 0
    if bpp <= 8 and not ncolors:
        ncolors = 1 << bpp
    pal_off = hsize + (12 if comp == 3 else 0)
    palette = [struct.unpack_from('<BBBB', dib, pal_off + 4 * i) for i in range(ncolors)] if bpp <= 8 else []
    xor_off = pal_off + 4 * len(palette)
    xor_stride = ((w * bpp + 31) // 32) * 4
    and_off = xor_off + xor_stride * h
    and_stride = ((w + 31) // 32) * 4
    rows = []
    has_alpha = bpp == 32 and any(dib[xor_off + i * 4 + 3] for i in range(w * h))
    for y in range(h - 1, -1, -1):          # los DIB van de abajo hacia arriba
        row = bytearray()
        xr = xor_off + y * xor_stride
        ar = and_off + y * and_stride
        for x in range(w):
            if bpp == 32:
                b, g, r, a = dib[xr + 4 * x:xr + 4 * x + 4]
            elif bpp == 24:
                b, g, r = dib[xr + 3 * x:xr + 3 * x + 3]
                a = 255
            elif bpp in (1, 4, 8):
                per = 8 // bpp
                byte = dib[xr + x // per]
                idx = (byte >> (8 - bpp * (x % per + 1))) & ((1 << bpp) - 1)
                b, g, r, _ = palette[idx] if idx < len(palette) else (0, 0, 0, 0)
                a = 255
            else:
                return None
            if not has_alpha:
                masked = and_off + and_stride * h <= len(dib) and (dib[ar + x // 8] >> (7 - x % 8)) & 1
                # Máscara 1 con color negro = transparente; con color = "invertir pantalla": se muestra opaco.
                a = 0 if masked and (r, g, b) == (0, 0, 0) else 255
            row += bytes((r, g, b, a))
        rows.append(row)
    return _png(w, h, rows)


def exe_icon_png(exe_path, out_path):
    """Guarda en out_path (PNG) el ícono más grande y con más colores del ejecutable. Devuelve True si pudo."""
    try:
        with open(exe_path, 'rb') as f:
            res = _pe_resources(f.read())
        if not res:
            return False
        groups = [k for k in res if k[0] == RT_GROUP_ICON]     # orden del directorio, como Windows (con nombre primero)
        png = None
        for key in groups:
            grp = res[key]
            count = struct.unpack_from('<H', grp, 4)[0]
            best = None
            for i in range(count):
                w, h, colors, _, planes, bpp, size, nid = struct.unpack_from('<BBBBHHIH', grp, 6 + 14 * i)
                rank = ((w or 256), bpp or (8 if colors == 0 else 4))
                if (RT_ICON, nid) in res and (best is None or rank > best[0]):
                    best = (rank, nid)
            if best is not None:
                png = _dib_to_png(res[(RT_ICON, best[1])])
                if png:
                    break
        if not png:
            return False
        with open(out_path, 'wb') as f:
            f.write(png)
        return True
    except Exception:
        return False
