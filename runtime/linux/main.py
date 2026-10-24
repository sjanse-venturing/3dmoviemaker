# main.py — punto de entrada de Creador de Películas 3D Runtime en Linux / Steam Deck (lo invoca creador.sh).
#
#   main.py                              abre la ventana principal (o el asistente si no hay nada instalado)
#   main.py --install                    abre el asistente de instalación
#   main.py --play <ID> [--file <.3MM>]  abre el juego directamente (lo usan los accesos de Steam y del menú)
#   main.py cli ...         comandos sin interfaz gráfica (ver «cli --help»)

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from creador import core, errors, proton, steam, sync  # noqa: E402
from creador.errors import CpError  # noqa: E402


def init(cfg):
    errors.load_strings(os.path.join(core.DATA_DIR, 'strings.es.json'))
    root = cfg.get('installRoot')
    errors.init_log(os.path.join(root, 'logs') if root else os.path.join(core.CONFIG_DIR, 'logs'))


# ---------------------------------------------------------------------------
# Comandos sin interfaz gráfica
# ---------------------------------------------------------------------------

def _root(args, cfg):
    root = args.root or cfg.get('installRoot')
    if not root:
        sys.exit('No hay una instalación. Usá «cli install --isos <carpeta>» primero.')
    return os.path.abspath(os.path.expanduser(root))


def cli(argv):
    p = argparse.ArgumentParser(prog='creador.sh cli', description='Creador de Películas 3D Runtime (Linux) sin interfaz gráfica.')
    p.add_argument('--root', help='carpeta de instalación (por defecto, la configurada)')
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('install', help='instalar desde una carpeta con la .iso')
    s.add_argument('--isos', required=True)
    s.add_argument('--games', help='IDs separados por comas (por defecto, todos los encontrados)')
    s.add_argument('--scale', type=int, choices=(0, 1, 2))
    s.add_argument('--player', help='nombre del jugador (carpeta de películas)')
    sub.add_parser('list', help='instalación, jugador y versión de Proton')
    s = sub.add_parser('play', help='abrir el juego')
    s.add_argument('id')
    s.add_argument('--file', help='película .3MM para abrir (ruta tal como la ve Wine, C:\\...)')
    s = sub.add_parser('repair', help='volver a copiar los archivos del programa (sin tocar las películas)')
    s.add_argument('id')
    s = sub.add_parser('uninstall', help='desinstalar (guarda antes una copia de las películas)')
    s.add_argument('id')
    s = sub.add_parser('export-saves', help='exportar películas (todas en un zip, o de los juegos indicados)')
    s.add_argument('ids', nargs='*')
    s.add_argument('--out', help='carpeta de destino (por defecto, Documentos/Creador de Películas 3D - copias)')
    s = sub.add_parser('import-saves', help='importar películas desde un zip de Windows o de Linux')
    s.add_argument('zip')
    s = sub.add_parser('steam', help='agregar a Steam con su artwork (cierra y vuelve a abrir Steam si hace falta)')
    s.add_argument('--no-restart', action='store_true', help='no reabrir Steam al terminar')
    sub.add_parser('menu', help='crear los accesos del menú del Modo Escritorio')
    s = sub.add_parser('sync', help='sincronización de películas entre equipos (se configura desde la ventana principal)')
    s.add_argument('action', choices=('status', 'now'), help='status: estado de cada juego; now: sincronizar todo ahora')
    args = p.parse_args(argv)

    cfg = core.get_config()
    if args.cmd == 'install':
        root = core.test_install_root(args.root or cfg.get('installRoot') or core.default_install_root())
        cfg['installRoot'] = root
        if args.scale is not None:
            cfg['scale'] = args.scale
        if args.player is not None:
            if not core.is_valid_player(args.player):
                info = errors.error_info(CpError('3DM-CFG-002', name=args.player))
                sys.exit('%s: %s' % (info.code, info.message))
            cfg['player'] = args.player
        cfg['isoFolder'] = os.path.abspath(args.isos)
        core.save_config(cfg)
    init(cfg)
    try:
        return _cli_run(args, cfg)
    except CpError as e:
        info = errors.error_info(e)
        print('%s: %s\n%s' % (info.code, info.title, info.message), file=sys.stderr)
        return 1


def _cli_run(args, cfg):
    if args.cmd == 'install':
        root = cfg['installRoot']
        isos, _ = core.find_isos(args.isos)
        ok = {i.game_id: i for i in isos if i.status == 'ok'}
        for i in isos:
            if i.status != 'ok':
                print('  ✗ %s: %s' % (i.name, i.message))
        ids = [x.strip() for x in args.games.split(',')] if args.games else [g['id'] for g in core.catalog() if g['id'] in ok]
        core.test_install_root(root, core.required_bytes(ids))
        core.install_runtime_files(root)
        for gid in ids:
            if gid not in ok:
                print('  ✗ %s: no se encontró su disco' % gid)
                continue
            last = [-1]

            def prog(pct, text, gid=gid):
                if pct // 10 != last[0]:
                    last[0] = pct // 10
                    print('  %s %3d%% %s' % (gid, pct, text[:70]), flush=True)
            core.install_game(gid, ok[gid].path, root, prog, player=core.get_player(cfg))
        proton.ensure_prefix(root, proton.select(cfg), print)
        print('Listo: %d juego(s) en %s, jugador %s' % (len(core.installed_games(root)), root, core.get_player(cfg)))
        return 0
    root = _root(args, cfg)
    if args.cmd == 'list':
        t = proton.select(cfg)
        print('Instalación: %s\nJugador: %s\nProton: %s' % (root, core.get_player(cfg), t.name + ' (' + t.path + ')' if t else 'no encontrado'))
        for ig in core.installed_games(root):
            print('  %-9s %s %s' % (ig.id, '✓' if ig.healthy else '✗', ig.name))
        return 0
    if args.cmd == 'play':
        if sync.enabled(cfg):
            try:
                print(sync.before_play(args.id, root, cfg).message)
            except CpError as e:
                info = errors.error_info(e)
                print('Aviso: no se pudo sincronizar (%s: %s). Se usan las películas de este equipo.' % (info.code, info.message))
        s = proton.start_game(args.id, root, cfg, print, file=args.file)
        diag = proton.complete_game(s)
        if sync.enabled(cfg):
            try:
                print(sync.after_play(args.id, root, cfg).message)
            except CpError as e:
                info = errors.error_info(e)
                print('Error: no se pudieron guardar las películas en la sincronización (%s: %s).' % (info.code, info.message))
        if diag:
            raise diag
        return 0
    if args.cmd == 'repair':
        entry = core.get_manifest(root)['games'].get(args.id)
        if not entry:
            raise CpError('3DM-RUN-006', game=args.id)
        core.install_game(args.id, entry['isoPath'], root, repair=True, player=core.get_player(cfg))
        print('Reparado.')
        return 0
    if args.cmd == 'uninstall':
        b = core.uninstall_game(args.id, root)
        steam.remove_desktop_entry(args.id)
        print('Desinstalado.' + (' Películas guardadas en %s' % b if b else ''))
        return 0
    if args.cmd == 'export-saves':
        if args.ids:
            for gid in args.ids:
                z = core.backup_saves(gid, root, args.out)
                print('%s: %s' % (gid, z or 'no tiene películas'))
        else:
            z = core.export_all_saves(root, args.out)
            print(z or 'No hay películas para exportar.')
        return 0
    if args.cmd == 'import-saves':
        r = core.import_saves(root, args.zip)
        for gid, files in r.imported.items():
            print('  ✓ %s: %s' % (gid, ', '.join(files)))
        for gid, why in r.skipped.items():
            print('  – %s: %s' % (gid, why))
        if r.ignored:
            print('  (se ignoraron: %s)' % ', '.join(r.ignored))
        for b in r.backups:
            print('  Copia de las películas anteriores: %s' % b)
        return 0
    if args.cmd == 'steam':
        if steam.in_gaming_mode():
            print('Hacelo desde el Modo Escritorio: hay que cerrar Steam para agregar el programa.')
            return 1
        was_running = steam.steam_running()
        if was_running:
            print('Cerrando Steam…', flush=True)
            if not steam.shutdown_steam():
                print('Steam no se cerró. Cerralo y volvé a intentar.')
                return 1
        files = steam.add_to_steam(root)
        print('Accesos agregados en: %s' % (', '.join(files) or 'ningún usuario de Steam'))
        if was_running and not args.no_restart:
            steam.start_steam()
        return 0
    if args.cmd == 'sync':
        s = sync.sync_config(cfg)
        print('Modo: %s%s  —  equipo: %s' % (s['mode'], ' (%s)' % s['folder'] if s['mode'] == 'folder' else '', s['deviceName']))
        if args.action == 'status':
            for gid, name, local, last, pending in sync.status(root):
                print('  %-9s películas: %-16s sincronizadas: %-16s %s' % (gid, sync.describe(local), sync.describe(last),
                                                                       'pendiente' if pending and local else ''))
            return 0
        if not sync.enabled(cfg):
            print('La sincronización está desactivada. Configurala desde la ventana principal («Sincronización…»).')
            return 1
        rc = 0
        for gid, r, info in sync.sync_all(root, cfg):
            if info:
                rc = 1
                print('  ✗ %s: %s — %s' % (gid, info.code, info.message))
            else:
                print('  ✓ ' + r.message + (' (la otra quedó en %s)' % r.conflict if r.conflict else ''))
        return rc
    if args.cmd == 'menu':
        steam.write_desktop_entries(root)
        print('Accesos creados en %s' % steam.desktop_dir())
        return 0
    return 1


# ---------------------------------------------------------------------------
# Interfaz gráfica
# ---------------------------------------------------------------------------

def gui(argv):
    mode, play_id, play_file = 'auto', None, None
    i = 0
    while i < len(argv):
        if argv[i] in ('--play', '-play') and i + 1 < len(argv):
            mode, play_id = 'play', argv[i + 1]
            i += 1
        elif argv[i] in ('--file', '-file') and i + 1 < len(argv):
            play_file = argv[i + 1]
            i += 1
        elif argv[i] in ('--install', '-install'):
            mode = 'install'
        i += 1
    cfg = core.get_config()
    init(cfg)
    from creador import ui
    if mode == 'play':
        return ui.play(play_id, play_file)
    return ui.main(mode)


if __name__ == '__main__':
    argv = sys.argv[1:]
    if argv and argv[0] == 'cli':
        sys.exit(cli(argv[1:]))
    try:
        sys.exit(gui(argv))
    except SystemExit:
        raise
    except BaseException as e:   # último recurso: cualquier error no previsto se muestra amigablemente
        import traceback
        errors.log('Error', 'Error no controlado: %s\n%s' % (e, traceback.format_exc()))
        try:
            from creador import ui
            ui.show_error_standalone(e)
        except Exception:
            traceback.print_exc()
        sys.exit(1)
