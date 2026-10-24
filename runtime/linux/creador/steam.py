# steam.py — accesos «no de Steam» (shortcuts.vdf) para abrir el programa en el Modo Juego del Steam Deck,
# con su artwork (portada, cabecera, fondo y logo), y entradas .desktop para el Modo Escritorio.
# Refleja src/Core/CreadorPeliculas.Steam.psm1.

import os
import shlex
import shutil
import struct
import subprocess
import time
import zlib

from . import art, core, icons, proton
from .errors import log

TAG = 'Creador de Películas 3D'
LIBRARY_NAME = 'Creador de Películas 3D - opciones'


# ---------------------------------------------------------------------------
# VDF binario
# ---------------------------------------------------------------------------

def vdf_load(data):
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b'\0', pos)
        s = data[pos:end].decode('utf-8', 'replace')
        pos = end + 1
        return s

    def read_map():
        nonlocal pos
        out = {}
        while True:
            t = data[pos]
            pos += 1
            if t == 0x08:
                return out
            key = cstr()
            if t == 0x00:
                out[key] = read_map()
            elif t == 0x01:
                out[key] = cstr()
            elif t == 0x02:
                out[key] = struct.unpack_from('<i', data, pos)[0]
                pos += 4
            elif t == 0x07:
                out[key] = struct.unpack_from('<Q', data, pos)[0]
                pos += 8
            else:
                raise ValueError('Tipo VDF desconocido 0x%02x' % t)

    if not data:
        return {}
    return read_map()


def vdf_dump(obj):
    out = bytearray()
    for k, v in obj.items():
        key = k.encode('utf-8') + b'\0'
        if isinstance(v, dict):
            out += b'\x00' + key + vdf_dump(v)
        elif isinstance(v, bool) or isinstance(v, int):
            if isinstance(v, int) and not isinstance(v, bool) and (v > 0x7FFFFFFF or v < -0x80000000):
                out += b'\x07' + key + struct.pack('<Q', v)
            else:
                out += b'\x02' + key + struct.pack('<i', int(v))
        else:
            out += b'\x01' + key + str(v).encode('utf-8') + b'\0'
    out += b'\x08'
    return bytes(out)


def shortcut_appid(exe, name):
    """El appid que Steam calcula para un acceso no-Steam (entero de 32 bits con signo en el VDF)."""
    v = (zlib.crc32((exe + name).encode('utf-8')) & 0xFFFFFFFF) | 0x80000000
    return v - (1 << 32)


# ---------------------------------------------------------------------------
# Accesos
# ---------------------------------------------------------------------------

def user_config_dirs():
    dirs = []
    for root in proton.steam_roots():
        ud = os.path.join(root, 'userdata')
        try:
            for n in os.listdir(ud):
                if n.isdigit() and n != '0' and os.path.isdir(os.path.join(ud, n, 'config')):
                    dirs.append(os.path.join(ud, n, 'config'))
        except OSError:
            pass
    return dirs


def icon_for(root, gid):
    """PNG del ícono del juego en <root>/app/icons (lo extrae del .exe la primera vez)."""
    g = core.game(gid)
    out_dir = os.path.join(root, 'app', 'icons')
    os.makedirs(out_dir, exist_ok=True)
    png = os.path.join(out_dir, gid + '.png')
    if not os.path.exists(png):
        hd = os.path.join(root, 'games', gid)
        if not icons.exe_icon_png(core.local_path(hd, g['icon']), png):
            return ''
    return png


def wanted_shortcuts(root):
    script = core.launcher_script(root)
    exe = '"%s"' % script
    start = '"%s"' % os.path.dirname(script)
    items = [(LIBRARY_NAME, '', '')]
    for ig in core.installed_games(root):
        items.append((ig.name, '--play %s' % ig.id, icon_for(root, ig.id)))
    return [{'appid': shortcut_appid(exe, name), 'AppName': name, 'Exe': exe, 'StartDir': start, 'icon': icon,
             'ShortcutPath': '', 'LaunchOptions': opts, 'IsHidden': 0, 'AllowDesktopConfig': 1, 'AllowOverlay': 1,
             'OpenVR': 0, 'Devkit': 0, 'DevkitGameID': '', 'DevkitOverrideAppID': 0, 'LastPlayTime': 0,
             'FlatpakAppID': '', 'tags': {'0': TAG}}
            for name, opts, icon in items]


def install_art(root, wanted):
    """Copia el artwork de cada juego a userdata/<id>/config/grid con los nombres que espera Steam.
    No requiere cerrar Steam."""
    by_name = {ig.name: ig.id for ig in core.installed_games(root)}
    for w in wanted:
        gid = by_name.get(w['AppName'])
        if not gid:
            continue
        try:
            src = art.make_art(gid, root)
        except Exception as e:
            log('Warn', 'No se pudo generar el artwork de %s: %s' % (gid, e))
            continue
        if not src:
            continue
        appid = w['appid'] & 0xFFFFFFFF
        for d in user_config_dirs():
            grid = os.path.join(d, 'grid')
            os.makedirs(grid, exist_ok=True)
            for name, pattern in art.GRID_NAMES.items():
                shutil.copyfile(os.path.join(src, name), os.path.join(grid, pattern % appid))


def _ours(entry):
    exe = str(entry.get('Exe', entry.get('exe', ''))).strip('"')
    return exe.endswith('/creador.sh')


def update_shortcuts_file(path, wanted):
    """Reemplaza nuestros accesos en un shortcuts.vdf conservando los demás. Devuelve cuántos escribió."""
    data = b''
    if os.path.exists(path):
        with open(path, 'rb') as f:
            data = f.read()
    doc = vdf_load(data) if data else {}
    current = list((doc.get('shortcuts') or {}).values())
    keep = [e for e in current if not _ours(e)]
    old = {str(e.get('AppName', e.get('appname'))): e for e in current if _ours(e)}
    for w in wanted:
        prev = old.get(w['AppName'])
        if prev:   # conservar la última vez que se jugó
            w['LastPlayTime'] = prev.get('LastPlayTime', 0)
    merged = keep + wanted
    if data and not os.path.exists(path + '.creador.bak'):
        shutil.copy2(path, path + '.creador.bak')
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(vdf_dump({'shortcuts': {str(i): e for i, e in enumerate(merged)}}))
    os.replace(tmp, path)
    return len(wanted)


def steam_running():
    try:
        return subprocess.run(['pgrep', '-x', 'steam'], capture_output=True).returncode == 0
    except OSError:
        return False


def in_gaming_mode():
    return os.environ.get('XDG_CURRENT_DESKTOP', '').lower() == 'gamescope' or bool(os.environ.get('GAMESCOPE_WAYLAND_DISPLAY'))


def shutdown_steam(timeout=60):
    subprocess.Popen(['steam', '-shutdown'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.time() + timeout
    while time.time() < end:
        if not steam_running():
            time.sleep(1)
            return True
        time.sleep(1)
    return False


def start_steam():
    subprocess.Popen(['setsid', 'steam'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                     start_new_session=True)


def add_to_steam(root):
    """Escribe los accesos en todos los usuarios de Steam. Steam tiene que estar cerrado. Devuelve los archivos."""
    wanted = wanted_shortcuts(root)
    written = []
    for d in user_config_dirs():
        path = os.path.join(d, 'shortcuts.vdf')
        update_shortcuts_file(path, [dict(w) for w in wanted])
        written.append(path)
        log('Info', 'Accesos de Steam actualizados en %s (%d)' % (path, len(wanted)))
    try:
        install_art(root, wanted)
    except OSError as e:
        log('Warn', 'No se pudo copiar el artwork de Steam: %s' % e)
    return written


# ---------------------------------------------------------------------------
# Menú del Modo Escritorio
# ---------------------------------------------------------------------------

def desktop_dir():
    return os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'applications')


def write_desktop_entries(root):
    script = core.launcher_script(root)
    d = desktop_dir()
    os.makedirs(d, exist_ok=True)
    for n in os.listdir(d):
        if n.startswith('creador-') and n.endswith('.desktop'):
            os.remove(os.path.join(d, n))
    entries = [('creador-opciones', LIBRARY_NAME, 'Instalar, opciones, películas y sincronización', '', 'applications-games')]
    for ig in core.installed_games(root):
        entries.append(('creador-' + ig.id.lower(), ig.name, 'Hacé tus propias películas en 3D', '--play ' + ig.id,
                        icon_for(root, ig.id) or 'applications-games'))
    for fid, name, comment, args, icon in entries:
        with open(os.path.join(d, fid + '.desktop'), 'w', encoding='utf-8') as f:
            f.write('[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=%s %s\nIcon=%s\n'
                    'Categories=Game;Education;\nTerminal=false\n' % (name, comment, shlex.quote(script), args, icon))
    try:
        subprocess.run(['update-desktop-database', d], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


def remove_desktop_entry(gid):
    p = os.path.join(desktop_dir(), 'creador-%s.desktop' % gid.lower())
    if os.path.exists(p):
        os.remove(p)
