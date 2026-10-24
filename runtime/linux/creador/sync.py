# sync.py — sincronización de películas (películas) entre equipos (Windows, Linux y Steam Deck).
# Refleja src/Core/CreadorPeliculas.Sync.psm1: mismo formato de paquete, mismas reglas de validación
# (src/data/sync.json) y mismas decisiones, para que un equipo con Windows y otro con Linux
# compartan la misma carpeta o la misma cuenta de Google Drive.
#
#   Paquete:  <ID>.zip con los archivos de película sueltos + creador-saves.json (format 2)
#   Destino:  modo «folder»: <carpeta>/CreadorPeliculas-sync/<ID>.zip
#             modo «drive»:  appDataFolder de Google Drive (carpeta privada de la app)
#   Regla:    gana siempre la película más reciente (fecha de modificación de sus archivos);
#             la que pierde queda como copia en «Creador de Películas 3D - copias».

import base64
import datetime
import hashlib
import io
import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

from . import core, errors
from .errors import CpError, log

STATE_FILE = os.path.join(core.CONFIG_DIR, 'sync-state.json')
TOKEN_FILE = os.path.join(core.CONFIG_DIR, 'sync-token.json')
CLIENT_FILE = os.path.join(core.CONFIG_DIR, 'google-client.json')
GOOGLE_CONSOLE_URL = 'https://console.cloud.google.com/apis/library/drive.googleapis.com'
DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive.appdata'
FORMAT = 2
MODES = ('off', 'folder', 'drive')

_settings = None


def settings():
    global _settings
    if _settings is None:
        with open(os.path.join(core.DATA_DIR, 'sync.json'), encoding='utf-8-sig') as f:
            _settings = json.load(f)
    return _settings


def limits():
    return settings()['limits']


def google_settings():
    """Cliente OAuth: variables de entorno > google-client.json del equipo (lo carga «Cómo habilitarlo…») > sync.json."""
    g = dict(settings()['google'])
    local = core.read_json(CLIENT_FILE) or {}
    if not isinstance(local, dict):
        local = {}
    g['clientId'] = os.environ.get('CP3D_GOOGLE_CLIENT_ID') or local.get('clientId') or g.get('clientId') or ''
    g['clientSecret'] = os.environ.get('CP3D_GOOGLE_CLIENT_SECRET') or local.get('clientSecret') or g.get('clientSecret') or ''
    return g


CLIENT_ID_RE = re.compile(r'^[0-9]+-[0-9a-z]+\.apps\.googleusercontent\.com$')


def save_google_client(client_id, client_secret):
    """Guarda el cliente OAuth pegado en la interfaz. Devuelve un mensaje si los datos no parecen válidos, o None."""
    client_id, client_secret = (client_id or '').strip(), (client_secret or '').strip()
    if not CLIENT_ID_RE.match(client_id):
        return 'El ID de cliente tiene que terminar en «.apps.googleusercontent.com».'
    if not re.match(r'^[A-Za-z0-9_-]{10,100}$', client_secret):
        return 'Pegá el secreto del cliente completo (por ejemplo, «GOCSPX-…»).'
    core.write_json(CLIENT_FILE, {'clientId': client_id, 'clientSecret': client_secret})
    log('Info', 'Cliente OAuth de Google configurado en este equipo')
    return None


def drive_available():
    return bool(google_settings()['clientId'])


# ---------------------------------------------------------------------------
# Configuración y estado local
# ---------------------------------------------------------------------------

def sync_config(cfg):
    """La sección «sync» de config.json, completa (genera el identificador del equipo la primera vez)."""
    s = cfg.get('sync')
    if not isinstance(s, dict):
        s = {}
    s.setdefault('mode', 'off')
    if s['mode'] not in MODES:
        s['mode'] = 'off'
    s.setdefault('folder', None)
    if not s.get('deviceId'):
        s['deviceId'] = uuid.uuid4().hex
    if not s.get('deviceName'):
        s['deviceName'] = (socket.gethostname() or 'equipo')[:64]
    cfg['sync'] = s
    return s


def suggested_folder():
    """Carpeta para proponer en «Carpeta sincronizada»: la de un programa de sincronización (Syncthing,
    Dropbox, Google Drive montado con rclone o GNOME) o, si no hay, la carpeta de películas. Devuelve (ruta, origen)."""
    home = os.path.expanduser('~')
    for path, source in ((os.path.join(home, 'Sync'), 'Syncthing'), (os.path.join(home, 'Dropbox'), 'Dropbox'),
                         (os.path.join(home, 'GoogleDrive'), 'Google Drive'), (os.path.join(home, 'Google Drive'), 'Google Drive'),
                         (os.path.join(home, 'OneDrive'), 'OneDrive')):
        if os.path.isdir(path):
            return path, source
    return core.saves_dir(), ''


def enabled(cfg):
    s = cfg.get('sync')
    return isinstance(s, dict) and s.get('mode') in ('folder', 'drive')


def load_state():
    st = core.read_json(STATE_FILE) or {}
    return st if isinstance(st, dict) else {}


def save_state(st):
    core.write_json(STATE_FILE, st)


def _mark_synced(gid, info, device=None):
    st = load_state()
    st[gid] = {'lastSyncedHash': info['bundleHash'], 'lastSyncedUpdatedAt': info['updatedAt'],
               'lastSyncAt': now_iso(), 'pendingUpload': False, 'lastDevice': device or info.get('deviceName')}
    save_state(st)


def _mark_pending(gid, pending=True):
    st = load_state()
    st.setdefault(gid, {})['pendingUpload'] = pending
    save_state(st)


# ---------------------------------------------------------------------------
# Fechas y hash
# ---------------------------------------------------------------------------

ISO_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def to_iso(ts):
    return datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def from_iso(text):
    return datetime.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()


def bundle_hash(files):
    """Hash del conjunto de archivos (sin distinguir mayúsculas en los nombres; igual en Windows)."""
    lines = sorted('%s:%s' % (f['name'].lower(), f['sha256'].lower()) for f in files)
    return hashlib.sha256('\n'.join(lines).encode('utf-8')).hexdigest()


# ---------------------------------------------------------------------------
# Películas locales
# ---------------------------------------------------------------------------

def is_sync_name(g, name):
    """¿Es un archivo de película que se sincroniza? (las películas menos los INI de configuración de cada equipo)."""
    if not core.is_save_name(g, name):
        return False
    return name.lower() not in {x.lower() for x in g.get('syncExclude') or []}


def sync_files(gid, root):
    g = core.game(gid)
    return [p for p in core.save_files(gid, root) if is_sync_name(g, os.path.basename(p))]


def local_info(gid, root):
    """Descripción de las películas locales: {files, bundleHash, updatedAt} o None si no hay."""
    files = []
    for p in sync_files(gid, root):
        with open(p, 'rb') as f:
            data = f.read()
        files.append({'name': os.path.basename(p), 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                      'mtime': to_iso(os.path.getmtime(p)), 'path': p})
    if not files:
        return None
    return {'files': files, 'bundleHash': bundle_hash(files), 'updatedAt': max(f['mtime'] for f in files)}


def build_bundle(gid, root, cfg, info=None):
    """Arma el paquete (bytes del zip) con las películas locales. Devuelve (datos, manifiesto)."""
    info = info or local_info(gid, root)
    s = sync_config(cfg)
    manifest = {'format': FORMAT, 'createdAt': now_iso(), 'platform': 'linux', 'games': [gid], 'gameId': gid,
                'updatedAt': info['updatedAt'], 'deviceId': s['deviceId'], 'deviceName': s['deviceName'],
                'bundleHash': info['bundleHash'],
                'files': [{k: f[k] for k in ('name', 'size', 'sha256', 'mtime')} for f in info['files']]}
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(core.SAVES_MANIFEST, json.dumps(manifest, ensure_ascii=False, indent=2))
        for f in info['files']:
            with open(f['path'], 'rb') as src:
                z.writestr(f['name'], src.read())
    return buf.getvalue(), manifest


# ---------------------------------------------------------------------------
# Validación de lo descargado (la carpeta o la cuenta pueden tener contenido ajeno)
# ---------------------------------------------------------------------------

def _reject(gid, reason):
    raise CpError('3DM-SYN-005', game=core.game(gid)['name'], reason=reason)


def _is_executable(data):
    if data[:2] == b'MZ' and len(data) >= 0x40:
        off = int.from_bytes(data[0x3C:0x40], 'little')
        if 0 < off <= len(data) - 2 and data[off:off + 2] in (b'PE', b'NE', b'LE', b'LX'):
            return True
    for magic in settings()['forbiddenMagic']:
        if data.startswith(bytes.fromhex(magic)):
            return True
    return False


def has_save_magic(g, data):
    """Si el juego declara «saveMagic» (hex), cada archivo tiene que empezar con alguna de esas firmas
    (lista blanca; para 3DMM, «CHN2», los archivos de Kauai)."""
    magic = g.get('saveMagic') or []
    return not magic or any(data.startswith(bytes.fromhex(m)) for m in magic)


INI_LINE = re.compile(r'^\s*(\[[^\]]*\]|[;#].*|[^=\[]+=.*)?\s*$')


def _check_ini(data):
    """Texto INI: sin bytes de control (salvo tab/CR/LF), líneas cortas, solo secciones, claves y comentarios."""
    if any(b < 0x20 and b not in (9, 10, 13) for b in data):
        return 'tiene bytes binarios'
    for line in data.decode('latin-1').split('\n'):
        line = line.rstrip('\r')
        if len(line) > limits()['maxIniLine']:
            return 'tiene una línea demasiado larga'
        if not INI_LINE.match(line):
            return 'tiene líneas que no son de un INI'
    return None


def _str(v, max_len=200):
    return isinstance(v, str) and 0 < len(v) <= max_len


def validate_bundle(gid, data, expected_hash=None):
    """Controla un paquete descargado. Devuelve (manifiesto, {nombre: bytes}). Ante cualquier
    problema lanza 3DM-SYN-005 con el motivo; nunca escribe nada en disco."""
    lim = limits()
    g = core.game(gid)
    if len(data) > lim['maxZipBytes']:
        _reject(gid, 'el paquete pesa demasiado (%d bytes)' % len(data))
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, ValueError, OSError) as e:
        _reject(gid, 'no es un zip válido (%s)' % e)
    with z:
        infos = z.infolist()
        if len(infos) > lim['maxEntries']:
            _reject(gid, 'tiene demasiados archivos (%d)' % len(infos))
        seen = set()
        for i in infos:
            n = i.filename
            if not n or n.endswith('/') or '/' in n or '\\' in n or ':' in n or n in ('.', '..') \
                    or any(ord(c) < 32 or ord(c) == 127 for c in n):
                _reject(gid, 'tiene una ruta o un nombre no permitido («%s»)' % n[:80])
            if n.lower() in seen:
                _reject(gid, 'tiene archivos repetidos («%s»)' % n)
            seen.add(n.lower())
            if i.flag_bits & 0x1:
                _reject(gid, 'tiene archivos cifrados')
            if i.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                _reject(gid, 'usa una compresión no admitida')
        if core.SAVES_MANIFEST not in seen:
            _reject(gid, 'le falta el manifiesto %s' % core.SAVES_MANIFEST)

        def read_limited(info, limit):
            if info.file_size > limit:
                _reject(gid, '«%s» pesa demasiado' % info.filename)
            if info.file_size > lim['ratioMinBytes'] and info.file_size > lim['maxRatio'] * max(1, info.compress_size):
                _reject(gid, '«%s» está comprimido de forma sospechosa' % info.filename)
            try:
                with z.open(info) as f:
                    out = f.read(limit + 1)
            except (zipfile.BadZipFile, OSError, RuntimeError, NotImplementedError, EOFError) as e:
                _reject(gid, '«%s» no se pudo leer (%s)' % (info.filename, e))
            if len(out) > limit:
                _reject(gid, '«%s» pesa demasiado' % info.filename)
            return out

        by_name = {i.filename: i for i in infos}
        try:
            meta = json.loads(read_limited(by_name[core.SAVES_MANIFEST], lim['maxManifestBytes']).decode('utf-8-sig'))
        except (ValueError, UnicodeDecodeError):
            _reject(gid, 'el manifiesto está dañado')
        keys = {'format', 'createdAt', 'platform', 'games', 'gameId', 'updatedAt', 'deviceId', 'deviceName', 'bundleHash', 'files'}
        if not isinstance(meta, dict) or set(meta) != keys:
            _reject(gid, 'el manifiesto no tiene el formato esperado')
        if meta['format'] != FORMAT or meta['gameId'] != gid or meta['games'] != [gid]:
            _reject(gid, 'el paquete no es de este juego o es de otra versión')
        if meta['platform'] not in ('windows', 'linux') or not _str(meta['deviceId'], 64) or not _str(meta['deviceName'], 64):
            _reject(gid, 'el manifiesto tiene datos del equipo inválidos')
        for k in ('createdAt', 'updatedAt'):
            if not isinstance(meta[k], str) or not ISO_RE.match(meta[k]):
                _reject(gid, 'el manifiesto tiene fechas inválidas')
        if from_iso(meta['updatedAt']) > time.time() + lim['futureToleranceSeconds']:
            _reject(gid, 'la película tiene fecha en el futuro (%s)' % meta['updatedAt'])
        if not isinstance(meta['bundleHash'], str) or not re.match(r'^[0-9a-f]{64}$', meta['bundleHash']):
            _reject(gid, 'el manifiesto tiene un hash inválido')
        files_meta = meta['files']
        if not isinstance(files_meta, list) or not files_meta:
            _reject(gid, 'el manifiesto no lista archivos')
        listed = {}
        for f in files_meta:
            if not isinstance(f, dict) or set(f) != {'name', 'size', 'sha256', 'mtime'}:
                _reject(gid, 'el manifiesto lista archivos con formato inválido')
            if not isinstance(f['name'], str) or not is_sync_name(g, f['name']):
                _reject(gid, '«%s» no es un archivo de película de este juego' % str(f['name'])[:80])
            if f['name'].lower() in {n.lower() for n in listed}:
                _reject(gid, 'el manifiesto repite «%s»' % f['name'])
            if not isinstance(f['size'], int) or isinstance(f['size'], bool) or not 0 <= f['size'] <= lim['maxFileBytes']:
                _reject(gid, '«%s» tiene un tamaño inválido' % f['name'])
            if not isinstance(f['sha256'], str) or not re.match(r'^[0-9a-f]{64}$', f['sha256']):
                _reject(gid, '«%s» tiene un hash inválido' % f['name'])
            if not isinstance(f['mtime'], str) or not ISO_RE.match(f['mtime']) or f['mtime'] > meta['updatedAt']:
                _reject(gid, '«%s» tiene una fecha inválida' % f['name'])
            listed[f['name']] = f
        if set(by_name) - {core.SAVES_MANIFEST} != set(listed):
            _reject(gid, 'los archivos del zip no coinciden con el manifiesto')
        if bundle_hash(files_meta) != meta['bundleHash'] or (expected_hash and expected_hash != meta['bundleHash']):
            _reject(gid, 'el hash del paquete no coincide')
        total = 0
        contents = {}
        for name, f in listed.items():
            body = read_limited(by_name[name], lim['maxFileBytes'])
            total += len(body)
            if total > lim['maxTotalBytes']:
                _reject(gid, 'el paquete descomprimido pesa demasiado')
            if len(body) != f['size'] or hashlib.sha256(body).hexdigest() != f['sha256']:
                _reject(gid, '«%s» está dañado o fue modificado' % name)
            if _is_executable(body):
                _reject(gid, '«%s» contiene un programa o un archivo comprimido' % name)
            if not has_save_magic(core.game(gid), body):
                _reject(gid, '«%s» no es una película válida' % name)
            if name.lower().endswith('.ini'):
                why = _check_ini(body)
                if why:
                    _reject(gid, '«%s» %s' % (name, why))
            contents[name] = body
    return meta, contents


def apply_bundle(gid, root, meta, contents):
    """Reemplaza las películas locales por las descargadas (ya validadas). Antes guarda una copia."""
    if core.running_game(root):
        raise CpError('3DM-RUN-001')
    hd = core.player_dir(gid, root)
    mtimes = {f['name']: from_iso(f['mtime']) for f in meta['files']}

    def action():
        os.makedirs(hd, exist_ok=True)
        backup = core.backup_saves(gid, root)
        for p in sync_files(gid, root):
            core.make_writable(p)
            os.remove(p)
        for name, body in contents.items():
            tmp = os.path.join(hd, '.%s.sync.tmp' % name)
            with open(tmp, 'wb') as out:
                out.write(body)
            os.utime(tmp, (mtimes[name], mtimes[name]))
            os.replace(tmp, os.path.join(hd, name))
        log('Info', 'Película de %s descargada (%s, de «%s»)' % (gid, meta['updatedAt'], meta['deviceName']))
        return backup

    return errors.step('Aplicar película sincronizada ' + gid, action, '3DM-SYN-007', game=core.game(gid)['name'], detail='')


# ---------------------------------------------------------------------------
# Destinos
# ---------------------------------------------------------------------------

NO_HASH = '0' * 64
EPOCH = '1970-01-01T00:00:00Z'


class RemoteInfo:
    """Lo que hay del otro lado. error: CpError si el paquete existe pero no pasó la validación."""

    def __init__(self, bundle_hash_, updated_at, device_name, ref=None, error=None):
        self.bundleHash, self.updatedAt, self.deviceName, self.ref, self.error = bundle_hash_, updated_at, device_name, ref, error


class FolderBackend:
    """Una carpeta común (Google Drive para escritorio, OneDrive, Dropbox, Syncthing, pendrive, red)."""

    kind = 'folder'

    def __init__(self, folder):
        self.folder = folder
        self.dir = os.path.join(folder or '', settings()['folderName'])
        self._cache = {}

    def _fail(self, gid, op, e):
        raise CpError('3DM-SYN-002', e, game=core.game(gid)['name'] if gid else 'los juegos', op=op, path=self.folder,
                      detail=str(e))

    def check(self):
        if not self.folder or not os.path.isdir(self.folder):
            self._fail(None, 'usar', FileNotFoundError('la carpeta no existe'))
        try:
            os.makedirs(self.dir, exist_ok=True)
            probe = os.path.join(self.dir, '.creador-probe-%s.tmp' % uuid.uuid4().hex[:8])
            with open(probe, 'w') as f:
                f.write('ok')
            os.remove(probe)
        except OSError as e:
            self._fail(None, 'escribir', e)

    def _path(self, gid):
        return os.path.join(self.dir, gid + '.zip')

    def get_meta(self, gid):
        if not self.folder or not os.path.isdir(self.folder):
            self._fail(gid, 'leer', FileNotFoundError('la carpeta no existe'))
        p = self._path(gid)
        if not os.path.exists(p):
            return None
        try:
            with open(p, 'rb') as f:
                data = f.read(limits()['maxZipBytes'] + 1)
        except OSError as e:
            self._fail(gid, 'leer', e)
        try:
            meta, _ = validate_bundle(gid, data)
        except CpError as e:
            return RemoteInfo(NO_HASH, EPOCH, '?', error=e)
        self._cache[gid] = data
        return RemoteInfo(meta['bundleHash'], meta['updatedAt'], meta['deviceName'])

    def download(self, gid, remote):
        if gid in self._cache:
            return self._cache.pop(gid)
        try:
            with open(self._path(gid), 'rb') as f:
                return f.read(limits()['maxZipBytes'] + 1)
        except OSError as e:
            self._fail(gid, 'leer', e)

    def upload(self, gid, data, manifest, remote):
        try:
            os.makedirs(self.dir, exist_ok=True)
            tmp = os.path.join(self.dir, '.%s.zip.tmp' % gid)
            with open(tmp, 'wb') as f:
                f.write(data)
            os.replace(tmp, self._path(gid))
        except OSError as e:
            self._fail(gid, 'guardar', e)


class HttpResponse:
    def __init__(self, status, body, headers=None):
        self.status, self.body, self.headers = status, body, headers or {}

    def json(self):
        try:
            return json.loads(self.body.decode('utf-8') or '{}')
        except ValueError:
            return {}


class NetworkError(Exception):
    """No hubo respuesta HTTP (sin red, DNS, tiempo agotado, TLS)."""


def urllib_transport(method, url, headers=None, body=None, timeout=15):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return HttpResponse(r.status, r.read(limits()['maxZipBytes'] + 65536), dict(r.headers))
    except urllib.error.HTTPError as e:
        with e:
            return HttpResponse(e.code, e.read(65536) if e.fp else b'', dict(e.headers or {}))
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise NetworkError(str(getattr(e, 'reason', e)))


class TokenStore:
    """El token de actualización de Google, solo legible por el usuario (0600)."""

    def __init__(self, path=TOKEN_FILE):
        self.path = path

    def load(self):
        t = core.read_json(self.path)
        return t if isinstance(t, dict) and t.get('refresh_token') else None

    def save(self, token):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + '.tmp'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(token, f)
        os.replace(tmp, self.path)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def clear(self):
        try:
            os.remove(self.path)
        except OSError:
            pass


def _email_from_id_token(id_token):
    try:
        part = id_token.split('.')[1]
        return json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))).get('email')
    except (IndexError, ValueError):
        return None


class DriveBackend:
    """Google Drive, en la carpeta privada de la app (appDataFolder): no la ve nadie más, ni el usuario en drive.google.com."""

    kind = 'drive'

    def __init__(self, store=None, transport=None, conf=None):
        self.conf = conf or google_settings()
        self.store = store or TokenStore()
        self.transport = transport or urllib_transport
        self.access = None
        self._list = None

    # ---- OAuth (flujo para dispositivos: código en pantalla) ---------------

    def _call(self, method, url, gid=None, headers=None, body=None, auth=True):
        """Petición con reintentos ante 429/5xx y renovación del token ante 401. Devuelve HttpResponse 2xx."""
        game_name = core.game(gid)['name'] if gid else 'los juegos'
        last = None
        for attempt in range(int(self.conf.get('retries', 3)) + 1):
            h = dict(headers or {})
            if auth:
                h['Authorization'] = 'Bearer ' + self._access_token(gid)
            try:
                r = self.transport(method, url, h, body, self.conf.get('timeoutSeconds', 15))
            except NetworkError as e:
                raise CpError('3DM-SYN-001', e, game=game_name, detail=str(e))
            if 200 <= r.status < 300:
                return r
            err = r.json().get('error') if isinstance(r.json().get('error'), dict) else {}
            reason = ''.join(x.get('reason', '') for x in err.get('errors') or [] if isinstance(x, dict))
            last = 'HTTP %d %s' % (r.status, (err.get('message') or r.body[:200].decode('utf-8', 'replace')).strip())
            if r.status == 401 and auth and attempt == 0:
                self.access = None
                continue
            if r.status == 401:
                raise CpError('3DM-SYN-003', Exception(last), detail=last)
            if r.status == 403 and 'storageQuotaExceeded' in reason:
                raise CpError('3DM-SYN-004', Exception(last), game=game_name)
            if r.status == 429 or r.status >= 500 or (r.status == 403 and 'ateLimitExceeded' in reason):
                time.sleep(min(8, float(self.conf.get('retryDelay', 0.5)) * 2 ** attempt))
                continue
            raise CpError('3DM-SYN-006', Exception(last), game=game_name, detail=last)
        raise CpError('3DM-SYN-006', Exception(last), game=game_name, detail=last)

    def _form(self, path, fields):
        url = self.conf['authBase'] + path
        body = urllib.parse.urlencode(fields).encode()
        try:
            return self.transport('POST', url, {'Content-Type': 'application/x-www-form-urlencoded'}, body,
                                  self.conf.get('timeoutSeconds', 15))
        except NetworkError as e:
            raise CpError('3DM-SYN-001', e, game='los juegos', detail=str(e))

    def start_link(self):
        """Pide un código para vincular. Devuelve {device_code, user_code, verification_url, interval, expires_in}."""
        if not self.conf['clientId']:
            raise CpError('3DM-SYN-008')
        r = self._form('/device/code', {'client_id': self.conf['clientId'], 'scope': self.conf['scope']})
        d = r.json()
        if r.status != 200 or 'device_code' not in d:
            msg = 'HTTP %d %s' % (r.status, d.get('error_description') or d.get('error') or '')
            raise CpError('3DM-SYN-006', Exception(msg), game='los juegos', detail=msg)
        d.setdefault('verification_url', d.get('verification_uri', 'https://www.google.com/device'))
        d.setdefault('interval', 5)
        return d

    def poll_link(self, device_code):
        """Un intento: devuelve 'pending', 'slow_down' o el correo vinculado (y guarda el token)."""
        r = self._form('/token', {'client_id': self.conf['clientId'], 'client_secret': self.conf['clientSecret'],
                                  'device_code': device_code, 'grant_type': 'urn:ietf:params:oauth:grant-type:device_code'})
        d = r.json()
        if r.status == 200 and d.get('refresh_token'):
            email = _email_from_id_token(d.get('id_token', '')) or ''
            self.store.save({'refresh_token': d['refresh_token'], 'email': email, 'linkedAt': now_iso()})
            self.access = (d.get('access_token'), time.time() + int(d.get('expires_in', 3600)) - 60)
            return email or 'tu cuenta'
        e = d.get('error', '')
        if e in ('authorization_pending', 'slow_down'):
            return 'pending' if e == 'authorization_pending' else 'slow_down'
        msg = '%s %s' % (e, d.get('error_description', ''))
        if e in ('access_denied', 'expired_token'):
            raise CpError('3DM-SYN-003', Exception(msg), detail='no se autorizó el acceso a tiempo' if e == 'expired_token' else 'se rechazó el acceso')
        raise CpError('3DM-SYN-006', Exception(msg), game='los juegos', detail=msg.strip() or 'HTTP %d' % r.status)

    def linked_email(self):
        t = self.store.load()
        return (t.get('email') or 'tu cuenta') if t else None

    def unlink(self):
        t = self.store.load()
        self.store.clear()
        self.access = None
        if t:
            try:
                self._form('/revoke', {'token': t['refresh_token']})
            except CpError as e:
                log('Warn', 'No se pudo revocar el token de Google: %s' % e.data.get('detail'))

    def _access_token(self, gid=None):
        if self.access and self.access[0] and self.access[1] > time.time():
            return self.access[0]
        if not self.conf['clientId']:
            raise CpError('3DM-SYN-008')
        t = self.store.load()
        if not t:
            raise CpError('3DM-SYN-003', Exception('no hay una cuenta vinculada'), detail='no hay una cuenta vinculada')
        r = self._form('/token', {'client_id': self.conf['clientId'], 'client_secret': self.conf['clientSecret'],
                                  'refresh_token': t['refresh_token'], 'grant_type': 'refresh_token'})
        d = r.json()
        if r.status == 200 and d.get('access_token'):
            self.access = (d['access_token'], time.time() + int(d.get('expires_in', 3600)) - 60)
            return self.access[0]
        msg = '%s %s' % (d.get('error', 'HTTP %d' % r.status), d.get('error_description', ''))
        if d.get('error') in ('invalid_grant', 'unauthorized_client', 'invalid_client') or r.status in (400, 401):
            raise CpError('3DM-SYN-003', Exception(msg), detail=msg.strip())
        raise CpError('3DM-SYN-006', Exception(msg), game=core.game(gid)['name'] if gid else 'los juegos', detail=msg.strip())

    # ---- archivos ------------------------------------------------------------

    def check(self):
        self._files(None, refresh=True)

    def _files(self, gid, refresh=False):
        if self._list is None or refresh:
            q = urllib.parse.urlencode({'spaces': 'appDataFolder', 'pageSize': '100', 'orderBy': 'modifiedTime desc',
                                        'fields': 'files(id,name,size,modifiedTime,appProperties)'})
            r = self._call('GET', self.conf['apiBase'] + '/drive/v3/files?' + q, gid)
            self._list = [f for f in r.json().get('files') or [] if isinstance(f, dict)]
        return self._list

    def get_meta(self, gid):
        f = next((f for f in self._files(gid, refresh=True) if f.get('name') == gid + '.zip'), None)
        if not f:
            return None
        p = f.get('appProperties') or {}
        h, u = p.get('bundleHash', ''), p.get('updatedAt', '')
        if not re.match(r'^[0-9a-f]{64}$', h) or not ISO_RE.match(u):
            h, u = NO_HASH, '9999-12-31T23:59:59Z'     # sin metadatos: se decide después de descargarlo y validarlo
        return RemoteInfo(h, u, p.get('deviceName', '?'), f.get('id'))

    def download(self, gid, remote):
        url = self.conf['apiBase'] + '/drive/v3/files/%s?alt=media' % urllib.parse.quote(remote.ref, safe='')
        return self._call('GET', url, gid).body

    def upload(self, gid, data, manifest, remote):
        meta = {'name': gid + '.zip', 'appProperties': {'bundleHash': manifest['bundleHash'], 'updatedAt': manifest['updatedAt'],
                                                       'deviceName': manifest['deviceName'][:60], 'gameId': gid}}
        if not remote or not remote.ref:
            meta['parents'] = ['appDataFolder']
        boundary = 'creador' + uuid.uuid4().hex
        body = b''.join([('--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' % boundary).encode(),
                         json.dumps(meta).encode('utf-8'),
                         ('\r\n--%s\r\nContent-Type: application/zip\r\n\r\n' % boundary).encode(), data,
                         ('\r\n--%s--\r\n' % boundary).encode()])
        headers = {'Content-Type': 'multipart/related; boundary=' + boundary}
        if remote and remote.ref:
            url = self.conf['apiBase'] + '/upload/drive/v3/files/%s?uploadType=multipart' % urllib.parse.quote(remote.ref, safe='')
            self._call('PATCH', url, gid, headers, body)
        else:
            self._call('POST', self.conf['apiBase'] + '/upload/drive/v3/files?uploadType=multipart', gid, headers, body)
        self._list = None


def backend_for(cfg):
    """El destino configurado, o None si la sincronización está desactivada."""
    s = cfg.get('sync') if isinstance(cfg.get('sync'), dict) else {}
    if s.get('mode') == 'folder':
        return FolderBackend(s.get('folder'))
    if s.get('mode') == 'drive':
        return DriveBackend()
    return None


# ---------------------------------------------------------------------------
# Decisiones
# ---------------------------------------------------------------------------

class SyncResult:
    """action: same | downloaded | uploaded | local-newer | remote-newer | nothing | off."""

    def __init__(self, gid, action, message, backup=None, conflict=None):
        self.gid, self.action, self.message, self.backup, self.conflict = gid, action, message, backup, conflict

    def __repr__(self):
        return '<SyncResult %s %s>' % (self.gid, self.action)


def _save_conflict(gid, data, remote):
    """Guarda en «Creador de Películas 3D - copias» la versión que va a perder (ya validada; es un zip importable)."""
    dest = core.saves_dir()
    os.makedirs(dest, exist_ok=True)
    device = re.sub(r'[^A-Za-z0-9_-]+', '_', remote.deviceName or 'otro')[:30] or 'otro'
    path = core._unique(os.path.join(dest, '%s-conflicto-%s-%s.zip' % (gid, device, core._timestamp())))
    with open(path, 'wb') as f:
        f.write(data)
    log('Info', 'Película de %s en conflicto guardada en %s' % (gid, path))
    return path


def sync_game(gid, root, cfg, download=True, upload=True, backend=None):
    """Sincroniza un juego. Antes de jugar: download=True, upload=False. Al cerrar: al revés.
    «Sincronizar ahora»: los dos. Lanza CpError con la causa si algo falla."""
    backend = backend or backend_for(cfg)
    name = core.game(gid)['name']
    if backend is None:
        return SyncResult(gid, 'off', 'La sincronización está desactivada.')
    sync_config(cfg)
    st = load_state().get(gid, {})
    local = local_info(gid, root)
    local_changed = local is not None and local['bundleHash'] != st.get('lastSyncedHash')
    if local_changed and upload:
        _mark_pending(gid)
    remote = backend.get_meta(gid)
    bad = remote.error if remote is not None else None     # hay un paquete, pero no pasó la validación
    if remote and not bad and local and remote.bundleHash == local['bundleHash']:
        _mark_synced(gid, local, remote.deviceName)
        return SyncResult(gid, 'same', '%s: ya estaba al día.' % name)
    remote_data = None
    if remote and not bad and (local is None or remote.updatedAt > local['updatedAt']):
        # Parece más nueva: se descarga y se valida antes de decidir (aunque solo vayamos a subir,
        # para que un paquete dañado con fecha falsa no impida guardar la película buena).
        try:
            remote_data = backend.download(gid, remote)
            meta, contents = validate_bundle(gid, remote_data, None if remote.bundleHash == NO_HASH else remote.bundleHash)
        except CpError as e:
            if e.code != '3DM-SYN-005' or not upload or local is None:
                raise
            bad, remote_data = e, None
        else:
            if local is not None and meta['updatedAt'] <= local['updatedAt']:
                remote = RemoteInfo(meta['bundleHash'], meta['updatedAt'], meta['deviceName'], remote.ref)
            elif not download:
                return SyncResult(gid, 'remote-newer', '%s: hay una película más nueva de «%s»; se va a usar la próxima vez.'
                                  % (name, meta['deviceName']))
            else:
                backup = apply_bundle(gid, root, meta, contents)
                _mark_synced(gid, {'bundleHash': meta['bundleHash'], 'updatedAt': meta['updatedAt']}, meta['deviceName'])
                return SyncResult(gid, 'downloaded', '%s: se usó la película de «%s» (%s).'
                                  % (name, meta['deviceName'], describe(meta['updatedAt'])), backup)
    if bad and (not upload or local is None):
        raise bad
    if local is None:
        return SyncResult(gid, 'nothing', '%s: todavía no hay películas.' % name)
    if not upload:
        if local_changed:
            _mark_pending(gid)
        return SyncResult(gid, 'local-newer', '%s: la película de este equipo es la más nueva.' % name)
    conflict = None
    if bad:
        log('Warn', 'Se reemplaza el paquete inválido de %s: %s' % (gid, bad.data.get('reason')))
    elif remote is not None and remote.bundleHash != st.get('lastSyncedHash'):
        # Otro equipo subió algo después de nuestra última sincronización: gana la más reciente (la nuestra),
        # pero la otra queda guardada.
        try:
            data = remote_data or backend.download(gid, remote)
            validate_bundle(gid, data)
            conflict = _save_conflict(gid, data, remote)
        except CpError as e:
            log('Warn', 'No se guardó la versión en conflicto de %s: %s' % (gid, e.code))
    data, manifest = build_bundle(gid, root, cfg, local)
    backend.upload(gid, data, manifest, remote)
    _mark_synced(gid, local, manifest['deviceName'])
    log('Info', 'Película de %s subida (%s)' % (gid, local['updatedAt']))
    return SyncResult(gid, 'uploaded', '%s: película guardada en la sincronización.' % name, conflict=conflict)


def before_play(gid, root, cfg, backend=None):
    return sync_game(gid, root, cfg, download=True, upload=False, backend=backend)


def after_play(gid, root, cfg, backend=None):
    return sync_game(gid, root, cfg, download=False, upload=True, backend=backend)


def sync_all(root, cfg, backend=None, on_progress=None):
    """Sincroniza todos los juegos instalados. Devuelve [(ID, SyncResult o None, ErrorInfo o None)]."""
    backend = backend or backend_for(cfg)
    out = []
    games = core.installed_games(root)
    for n, ig in enumerate(games):
        if on_progress:
            on_progress(int(100 * n / max(1, len(games))), 'Sincronizando %s…' % ig.name)
        try:
            out.append((ig.id, sync_game(ig.id, root, cfg, backend=backend), None))
        except CpError as e:
            out.append((ig.id, None, errors.error_info(e)))
            if e.code in ('3DM-SYN-001', '3DM-SYN-003', '3DM-SYN-008'):
                break    # sin red o sin cuenta: no tiene sentido seguir con los demás
    return out


def status(root):
    """Para la tabla de «Sincronización…»: [(ID, nombre, fecha local, última sincronización, pendiente)]."""
    st = load_state()
    rows = []
    for ig in core.installed_games(root):
        info = local_info(ig.id, root)
        s = st.get(ig.id, {})
        pending = bool(s.get('pendingUpload')) or (info is not None and info['bundleHash'] != s.get('lastSyncedHash'))
        rows.append((ig.id, ig.name, info['updatedAt'] if info else None, s.get('lastSyncAt'), pending))
    return rows


def describe(iso):
    """Fecha ISO (UTC) en hora local legible."""
    if not iso:
        return '—'
    return datetime.datetime.fromtimestamp(from_iso(iso)).strftime('%d/%m/%Y %H:%M')
