# errors.py — errores con mensajes amigables (mismo catálogo que Windows) y log técnico.

import datetime
import json
import os
import platform
import traceback

_strings = None
_log_file = None


def load_strings(path):
    global _strings
    with open(path, encoding='utf-8-sig') as f:
        _strings = json.load(f)


def strings():
    return _strings or {'errors': {}, 'actions': {}}


class CpError(Exception):
    """Error con código del catálogo strings.es.json. Uso: raise CpError('3DM-ISO-002', file='x.iso')."""

    def __init__(self, code, inner=None, **data):
        super().__init__(code)
        self.code = code
        self.data = data
        self.inner = inner
        if inner is not None:
            self.__cause__ = inner


class ErrorInfo:
    def __init__(self, code, title, message, actions, details):
        self.code, self.title, self.message, self.actions, self.details = code, title, message, actions, details


def error_info(exc):
    """Traduce cualquier excepción a ErrorInfo (código, título, mensaje, acciones, detalles)."""
    tr = None
    cur = exc
    while cur is not None:
        if isinstance(cur, CpError):
            tr = cur
            break
        cur = cur.__cause__ or cur.__context__
    code, data = ('3DM-GEN-001', {}) if tr is None else (tr.code, tr.data)
    errors = strings()['errors']
    entry = errors.get(code)
    if entry is None:
        code = '3DM-GEN-001'
        entry = errors.get(code)
    title, message, actions = 'Error', str(exc), ['details']
    if entry:
        title, message, actions = entry['title'], entry['message'], list(entry['actions'])
        for k, v in data.items():
            message = message.replace('{' + k + '}', str(v))
    lines = ['Código: ' + code]
    cur = exc
    seen = set()
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        lines.append('%s: %s' % (type(cur).__name__, cur))
        cur = cur.__cause__ or cur.__context__
    lines.append(''.join(traceback.format_exception(type(exc), exc, exc.__traceback__)))
    return ErrorInfo(code, title, message, actions, '\n'.join(lines))


def action_label(action):
    return strings()['actions'].get(action, action)


def init_log(directory):
    global _log_file
    os.makedirs(directory, exist_ok=True)
    _log_file = os.path.join(directory, 'creador-%s.log' % datetime.date.today().strftime('%Y%m%d'))
    olds = sorted((n for n in os.listdir(directory) if n.startswith('creador-') and n.endswith('.log')), reverse=True)
    for n in olds[10:]:
        try:
            os.remove(os.path.join(directory, n))
        except OSError:
            pass
    log('Info', '=== Creador de Películas 3D Runtime (Linux) — %s — Python %s — %s' % (
        datetime.datetime.now().isoformat(timespec='seconds'), platform.python_version(), platform.platform()))


def log_file():
    return _log_file


def log(level, message):
    if not _log_file:
        return
    line = '%s [%s] %s\n' % (datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3], level.upper(), message)
    try:
        with open(_log_file, 'a', encoding='utf-8') as f:
            f.write(line)
    except OSError:
        pass


def step(name, action, error_code='3DM-GEN-001', rollback=None, **error_data):
    """Ejecuta un paso con log, traduce excepciones al código indicado y ejecuta un rollback opcional."""
    log('Info', 'INICIO ' + name)
    try:
        result = action()
        log('Info', 'OK ' + name)
        return result
    except BaseException as e:
        log('Error', 'FALLO %s :: %s :: %s\n%s' % (name, type(e).__name__, e, traceback.format_exc()))
        if rollback:
            try:
                rollback()
                log('Info', 'ROLLBACK ' + name)
            except Exception as r:
                log('Error', 'ROLLBACK FALLÓ %s :: %s' % (name, r))
        if isinstance(e, (CpError, Cancelled)) or not isinstance(e, Exception):
            raise
        raise CpError(error_code, e, **error_data) from e


class Cancelled(Exception):
    """El usuario canceló la operación."""


def report(info):
    """Texto para «Copiar informe»: resumen del error + últimas líneas del log."""
    out = ['Informe de Creador de Películas 3D Runtime',
           'Fecha: %s  Sistema: %s' % (datetime.datetime.now().isoformat(timespec='seconds'), platform.platform())]
    if info:
        out.append('Error: %s — %s' % (info.code, info.message))
        out.append(info.details)
    if _log_file and os.path.exists(_log_file):
        out.append('--- Últimas líneas del log ---')
        with open(_log_file, encoding='utf-8', errors='replace') as f:
            out.extend(l.rstrip('\n') for l in f.readlines()[-200:])
    return '\n'.join(out)
