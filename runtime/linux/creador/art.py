# art.py — artwork de Steam (portada, cabecera, fondo y logo) generado desde una imagen del CD.
# Mismas medidas y composición que New-CpArtImages (src/Core/CreadorPeliculas.Steam.psm1), solo con la
# biblioteca estándar de Python: lee el BMP del catálogo, escala con interpolación bilineal y escribe PNG.

import os
import struct

from . import core
from .icons import _png
from .errors import log


class Image:
    """Imagen RGBA en memoria (bytearray de ancho*alto*4)."""

    def __init__(self, w, h, data=None):
        self.w, self.h = w, h
        self.data = data if data is not None else bytearray(w * h * 4)

    def crop(self, x, y, w, h):
        out = Image(w, h)
        for r in range(h):
            s = ((y + r) * self.w + x) * 4
            out.data[r * w * 4:(r + 1) * w * 4] = self.data[s:s + w * 4]
        return out

    def rows(self):
        return [self.data[r * self.w * 4:(r + 1) * self.w * 4] for r in range(self.h)]


def _rle8(data, off, w, h):
    """Descomprime un BMP RLE8 (como los .DIB del catálogo del CD) a filas de índices de 8 bits, de abajo arriba."""
    stride = (w + 3) & ~3
    out = bytearray(stride * h)
    x = y = 0
    i = off
    while i + 1 < len(data) and y < h:
        n, v = data[i], data[i + 1]
        i += 2
        if n:                                   # n repeticiones del índice v
            for _ in range(n):
                if x < w:
                    out[y * stride + x] = v
                x += 1
        elif v == 0:                            # fin de línea
            x, y = 0, y + 1
        elif v == 1:                            # fin de la imagen
            break
        elif v == 2:                            # salto
            x += data[i]
            y += data[i + 1]
            i += 2
        else:                                   # v índices literales (con relleno a 16 bits)
            for k in range(v):
                if x < w:
                    out[y * stride + x] = data[i + k]
                x += 1
            i += v + (v & 1)
    return out


def read_bmp(path):
    """BMP de 8 bits (sin compresión o RLE8), 24 o 32 bits (los .DIB del CD son archivos BM comunes)."""
    with open(path, 'rb') as f:
        b = f.read()
    if b[:2] != b'BM':
        raise ValueError('No es un BMP: %s' % path)
    off = struct.unpack_from('<I', b, 10)[0]
    hsize, w, h, planes, bpp, comp = struct.unpack_from('<IiiHHI', b, 14)
    if comp == 1 and bpp == 8 and h > 0:
        b = b[:off] + bytes(_rle8(b, off, w, h))
        comp = 0
    if comp not in (0, 3):
        raise ValueError('BMP comprimido no soportado')
    bottom_up = h > 0
    h = abs(h)
    ncolors = struct.unpack_from('<I', b, 14 + 32)[0] if hsize >= 36 else 0
    if bpp <= 8 and not ncolors:
        ncolors = 1 << bpp
    pal = [b[14 + hsize + 4 * i:14 + hsize + 4 * i + 3] for i in range(ncolors)] if bpp <= 8 else []
    stride = ((w * bpp + 31) // 32) * 4
    img = Image(w, h)
    for y in range(h):
        src = off + (h - 1 - y if bottom_up else y) * stride
        o = y * w * 4
        for x in range(w):
            if bpp == 8:
                bb, gg, rr = pal[b[src + x]]
            elif bpp == 24:
                bb, gg, rr = b[src + 3 * x:src + 3 * x + 3]
            elif bpp == 32:
                bb, gg, rr = b[src + 4 * x:src + 4 * x + 3]
            else:
                raise ValueError('BMP de %d bits no soportado' % bpp)
            img.data[o:o + 4] = bytes((rr, gg, bb, 255))
            o += 4
    return img


def color_key(img, rgb, tolerance):
    """Vuelve transparentes los píxeles cercanos a rgb (suma de diferencias <= tolerance)."""
    d = img.data
    for i in range(0, len(d), 4):
        if abs(d[i] - rgb[0]) + abs(d[i + 1] - rgb[1]) + abs(d[i + 2] - rgb[2]) <= tolerance:
            d[i:i + 4] = b'\0\0\0\0'
    return img


def _axis(src, dst):
    """Índices y pesos de la interpolación bilineal en un eje."""
    out = []
    for i in range(dst):
        f = (i + 0.5) * src / dst - 0.5
        f = min(max(f, 0.0), src - 1.0)
        i0 = int(f)
        i1 = min(i0 + 1, src - 1)
        out.append((i0, i1, f - i0))
    return out


def scale(img, w, h):
    """Escala con interpolación bilineal (con alfa premultiplicado, para no oscurecer bordes)."""
    out = Image(w, h)
    xs, ys = _axis(img.w, w), _axis(img.h, h)
    s, d, sw = img.data, out.data, img.w * 4
    for y, (y0, y1, fy) in enumerate(ys):
        r0, r1 = y0 * sw, y1 * sw
        o = y * w * 4
        for x0, x1, fx in xs:
            acc = [0.0, 0.0, 0.0, 0.0]
            for base, wgt in ((r0 + x0 * 4, (1 - fx) * (1 - fy)), (r0 + x1 * 4, fx * (1 - fy)),
                              (r1 + x0 * 4, (1 - fx) * fy), (r1 + x1 * 4, fx * fy)):
                if wgt:
                    a = s[base + 3] * wgt
                    acc[0] += s[base] * a
                    acc[1] += s[base + 1] * a
                    acc[2] += s[base + 2] * a
                    acc[3] += a
            a = acc[3]
            if a > 0:
                d[o] = min(255, int(acc[0] / a + 0.5))
                d[o + 1] = min(255, int(acc[1] / a + 0.5))
                d[o + 2] = min(255, int(acc[2] / a + 0.5))
                d[o + 3] = min(255, int(a + 0.5))
            o += 4
    return out


def paste(canvas, img, x, y):
    """Pega img sobre canvas en (x, y) mezclando por su alfa."""
    c, s = canvas.data, img.data
    for r in range(img.h):
        cy = y + r
        if not 0 <= cy < canvas.h:
            continue
        for col in range(img.w):
            cx = x + col
            if not 0 <= cx < canvas.w:
                continue
            si = (r * img.w + col) * 4
            a = s[si + 3]
            if not a:
                continue
            ci = (cy * canvas.w + cx) * 4
            if a == 255:
                c[ci:ci + 4] = s[si:si + 4]
                continue
            ca = c[ci + 3]
            oa = a + ca * (255 - a) // 255
            for k in range(3):
                c[ci + k] = (s[si + k] * a + c[ci + k] * ca * (255 - a) // 255) // max(1, oa)
            c[ci + 3] = oa


def compose(w, h, parts, background=None):
    """Lienzo w x h (fondo de color o transparente) con cada parte escalada para entrar en su rectángulo,
    manteniendo la proporción y centrada en él. parts: [(imagen, x, y, ancho, alto)]."""
    canvas = Image(w, h)
    if background is not None:
        canvas.data[:] = bytes((background[0], background[1], background[2], 255)) * (w * h)
    for img, bx, by, bw, bh in parts:
        s = min(bw / img.w, bh / img.h)
        pw, ph = int(img.w * s), int(img.h * s)
        paste(canvas, scale(img, pw, ph), bx + round((bw - pw) / 2), by + round((bh - ph) / 2))
    return canvas


def save_png(img, path):
    with open(path, 'wb') as f:
        f.write(_png(img.w, img.h, img.rows()))


def hex_rgb(h):
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


# Medidas recomendadas por Steam: portada 600x900, cabecera 920x430, fondo 1920x620, logo (máx. 1280x720).
LAYOUTS = {
    'portrait.png': (600, 900, [('logo', 30, 30, 540, 140), ('picture', 20, 190, 560, 690)], False),
    'header.png': (920, 430, [('logo', 30, 20, 520, 390), ('picture', 560, 10, 340, 410)], False),
    'hero.png': (1920, 620, [('picture', 1260, 10, 560, 600)], False),
    'logo.png': (900, 230, [('logo', 0, 0, 900, 230)], True),
}

# Nombres en config/grid: <appid sin signo> + sufijo.
GRID_NAMES = {'portrait.png': '%dp.png', 'header.png': '%d.png', 'hero.png': '%d_hero.png', 'logo.png': '%d_logo.png'}


def make_art(gid, root):
    """Genera las imágenes en <root>/games/<ID>/art/steam a partir de la receta «art» de games.json.
    Devuelve la carpeta, o None si el juego no tiene receta o falta la imagen."""
    g = core.game(gid)
    art = g.get('art')
    if not art:
        return None
    hd = os.path.join(root, 'games', gid)
    src = core.local_path(hd, art['source'])
    if not os.path.exists(src):
        return None
    out = os.path.join(hd, 'art', 'steam')
    hero = os.path.join(out, 'hero.png')
    if os.path.exists(hero) and os.path.getmtime(hero) >= os.path.getmtime(src):
        return out
    os.makedirs(out, exist_ok=True)
    base = read_bmp(src)
    pieces = {
        'logo': color_key(base.crop(*art['logo']['rect']), hex_rgb(art['logo']['key']), int(art['logo']['tolerance'])),
        'picture': base.crop(*art['picture']['rect']),
    }
    bg = hex_rgb(art['background'])
    for name, (w, h, parts, transparent) in LAYOUTS.items():
        img = compose(w, h, [(pieces[k], x, y, bw, bh) for k, x, y, bw, bh in parts], None if transparent else bg)
        save_png(img, os.path.join(out, name))
    log('Info', 'Artwork de Steam generado en %s' % out)
    return out
