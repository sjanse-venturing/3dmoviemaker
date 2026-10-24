# proton.py — ejecutar el juego con Proton (Wine de Steam) en Linux / Steam Deck.
#
# Prefijo propio en <root>/proton/pfx. Dentro de él:
#   C:\CreadorPeliculas\{games,logs}  -> enlaces a <root>/{games,logs}  (rutas cortas y ANSI)
#   C:\windows\Fonts                  <- las fuentes del CD (Comic Sans), que Wine no trae
# Se usan los mismos cplaunch.exe / cphook.dll que en Windows. No hace falta CD: el juego busca su
# contenido primero en el disco y la instalación lo copia todo.

import glob
import os
import re
import shutil
import subprocess
import time

from . import core
from .errors import CpError, log


# ---------------------------------------------------------------------------
# Steam y versiones de Proton
# ---------------------------------------------------------------------------

def steam_roots():
    roots = []
    for c in ('~/.local/share/Steam', '~/.steam/steam', '~/.steam/root',
              '~/.var/app/com.valvesoftware.Steam/data/Steam'):
        p = os.path.realpath(os.path.expanduser(c))
        if os.path.isdir(os.path.join(p, 'steamapps')) and p not in roots:
            roots.append(p)
    return roots


def library_folders():
    libs = []
    for root in steam_roots():
        libs.append(root)
        vdf = os.path.join(root, 'steamapps', 'libraryfolders.vdf')
        try:
            with open(vdf, encoding='utf-8', errors='replace') as f:
                for m in re.finditer(r'"path"\s+"([^"]+)"', f.read()):
                    p = os.path.realpath(m.group(1).replace('\\\\', '\\'))
                    if p not in libs:
                        libs.append(p)
        except OSError:
            pass
    return libs


# Con Proton 11.0 y Experimental se observaron pantallas en negro en juegos GDI de 256 colores con esta
# misma capa nativa (2026-10-15), así que se prefiere la 10.0.
RECOMMENDED = ('Proton 10.0',)


class ProtonTool:
    def __init__(self, name, path):
        self.name = name
        self.path = path          # carpeta que contiene el script «proton»
        self.script = os.path.join(path, 'proton')

    @property
    def recommended(self):
        return self.name in RECOMMENDED

    def rank(self):
        if self.recommended:
            return (4, 0, 0)
        m = re.match(r'^Proton (\d+)\.(\d+)$', self.name)
        if m:
            return (3, int(m.group(1)), int(m.group(2)))
        if self.name == 'Proton - Experimental':
            return (2, 0, 0)
        m = re.match(r'^GE-Proton(\d+)-(\d+)$', self.name)
        if m:
            return (1, int(m.group(1)), int(m.group(2)))
        return (0, 0, 0)


def list_protons():
    found = {}
    dirs = [os.path.join(lib, 'steamapps', 'common', '*') for lib in library_folders()]
    dirs += [os.path.join(r, 'compatibilitytools.d', '*') for r in steam_roots()]
    dirs.append(os.path.expanduser('~/.steam/root/compatibilitytools.d/*'))
    for pattern in dirs:
        for d in glob.glob(pattern):
            if os.path.isfile(os.path.join(d, 'proton')) and os.path.basename(d) not in found:
                found[os.path.basename(d)] = ProtonTool(os.path.basename(d), d)
    return sorted(found.values(), key=lambda t: t.rank(), reverse=True)


def select(cfg=None):
    """La versión elegida en Opciones (nombre o ruta), la recomendada o la estable más nueva."""
    tools = list_protons()
    wanted = (cfg or {}).get('proton')
    if wanted:
        for t in tools:
            if wanted in (t.name, t.path):
                return t
        if os.path.isfile(os.path.join(wanted, 'proton')):
            return ProtonTool(os.path.basename(wanted), wanted)
    return tools[0] if tools else None


# ---------------------------------------------------------------------------
# Prefijo
# ---------------------------------------------------------------------------

def compat_dir(root):
    return os.path.join(root, 'proton')


def prefix_dir(root):
    return os.path.join(compat_dir(root), 'pfx')


def base_env(root, tool):
    env = dict(os.environ)
    env['STEAM_COMPAT_DATA_PATH'] = compat_dir(root)
    roots = steam_roots()
    env['STEAM_COMPAT_CLIENT_INSTALL_PATH'] = roots[0] if roots else os.path.expanduser('~/.local/share/Steam')
    env.setdefault('WINEDEBUG', '-all')
    return env


def _relink(link, target):
    if os.path.islink(link):
        if os.readlink(link) == target:
            return
        os.remove(link)
    elif os.path.exists(link):
        raise OSError('%s existe y no es un enlace' % link)
    os.symlink(target, link)


def ensure_prefix(root, tool, on_progress=None):
    """Crea el prefijo de Proton la primera vez, arma C:\\CreadorPeliculas y copia las fuentes del juego."""
    pfx = prefix_dir(root)
    if not os.path.isfile(os.path.join(pfx, 'system.reg')):
        if tool is None:
            raise CpError('3DM-ENV-004')
        if on_progress:
            on_progress('Preparando la capa de compatibilidad (Proton). La primera vez tarda un poco…')
        os.makedirs(compat_dir(root), exist_ok=True)
        log('Info', 'Creando prefijo de Proton con %s en %s' % (tool.name, pfx))
        # Proton arma el prefijo antes de ejecutar el comando; basta uno que termine enseguida.
        r = subprocess.run([tool.script, 'run', 'reg.exe', 'query', 'HKCU\\Software\\Wine'], env=base_env(root, tool),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=600)
        log('Info', 'Prefijo creado (código %d): %s' % (r.returncode, r.stdout.decode('utf-8', 'replace')[-2000:]))
        if not os.path.isfile(os.path.join(pfx, 'system.reg')):
            raise CpError('3DM-ENV-004')
    top = os.path.join(pfx, 'drive_c', core.WIN_ROOT.split('\\', 1)[1])
    os.makedirs(top, exist_ok=True)
    for sub in ('games', 'logs'):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
        _relink(os.path.join(top, sub), os.path.join(root, sub))
    install_fonts(root, pfx)
    return pfx


def install_fonts(root, pfx):
    """Copia a C:\\windows\\Fonts las fuentes que agregaba el instalador original (Comic Sans); Wine las
    encuentra solas en esa carpeta. Windows 10 ya las trae."""
    fonts = os.path.join(pfx, 'drive_c', 'windows', 'Fonts')
    for ig in core.installed_games(root):
        src = core.fonts_dir(ig.id, root)
        try:
            names = os.listdir(src)
        except OSError:
            continue
        os.makedirs(fonts, exist_ok=True)
        for n in names:
            dst = os.path.join(fonts, n.lower())
            if not os.path.exists(dst):
                shutil.copyfile(os.path.join(src, n), dst)
                log('Info', 'Fuente %s copiada al prefijo' % n)


# ---------------------------------------------------------------------------
# Lanzamiento
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, gid, g, root):
        self.id, self.game, self.root = gid, g, root
        self.process = None
        self.started = None
        self.exit_code = None


def win_exe_path(gid, root):
    """Ruta del ejecutable tal como está en disco (respeta mayúsculas), en formato C:\\..."""
    hd = os.path.join(root, 'games', gid)
    exe_local = core.local_path(hd, core.game(gid)['exe'])
    return core.win_hd(gid) + '\\' + os.path.relpath(exe_local, hd).replace(os.sep, '\\')


def build_command(gid, root, cfg, tool, file=None):
    """Comando y variables de entorno para lanzar el juego (separado de start_game para las pruebas)."""
    g = core.game(gid)
    player = core.get_player(cfg)
    win_hd = core.win_hd(gid)
    win_exe = win_exe_path(gid, root)
    env = base_env(root, tool)
    env.update({
        'CP3D_LOG': '%s\\logs\\juego-%s.log' % (core.WIN_ROOT, gid),
        'CP3D_TRACE': '1' if os.environ.get('CP3D_TRACE') == '1' else '0',
        'CP3D_REGFILE': '%s\\%s' % (win_hd, g['registry']['file']),
        'CP3D_USER': player,
        'CP3D_SCALE': str(int(cfg.get('scale') or 0)),
    })
    env.pop('CP3D_QUIET', None)
    linux = g.get('linux') or {}
    env.update({k: str(v) for k, v in (linux.get('env') or {}).items()})
    args = [a for a in core.expand_template(g.get('args') or '', core.game_vars(gid, player)).split(' ') if a]
    if file:
        args.append(file)
    cmd = [tool.script, 'run', os.path.join(core.native_bin(), 'cplaunch.exe')]
    if linux.get('nohook') or os.environ.get('CP3D_NOHOOK') == '1':   # diagnóstico
        cmd.append('--nohook')
    cmd += ['--wait', '--cwd', win_exe.rsplit('\\', 1)[0], '--', win_exe] + args
    return cmd, env


def start_game(gid, root, cfg, on_progress=None, file=None):
    """Escribe la configuración (registro virtual) y lanza el juego con Proton. Devuelve una Session.
    file: película .3MM para abrir directamente (ruta tal como la ve Wine)."""
    g = core.game(gid)
    m = core.get_manifest(root)
    if gid not in m['games']:
        raise CpError('3DM-RUN-006', game=g['name'])
    hd = os.path.join(root, 'games', gid)
    exe_local = core.local_path(hd, g['exe'])
    if not os.path.exists(exe_local):
        raise CpError('3DM-RUN-006', game=g['name'])
    if core.running_game(root):
        raise CpError('3DM-RUN-001')
    tool = select(cfg)
    if tool is None:
        raise CpError('3DM-ENV-004')

    session = Session(gid, g, root)
    ensure_prefix(root, tool, on_progress)
    player = core.get_player(cfg)
    log('Info', 'Juego %s: carpeta %s, jugador %s, %s' % (gid, hd, player, tool.name))
    from . import errors
    errors.step('Configurar ' + gid, lambda: core.write_game_config(g, root, player), '3DM-CFG-001', game=g['name'])

    logs = os.path.join(root, 'logs')
    os.makedirs(logs, exist_ok=True)
    game_log = os.path.join(logs, 'juego-%s.log' % gid)
    if os.path.exists(game_log):
        open(game_log, 'w').close()
    cmd, env = build_command(gid, root, cfg, tool, file)
    log('Info', 'Lanzando: %s' % ' '.join(cmd))
    try:
        session.process = subprocess.Popen(cmd, env=env, cwd=os.path.dirname(exe_local), stdin=subprocess.DEVNULL)
    except OSError as e:
        raise CpError('3DM-RUN-005', e, game=g['name'])
    session.started = time.time()
    return session


def complete_game(session, diagnose=True):
    """Espera a que termine el juego y devuelve None o un CpError de diagnóstico."""
    if session.process is None:
        return None
    code = session.process.wait()
    session.exit_code = code
    elapsed = time.time() - session.started
    log('Info', 'Juego %s terminó: código %d tras %.0f s' % (session.id, code, elapsed))
    if not diagnose:
        return None
    name = session.game['name']
    # En Linux el código de salida se trunca a 8 bits: 9001-9003 de cplaunch llegan como 41-43.
    if code in (9001 & 0xFF, 9002 & 0xFF, 9003 & 0xFF):
        return CpError('3DM-RUN-005', game=name)
    crash = []
    game_log = os.path.join(session.root, 'logs', 'juego-%s.log' % session.id)
    try:
        with open(game_log, encoding='utf-8', errors='replace') as f:
            text = f.read()
        crash = [re.sub(r'^\[\s*\d+\] FALLO ', '', l) for l in text.splitlines() if '] FALLO ' in l]
        if 'cphook cargado' not in text and not (session.game.get('linux') or {}).get('nohook'):
            log('Warn', 'El registro del juego no muestra cphook cargado')
    except OSError:
        pass
    if crash:
        detail = 'Detalle del fallo:\n' + '\n'.join(crash)
        log('Error', 'Detalle del fallo de %s:\n%s' % (session.id, detail))
        return CpError('3DM-RUN-004', Exception(detail), game=name, code='0x%08X' % (code & 0xFFFFFFFF))
    if elapsed < 5 and code != 0:
        return CpError('3DM-RUN-003', game=name)
    return None
