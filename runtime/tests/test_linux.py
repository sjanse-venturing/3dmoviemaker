# Pruebas automáticas del núcleo de Linux / Steam Deck (sin interfaz gráfica ni Proton).
# Uso:  python3 -m unittest discover -s runtime/tests -p 'test_*.py'
# Con CP3D_ISOS=<carpeta con la .iso> se prueba también la imagen real (detección e instalación completa).
# También corren en Windows (con el Python del sistema), salvo lo que necesita enlaces simbólicos.

import base64
import hashlib
import http.server
import io
import json
import os
import re
import struct
import sys
import tempfile
import threading
import unittest
import urllib.parse
import zipfile
import zlib
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'linux'))

from creador import art, core, errors, proton, steam, sync  # noqa: E402
from creador.errors import CpError  # noqa: E402
from creador.iso import Iso  # noqa: E402

errors.load_strings(os.path.join(core.DATA_DIR, 'strings.es.json'))
# Configuración propia de las pruebas: nunca la del usuario (de ahí sale el nombre del jugador).
core.CONFIG_FILE = os.path.join(tempfile.mkdtemp(prefix='creador-cfg-'), 'config.json')

GID = '3DMM'
PLAYER = core.DEFAULT_PLAYER
MOVIE = b'CHN2 COS\x05\x00\x04\x00'    # comienzo de un .3MM real (archivo «chunky» de Kauai)


def movie(text):
    return MOVIE + text.encode('utf-8')


def fake_install(root, ids=(GID,)):
    """Instalación mínima: manifiesto y el exe del juego, sin copiar el disco."""
    m = {'version': 1, 'games': {}}
    for gid in ids:
        hd = os.path.join(root, 'games', gid)
        exe = os.path.join(hd, *core.game(gid)['exe'].split('\\'))
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        with open(exe, 'wb') as f:
            f.write(b'MZ')
        m['games'][gid] = {'id': gid, 'hd': hd, 'isoPath': '', 'label': ''}
    core.save_manifest(root, m)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb' if isinstance(data, bytes) else 'w') as f:
        f.write(data)


def read(path, mode='r'):
    with open(path, mode) as f:
        return f.read()


def zip_names(path):
    with zipfile.ZipFile(path) as z:
        return z.namelist()


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    assert head[:8] == b'\x89PNG\r\n\x1a\n'
    return struct.unpack('>II', head[16:24])


def bmp8(w, h, pixel):
    """BMP de 8 bits (como los .DIB del CD) con una paleta de 256 grises y píxeles pixel(x, y) -> índice."""
    stride = (w + 3) & ~3
    pal = b''.join(bytes((i, i, i, 0)) for i in range(256))
    rows = b''.join(bytes(pixel(x, y) for x in range(w)) + b'\0' * (stride - w) for y in range(h - 1, -1, -1))
    off = 14 + 40 + len(pal)
    return (b'BM' + struct.pack('<IHHI', off + len(rows), 0, 0, off) +
            struct.pack('<IiiHHIIiiII', 40, w, h, 1, 8, 0, len(rows), 2835, 2835, 256, 0) + pal + rows)


class CatalogTests(unittest.TestCase):
    def test_games(self):
        c = core.catalog()
        self.assertEqual([g['id'] for g in c], [GID])
        for k in ('id', 'name', 'age', 'engine', 'iso', 'layout', 'exe', 'icon', 'saves', 'savesDir', 'registry', 'saveMagic'):
            self.assertIn(k, c[0])

    def test_error_codes_defined(self):
        codes = set()
        for base in (os.path.join(core.APP_ROOT, 'linux'), os.path.join(core.APP_ROOT, 'src')):
            for d, _, files in os.walk(base):
                for n in files:
                    if n.endswith(('.py', '.ps1', '.psm1')):
                        with open(os.path.join(d, n), encoding='utf-8-sig') as f:
                            codes |= set(re.findall(r'3DM-[A-Z]{3}-\d{3}', f.read()))
        defined = set(errors.strings()['errors'])
        self.assertFalse(codes - defined, 'faltan en strings.es.json')

    def test_error_message(self):
        info = errors.error_info(CpError('3DM-DSK-001', drive='/x', need='2 GB', free='1 GB'))
        self.assertIn('2 GB', info.message)
        self.assertEqual(errors.error_info(ValueError('raro')).code, '3DM-GEN-001')


class PlayerTests(unittest.TestCase):
    def test_valid(self):
        for n in ('Jugador', 'Ana', 'José María', 'Nico 2', 'x' * 24):
            self.assertTrue(core.is_valid_player(n), n)

    def test_invalid(self):
        for n in ('', ' Ana', 'Ana ', 'a/b', 'a\\b', 'a:b', 'a*', 'a?', 'a"b', 'a<b', 'a|b', 'x' * 25, 'Ana.', 'tab\tx',
                  'McZee', 'melanie', 'CON', 'nul', 'COM1', 'lpt9', 'Ωmega', None):
            self.assertFalse(core.is_valid_player(n), repr(n))

    def test_config_fallback(self):
        self.assertEqual(core.get_player({'player': 'a/b'}), PLAYER)
        self.assertEqual(core.get_player({'player': 'Ana'}), 'Ana')


class IniTests(unittest.TestCase):
    def test_merge(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'a.ini')
            with open(p, 'wb') as f:
                f.write(b'[HKLM]\r\nInstallDirectory=viejo\r\nOtra=1\r\n\r\n[HKCU]\r\nX=2\r\n')
            core.set_ini_values(p, {'HKLM': {'InstallDirectory': 'sz:{HD}\\MSKIDS', 'Nueva': 'dw:0'},
                                    'HKLM\\Products': {'2': 'sz:3D Creador de Películas/3DMovie'}}, {'HD': 'C:\\J'})
            raw = read(p, 'rb')
            self.assertIn(b'InstallDirectory=sz:C:\\J\\MSKIDS\r\n', raw)
            self.assertIn(b'Otra=1', raw)
            self.assertIn(b'Nueva=dw:0', raw)
            self.assertIn(b'X=2', raw)
            self.assertIn(b'2=sz:3D Creador de Pel\xedculas/3DMovie', raw, 'debe quedar en ANSI (cp1252)')


class RegistryTests(unittest.TestCase):
    """Registro virtual que lee cphook.dll (mismas reglas que Write-CpGameConfig en Windows)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        fake_install(self.root)
        self.reg = core.registry_file(GID, self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def values(self):
        out, section = {}, None
        for line in read(self.reg, 'rb').decode('cp1252').split('\r\n'):
            if line.startswith('['):
                section = line[1:-1]
            elif '=' in line:
                k, v = line.split('=', 1)
                out[(section, k)] = v
        return out

    def test_first_run_then_known(self):
        core.write_game_config(core.game(GID), self.root, 'Ana')
        v = self.values()
        hd = 'C:\\CreadorPeliculas\\games\\3DMM'
        self.assertEqual(v[('HKLM', 'InstallDirectory')], 'sz:' + hd + '\\MSKIDS')
        self.assertEqual(v[('HKLM\\Products', '2')], 'sz:3D Creador de Películas/3DMovie')
        self.assertEqual(v[('HKCU', 'GreaterThan8bppMsg')], 'dw:0')
        # Primera vez: la carpeta del jugador no existe y el juego la crea (con su bienvenida).
        self.assertEqual(v[('HKCU', 'HomeDirectory')], 'sz:')
        self.assertFalse(os.path.exists(core.player_dir(GID, self.root, 'Ana')))
        os.makedirs(core.player_dir(GID, self.root, 'Ana'))
        core.write_game_config(core.game(GID), self.root, 'Ana')
        self.assertEqual(self.values()[('HKCU', 'HomeDirectory')], 'sz:' + hd + '\\MSKIDS\\Users\\Ana\\')
        self.assertTrue(read(self.reg, 'rb').endswith(b'\r\n'))

    def test_player_dir(self):
        self.assertEqual(core.player_dir(GID, self.root, 'Ana'),
                         os.path.join(self.root, 'games', GID, 'MSKIDS', 'Users', 'Ana'))
        self.assertEqual(core.game_vars(GID, 'Ana')['USERDIR'], 'C:\\CreadorPeliculas\\games\\3DMM\\MSKIDS\\Users\\Ana')


class CopyTests(unittest.TestCase):
    def test_include_patterns(self):
        self.assertTrue(core._included('SETUP\\MOMIA.3MM', ['*.3mm']))
        self.assertFalse(core._included('SETUP\\INSTALAR.INF', ['*.3MM']))
        self.assertTrue(core._included('X\\Y.Z', ()))
        self.assertTrue(core._included('PSS\\3dmm.hlp', ['3DMM.HLP', '3DMM.CNT']))


class LaunchTests(unittest.TestCase):
    def test_command(self):
        with tempfile.TemporaryDirectory() as t:
            fake_install(t)
            tool = proton.ProtonTool('Proton 10.0', '/x/Proton 10.0')
            cmd, env = proton.build_command(GID, t, {'scale': 2, 'player': 'Ana'}, tool, 'C:\\pelis\\Mi película.3MM')
            exe = 'C:\\CreadorPeliculas\\games\\3DMM\\MSKIDS\\3D Creador de Películas\\3DMOVIE.EXE'
            self.assertEqual(cmd[0], tool.script)
            self.assertEqual(cmd[1], 'run')
            self.assertTrue(cmd[2].endswith('cplaunch.exe'))
            i = cmd.index('--cwd')
            self.assertEqual(cmd[i + 1], exe.rsplit('\\', 1)[0])
            self.assertEqual(cmd[i + 2:], ['--', exe, '-m', 'C:\\pelis\\Mi película.3MM'])
            self.assertEqual(env['CP3D_REGFILE'], 'C:\\CreadorPeliculas\\games\\3DMM\\registro.ini')
            self.assertEqual(env['CP3D_USER'], 'Ana')
            self.assertEqual(env['CP3D_SCALE'], '2')
            self.assertEqual(env['CP3D_LOG'], 'C:\\CreadorPeliculas\\logs\\juego-3DMM.log')
            self.assertNotIn('wing32', env.get('WINEDLLOVERRIDES', '').lower())


class SavesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def movie(self, root, name, data):
        write(os.path.join(core.player_dir(GID, root, PLAYER), name), data)

    def test_export_import_all(self):
        a = os.path.join(self.t, 'a')
        fake_install(a)
        self.movie(a, 'Mi película.3MM', movie('A'))
        self.movie(a, 'notas.txt', 'no es película')
        z = core.export_all_saves(a, os.path.join(self.t, 'out'))
        self.assertTrue(os.path.basename(z).startswith('creador-peliculas-'))
        self.assertEqual(set(zip_names(z)), {'creador-saves.json', '3DMM/Mi película.3MM'})

        b = os.path.join(self.t, 'b')
        fake_install(b)
        self.movie(b, 'mi PELÍCULA.3mm', movie('vieja'))     # otra capitalización: se reemplaza
        r = core.import_saves(b, z, os.path.join(self.t, 'bk'))
        self.assertEqual(r.imported[GID], ['Mi película.3MM'])
        self.assertEqual(len(r.backups), 1)
        files = os.listdir(core.player_dir(GID, b, PLAYER))
        self.assertEqual(files, ['Mi película.3MM'])
        self.assertIn('mi PELÍCULA.3mm', zip_names(r.backups[0]))

    def test_import_loose_zip(self):
        # Un zip cualquiera con películas sueltas: el catálogo tiene un solo juego, son de él.
        z = os.path.join(self.t, 'pelis de Ana.zip')
        with zipfile.ZipFile(z, 'w') as f:
            f.writestr('UNO.3MM', movie('1'))
            f.writestr('readme.txt', 'x')
        b = os.path.join(self.t, 'b')
        fake_install(b)
        r = core.import_saves(b, z, os.path.join(self.t, 'bk'))
        self.assertEqual(r.imported[GID], ['UNO.3MM'])
        self.assertEqual(r.ignored, ['readme.txt'])
        self.assertEqual(r.backups, [])

    def test_per_game_backup_roundtrip(self):
        a = os.path.join(self.t, 'a')
        fake_install(a)
        self.movie(a, 'DOS.3MM', movie('2'))
        z = core.backup_saves(GID, a, os.path.join(self.t, 'out'))
        with zipfile.ZipFile(z) as f:
            meta = json.loads(f.read('creador-saves.json'))
        self.assertEqual(meta['games'], [GID])
        b = os.path.join(self.t, 'b')
        fake_install(b)
        r = core.import_saves(b, z, os.path.join(self.t, 'bk'))
        self.assertEqual(r.imported[GID], ['DOS.3MM'])

    def test_rejects_unsafe_entries(self):
        z = os.path.join(self.t, 'otro.zip')
        with zipfile.ZipFile(z, 'w') as f:
            for n in ('../evil.3MM', '3DMM/../../x.3MM', '3DMM/sub/A.3MM', '3DMM/3DMOVIE.EXE', '3DMM\\..\\y.3MM'):
                f.writestr(n, 'x')
        with self.assertRaises(CpError) as c:
            core.read_saves_zip(z)
        self.assertEqual(c.exception.code, '3DM-SAV-001')

    def test_not_a_zip(self):
        p = os.path.join(self.t, 'x.zip')
        write(p, 'no soy un zip')
        with self.assertRaises(CpError) as c:
            core.read_saves_zip(p)
        self.assertEqual(c.exception.code, '3DM-SAV-001')


def set_mtime(path, iso):
    t = sync.from_iso(iso)
    os.utime(path, (t, t))


def make_zip(entries, manifest=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        if manifest is not None:
            z.writestr('creador-saves.json', json.dumps(manifest))
        for n, body in entries.items():
            z.writestr(n, body)
    return buf.getvalue()


def manifest_for(gid, entries, updated='2026-01-01T10:00:00Z', **over):
    files = [{'name': n, 'size': len(b), 'sha256': hashlib.sha256(b).hexdigest(), 'mtime': updated} for n, b in entries.items()]
    m = {'format': 2, 'createdAt': updated, 'platform': 'windows', 'games': [gid], 'gameId': gid, 'updatedAt': updated,
         'deviceId': 'abc', 'deviceName': 'PC', 'bundleHash': sync.bundle_hash(files), 'files': files}
    m.update(over)
    return m


class SyncTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name
        self.patches = [mock.patch.object(sync, 'STATE_FILE', os.path.join(self.t, 'state-a.json')),
                        mock.patch.object(core, 'saves_dir', lambda: os.path.join(self.t, 'copias'))]
        for p in self.patches:
            p.start()
        self.a = os.path.join(self.t, 'a')
        self.b = os.path.join(self.t, 'b')
        fake_install(self.a)
        fake_install(self.b)
        self.cloud = os.path.join(self.t, 'nube')
        os.makedirs(self.cloud)
        self.cfg_a = {'sync': {'mode': 'folder', 'folder': self.cloud, 'deviceId': 'a' * 32, 'deviceName': 'PC'}}
        self.cfg_b = {'sync': {'mode': 'folder', 'folder': self.cloud, 'deviceId': 'b' * 32, 'deviceName': 'Deck'}}

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def as_device(self, name):
        """Cada «equipo» tiene su propio sync-state.json."""
        sync.STATE_FILE = os.path.join(self.t, 'state-%s.json' % name)

    def path(self, root, name):
        return os.path.join(core.player_dir(GID, root, PLAYER), name)

    def save(self, root, name, text, when):
        p = self.path(root, name)
        write(p, movie(text))
        set_mtime(p, when)
        return p


class SyncFolderTests(SyncTestBase):
    def test_roundtrip_newest_wins(self):
        self.as_device('a')
        self.save(self.a, 'ANA.3MM', 'Ana', '2026-01-01T10:00:00Z')
        r = sync.after_play(GID, self.a, self.cfg_a)
        self.assertEqual(r.action, 'uploaded')
        self.assertTrue(os.path.exists(os.path.join(self.cloud, 'CreadorPeliculas-sync', '3DMM.zip')))
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a).action, 'same')

        self.as_device('b')     # en el otro equipo todavía no existe la carpeta del jugador: se crea
        r = sync.before_play(GID, self.b, self.cfg_b)
        self.assertEqual(r.action, 'downloaded')
        p = self.path(self.b, 'ANA.3MM')
        self.assertIn(b'Ana', read(p, 'rb'))
        self.assertEqual(sync.to_iso(os.path.getmtime(p)), '2026-01-01T10:00:00Z')
        self.assertEqual(sync.before_play(GID, self.b, self.cfg_b).action, 'same')

        self.save(self.b, 'ANA.3MM', 'Ana editada', '2026-01-02T10:00:00Z')
        self.assertEqual(sync.after_play(GID, self.b, self.cfg_b).action, 'uploaded')
        self.as_device('a')
        r = sync.before_play(GID, self.a, self.cfg_a)
        self.assertEqual(r.action, 'downloaded')
        self.assertTrue(r.backup and os.path.exists(r.backup), 'debe guardar las películas que reemplaza')
        self.assertIn(b'editada', read(self.path(self.a, 'ANA.3MM'), 'rb'))

    def test_local_newer_is_kept(self):
        self.as_device('b')
        self.save(self.b, 'X.3MM', 'Vieja', '2026-01-01T10:00:00Z')
        sync.after_play(GID, self.b, self.cfg_b)
        self.as_device('a')
        self.save(self.a, 'X.3MM', 'Nueva', '2026-03-01T10:00:00Z')
        self.assertEqual(sync.before_play(GID, self.a, self.cfg_a).action, 'local-newer')
        self.assertIn(b'Nueva', read(self.path(self.a, 'X.3MM'), 'rb'))
        self.assertTrue(sync.status(self.a)[0][4], 'debe quedar pendiente de subir')

    def test_conflict_keeps_a_copy(self):
        self.as_device('a')
        self.save(self.a, 'X.3MM', 'A1', '2026-01-01T10:00:00Z')
        sync.after_play(GID, self.a, self.cfg_a)
        self.as_device('b')
        sync.before_play(GID, self.b, self.cfg_b)
        self.save(self.b, 'X.3MM', 'B2', '2026-01-02T10:00:00Z')
        sync.after_play(GID, self.b, self.cfg_b)
        self.as_device('a')                     # A trabajó sin red y después de B
        self.save(self.a, 'X.3MM', 'A3', '2026-01-03T10:00:00Z')
        r = sync.after_play(GID, self.a, self.cfg_a)
        self.assertEqual(r.action, 'uploaded')
        self.assertTrue(r.conflict and 'conflicto-Deck' in r.conflict)
        content, _ = core.read_saves_zip(r.conflict)      # la copia se puede importar
        self.assertIn('X.3MM', content[GID])

    def test_remote_newer_is_not_overwritten_on_close(self):
        self.as_device('b')
        self.save(self.b, 'X.3MM', 'B', '2026-05-01T10:00:00Z')
        sync.after_play(GID, self.b, self.cfg_b)
        self.as_device('a')
        self.save(self.a, 'X.3MM', 'A', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a).action, 'remote-newer')

    def test_only_movies_are_synced(self):
        self.as_device('a')
        self.save(self.a, 'X.3MM', 'peli', '2026-01-01T10:00:00Z')
        write(self.path(self.a, 'sonido.wav'), b'RIFF')
        sync.after_play(GID, self.a, self.cfg_a)
        names = zip_names(os.path.join(self.cloud, 'CreadorPeliculas-sync', '3DMM.zip'))
        self.assertEqual(sorted(names), ['X.3MM', 'creador-saves.json'])

    def test_suggested_folder(self):
        home = os.path.join(self.t, 'home')
        os.makedirs(home)
        with mock.patch.object(os.path, 'expanduser', lambda p: p.replace('~', home)):
            self.assertEqual(sync.suggested_folder(), (core.saves_dir(), ''))     # sin programas: la carpeta de copias
            os.makedirs(os.path.join(home, 'Sync'))
            self.assertEqual(sync.suggested_folder(), (os.path.join(home, 'Sync'), 'Syncthing'))

    def test_folder_missing(self):
        cfg = {'sync': {'mode': 'folder', 'folder': os.path.join(self.t, 'no-existe')}}
        self.save(self.a, 'X.3MM', 'peli', '2026-01-01T10:00:00Z')
        with self.assertRaises(CpError) as c:
            sync.after_play(GID, self.a, cfg)
        self.assertEqual(c.exception.code, '3DM-SYN-002')
        self.assertTrue([r for r in sync.status(self.a) if r[0] == GID][0][4], 'debe quedar pendiente')

    def test_bad_remote_blocks_play_but_not_upload(self):
        d = os.path.join(self.cloud, 'CreadorPeliculas-sync')
        os.makedirs(d)
        entries = {'X.3MM': b'MZ' + b'\0' * 0x3A + b'\x40\0\0\0PE\0\0'}
        with open(os.path.join(d, '3DMM.zip'), 'wb') as f:
            f.write(make_zip(entries, manifest_for(GID, entries)))
        with self.assertRaises(CpError) as c:
            sync.before_play(GID, self.a, self.cfg_a)
        self.assertEqual(c.exception.code, '3DM-SYN-005')
        self.save(self.a, 'X.3MM', 'A', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a).action, 'uploaded')
        self.assertEqual(sync.before_play(GID, self.a, self.cfg_a).action, 'same')


class SyncValidationTests(unittest.TestCase):
    GOOD = {'Mi película.3MM': movie('una'), 'OTRA.3MM': movie('dos')}

    def assertRejected(self, data, gid=GID):
        with self.assertRaises(CpError) as c:
            sync.validate_bundle(gid, data)
        self.assertEqual(c.exception.code, '3DM-SYN-005')
        return c.exception.data['reason']

    def test_good(self):
        meta, files = sync.validate_bundle(GID, make_zip(self.GOOD, manifest_for(GID, self.GOOD)))
        self.assertEqual(set(files), set(self.GOOD))

    def test_rejections(self):
        g = self.GOOD
        exe = b'MZ' + b'\0' * 0x3A + b'\x40\0\0\0PE\0\0'
        bomb = MOVIE + b'\0' * (8 << 20)
        cases = {
            'ruta': make_zip(dict(g, **{'../x.3MM': movie('1')}), manifest_for(GID, g)),
            'carpeta': make_zip({'3DMM/A.3MM': movie('a')}, manifest_for(GID, {'3DMM/A.3MM': movie('a')})),
            'otro juego': make_zip(g, manifest_for('OTRO', g)),
            'no es película': make_zip({'3DMOVIE.EXE': b'x'}, manifest_for(GID, {'3DMOVIE.EXE': b'x'})),
            'sin manifiesto': make_zip(g),
            'archivo extra': make_zip(dict(g, **{'B.3MM': movie('b')}), manifest_for(GID, g)),
            'falta archivo': make_zip({'OTRA.3MM': g['OTRA.3MM']}, manifest_for(GID, g)),
            'hash': make_zip(dict(g, **{'OTRA.3MM': movie('cambiada')}), manifest_for(GID, g)),
            'futuro': make_zip(g, manifest_for(GID, g, updated='2099-01-01T00:00:00Z')),
            'clave extra': make_zip(g, manifest_for(GID, g, extra=1)),
            'ejecutable': make_zip({'A.3MM': exe}, manifest_for(GID, {'A.3MM': exe})),
            'zip adentro': make_zip({'A.3MM': b'PK\x03\x04rest'}, manifest_for(GID, {'A.3MM': b'PK\x03\x04rest'})),
            'sin firma CHN2': make_zip({'A.3MM': b'RIFF datos'}, manifest_for(GID, {'A.3MM': b'RIFF datos'})),
            'bomba': make_zip({'A.3MM': bomb}, manifest_for(GID, {'A.3MM': bomb})),
            'no zip': b'hola',
        }
        for why, data in cases.items():
            with self.subTest(why):
                self.assertRejected(data)
        self.assertIn('no es una película', self.assertRejected(cases['sin firma CHN2']))
        dup = io.BytesIO()
        with zipfile.ZipFile(dup, 'w') as z:
            z.writestr('creador-saves.json', json.dumps(manifest_for(GID, {'a.3mm': movie('1')})))
            z.writestr('a.3mm', movie('1'))
            z.writestr('A.3MM', movie('2'))
        self.assertIn('repetidos', self.assertRejected(dup.getvalue()))
        many = {'P%04d.3MM' % i: movie(str(i)) for i in range(core.read_json(os.path.join(core.DATA_DIR, 'sync.json'))['limits']['maxEntries'] + 5)}
        self.assertIn('demasiados', self.assertRejected(make_zip(many, manifest_for(GID, many))))

    def test_linux_fixture(self):
        # tests/fixtures/sync-linux-3DMM.zip lo genera build_bundle (Linux); Run-Tests.ps1 lo valida en Windows.
        with open(os.path.join(HERE, 'fixtures', 'sync-linux-3DMM.zip'), 'rb') as f:
            meta, files = sync.validate_bundle(GID, f.read())
        self.assertEqual(meta['platform'], 'linux')
        self.assertEqual(sorted(files), ['Mi película.3MM'])
        self.assertEqual(meta['updatedAt'], '2026-01-01T10:00:00Z')

    def test_windows_bundle(self):
        # tests/fixtures/sync-windows-3DMM.zip lo genera New-CpSyncBundle (Windows).
        p = os.path.join(HERE, 'fixtures', 'sync-windows-3DMM.zip')
        if not os.path.exists(p):
            self.skipTest('falta sync-windows-3DMM.zip (lo genera Run-Tests.ps1 en Windows)')
        with open(p, 'rb') as f:
            meta, files = sync.validate_bundle(GID, f.read())
        self.assertEqual(meta['platform'], 'windows')
        self.assertEqual(sorted(files), ['Película de PC.3MM'])
        self.assertTrue(all(b.startswith(b'CHN2') for b in files.values()))


class FakeGoogle(http.server.BaseHTTPRequestHandler):
    """Imita los endpoints de OAuth y Drive que usa sync.DriveBackend."""
    files = {}
    fail = []          # códigos a devolver en las próximas peticiones a Drive
    tokens_ok = True
    calls = []

    def log_message(self, *a):
        pass

    def reply(self, status, obj=None, raw=None, ctype='application/json'):
        body = raw if raw is not None else json.dumps(obj or {}).encode()
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get('Content-Length') or 0))

    def handle_any(self):
        u = urllib.parse.urlparse(self.path)
        FakeGoogle.calls.append((self.command, u.path))
        data = self.body()
        if u.path == '/device/code':
            return self.reply(200, {'device_code': 'DEV', 'user_code': 'ABCD-EFGH', 'verification_url': 'https://www.google.com/device',
                                    'interval': 1, 'expires_in': 600})
        if u.path == '/token':
            f = urllib.parse.parse_qs(data.decode())
            if f.get('grant_type') == ['urn:ietf:params:oauth:grant-type:device_code']:
                payload = base64.urlsafe_b64encode(json.dumps({'email': 'ana@example.com'}).encode()).decode().rstrip('=')
                return self.reply(200, {'access_token': 'AT', 'refresh_token': 'RT', 'expires_in': 3600, 'id_token': 'x.%s.y' % payload})
            if not FakeGoogle.tokens_ok:
                return self.reply(400, {'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'})
            return self.reply(200, {'access_token': 'AT', 'expires_in': 3600})
        if u.path == '/revoke':
            return self.reply(200)
        if self.headers.get('Authorization') != 'Bearer AT':
            return self.reply(401, {'error': {'message': 'Invalid Credentials'}})
        if FakeGoogle.fail:
            code = FakeGoogle.fail.pop(0)
            reason = 'storageQuotaExceeded' if code == 403 else 'backendError'
            return self.reply(code, {'error': {'message': 'falla simulada', 'errors': [{'reason': reason}]}})
        if u.path == '/drive/v3/files' and self.command == 'GET':
            return self.reply(200, {'files': [dict(id=k, **{x: v[x] for x in ('name', 'appProperties')}) for k, v in FakeGoogle.files.items()]})
        if u.path.startswith('/drive/v3/files/') and self.command == 'GET':
            f = FakeGoogle.files.get(u.path.rsplit('/', 1)[1])
            return self.reply(200, raw=f['data'], ctype='application/zip') if f else self.reply(404, {'error': {'message': 'no'}})
        if u.path.startswith('/upload/drive/v3/files'):
            boundary = self.headers['Content-Type'].split('boundary=')[1].encode()
            parts = data.split(b'--' + boundary)
            meta = json.loads(parts[1].split(b'\r\n\r\n', 1)[1].rstrip(b'\r\n'))
            content = parts[2].split(b'\r\n\r\n', 1)[1][:-2]
            fid = u.path.rsplit('/', 1)[1] if self.command == 'PATCH' else 'id%d' % (len(FakeGoogle.files) + 1)
            if self.command == 'POST':
                assert meta.get('parents') == ['appDataFolder']
            FakeGoogle.files[fid] = {'name': meta['name'], 'appProperties': meta['appProperties'], 'data': content}
            return self.reply(200, {'id': fid})
        return self.reply(404, {'error': {'message': 'ruta desconocida'}})

    do_GET = do_POST = do_PATCH = handle_any


class SyncDriveTests(SyncTestBase):
    def setUp(self):
        super().setUp()
        FakeGoogle.files, FakeGoogle.fail, FakeGoogle.tokens_ok, FakeGoogle.calls = {}, [], True, []
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGoogle)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        base = 'http://127.0.0.1:%d' % self.server.server_port
        self.conf = dict(sync.google_settings(), clientId='cid', clientSecret='sec', authBase=base, apiBase=base, retryDelay=0.01)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        super().tearDown()

    def backend(self, name):
        return sync.DriveBackend(sync.TokenStore(os.path.join(self.t, 'token-%s.json' % name)), conf=self.conf)

    def test_link_and_roundtrip(self):
        da, db = self.backend('a'), self.backend('b')
        code = da.start_link()
        self.assertEqual(code['user_code'], 'ABCD-EFGH')
        self.assertEqual(da.poll_link(code['device_code']), 'ana@example.com')
        self.assertEqual(da.linked_email(), 'ana@example.com')
        db.poll_link('DEV')
        self.as_device('a')
        self.save(self.a, 'X.3MM', 'Ana', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a, da).action, 'uploaded')
        self.save(self.a, 'X.3MM', 'Ana2', '2026-01-02T10:00:00Z')
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a, da).action, 'uploaded')
        self.assertEqual(len(FakeGoogle.files), 1, 'la segunda subida debe actualizar el mismo archivo')
        self.as_device('b')
        self.assertEqual(sync.before_play(GID, self.b, self.cfg_b, db).action, 'downloaded')
        self.assertIn(b'Ana2', read(self.path(self.b, 'X.3MM'), 'rb'))
        db.unlink()
        self.assertIsNone(db.linked_email())

    def test_errors(self):
        d = self.backend('a')
        d.poll_link('DEV')
        self.save(self.a, 'X.3MM', 'a', '2026-01-01T10:00:00Z')
        FakeGoogle.fail = [503, 500]                       # pasajero: se reintenta
        self.assertEqual(sync.after_play(GID, self.a, self.cfg_a, d).action, 'uploaded')
        FakeGoogle.fail = [500] * 10
        with self.assertRaises(CpError) as c:
            sync.before_play(GID, self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, '3DM-SYN-006')
        FakeGoogle.fail = [403]
        self.save(self.a, 'X.3MM', 'b', '2026-01-02T10:00:00Z')
        with self.assertRaises(CpError) as c:
            sync.after_play(GID, self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, '3DM-SYN-004')
        FakeGoogle.fail = []
        d.access = None
        FakeGoogle.tokens_ok = False
        with self.assertRaises(CpError) as c:
            sync.after_play(GID, self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, '3DM-SYN-003')
        port = self.server.server_port
        self.server.shutdown()
        self.server.server_close()
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGoogle)     # para el tearDown
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        d.conf = dict(d.conf, apiBase='http://127.0.0.1:%d' % port, authBase='http://127.0.0.1:%d' % port)
        d.access = None
        with self.assertRaises(CpError) as c:
            sync.after_play(GID, self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, '3DM-SYN-001')

    def test_client_from_ui(self):
        with mock.patch.object(sync, 'CLIENT_FILE', os.path.join(self.t, 'google-client.json')), \
                mock.patch.dict(os.environ, {'CP3D_GOOGLE_CLIENT_ID': '', 'CP3D_GOOGLE_CLIENT_SECRET': ''}):
            self.assertIn('googleusercontent', sync.save_google_client('no-es-un-id', 'GOCSPX-abcdefghijkl'))
            self.assertIsNotNone(sync.save_google_client('123-abc.apps.googleusercontent.com', 'corto'))
            self.assertIsNone(sync.save_google_client(' 123-abc.apps.googleusercontent.com ', 'GOCSPX-abcdefghijkl'))
            self.assertEqual(sync.google_settings()['clientId'], '123-abc.apps.googleusercontent.com')
            self.assertTrue(sync.drive_available())

    def test_not_configured(self):
        d = sync.DriveBackend(sync.TokenStore(os.path.join(self.t, 't.json')), conf=dict(self.conf, clientId=''))
        with self.assertRaises(CpError) as c:
            d.start_link()
        self.assertEqual(c.exception.code, '3DM-SYN-008')


GAME_NAME = '3D Creador de Películas'


class SteamTests(unittest.TestCase):
    def test_vdf_roundtrip_and_merge(self):
        other = {'appid': -123, 'AppName': 'Otro juego', 'Exe': '"/usr/bin/otro"', 'tags': {'0': 'X'}, 'LastPlayTime': 5}
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'shortcuts.vdf')
            with open(p, 'wb') as f:
                f.write(steam.vdf_dump({'shortcuts': {'0': other}}))
            exe = '"/home/deck/CreadorPeliculas/app/creador.sh"'
            wanted = [{'appid': steam.shortcut_appid(exe, n), 'AppName': n, 'Exe': exe, 'LaunchOptions': o,
                       'tags': {'0': steam.TAG}, 'LastPlayTime': 0}
                      for n, o in ((steam.LIBRARY_NAME, ''), (GAME_NAME, '--play 3DMM'))]
            steam.update_shortcuts_file(p, [dict(w) for w in wanted])
            steam.update_shortcuts_file(p, [dict(w) for w in wanted])        # no duplica
            doc = steam.vdf_load(read(p, 'rb'))
            names = [e['AppName'] for e in doc['shortcuts'].values()]
            self.assertEqual(sorted(names), sorted([steam.LIBRARY_NAME, GAME_NAME, 'Otro juego']))
            self.assertTrue(os.path.exists(p + '.creador.bak'))

    def test_windows_fixture(self):
        # Los mismos archivos los lee CreadorPeliculas.Steam.psm1 (Run-Tests.ps1): el VDF se reescribe idéntico y el
        # appid es el del acceso de Windows al juego: crc32('"C:\x\powershell.exe"' + nombre) | 0x80000000, con signo.
        with open(os.path.join(HERE, 'fixtures', 'shortcuts-linux.vdf'), 'rb') as f:
            data = f.read()
        self.assertEqual(steam.vdf_dump(steam.vdf_load(data)), data)
        doc = steam.vdf_load(data)
        self.assertEqual(doc['shortcuts']['1']['AppName'], GAME_NAME)
        self.assertEqual(doc['shortcuts']['1']['grande'], 5000000000)
        with open(os.path.join(HERE, 'fixtures', 'appid.txt')) as f:
            self.assertEqual(steam.shortcut_appid('"C:\\x\\powershell.exe"', GAME_NAME), int(f.read()))

    def test_appid(self):
        a = steam.shortcut_appid('"/x/creador.sh"', GAME_NAME)
        self.assertLess(a, 0)                          # bit alto encendido, entero con signo
        self.assertEqual(a, (zlib.crc32(('"/x/creador.sh"' + GAME_NAME).encode('utf-8')) | 0x80000000) - (1 << 32))

    def test_artwork(self):
        # Imagen sintética de 512x384 como 3DMVMAIN.DIB: fondo crema (240) a la izquierda con un «logo» oscuro,
        # ilustración a la derecha.
        def px(x, y):
            if x < 228:
                return 0 if 20 <= y < 60 and 10 <= x < 200 else 240
            return 100 + (x + y) % 100
        with tempfile.TemporaryDirectory() as t:
            fake_install(t)
            g = core.game(GID)
            write(core.local_path(os.path.join(t, 'games', GID), g['art']['source']), bmp8(512, 384, px))
            out = art.make_art(GID, t)
            sizes = {n: png_size(os.path.join(out, n)) for n in art.LAYOUTS}
            self.assertEqual(sizes, {'portrait.png': (600, 900), 'header.png': (920, 430), 'hero.png': (1920, 620),
                                     'logo.png': (900, 230)})
            # El logo tiene fondo transparente (se quitó el crema del catálogo).
            raw = read(os.path.join(out, 'logo.png'), 'rb')
            self.assertIn(b'IDAT', raw)
            # Al agregar a Steam se copian a config/grid con el appid sin signo.
            cfgdir = os.path.join(t, 'steam', 'userdata', '42', 'config')
            os.makedirs(cfgdir)
            with mock.patch.object(steam, 'user_config_dirs', lambda: [cfgdir]):
                wanted = [{'appid': steam.shortcut_appid('"/x/creador.sh"', GAME_NAME), 'AppName': GAME_NAME}]
                steam.install_art(t, wanted)
            u = wanted[0]['appid'] & 0xFFFFFFFF
            self.assertEqual(sorted(os.listdir(os.path.join(cfgdir, 'grid'))),
                             sorted(['%dp.png' % u, '%d.png' % u, '%d_hero.png' % u, '%d_logo.png' % u]))

    def test_logo_is_transparent(self):
        img = art.Image(4, 1, bytearray(b'\xf0\xf0\xe0\xff' * 2 + b'\x00\x00\x00\xff' * 2))
        art.color_key(img, (0xF0, 0xF0, 0xE0), 40)
        self.assertEqual(bytes(img.data), b'\0' * 8 + b'\x00\x00\x00\xff' * 2)


class ProtonTests(unittest.TestCase):
    def test_prefers_recommended(self):
        tools = [proton.ProtonTool(n, '/x/' + n) for n in ('Proton 11.0', 'Proton - Experimental', 'Proton 10.0', 'Proton 9.0 (Beta)')]
        self.assertEqual(sorted(tools, key=lambda t: t.rank(), reverse=True)[0].name, 'Proton 10.0')
        tools = [proton.ProtonTool(n, '/x/' + n) for n in ('Proton 8.0', 'Proton 11.0', 'Proton - Experimental')]
        self.assertEqual(sorted(tools, key=lambda t: t.rank(), reverse=True)[0].name, 'Proton 11.0')


@unittest.skipUnless(os.environ.get('CP3D_ISOS'), 'definí CP3D_ISOS para probar la imagen real')
class IsoTests(unittest.TestCase):
    def test_find_and_install(self):
        isos, _ = core.find_isos(os.environ['CP3D_ISOS'])
        ok = [i for i in isos if i.status == 'ok']
        self.assertTrue(ok)
        i = ok[0]
        self.assertEqual(i.game_id, GID)
        with Iso(i.path) as iso:
            self.assertTrue(iso.find(core.game(GID)['iso']['keyFile']))
            self.assertEqual(iso.volume_label, core.game(GID)['iso']['label'])
        with tempfile.TemporaryDirectory() as t:
            core.install_game(GID, i.path, t, player='Ana')
            hd = os.path.join(t, 'games', GID)
            pd = core.local_path(hd, 'MSKIDS\\3D Creador de Películas')
            self.assertTrue(os.path.exists(core.local_path(hd, core.game(GID)['exe'])))
            self.assertTrue(os.path.exists(os.path.join(pd, 'BUILDING.CHK')), 'todo el contenido del CD en el disco')
            self.assertTrue(os.path.exists(os.path.join(pd, '3DMM.HLP')))
            self.assertEqual(len(os.listdir(core.local_path(hd, 'MSKIDS\\Users\\Melanie'))), 6)
            self.assertEqual(len(os.listdir(core.local_path(hd, 'MSKIDS\\Users\\McZee'))), 17)
            self.assertEqual(sorted(n.upper() for n in os.listdir(core.fonts_dir(GID, t))), ['COMIC.TTF', 'COMICBD.TTF'])
            self.assertTrue(os.path.exists(core.local_path(hd, core.game(GID)['art']['source'])))
            self.assertFalse(os.path.exists(core.player_dir(GID, t, 'Ana')), 'la crea el juego la primera vez')
            self.assertIn(b'HomeDirectory=sz:\r\n', read(core.registry_file(GID, t), 'rb'))
            out = art.make_art(GID, t)
            self.assertEqual(png_size(os.path.join(out, 'portrait.png')), (600, 900))


if __name__ == '__main__':
    unittest.main()
