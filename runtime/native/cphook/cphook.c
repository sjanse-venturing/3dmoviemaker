/*
 * cphook.dll — capa de compatibilidad de Creador de Películas 3D Runtime.
 *
 * La inyecta cplaunch.exe en 3DMOVIE.EXE antes de que arranque. Parchea la
 * IAT del ejecutable para:
 *   - Registro virtual: la clave "Software\Microsoft\Microsoft Kids\3D Movie
 *     Maker" (HKLM y HKCU) se lee y se escribe en un INI de la instalación.
 *     El juego exige InstallDirectory y Products en HKLM, que un usuario
 *     estándar no puede crear; así no se toca el registro real.
 *   - Usuario estable: WNetGetUserA devuelve el nombre de jugador elegido, para
 *     que la carpeta de películas (Users\<nombre>) sea la misma en todos los
 *     equipos.
 *   - Pantalla completa escalada: el juego cree que la pantalla mide 640x480 y
 *     elige su modo de pantalla completa; la ventana real ocupa el monitor y el
 *     juego dibuja en una "sombra" de 640x480 que se presenta escalada.
 *   - Paleta del sistema emulada (Wine / Proton) y registro de fallos.
 *
 * La configuración llega por variables de entorno (las hereda del lanzador):
 *   CP3D_LOG        archivo de log (vacío = sin log)
 *   CP3D_REGFILE    INI del registro virtual
 *   CP3D_USER       nombre del jugador (carpeta Users\<nombre>)
 *   CP3D_SCALE      0 = ajustar a pantalla (por defecto), 1 = ventana original de 640x480, 2..4 = escala entera
 *   CP3D_VIEW       WxH: tamaño fijo de la vista (diagnóstico)
 *   CP3D_TRACE      1 = registrar registro, archivos, ventanas y audio
 *   CP3D_DPIAWARE   0 = no declarar el proceso consciente de DPI (diagnóstico)
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Configuración y log                                                  */
/* ------------------------------------------------------------------ */

static CRITICAL_SECTION g_logLock;
static FILE *g_log;
static int g_trace;
static char g_regFile[MAX_PATH];
static char g_user[64];
static int g_scale;               /* 0 = ajustar */
static int g_viewW, g_viewH;      /* CP3D_VIEW: tamaño fijo de la vista (diagnóstico) */
static HMODULE g_self;

static void tlog(const char *fmt, ...) {
    va_list ap;
    if (!g_log) return;
    EnterCriticalSection(&g_logLock);
    fprintf(g_log, "[%8lu] ", GetTickCount());
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_logLock);
}

static void read_env(const char *name, char *buf, DWORD size) {
    DWORD n = GetEnvironmentVariableA(name, buf, size);
    if (n == 0 || n >= size) buf[0] = 0;
}

static void load_config(void) {
    char tmp[MAX_PATH];
    read_env("CP3D_LOG", tmp, sizeof tmp);
    if (tmp[0]) g_log = fopen(tmp, "a");
    read_env("CP3D_TRACE", tmp, sizeof tmp);
    g_trace = tmp[0] == '1';
    read_env("CP3D_REGFILE", g_regFile, sizeof g_regFile);
    read_env("CP3D_USER", g_user, sizeof g_user);
    read_env("CP3D_SCALE", tmp, sizeof tmp);
    g_scale = tmp[0] ? atoi(tmp) : 0;
    read_env("CP3D_VIEW", tmp, sizeof tmp);
    if (sscanf(tmp, "%dx%d", &g_viewW, &g_viewH) != 2) g_viewW = g_viewH = 0;
}

/* ------------------------------------------------------------------ */
/* Registro de fallos                                                   */
/* ------------------------------------------------------------------ */

/*
 * Si el juego se cae (violación de acceso, etc.), deja en el log el módulo y
 * el desplazamiento donde ocurrió, los registros y la pila. Se registra
 * siempre (sin traza): el lanzador copia este bloque al informe de error.
 * Si el juego instala su propio filtro, lo llamamos después del nuestro.
 */
static LPTOP_LEVEL_EXCEPTION_FILTER g_gameFilter;

static void describe_address(DWORD addr, char *out, size_t size) {
    HMODULE m = NULL;
    char path[MAX_PATH];
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)(ULONG_PTR)addr, &m) && m && GetModuleFileNameA(m, path, sizeof path)) {
        const char *b = strrchr(path, '\\');
        _snprintf(out, size, "%s+0x%lX", b ? b + 1 : path, addr - (DWORD)(ULONG_PTR)m);
    } else {
        _snprintf(out, size, "?");
    }
    out[size - 1] = 0;
}

static LONG WINAPI crash_filter(EXCEPTION_POINTERS *ep) {
    static volatile LONG once;
    if (ep && ep->ExceptionRecord && InterlockedExchange(&once, 1) == 0) {
        EXCEPTION_RECORD *er = ep->ExceptionRecord;
        DWORD eip = (DWORD)(ULONG_PTR)er->ExceptionAddress;
        char where[MAX_PATH + 32];
        describe_address(eip, where, sizeof where);
        tlog("FALLO excepción 0x%08lX en 0x%08lX (%s), hilo %lu", er->ExceptionCode, eip, where, GetCurrentThreadId());
        if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2)
            tlog("FALLO acceso de %s a la dirección 0x%08lX",
                 er->ExceptionInformation[0] == 0 ? "lectura" : er->ExceptionInformation[0] == 1 ? "escritura" : "ejecución",
                 (DWORD)er->ExceptionInformation[1]);
#ifdef _M_IX86
        if (ep->ContextRecord) {
            CONTEXT *c = ep->ContextRecord;
            DWORD *sp = (DWORD *)(ULONG_PTR)c->Esp;
            int i;
            tlog("FALLO EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX ESI=%08lX EDI=%08lX EBP=%08lX ESP=%08lX",
                 c->Eax, c->Ebx, c->Ecx, c->Edx, c->Esi, c->Edi, c->Ebp, c->Esp);
            /* Valores de la pila que apuntan a código: la cadena de llamadas aproximada. */
            for (i = 0; i < 64; i++) {
                DWORD v;
                if (IsBadReadPtr(sp + i, sizeof v)) break;
                v = sp[i];
                describe_address(v, where, sizeof where);
                if (where[0] != '?') tlog("FALLO pila[%02d] %08lX %s", i, v, where);
            }
        }
#endif
    }
    return g_gameFilter ? g_gameFilter(ep) : EXCEPTION_CONTINUE_SEARCH;
}

typedef LPTOP_LEVEL_EXCEPTION_FILTER(WINAPI *SUEF_t)(LPTOP_LEVEL_EXCEPTION_FILTER);
static SUEF_t real_SetUnhandledExceptionFilter;
static LPTOP_LEVEL_EXCEPTION_FILTER WINAPI hk_SetUnhandledExceptionFilter(LPTOP_LEVEL_EXCEPTION_FILTER f) {
    LPTOP_LEVEL_EXCEPTION_FILTER prev = g_gameFilter;
    g_gameFilter = f;
    return prev;
}

/* ------------------------------------------------------------------ */
/* Pantalla completa escalada                                           */
/* ------------------------------------------------------------------ */

#define LOGICAL_W 640
#define LOGICAL_H 480

/*
 * 3DMOVIE.EXE corre en pantalla completa solo si la pantalla ya mide 640x480
 * (en NT no cambia de resolución): si no, abre una ventana de 640x480. Le
 * informamos 640x480 en GetSystemMetrics, así crea su ventana emergente de
 * 640x480 en 0,0, y nosotros la creamos del tamaño real del monitor.
 *
 * El motor (Kauai) pide el DC de la ventana una sola vez (GetDC) y dibuja en
 * él toda la sesión: copias con StretchBlt, vídeo con DrawDibDraw, ScrollDC,
 * InvertRect, FillRect, texto, regiones de recorte... En lugar de traducir
 * cada llamada, le damos un DC de memoria de 640x480 (la "sombra"): todo se
 * dibuja ahí en coordenadas lógicas, con sus recortes y paleta, y lo que cambió
 * (los límites acumulados del DC) se presenta escalado en la ventana real.
 *
 * Un punto lógico L corresponde al real V + L * escala, donde V es el origen de
 * la vista centrada en el monitor. El juego cree que su ventana está en 0,0 y
 * mide 640x480; la ventana real también está en 0,0 (monitor principal), así
 * que solo hay que escalar las coordenadas de pantalla del mouse.
 */
enum { MODE_NONE, MODE_SCREEN };
static int g_mode = MODE_NONE;
static HWND g_target;      /* ventana principal del juego (a pantalla completa) */
static int g_scrW, g_scrH; /* tamaño real del monitor principal */
static int g_vx, g_vy;     /* origen real de la vista escalada */
static int g_vw = LOGICAL_W, g_vh = LOGICAL_H; /* tamaño real de la vista */
static WNDPROC g_targetProc;
static HDC g_shadowDC;
static HBITMAP g_shadowBmp;
static int g_shadowSaved;  /* SaveDC del estado limpio (para GetDC anidados) */
static int g_dcUsers;      /* GetDC entregados sin su ReleaseDC */
static PAINTSTRUCT g_realPs;
static HDC g_realPaintDC;

#define CP_TIMER_ID 0x7C3D /* temporizador propio para presentar lo pendiente */

typedef int(WINAPI *GSM_t)(int);
typedef HDC(WINAPI *GDC2_t)(HWND);
typedef int(WINAPI *RDC_t)(HWND, HDC);
typedef HDC(WINAPI *BP_t)(HWND, LPPAINTSTRUCT);
typedef BOOL(WINAPI *EP_t)(HWND, const PAINTSTRUCT *);
typedef BOOL(WINAPI *GUR_t)(HWND, LPRECT, BOOL);
typedef BOOL(WINAPI *GCR_t)(HWND, LPRECT);
typedef BOOL(WINAPI *GWR_t)(HWND, LPRECT);
typedef BOOL(WINAPI *IR_t)(HWND, const RECT *, BOOL);
typedef BOOL(WINAPI *VR_t)(HWND, const RECT *);
typedef BOOL(WINAPI *SWP_t)(HWND, HWND, int, int, int, int, UINT);
typedef BOOL(WINAPI *MW_t)(HWND, int, int, int, int, BOOL);
typedef int(WINAPI *SWEx_t)(HWND, int, int, const RECT *, const RECT *, HRGN, LPRECT, UINT);
typedef BOOL(WINAPI *SDC_t)(HDC, int, int, const RECT *, const RECT *, HRGN, LPRECT);
typedef BOOL(WINAPI *CC_t)(const RECT *);
typedef BOOL(WINAPI *SB_t)(HDC, int, int, int, int, HDC, int, int, int, int, DWORD);
typedef int(WINAPI *FR_t)(HDC, const RECT *, HBRUSH);
typedef BOOL(WINAPI *INVR_t)(HDC, const RECT *);
typedef BOOL(WINAPI *DDD_t)(HANDLE, HDC, int, int, int, int, LPBITMAPINFOHEADER, LPVOID, int, int, int, int, UINT);
static GSM_t real_GetSystemMetrics;
static GDC2_t real_GetDC;
static RDC_t real_ReleaseDC;
static BP_t real_BeginPaint;
static EP_t real_EndPaint;
static GUR_t real_GetUpdateRect;
static GCR_t real_GetClientRect;
static GWR_t real_GetWindowRect;
static IR_t real_InvalidateRect;
static VR_t real_ValidateRect;
static SWP_t real_SetWindowPos;
static MW_t real_MoveWindow;
static SWEx_t real_ScrollWindowEx;
static SDC_t real_ScrollDC;
static CC_t real_ClipCursor;
static SB_t real_StretchBlt;
static FR_t real_FillRect;
static INVR_t real_InvertRect;
static DDD_t real_DrawDibDraw;

static int scaled(void) { return g_mode == MODE_SCREEN; }
/* lógico -> real */
static int rx(int v) { return g_vx + MulDiv(v, g_vw, LOGICAL_W); }
static int ry(int v) { return g_vy + MulDiv(v, g_vh, LOGICAL_H); }
/* real -> lógico */
static int lx(int v) { return MulDiv(v - g_vx, LOGICAL_W, g_vw); }
static int ly(int v) { return MulDiv(v - g_vy, LOGICAL_H, g_vh); }

/* Calcula el tamaño real de la vista dentro de un área disponible aw x ah. */
static void pick_size(int aw, int ah, int *w, int *h) {
    int s;
    if (g_scale == 1 || aw < LOGICAL_W || ah < LOGICAL_H) { *w = LOGICAL_W; *h = LOGICAL_H; return; }
    /* Diagnóstico: tamaño fijo, aunque no entre en la pantalla (para reproducir otras resoluciones). */
    if (g_viewW >= LOGICAL_W && g_viewH >= LOGICAL_H) { *w = g_viewW; *h = g_viewH; return; }
    if (g_scale >= 2) {
        for (s = g_scale; s > 1 && (LOGICAL_W * s > aw || LOGICAL_H * s > ah); s--) {}
        *w = LOGICAL_W * s; *h = LOGICAL_H * s;
        return;
    }
    /* 0 = ajustar al área disponible manteniendo 4:3 */
    if ((long)aw * LOGICAL_H > (long)ah * LOGICAL_W) { *h = ah; *w = ah * LOGICAL_W / LOGICAL_H; }
    else { *w = aw; *h = aw * LOGICAL_H / LOGICAL_W; }
}

static void map_rect_to_real(const RECT *in, RECT *out) {
    out->left = rx(in->left) - 1; out->top = ry(in->top) - 1;
    out->right = rx(in->right) + 1; out->bottom = ry(in->bottom) + 1;
}

static void map_rect_to_logical(RECT *r) {
    r->left = lx(r->left); r->top = ly(r->top);
    r->right = lx(r->right + g_vw / LOGICAL_W) + 1; r->bottom = ly(r->bottom + g_vh / LOGICAL_H) + 1;
    if (r->left < 0) r->left = 0;
    if (r->top < 0) r->top = 0;
    if (r->right > LOGICAL_W) r->right = LOGICAL_W;
    if (r->bottom > LOGICAL_H) r->bottom = LOGICAL_H;
}

/*
 * Presenta en la ventana un rectángulo lógico tomándolo de la sombra, con un
 * píxel lógico de margen. Con escalas no enteras (p. ej. 2,25x) cada copia
 * escalada redondea distinto; con el margen los bordes siempre quedan con el
 * contenido actual.
 */
static void present_logical(HDC dst, int x0, int y0, int x1, int y1) {
    int X0, Y0;
    if (--x0 < 0) x0 = 0;
    if (--y0 < 0) y0 = 0;
    if (++x1 > LOGICAL_W) x1 = LOGICAL_W;
    if (++y1 > LOGICAL_H) y1 = LOGICAL_H;
    if (x1 <= x0 || y1 <= y0) return;
    X0 = rx(x0); Y0 = ry(y0);
    SetStretchBltMode(dst, COLORONCOLOR);
    real_StretchBlt(dst, X0, Y0, rx(x1) - X0, ry(y1) - Y0, g_shadowDC, x0, y0, x1 - x0, y1 - y0, SRCCOPY);
}

/* Bandas negras alrededor de la vista 4:3. */
static void paint_bars(HDC dst) {
    RECT r;
    HBRUSH b = (HBRUSH)GetStockObject(BLACK_BRUSH);
    SetRect(&r, 0, 0, g_scrW, g_vy); real_FillRect(dst, &r, b);
    SetRect(&r, 0, g_vy + g_vh, g_scrW, g_scrH); real_FillRect(dst, &r, b);
    SetRect(&r, 0, g_vy, g_vx, g_vy + g_vh); real_FillRect(dst, &r, b);
    SetRect(&r, g_vx + g_vw, g_vy, g_scrW, g_vy + g_vh); real_FillRect(dst, &r, b);
}

/* Presenta lo que se dibujó en la sombra desde la última vez (o todo). */
static void flush_shadow(int all) {
    RECT r;
    HDC dst;
    UINT st;
    if (!scaled() || !g_shadowDC) return;
    GdiFlush();
    st = GetBoundsRect(g_shadowDC, &r, DCB_RESET);
    if (!all && (st & DCB_SET) != DCB_SET) return;
    dst = real_GetDC(g_target);
    if (!dst) return;
    if (all) {
        paint_bars(dst);
        present_logical(dst, 0, 0, LOGICAL_W, LOGICAL_H);
    } else {
        present_logical(dst, r.left, r.top, r.right, r.bottom);
    }
    real_ReleaseDC(g_target, dst);
}

static int is_shadow(HDC dc) { return dc && dc == g_shadowDC; }

static void create_shadow(HWND hwnd) {
    HDC wdc = real_GetDC(hwnd);
    if (!wdc) return;
    g_shadowDC = CreateCompatibleDC(wdc);
    g_shadowBmp = CreateCompatibleBitmap(wdc, LOGICAL_W, LOGICAL_H);
    real_ReleaseDC(hwnd, wdc);
    if (!g_shadowDC || !g_shadowBmp) {
        if (g_shadowDC) DeleteDC(g_shadowDC);
        if (g_shadowBmp) DeleteObject(g_shadowBmp);
        g_shadowDC = NULL; g_shadowBmp = NULL;
        return;
    }
    SelectObject(g_shadowDC, g_shadowBmp);
    PatBlt(g_shadowDC, 0, 0, LOGICAL_W, LOGICAL_H, BLACKNESS);
    SetBoundsRect(g_shadowDC, NULL, DCB_ENABLE | DCB_RESET);
}

/* Traduce los mensajes de mouse de coordenadas reales a lógicas y presenta lo pendiente. */
static LRESULT CALLBACK target_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_TIMER && wp == CP_TIMER_ID) { flush_shadow(0); return 0; }
    if (scaled() && msg >= WM_MOUSEFIRST && msg <= WM_MOUSELAST && msg != WM_MOUSEWHEEL) {
        int x = (short)LOWORD(lp), y = (short)HIWORD(lp);
        lp = MAKELPARAM(lx(x), ly(y));
        if (g_trace && msg != WM_MOUSEMOVE) tlog("MOUSE msg %04x %d,%d -> %d,%d", msg, x, y, lx(x), ly(y));
    }
    if (msg == WM_ERASEBKGND && scaled()) return 1; /* lo pinta flush_shadow(1) */
    if (g_trace && (msg == WM_ACTIVATEAPP || msg == WM_ACTIVATE || msg == WM_KILLFOCUS || msg == WM_SETFOCUS || msg == WM_SIZE))
        tlog("ventana msg %04x wp=%lx lp=%lx", msg, (DWORD)wp, (DWORD)lp);
    return CallWindowProcA(g_targetProc, hwnd, msg, wp, lp);
}

/* La ventana emergente de 640x480 del juego pasa a ocupar el monitor. */
static void adopt_screen(HWND hwnd) {
    int w, h;
    pick_size(g_scrW, g_scrH, &w, &h);
    g_mode = MODE_SCREEN;
    g_target = hwnd;
    g_vw = w;
    g_vh = h;
    g_vx = (g_scrW - w) / 2;
    g_vy = (g_scrH - h) / 2;
    create_shadow(hwnd);
    g_targetProc = (WNDPROC)SetWindowLongPtrA(hwnd, GWLP_WNDPROC, (LONG_PTR)target_proc);
    SetTimer(hwnd, CP_TIMER_ID, 15, NULL);
    tlog("pantalla completa: ventana %p, monitor %dx%d, vista %dx%d en %d,%d", hwnd, g_scrW, g_scrH, w, h, g_vx, g_vy);
}

static int WINAPI hk_GetSystemMetrics(int i) {
    if (g_scale != 1 && (i == SM_CXSCREEN || i == SM_CYSCREEN)) return i == SM_CXSCREEN ? LOGICAL_W : LOGICAL_H;
    return real_GetSystemMetrics(i);
}

static HDC WINAPI hk_GetDC(HWND h) {
    if (!scaled() || h != g_target || !g_shadowDC) return real_GetDC(h);
    /* Un segundo GetDC mientras el motor conserva el suyo: guardamos el estado para restaurarlo al liberar. */
    if (g_dcUsers++ > 0) SaveDC(g_shadowDC);
    if (g_trace) tlog("GetDC(ventana) -> sombra (%d en uso)", g_dcUsers);
    return g_shadowDC;
}

static int WINAPI hk_ReleaseDC(HWND h, HDC dc) {
    if (!is_shadow(dc)) return real_ReleaseDC(h, dc);
    flush_shadow(0);
    if (g_dcUsers > 1) RestoreDC(g_shadowDC, -1);
    if (g_dcUsers > 0) g_dcUsers--;
    return 1;
}

static HDC WINAPI hk_BeginPaint(HWND h, LPPAINTSTRUCT ps) {
    HDC dc;
    if (!scaled() || h != g_target || !g_shadowDC || !ps) return real_BeginPaint(h, ps);
    g_realPaintDC = real_BeginPaint(h, &g_realPs);
    *ps = g_realPs;
    ps->hdc = g_shadowDC;
    map_rect_to_logical(&ps->rcPaint);
    ps->fErase = FALSE;
    SaveDC(g_shadowDC);
    dc = g_shadowDC;
    return dc;
}

static BOOL WINAPI hk_EndPaint(HWND h, const PAINTSTRUCT *ps) {
    if (!ps || !is_shadow(ps->hdc)) return real_EndPaint(h, ps);
    RestoreDC(g_shadowDC, -1);
    /* La ventana real pide repintar (al restaurarla, al cerrar un diálogo encima...): se presenta todo. */
    if (g_realPaintDC) { paint_bars(g_realPaintDC); present_logical(g_realPaintDC, 0, 0, LOGICAL_W, LOGICAL_H); }
    GetBoundsRect(g_shadowDC, NULL, DCB_RESET);
    g_realPaintDC = NULL;
    return real_EndPaint(h, &g_realPs);
}

static BOOL WINAPI hk_GetUpdateRect(HWND h, LPRECT r, BOOL erase) {
    BOOL res = real_GetUpdateRect(h, r, erase);
    if (res && r && scaled() && h == g_target) map_rect_to_logical(r);
    return res;
}

static BOOL WINAPI hk_GetClientRect(HWND h, LPRECT r) {
    if (!scaled() || h != g_target || !r) return real_GetClientRect(h, r);
    SetRect(r, 0, 0, LOGICAL_W, LOGICAL_H);
    return TRUE;
}

static BOOL WINAPI hk_GetWindowRect(HWND h, LPRECT r) {
    if (!scaled() || h != g_target || !r) return real_GetWindowRect(h, r);
    SetRect(r, 0, 0, LOGICAL_W, LOGICAL_H);
    return TRUE;
}

static BOOL WINAPI hk_InvalidateRect(HWND h, const RECT *rc, BOOL erase) {
    RECT r2;
    if (h == g_target && rc && scaled()) { map_rect_to_real(rc, &r2); rc = &r2; }
    return real_InvalidateRect(h, rc, erase);
}

static BOOL WINAPI hk_ValidateRect(HWND h, const RECT *rc) {
    RECT r2;
    if (h == g_target && rc && scaled()) { map_rect_to_real(rc, &r2); rc = &r2; }
    return real_ValidateRect(h, rc);
}

/*
 * Ventanas de nivel superior del juego que no son la principal (los diálogos de
 * abrir y guardar películas): el juego las ubica en coordenadas de su pantalla
 * de 640x480. Se mantiene su tamaño y se lleva su centro al punto equivalente
 * de la vista escalada.
 */
static int is_game_popup(HWND h) {
    return scaled() && h && h != g_target && !(GetWindowLongA(h, GWL_STYLE) & WS_CHILD) &&
           GetWindow(h, GW_OWNER) == g_target;
}

static void place_popup(int *x, int *y, int w, int h) {
    *x = rx(*x + w / 2) - w / 2;
    *y = ry(*y + h / 2) - h / 2;
    if (*x < 0) *x = 0;
    if (*y < 0) *y = 0;
}

/* El juego no mueve ni achica la ventana de pantalla completa. */
static BOOL WINAPI hk_SetWindowPos(HWND h, HWND after, int x, int y, int w, int hh, UINT flags) {
    if (scaled() && h == g_target) flags |= SWP_NOMOVE | SWP_NOSIZE;
    else if (!(flags & SWP_NOMOVE) && is_game_popup(h)) {
        RECT r;
        int pw = w, ph = hh;
        if ((flags & SWP_NOSIZE) && real_GetWindowRect(h, &r)) { pw = r.right - r.left; ph = r.bottom - r.top; }
        place_popup(&x, &y, pw, ph);
        if (g_trace) tlog("SetWindowPos diálogo %p -> %d,%d", h, x, y);
    }
    return real_SetWindowPos(h, after, x, y, w, hh, flags);
}

static BOOL WINAPI hk_MoveWindow(HWND h, int x, int y, int w, int hh, BOOL repaint) {
    if (scaled() && h == g_target) {
        if (repaint) real_InvalidateRect(h, NULL, FALSE);
        return TRUE;
    }
    if (is_game_popup(h)) {
        place_popup(&x, &y, w, hh);
        return real_MoveWindow(h, x, y, w, hh, repaint);
    }
    /* Ventanas hijas (la del vídeo de MCI): se ubican en coordenadas lógicas. */
    if (scaled() && GetParent(h) == g_target) {
        int x0 = rx(x), y0 = ry(y);
        if (g_trace) tlog("MoveWindow hija %p %d,%d %dx%d -> %d,%d %dx%d", h, x, y, w, hh, x0, y0, rx(x + w) - x0, ry(y + hh) - y0);
        return real_MoveWindow(h, x0, y0, rx(x + w) - x0, ry(y + hh) - y0, repaint);
    }
    return real_MoveWindow(h, x, y, w, hh, repaint);
}

/*
 * Vídeo por MCI (avivideo): el motor abre el AVI con una ventana hija de la
 * ventana principal y la ubica con MoveWindow (ver arriba). MCIAVI no estira
 * la imagen al tamaño de la ventana: al reproducir o mostrar, fijamos el
 * rectángulo de destino al tamaño escalado.
 */
typedef MCIERROR(WINAPI *MSCA_t)(MCIDEVICEID, UINT, DWORD_PTR, DWORD_PTR);
static MSCA_t real_mciSendCommandA;
static MCIDEVICEID g_videoDev[8];

static int is_video_dev(MCIDEVICEID d) {
    int i;
    for (i = 0; i < 8; i++) if (d && g_videoDev[i] == d) return 1;
    return 0;
}

static void scale_video(MCIDEVICEID d) {
    MCI_ANIM_RECT_PARMS src, dst;
    ZeroMemory(&src, sizeof src);
    if (real_mciSendCommandA(d, MCI_WHERE, MCI_ANIM_WHERE_SOURCE, (DWORD_PTR)&src) != 0) return;
    ZeroMemory(&dst, sizeof dst);
    /* En MCI, right y bottom de estos rectángulos son el ancho y el alto. */
    dst.rc.right = MulDiv(src.rc.right, g_vw, LOGICAL_W);
    dst.rc.bottom = MulDiv(src.rc.bottom, g_vh, LOGICAL_H);
    real_mciSendCommandA(d, MCI_PUT, MCI_ANIM_PUT_DESTINATION | MCI_ANIM_RECT, (DWORD_PTR)&dst);
    if (g_trace) tlog("vídeo %u: origen %ldx%ld -> destino %ldx%ld", d, src.rc.right, src.rc.bottom, dst.rc.right, dst.rc.bottom);
}

static MCIERROR WINAPI hk_mciSendCommandA(MCIDEVICEID d, UINT msg, DWORD_PTR flags, DWORD_PTR parm) {
    MCIERROR r = real_mciSendCommandA(d, msg, flags, parm);
    if (g_trace && msg == MCI_OPEN)
        tlog("MCI_OPEN %s -> %lu", parm && (flags & MCI_OPEN_ELEMENT) ? ((MCI_OPEN_PARMSA *)parm)->lpstrElementName : "", r);
    if (r || !scaled() || !parm) return r;
    if (msg == MCI_OPEN && (flags & MCI_ANIM_OPEN_PARENT) && ((MCI_ANIM_OPEN_PARMSA *)parm)->hWndParent == g_target) {
        int i;
        for (i = 0; i < 8; i++) if (!g_videoDev[i]) { g_videoDev[i] = ((MCI_ANIM_OPEN_PARMSA *)parm)->wDeviceID; break; }
    } else if ((msg == MCI_PLAY || msg == MCI_WINDOW) && is_video_dev(d)) {
        scale_video(d);
    } else if (msg == MCI_CLOSE && is_video_dev(d)) {
        int i;
        for (i = 0; i < 8; i++) if (g_videoDev[i] == d) g_videoDev[i] = 0;
    }
    return r;
}

/* Desplazar el contenido de la ventana = desplazar la sombra y presentar. */
static int WINAPI hk_ScrollWindowEx(HWND h, int dx, int dy, const RECT *scroll, const RECT *clip, HRGN upd, LPRECT updRc,
                                    UINT flags) {
    RECT u;
    if (!scaled() || h != g_target || !g_shadowDC) return real_ScrollWindowEx(h, dx, dy, scroll, clip, upd, updRc, flags);
    SetRectEmpty(&u);
    real_ScrollDC(g_shadowDC, dx, dy, scroll, clip, NULL, &u);
    flush_shadow(1);
    if (updRc) *updRc = u;
    if ((flags & SW_INVALIDATE) && !IsRectEmpty(&u)) hk_InvalidateRect(h, &u, (flags & SW_ERASE) != 0);
    return IsRectEmpty(&u) ? NULLREGION : SIMPLEREGION;
}

static BOOL WINAPI hk_ScrollDC(HDC dc, int dx, int dy, const RECT *scroll, const RECT *clip, HRGN upd, LPRECT updRc) {
    BOOL r = real_ScrollDC(dc, dx, dy, scroll, clip, upd, updRc);
    if (is_shadow(dc)) flush_shadow(1);
    return r;
}

static BOOL WINAPI hk_StretchBlt(HDC dst, int x, int y, int w, int h, HDC src, int xs, int ys, int ws, int hs, DWORD rop) {
    BOOL r = real_StretchBlt(dst, x, y, w, h, src, xs, ys, ws, hs, rop);
    if (is_shadow(dst)) flush_shadow(0);
    return r;
}

static int WINAPI hk_FillRect(HDC dc, const RECT *rc, HBRUSH b) {
    int r = real_FillRect(dc, rc, b);
    if (is_shadow(dc)) flush_shadow(0);
    return r;
}

static BOOL WINAPI hk_InvertRect(HDC dc, const RECT *rc) {
    BOOL r = real_InvertRect(dc, rc);
    if (is_shadow(dc)) flush_shadow(0);
    return r;
}

/* Vídeo (AVI): DrawDibDraw dibuja en la sombra; se presenta cada cuadro. */
static BOOL WINAPI hk_DrawDibDraw(HANDLE hdd, HDC dc, int x, int y, int w, int h, LPBITMAPINFOHEADER bi, LPVOID bits, int xs,
                                  int ys, int ws, int hs, UINT flags) {
    BOOL r = real_DrawDibDraw(hdd, dc, x, y, w, h, bi, bits, xs, ys, ws, hs, flags);
    if (is_shadow(dc)) flush_shadow(0);
    return r;
}

/* Mouse: punto de pantalla real -> lógico (el juego cree que su ventana está en 0,0 y mide 640x480). */
static void map_screen_point(POINT *p) {
    if (!scaled()) return;
    p->x = lx(p->x);
    p->y = ly(p->y);
}

static void unmap_screen_point(POINT *p) {
    if (!scaled()) return;
    p->x = rx(p->x);
    p->y = ry(p->y);
}

static BOOL WINAPI hk_ClipCursor(const RECT *rc) {
    RECT r2;
    if (scaled() && rc) {
        r2.left = rx(rc->left); r2.top = ry(rc->top); r2.right = rx(rc->right); r2.bottom = ry(rc->bottom);
        rc = &r2;
    }
    return real_ClipCursor(rc);
}

typedef BOOL(WINAPI *GCP_t)(LPPOINT);
typedef BOOL(WINAPI *SCP_t)(int, int);
typedef DWORD(WINAPI *GMP_t)(void);
typedef BOOL(WINAPI *GMA_t)(LPMSG, HWND, UINT, UINT);
typedef BOOL(WINAPI *PMA_t)(LPMSG, HWND, UINT, UINT, UINT);
typedef HWND(WINAPI *WFP_t)(POINT);
static GCP_t real_GetCursorPos;
static SCP_t real_SetCursorPos;
static GMP_t real_GetMessagePos;
static GMA_t real_GetMessageA;
static PMA_t real_PeekMessageA;
static WFP_t real_WindowFromPoint;

static BOOL WINAPI hk_GetCursorPos(LPPOINT p) {
    BOOL r = real_GetCursorPos(p);
    if (r && p) {
        POINT in = *p;
        map_screen_point(p);
        if (g_trace) {
            static POINT last;
            if (in.x != last.x || in.y != last.y) tlog("GetCursorPos %ld,%ld -> %ld,%ld", in.x, in.y, p->x, p->y);
            last = in;
        }
    }
    return r;
}

static BOOL WINAPI hk_SetCursorPos(int x, int y) {
    POINT p;
    p.x = x; p.y = y;
    unmap_screen_point(&p);
    if (g_trace) tlog("SetCursorPos %d,%d -> %ld,%ld", x, y, p.x, p.y);
    return real_SetCursorPos(p.x, p.y);
}

/* El motor también lee la posición del mouse de GetMessagePos y del campo pt de MSG. */
static DWORD WINAPI hk_GetMessagePos(void) {
    DWORD r = real_GetMessagePos();
    POINT p;
    if (!scaled()) return r;
    p.x = (short)LOWORD(r);
    p.y = (short)HIWORD(r);
    map_screen_point(&p);
    return MAKELONG((short)p.x, (short)p.y);
}

static BOOL WINAPI hk_GetMessageA(LPMSG m, HWND h, UINT a, UINT b) {
    BOOL r = real_GetMessageA(m, h, a, b);
    if (r != -1 && m) map_screen_point(&m->pt);
    return r;
}

static BOOL WINAPI hk_PeekMessageA(LPMSG m, HWND h, UINT a, UINT b, UINT rm) {
    BOOL r = real_PeekMessageA(m, h, a, b, rm);
    if (r && m) map_screen_point(&m->pt);
    return r;
}

static HWND WINAPI hk_WindowFromPoint(POINT p) {
    unmap_screen_point(&p);
    return real_WindowFromPoint(p);
}

/* ------------------------------------------------------------------ */
/* Registro virtual                                                     */
/* ------------------------------------------------------------------ */

/*
 * 3DMOVIE.EXE abre "Software\Microsoft\Microsoft Kids\3D Movie Maker" con
 * RegCreateKeyEx(KEY_ALL_ACCESS) en HKLM (InstallDirectory, Products) y en
 * HKCU (HomeDirectory, UserData, avisos). Sin permisos de administrador la
 * apertura en HKLM falla y el juego no arranca. Esa clave (y sus subclaves) se
 * sirve desde un INI (CP3D_REGFILE), sección = raíz + subclave:
 *
 *   [HKLM]           InstallDirectory=sz:C:\...\MSKIDS
 *   [HKLM\Products]  2=sz:3D Creador de Películas/3DMovie
 *   [HKCU]           HomeDirectory=sz:...   UserData=bin:0A0B...   BetterSpeed=dw:0
 *
 * Los handles falsos son direcciones de esta DLL: nunca coinciden con uno real.
 */
#define CP_REG_PREFIX "Software\\Microsoft\\Microsoft Kids\\3D Movie Maker"
#define CP_REG_MAXKEYS 32
#define CP_REG_VALMAX 4096

typedef struct { int used; char section[96]; } VKey;
static VKey g_vkeys[CP_REG_MAXKEYS];
static CRITICAL_SECTION g_regLock;

typedef LONG(WINAPI *RCKE_t)(HKEY, LPCSTR, DWORD, LPSTR, DWORD, REGSAM, LPSECURITY_ATTRIBUTES, PHKEY, LPDWORD);
typedef LONG(WINAPI *ROKE_t)(HKEY, LPCSTR, DWORD, REGSAM, PHKEY);
typedef LONG(WINAPI *RQVE_t)(HKEY, LPCSTR, LPDWORD, LPDWORD, LPBYTE, LPDWORD);
typedef LONG(WINAPI *RSVE_t)(HKEY, LPCSTR, DWORD, DWORD, const BYTE *, DWORD);
typedef LONG(WINAPI *REV_t)(HKEY, DWORD, LPSTR, LPDWORD, LPDWORD, LPDWORD, LPBYTE, LPDWORD);
typedef LONG(WINAPI *RCK_t)(HKEY);
static RCKE_t real_RegCreateKeyExA;
static ROKE_t real_RegOpenKeyExA;
static RQVE_t real_RegQueryValueExA;
static RSVE_t real_RegSetValueExA;
static REV_t real_RegEnumValueA;
static RCK_t real_RegCloseKey;

static VKey *vkey_of(HKEY h) {
    VKey *k = (VKey *)h;
    return (k >= g_vkeys && k < g_vkeys + CP_REG_MAXKEYS && k->used) ? k : NULL;
}

/* ¿root\sub pertenece a la clave virtual? Si sí, arma el nombre de sección. */
static int vkey_section(HKEY root, LPCSTR sub, char *section, size_t size) {
    const char *rootName;
    size_t n = strlen(CP_REG_PREFIX);
    VKey *parent = vkey_of(root);
    if (!g_regFile[0] || !sub) return 0;
    if (parent) {
        if (*sub) _snprintf(section, size, "%s\\%s", parent->section, sub);
        else _snprintf(section, size, "%s", parent->section);
        section[size - 1] = 0;
        return 1;
    }
    if (root == HKEY_LOCAL_MACHINE) rootName = "HKLM";
    else if (root == HKEY_CURRENT_USER) rootName = "HKCU";
    else return 0;
    if (_strnicmp(sub, CP_REG_PREFIX, n) != 0 || (sub[n] && sub[n] != '\\')) return 0;
    _snprintf(section, size, "%s%s", rootName, sub + n);
    section[size - 1] = 0;
    return 1;
}

static HKEY vkey_open(const char *section) {
    int i;
    EnterCriticalSection(&g_regLock);
    for (i = 0; i < CP_REG_MAXKEYS; i++) {
        if (!g_vkeys[i].used) {
            g_vkeys[i].used = 1;
            lstrcpynA(g_vkeys[i].section, section, sizeof g_vkeys[i].section);
            LeaveCriticalSection(&g_regLock);
            return (HKEY)&g_vkeys[i];
        }
    }
    LeaveCriticalSection(&g_regLock);
    return NULL;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decodifica "sz:texto", "dw:123" o "bin:A1B2..." en (tipo, datos, tamaño). */
static int decode_value(const char *v, DWORD *type, BYTE *out, DWORD *len) {
    if (!_strnicmp(v, "sz:", 3)) {
        *type = REG_SZ;
        *len = (DWORD)strlen(v + 3) + 1;
        memcpy(out, v + 3, *len);
    } else if (!_strnicmp(v, "dw:", 3)) {
        DWORD d = (DWORD)strtoul(v + 3, NULL, 0);
        *type = REG_DWORD;
        *len = sizeof d;
        memcpy(out, &d, sizeof d);
    } else if (!_strnicmp(v, "bin:", 4)) {
        const char *p = v + 4;
        DWORD n = 0;
        while (p[0] && p[1] && n < CP_REG_VALMAX) {
            int a = hexval(p[0]), b = hexval(p[1]);
            if (a < 0 || b < 0) break;
            out[n++] = (BYTE)(a * 16 + b);
            p += 2;
        }
        *type = REG_BINARY;
        *len = n;
    } else {
        return 0;
    }
    return 1;
}

static void encode_value(DWORD type, const BYTE *data, DWORD len, char *out, size_t size) {
    static const char hx[] = "0123456789ABCDEF";
    if (type == REG_SZ || type == REG_EXPAND_SZ) {
        _snprintf(out, size, "sz:%.*s", (int)(len && data[len - 1] == 0 ? len - 1 : len), (const char *)data);
    } else if (type == REG_DWORD && len >= 4) {
        _snprintf(out, size, "dw:%lu", *(const DWORD *)data);
    } else {
        size_t o = 4;
        DWORD i;
        lstrcpynA(out, "bin:", (int)size);
        for (i = 0; i < len && o + 2 < size; i++) {
            out[o++] = hx[data[i] >> 4];
            out[o++] = hx[data[i] & 15];
        }
        out[o] = 0;
    }
    out[size - 1] = 0;
}

/* Copia el valor al buffer del llamador con la semántica de RegQueryValueEx. */
static LONG give_value(DWORD type, const BYTE *val, DWORD len, LPDWORD ptype, LPBYTE data, LPDWORD cb) {
    LONG r = ERROR_SUCCESS;
    if (ptype) *ptype = type;
    if (data) {
        if (!cb) return ERROR_INVALID_PARAMETER;
        if (*cb < len) r = ERROR_MORE_DATA;
        else memcpy(data, val, len);
    }
    if (cb) *cb = len;
    return r;
}

static LONG WINAPI hk_RegCreateKeyExA(HKEY root, LPCSTR sub, DWORD res, LPSTR cls, DWORD opt, REGSAM sam,
                                      LPSECURITY_ATTRIBUTES sa, PHKEY out, LPDWORD disp) {
    char section[96];
    if (!vkey_section(root, sub, section, sizeof section))
        return real_RegCreateKeyExA(root, sub, res, cls, opt, sam, sa, out, disp);
    if (!out || !(*out = vkey_open(section))) return ERROR_NOT_ENOUGH_MEMORY;
    /* Siempre "ya existía": con los valores por omisión el juego escribe igual los que falten. */
    if (disp) *disp = REG_OPENED_EXISTING_KEY;
    if (g_trace) tlog("REG abrir [%s]", section);
    return ERROR_SUCCESS;
}

static LONG WINAPI hk_RegOpenKeyExA(HKEY root, LPCSTR sub, DWORD opt, REGSAM sam, PHKEY out) {
    char section[96];
    if (!vkey_section(root, sub, section, sizeof section)) return real_RegOpenKeyExA(root, sub, opt, sam, out);
    if (!out || !(*out = vkey_open(section))) return ERROR_NOT_ENOUGH_MEMORY;
    if (g_trace) tlog("REG abrir [%s]", section);
    return ERROR_SUCCESS;
}

static LONG WINAPI hk_RegQueryValueExA(HKEY h, LPCSTR name, LPDWORD res, LPDWORD type, LPBYTE data, LPDWORD cb) {
    VKey *k = vkey_of(h);
    char raw[CP_REG_VALMAX * 2 + 8];
    static BYTE val[CP_REG_VALMAX + 1];
    DWORD vtype, vlen;
    LONG r;
    if (!k) return real_RegQueryValueExA(h, name, res, type, data, cb);
    EnterCriticalSection(&g_regLock);
    GetPrivateProfileStringA(k->section, name && *name ? name : "@", "", raw, sizeof raw, g_regFile);
    if (!raw[0] || !decode_value(raw, &vtype, val, &vlen)) r = ERROR_FILE_NOT_FOUND;
    else r = give_value(vtype, val, vlen, type, data, cb);
    LeaveCriticalSection(&g_regLock);
    if (g_trace) tlog("REG leer [%s] %s -> %ld \"%s\"", k->section, name ? name : "@", r, raw);
    return r;
}

static LONG WINAPI hk_RegSetValueExA(HKEY h, LPCSTR name, DWORD res, DWORD type, const BYTE *data, DWORD cb) {
    VKey *k = vkey_of(h);
    char enc[CP_REG_VALMAX * 2 + 8];
    if (!k) return real_RegSetValueExA(h, name, res, type, data, cb);
    if (!data && cb) return ERROR_INVALID_PARAMETER;
    encode_value(type, data ? data : (const BYTE *)"", cb, enc, sizeof enc);
    EnterCriticalSection(&g_regLock);
    WritePrivateProfileStringA(k->section, name && *name ? name : "@", enc, g_regFile);
    LeaveCriticalSection(&g_regLock);
    if (g_trace) tlog("REG escribir [%s] %s = %s", k->section, name ? name : "@", enc);
    return ERROR_SUCCESS;
}

static LONG WINAPI hk_RegEnumValueA(HKEY h, DWORD idx, LPSTR name, LPDWORD cchName, LPDWORD res, LPDWORD type, LPBYTE data,
                                    LPDWORD cb) {
    VKey *k = vkey_of(h);
    static char sec[32768];
    static BYTE val[CP_REG_VALMAX + 1];
    char *p, *eq;
    DWORD i = 0, vtype, vlen, nlen;
    LONG r = ERROR_NO_MORE_ITEMS;
    if (!k) return real_RegEnumValueA(h, idx, name, cchName, res, type, data, cb);
    EnterCriticalSection(&g_regLock);
    if (GetPrivateProfileSectionA(k->section, sec, sizeof sec, g_regFile) > 0) {
        for (p = sec; *p; p += strlen(p) + 1) {
            eq = strchr(p, '=');
            if (!eq || i++ != idx) continue;
            *eq = 0;
            nlen = (DWORD)strlen(p);
            if (!cchName || !name || *cchName <= nlen) { r = ERROR_MORE_DATA; break; }
            memcpy(name, p, nlen + 1);
            *cchName = nlen;
            r = decode_value(eq + 1, &vtype, val, &vlen) ? give_value(vtype, val, vlen, type, data, cb) : ERROR_INVALID_DATA;
            break;
        }
    }
    LeaveCriticalSection(&g_regLock);
    if (g_trace) tlog("REG enumerar [%s] #%lu -> %ld %s", k->section, idx, r, r == ERROR_SUCCESS ? name : "");
    return r;
}

static LONG WINAPI hk_RegCloseKey(HKEY h) {
    VKey *k = vkey_of(h);
    if (!k) return real_RegCloseKey(h);
    k->used = 0;
    return ERROR_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Nombre de usuario                                                    */
/* ------------------------------------------------------------------ */

/*
 * La carpeta de películas es MSKIDS\Users\<nombre de usuario de red>. En cada
 * equipo ese nombre es distinto (en Proton, "steamuser"): devolvemos el nombre
 * de jugador configurado para que las películas sincronizadas aparezcan.
 */
typedef DWORD(WINAPI *WNGU_t)(LPCSTR, LPSTR, LPDWORD);
static WNGU_t real_WNetGetUserA;
static DWORD WINAPI hk_WNetGetUserA(LPCSTR local, LPSTR name, LPDWORD len) {
    DWORD n;
    if (!g_user[0]) return real_WNetGetUserA(local, name, len);
    n = (DWORD)strlen(g_user) + 1;
    if (!len) return ERROR_INVALID_PARAMETER;
    if (!name || *len < n) { *len = n; return ERROR_MORE_DATA; }
    memcpy(name, g_user, n);
    return NO_ERROR;
}

/* ------------------------------------------------------------------ */
/* Archivos                                                             */
/* ------------------------------------------------------------------ */

/*
 * Algunos motores de la época recorren cada carpeta de una ruta con
 * FindFirstFileA y descartan las que tienen el atributo oculto o de sistema; la
 * instalación predeterminada está bajo %LOCALAPPDATA%, dentro de AppData
 * (oculta). Ocultamos esos atributos al juego.
 */
#define CP_HIDE_ATTRS (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)
/* Sin atributos, Windows informa FILE_ATTRIBUTE_NORMAL (nunca 0). */
static DWORD visible_attrs(DWORD a) { a &= ~CP_HIDE_ATTRS; return a ? a : FILE_ATTRIBUTE_NORMAL; }
typedef HANDLE(WINAPI *FFFA_t)(LPCSTR, LPWIN32_FIND_DATAA);
typedef BOOL(WINAPI *FNFA_t)(HANDLE, LPWIN32_FIND_DATAA);
typedef DWORD(WINAPI *GFAA_t)(LPCSTR);
typedef HANDLE(WINAPI *CFA_t)(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
typedef HFILE(WINAPI *LO_t)(LPCSTR, int);
static FFFA_t real_FindFirstFileA;
static FNFA_t real_FindNextFileA;
static GFAA_t real_GetFileAttributesA;
static CFA_t real_CreateFileA;
static LO_t real__lopen;

static HANDLE WINAPI hk_FindFirstFileA(LPCSTR name, LPWIN32_FIND_DATAA fd) {
    HANDLE h = real_FindFirstFileA(name, fd);
    if (h != INVALID_HANDLE_VALUE && fd) fd->dwFileAttributes = visible_attrs(fd->dwFileAttributes);
    if (g_trace) tlog("FIND %s -> %s", name ? name : "(null)", h != INVALID_HANDLE_VALUE ? "ok" : "no");
    return h;
}

static BOOL WINAPI hk_FindNextFileA(HANDLE h, LPWIN32_FIND_DATAA fd) {
    BOOL r = real_FindNextFileA(h, fd);
    if (r && fd) fd->dwFileAttributes = visible_attrs(fd->dwFileAttributes);
    return r;
}

static DWORD WINAPI hk_GetFileAttributesA(LPCSTR name) {
    DWORD r = real_GetFileAttributesA(name);
    return r == INVALID_FILE_ATTRIBUTES ? r : visible_attrs(r);
}

static HANDLE WINAPI hk_CreateFileA(LPCSTR name, DWORD acc, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disp, DWORD flags, HANDLE tmpl) {
    HANDLE h = real_CreateFileA(name, acc, share, sa, disp, flags, tmpl);
    if (g_trace || h == INVALID_HANDLE_VALUE)
        tlog("FILE %s %s -> %s (err %lu)", (acc & GENERIC_WRITE) ? "W" : "R", name ? name : "(null)",
             h == INVALID_HANDLE_VALUE ? "FAIL" : "ok", h == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    return h;
}

/* API de archivos de Windows 3.1 (el motor la usa para algunos archivos): se registra igual. */
static HFILE WINAPI hk__lopen(LPCSTR name, int mode) {
    HFILE h = real__lopen(name, mode);
    if (g_trace || h == HFILE_ERROR)
        tlog("LOPEN %s mode=%x -> %s (err %lu)", name ? name : "(null)", mode, h == HFILE_ERROR ? "FAIL" : "ok",
             h == HFILE_ERROR ? GetLastError() : 0);
    return h;
}

/*
 * Los programas de la época calculan el espacio libre como clusters x sectores
 * x bytes en 32 bits: con discos actuales la cuenta desborda y puede dar "sin
 * espacio" al guardar. Limitamos lo informado a menos de 2 GB (como en Windows 95).
 */
typedef BOOL(WINAPI *GDFS_t)(LPCSTR, LPDWORD, LPDWORD, LPDWORD, LPDWORD);
static GDFS_t real_GetDiskFreeSpaceA;
static BOOL WINAPI hk_GetDiskFreeSpaceA(LPCSTR root, LPDWORD spc, LPDWORD bps, LPDWORD freeC, LPDWORD totalC) {
    DWORD a = 0, b = 0, f = 0, t = 0;
    BOOL r = real_GetDiskFreeSpaceA(root, &a, &b, &f, &t);
    if (r && a && b) {
        unsigned __int64 cluster = (unsigned __int64)a * b;
        DWORD maxC = (DWORD)(0x7FF00000ULL / cluster);
        if (f > maxC) f = maxC;
        if (t > maxC) t = maxC;
    }
    if (spc) *spc = a;
    if (bps) *bps = b;
    if (freeC) *freeC = f;
    if (totalC) *totalC = t;
    return r;
}

/* ------------------------------------------------------------------ */
/* Cambios globales del sistema y diálogos                              */
/* ------------------------------------------------------------------ */

typedef LONG(WINAPI *CDS_t)(DEVMODEA *, DWORD);
typedef BOOL(WINAPI *SSC_t)(int, const INT *, const COLORREF *);
typedef UINT(WINAPI *SSPU_t)(HDC, UINT);
typedef int(WINAPI *MBA_t)(HWND, LPCSTR, LPCSTR, UINT);
typedef HWND(WINAPI *CWEA_t)(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
typedef HMODULE(WINAPI *LLA_t)(LPCSTR);
static CDS_t real_ChangeDisplaySettingsA;
static SSC_t real_SetSysColors;
static SSPU_t real_SetSystemPaletteUse;
static MBA_t real_MessageBoxA;
static CWEA_t real_CreateWindowExA;
static LLA_t real_LoadLibraryA;

static LONG WINAPI hk_ChangeDisplaySettingsA(DEVMODEA *dm, DWORD flags) {
    tlog("ChangeDisplaySettingsA ignorado (%lux%lux%lu, flags %lx)", dm ? dm->dmPelsWidth : 0, dm ? dm->dmPelsHeight : 0,
         dm ? dm->dmBitsPerPel : 0, flags);
    return DISP_CHANGE_SUCCESSFUL;
}

static BOOL WINAPI hk_SetSysColors(int n, const INT *el, const COLORREF *rgb) {
    (void)el; (void)rgb;
    tlog("SetSysColors(%d) ignorado", n);
    return TRUE;
}

static UINT WINAPI hk_SetSystemPaletteUse(HDC dc, UINT use) {
    (void)dc; (void)use;
    return SYSPAL_STATIC;
}

static int WINAPI hk_MessageBoxA(HWND hwnd, LPCSTR text, LPCSTR caption, UINT type) {
    tlog("MessageBox [%s] \"%s\" type=%x", caption ? caption : "", text ? text : "", type);
    return real_MessageBoxA(hwnd, text, caption, type);
}

/* ------------------------------------------------------------------ */
/* Paleta                                                               */
/* ------------------------------------------------------------------ */

/*
 * Paleta del sistema emulada. Los motores arman una "paleta identidad": realizan
 * su paleta y la leen de vuelta con GetSystemPaletteEntries para armar la tabla
 * de colores de sus DIB. En color verdadero Windows 10 sigue informando una
 * paleta del sistema (los 20 colores estáticos más lo último que se realizó);
 * Wine / Proton devuelve 0 entradas y NUMRESERVED = -1, y los juegos quedan con
 * todos los colores en negro (6° Curso, ACES, KA-MFC). Si la pantalla no tiene
 * paleta y la llamada real no devuelve nada, respondemos como Windows.
 */
typedef UINT(WINAPI *GSPE_t)(HDC, UINT, UINT, LPPALETTEENTRY);
typedef UINT(WINAPI *RP_t)(HDC);
typedef int(WINAPI *GDC_t)(HDC, int);
static GSPE_t real_GetSystemPaletteEntries;
static RP_t real_RealizePalette;
static GDC_t real_GetDeviceCaps;
static PALETTEENTRY g_sysPal[256];
static int g_sysPalInit;

static void syspal_init(void) {
    static const DWORD statics[20] = {
        0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0, 0xC0DCC0, 0xA6CAF0,
        0xFFFBF0, 0xA0A0A4, 0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF };
    int i;
    if (g_sysPalInit) return;
    g_sysPalInit = 1;
    for (i = 0; i < 20; i++) {
        PALETTEENTRY *e = &g_sysPal[i < 10 ? i : 236 + i];
        e->peRed = (BYTE)(statics[i] >> 16); e->peGreen = (BYTE)(statics[i] >> 8); e->peBlue = (BYTE)statics[i]; e->peFlags = 0;
    }
}

static int has_palette(HDC dc) { return (real_GetDeviceCaps(dc, RASTERCAPS) & RC_PALETTE) != 0; }

static UINT WINAPI hk_GetSystemPaletteEntries(HDC dc, UINT start, UINT n, LPPALETTEENTRY pe) {
    UINT r = real_GetSystemPaletteEntries(dc, start, n, pe);
    if (r == 0 && start < 256 && !has_palette(dc)) {
        syspal_init();
        if (n > 256 - start) n = 256 - start;
        if (pe) memcpy(pe, &g_sysPal[start], n * sizeof *pe);
        r = n;
    }
    if (g_trace) tlog("GetSystemPaletteEntries(%u, %u) -> %u", start, n, r);
    return r;
}

/* Al realizar una paleta, sus colores pasan a la paleta del sistema emulada (como en primer plano en Windows). */
static UINT WINAPI hk_RealizePalette(HDC dc) {
    UINT r = real_RealizePalette(dc);
    HPALETTE pal = (HPALETTE)GetCurrentObject(dc, OBJ_PAL);
    PALETTEENTRY pe[256];
    UINT n, i;
    if (pal && !has_palette(dc) && (n = GetPaletteEntries(pal, 0, 256, pe)) > 0) {
        syspal_init();
        if (n == 256) {
            for (i = 10; i < 246; i++) g_sysPal[i] = pe[i];
        } else {
            for (i = 0; i < n && i < 236; i++) g_sysPal[10 + i] = pe[i];
        }
    }
    if (g_trace) tlog("RealizePalette(%p, ventana %p) -> %u", dc, WindowFromDC(dc), r);
    return r;
}

/* NUMRESERVED: Windows informa los 20 colores estáticos aunque la pantalla no tenga paleta; Wine, -1. */
static int WINAPI hk_GetDeviceCaps(HDC dc, int idx) {
    int r = real_GetDeviceCaps(dc, idx);
    if (idx == NUMRESERVED && r < 0) r = 20;
    if (g_trace && (idx == NUMRESERVED || idx == SIZEPALETTE || idx == RASTERCAPS || idx == BITSPIXEL || idx == PLANES))
        tlog("GetDeviceCaps(%d) -> %d", idx, r);
    return r;
}

/*
 * En color verdadero Windows no envía WM_QUERYNEWPALETTE, WM_PALETTECHANGED ni
 * WM_PALETTEISCHANGING (no hay paleta de pantalla); Wine sí, al activar la
 * ventana. ACES los atiende con assert(modo de 256 colores) y falla con
 * "Assertion failed: line 407 in file vgawin2". Las ventanas principales del
 * juego no ven esos mensajes si la pantalla no tiene paleta.
 */
#define CP_PAL_PROP "CreadorPalProc"

static int screen_has_palette(void) {
    static int cached = -1;
    if (cached < 0) {
        HDC dc = GetDC(NULL);
        cached = dc ? has_palette(dc) : 0;
        if (dc) ReleaseDC(NULL, dc);
    }
    return cached;
}

static LRESULT CALLBACK palette_filter_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    WNDPROC orig = (WNDPROC)GetPropA(h, CP_PAL_PROP);
    if ((m == WM_QUERYNEWPALETTE || m == WM_PALETTECHANGED || m == WM_PALETTEISCHANGING) && !screen_has_palette()) {
        if (g_trace) tlog("mensaje de paleta %04x ignorado (pantalla sin paleta)", m);
        return 0;
    }
    if (m == WM_NCDESTROY) RemovePropA(h, CP_PAL_PROP);
    return orig ? CallWindowProcA(orig, h, m, w, l) : DefWindowProcA(h, m, w, l);
}

static void filter_palette_messages(HWND h) {
    WNDPROC orig = (WNDPROC)GetWindowLongPtrA(h, GWLP_WNDPROC);
    if (!orig || orig == palette_filter_proc || !SetPropA(h, CP_PAL_PROP, (HANDLE)orig)) return;
    SetWindowLongPtrA(h, GWLP_WNDPROC, (LONG_PTR)palette_filter_proc);
}

static HWND WINAPI hk_CreateWindowExA(DWORD ex, LPCSTR cls, LPCSTR title, DWORD style, int x, int y, int w, int h,
                                      HWND parent, HMENU menu, HINSTANCE inst, LPVOID param) {
    HWND r;
    /* La ventana emergente de pantalla completa (640x480 en 0,0, porque le dijimos que la pantalla mide eso). */
    int screen = g_scale != 1 && g_mode == MODE_NONE && !parent && (style & WS_POPUP) && !(style & WS_CHILD) && x == 0 &&
                 y == 0 && w == LOGICAL_W && h == LOGICAL_H;
    if (screen) {
        g_scrW = real_GetSystemMetrics(SM_CXSCREEN);
        g_scrH = real_GetSystemMetrics(SM_CYSCREEN);
        w = g_scrW;
        h = g_scrH;
    }
    r = real_CreateWindowExA(ex, cls, title, style, x, y, w, h, parent, menu, inst, param);
    if (r && !(style & WS_CHILD)) filter_palette_messages(r);
    if (g_trace) tlog("CreateWindowEx class=%s title=%s style=%lx %d,%d %dx%d parent=%p -> %p",
                      ((ULONG_PTR)cls >> 16) ? cls : "(atom)", title ? title : "", style, x, y, w, h, parent, r);
    if (r && screen) adopt_screen(r);
    return r;
}

/* ------------------------------------------------------------------ */
/* Audio y parcheo de IAT                                               */
/* ------------------------------------------------------------------ */

typedef struct { const char *dll; const char *name; void *hook; void **real; } Hook;

static HMODULE WINAPI hk_LoadLibraryA(LPCSTR name);

/*
 * Audio: WSOUND32.DLL (1996) pasa el ID de dispositivo como entero de 16 bits,
 * así que WAVE_MAPPER (-1) llega como 0xFFFF. Windows 9x lo aceptaba; la pila
 * de audio actual puede quedarse bloqueada. Lo normalizamos.
 */
typedef MMRESULT(WINAPI *WOO_t)(LPHWAVEOUT, UINT, LPCWAVEFORMATEX, DWORD_PTR, DWORD_PTR, DWORD);
static WOO_t real_waveOutOpen;

/*
 * ¿El hilo actual tiene tomado el "loader lock"? (estamos dentro de un DllMain)
 * PEB (x86) +0xA0 = LoaderLock (RTL_CRITICAL_SECTION*), cuyo campo
 * OwningThread (+0x0C) es el id del hilo dueño.
 */
static int in_loader_lock(void) {
#ifdef _M_IX86
    BYTE *peb = (BYTE *)__readfsdword(0x30);
    RTL_CRITICAL_SECTION *cs = *(RTL_CRITICAL_SECTION **)(peb + 0xA0);
    return cs && (DWORD)(ULONG_PTR)cs->OwningThread == GetCurrentThreadId();
#else
    return 0;
#endif
}

static MMRESULT WINAPI hk_waveOutOpen(LPHWAVEOUT h, UINT dev, LPCWAVEFORMATEX fmt, DWORD_PTR cb, DWORD_PTR inst, DWORD flags) {
    MMRESULT r;
    DWORD t0 = GetTickCount();
    if (dev == 0xFFFF) dev = WAVE_MAPPER;
    /*
     * WSOUND32.DLL sondea el dispositivo de audio desde su DllMain. En Windows
     * moderno, abrir audio con el loader lock tomado produce un deadlock.
     * Respondemos "dispositivo ocupado" (MMSYSERR_ALLOCATED), que el motor
     * interpreta como "el formato está soportado" sin necesitar un handle.
     */
    if (in_loader_lock() && !(flags & WAVE_FORMAT_QUERY)) {
        tlog("waveOutOpen dentro de DllMain: se responde MMSYSERR_ALLOCATED para evitar el bloqueo");
        return MMSYSERR_ALLOCATED;
    }
    r = real_waveOutOpen(h, dev, fmt, cb, inst, flags);
    if (g_trace)
        tlog("waveOutOpen dev=%d fmt=%u ch=%u %luHz %ubits flags=%lx -> %u (%lu ms)", (int)dev, fmt ? fmt->wFormatTag : 0,
             fmt ? fmt->nChannels : 0, fmt ? fmt->nSamplesPerSec : 0, fmt ? fmt->wBitsPerSample : 0, flags, r,
             GetTickCount() - t0);
    return r;
}

/*
 * waveOutClose / waveOutReset pueden bloquearse para siempre si se llaman
 * desde el hilo de la interfaz sin procesar mensajes (el servicio de audio de
 * Windows necesita que ese hilo responda). Los ejecutamos en un hilo auxiliar
 * mientras el hilo del juego sigue procesando mensajes, con un tiempo máximo.
 */
typedef MMRESULT(WINAPI *WOH_t)(HWAVEOUT);
static WOH_t real_waveOutClose, real_waveOutReset;
typedef struct { WOH_t fn; HWAVEOUT h; volatile MMRESULT r; } WaveJob;

static DWORD WINAPI wave_worker(LPVOID p) {
    WaveJob *j = (WaveJob *)p;
    j->r = j->fn(j->h);
    return 0;
}

static MMRESULT run_wave_pumping(WOH_t fn, HWAVEOUT h, const char *name) {
    WaveJob *j;
    HANDLE th;
    DWORD start = GetTickCount();
    int quit = 0;
    WPARAM quitCode = 0;
    MMRESULT r;
    if (!fn) return MMSYSERR_ERROR;
    /*
     * Con el loader lock tomado (WSOUND32 cierra el audio en su DllMain al
     * terminar el proceso) la llamada real se bloquea para siempre. El proceso
     * está terminando y Windows libera el dispositivo igual: no hacemos nada.
     */
    if (in_loader_lock()) {
        tlog("%s dentro de DllMain: se omite para evitar el bloqueo al salir", name);
        return MMSYSERR_NOERROR;
    }
    j = (WaveJob *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *j);
    if (!j) return fn(h);
    j->fn = fn; j->h = h; j->r = MMSYSERR_NOERROR;
    th = CreateThread(NULL, 0, wave_worker, j, 0, NULL);
    if (!th) { HeapFree(GetProcessHeap(), 0, j); return fn(h); }
    for (;;) {
        MSG m;
        DWORD w = MsgWaitForMultipleObjects(1, &th, FALSE, 50, QS_ALLINPUT);
        if (w == WAIT_OBJECT_0) break;
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
            if (m.message == WM_QUIT) { quit = 1; quitCode = m.wParam; continue; }
            TranslateMessage(&m);
            DispatchMessageA(&m);
        }
        if (GetTickCount() - start > 4000) {
            tlog("%s no respondió en 4 s: se continúa sin esperar", name);
            CloseHandle(th);
            if (quit) PostQuitMessage((int)quitCode);
            return MMSYSERR_NOERROR; /* el hilo auxiliar conserva el bloque j */
        }
    }
    CloseHandle(th);
    r = j->r;
    HeapFree(GetProcessHeap(), 0, j);
    if (quit) PostQuitMessage((int)quitCode);
    if (g_trace) tlog("%s(%p) -> %u (%lu ms)", name, h, r, GetTickCount() - start);
    return r;
}

static MMRESULT WINAPI hk_waveOutClose(HWAVEOUT h) { return run_wave_pumping(real_waveOutClose, h, "waveOutClose"); }
static MMRESULT WINAPI hk_waveOutReset(HWAVEOUT h) { return run_wave_pumping(real_waveOutReset, h, "waveOutReset"); }

/* Diagnóstico (solo con traza): ¿el juego realmente envía audio y con qué volumen? */
typedef MMRESULT(WINAPI *WOW_t)(HWAVEOUT, LPWAVEHDR, UINT);
typedef MMRESULT(WINAPI *WOSV_t)(HWAVEOUT, DWORD);
static WOW_t real_waveOutWrite;
static WOSV_t real_waveOutSetVolume;
static MMRESULT WINAPI hk_waveOutWrite(HWAVEOUT h, LPWAVEHDR hdr, UINT size) {
    MMRESULT r = real_waveOutWrite(h, hdr, size);
    if (g_trace) {
        static LONG n;
        LONG k = InterlockedIncrement(&n);
        if (k <= 5 || (k % 50) == 0) {
            int mn = 255, mx = 0;
            DWORD i;
            if (hdr && hdr->lpData)
                for (i = 0; i < hdr->dwBufferLength; i++) {
                    int v = (BYTE)hdr->lpData[i];
                    if (v < mn) mn = v;
                    if (v > mx) mx = v;
                }
            tlog("waveOutWrite #%ld %p %lu bytes -> %u (muestras %d..%d)", k, h, hdr ? hdr->dwBufferLength : 0, r, mn, mx);
        }
    }
    return r;
}
static MMRESULT WINAPI hk_waveOutSetVolume(HWAVEOUT h, DWORD vol) {
    MMRESULT r = real_waveOutSetVolume(h, vol);
    if (g_trace) tlog("waveOutSetVolume %p %08lX -> %u", h, vol, r);
    return r;
}

static Hook g_hooks[] = {
    { "KERNEL32.DLL", "CreateFileA", hk_CreateFileA, (void **)&real_CreateFileA },
    { "KERNEL32.DLL", "_lopen", hk__lopen, (void **)&real__lopen },
    { "KERNEL32.DLL", "GetFileAttributesA", hk_GetFileAttributesA, (void **)&real_GetFileAttributesA },
    { "KERNEL32.DLL", "FindFirstFileA", hk_FindFirstFileA, (void **)&real_FindFirstFileA },
    { "KERNEL32.DLL", "FindNextFileA", hk_FindNextFileA, (void **)&real_FindNextFileA },
    { "KERNEL32.DLL", "GetDiskFreeSpaceA", hk_GetDiskFreeSpaceA, (void **)&real_GetDiskFreeSpaceA },
    { "KERNEL32.DLL", "LoadLibraryA", hk_LoadLibraryA, (void **)&real_LoadLibraryA },
    { "KERNEL32.DLL", "SetUnhandledExceptionFilter", hk_SetUnhandledExceptionFilter, (void **)&real_SetUnhandledExceptionFilter },
    { "ADVAPI32.DLL", "RegCreateKeyExA", hk_RegCreateKeyExA, (void **)&real_RegCreateKeyExA },
    { "ADVAPI32.DLL", "RegOpenKeyExA", hk_RegOpenKeyExA, (void **)&real_RegOpenKeyExA },
    { "ADVAPI32.DLL", "RegQueryValueExA", hk_RegQueryValueExA, (void **)&real_RegQueryValueExA },
    { "ADVAPI32.DLL", "RegSetValueExA", hk_RegSetValueExA, (void **)&real_RegSetValueExA },
    { "ADVAPI32.DLL", "RegEnumValueA", hk_RegEnumValueA, (void **)&real_RegEnumValueA },
    { "ADVAPI32.DLL", "RegCloseKey", hk_RegCloseKey, (void **)&real_RegCloseKey },
    { "MPR.DLL", "WNetGetUserA", hk_WNetGetUserA, (void **)&real_WNetGetUserA },
    { "USER32.DLL", "ChangeDisplaySettingsA", hk_ChangeDisplaySettingsA, (void **)&real_ChangeDisplaySettingsA },
    { "USER32.DLL", "SetSysColors", hk_SetSysColors, (void **)&real_SetSysColors },
    { "USER32.DLL", "MessageBoxA", hk_MessageBoxA, (void **)&real_MessageBoxA },
    { "USER32.DLL", "CreateWindowExA", hk_CreateWindowExA, (void **)&real_CreateWindowExA },
    { "USER32.DLL", "GetSystemMetrics", hk_GetSystemMetrics, (void **)&real_GetSystemMetrics },
    { "USER32.DLL", "GetDC", hk_GetDC, (void **)&real_GetDC },
    { "USER32.DLL", "ReleaseDC", hk_ReleaseDC, (void **)&real_ReleaseDC },
    { "USER32.DLL", "BeginPaint", hk_BeginPaint, (void **)&real_BeginPaint },
    { "USER32.DLL", "EndPaint", hk_EndPaint, (void **)&real_EndPaint },
    { "USER32.DLL", "GetUpdateRect", hk_GetUpdateRect, (void **)&real_GetUpdateRect },
    { "USER32.DLL", "GetClientRect", hk_GetClientRect, (void **)&real_GetClientRect },
    { "USER32.DLL", "GetWindowRect", hk_GetWindowRect, (void **)&real_GetWindowRect },
    { "USER32.DLL", "InvalidateRect", hk_InvalidateRect, (void **)&real_InvalidateRect },
    { "USER32.DLL", "ValidateRect", hk_ValidateRect, (void **)&real_ValidateRect },
    { "USER32.DLL", "SetWindowPos", hk_SetWindowPos, (void **)&real_SetWindowPos },
    { "USER32.DLL", "MoveWindow", hk_MoveWindow, (void **)&real_MoveWindow },
    { "USER32.DLL", "ScrollWindowEx", hk_ScrollWindowEx, (void **)&real_ScrollWindowEx },
    { "USER32.DLL", "ScrollDC", hk_ScrollDC, (void **)&real_ScrollDC },
    { "USER32.DLL", "ClipCursor", hk_ClipCursor, (void **)&real_ClipCursor },
    { "USER32.DLL", "FillRect", hk_FillRect, (void **)&real_FillRect },
    { "USER32.DLL", "InvertRect", hk_InvertRect, (void **)&real_InvertRect },
    { "USER32.DLL", "GetCursorPos", hk_GetCursorPos, (void **)&real_GetCursorPos },
    { "USER32.DLL", "SetCursorPos", hk_SetCursorPos, (void **)&real_SetCursorPos },
    { "USER32.DLL", "GetMessagePos", hk_GetMessagePos, (void **)&real_GetMessagePos },
    { "USER32.DLL", "GetMessageA", hk_GetMessageA, (void **)&real_GetMessageA },
    { "USER32.DLL", "PeekMessageA", hk_PeekMessageA, (void **)&real_PeekMessageA },
    { "USER32.DLL", "WindowFromPoint", hk_WindowFromPoint, (void **)&real_WindowFromPoint },
    { "GDI32.DLL", "SetSystemPaletteUse", hk_SetSystemPaletteUse, (void **)&real_SetSystemPaletteUse },
    { "GDI32.DLL", "GetSystemPaletteEntries", hk_GetSystemPaletteEntries, (void **)&real_GetSystemPaletteEntries },
    { "GDI32.DLL", "RealizePalette", hk_RealizePalette, (void **)&real_RealizePalette },
    { "GDI32.DLL", "GetDeviceCaps", hk_GetDeviceCaps, (void **)&real_GetDeviceCaps },
    { "GDI32.DLL", "StretchBlt", hk_StretchBlt, (void **)&real_StretchBlt },
    { "MSVFW32.DLL", "DrawDibDraw", hk_DrawDibDraw, (void **)&real_DrawDibDraw },
    { "WINMM.DLL", "mciSendCommandA", hk_mciSendCommandA, (void **)&real_mciSendCommandA },
};
#define NHOOKS (sizeof g_hooks / sizeof g_hooks[0])

static void resolve_reals(void) {
    size_t i;
    for (i = 0; i < NHOOKS; i++) {
        HMODULE m = GetModuleHandleA(g_hooks[i].dll);
        if (!m) m = LoadLibraryA(g_hooks[i].dll);
        *g_hooks[i].real = m ? (void *)GetProcAddress(m, g_hooks[i].name) : NULL;
    }
}

static int patch_module(HMODULE mod) {
    BYTE *base = (BYTE *)mod;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    int patched = 0;
    if (!mod || dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++) {
        const char *dll = (const char *)(base + imp->Name);
        IMAGE_THUNK_DATA *names, *addrs;
        size_t i;
        int relevant = 0;
        for (i = 0; i < NHOOKS; i++) if (_stricmp(dll, g_hooks[i].dll) == 0) relevant = 1;
        if (!relevant) continue;
        names = (IMAGE_THUNK_DATA *)(base + (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
        addrs = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++) {
            const char *fn;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            fn = (const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name;
            for (i = 0; i < NHOOKS; i++) {
                if (_stricmp(dll, g_hooks[i].dll) == 0 && strcmp(fn, g_hooks[i].name) == 0 && *g_hooks[i].real) {
                    DWORD old;
                    if (VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) {
                        addrs->u1.Function = (ULONG_PTR)g_hooks[i].hook;
                        VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
                        patched++;
                    }
                }
            }
        }
    }
    return patched;
}

/*
 * Parchea en la IAT de `mod` la importación `fn` (de cualquier DLL) y devuelve
 * en *orig el destino original. Se usa sobre winmm.dll, cuyas funciones
 * exportadas son stubs que saltan por su propia IAT: así se intercepta a todos
 * los llamadores del proceso, incluso a DLLs que todavía están en su DllMain.
 */
static int patch_import_any(HMODULE mod, const char *fn, void *hook, void **orig) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    if (!mod) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++) {
        IMAGE_THUNK_DATA *names, *addrs;
        if (!imp->OriginalFirstThunk) continue;
        names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        addrs = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++) {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, fn) != 0) continue;
            if (!VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) return 0;
            *orig = (void *)addrs->u1.Function;
            addrs->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
            return 1;
        }
    }
    return 0;
}

/* Igual que patch_import_any, pero sobre la tabla de importaciones diferidas (delay-load). */
static int patch_delay_import_any(HMODULE mod, const char *fn, void *hook) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_DELAYLOAD_DESCRIPTOR *d;
    if (!mod) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (d = (IMAGE_DELAYLOAD_DESCRIPTOR *)(base + dir->VirtualAddress); d->DllNameRVA; d++) {
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + d->ImportNameTableRVA);
        IMAGE_THUNK_DATA *addrs = (IMAGE_THUNK_DATA *)(base + d->ImportAddressTableRVA);
        for (; names->u1.AddressOfData; names++, addrs++) {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, fn) != 0) continue;
            if (!VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) return 0;
            addrs->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
            return 1;
        }
    }
    return 0;
}

/*
 * Reemplaza en la tabla de exportaciones de `mod` la dirección de `fn`: los
 * módulos que se carguen después (y GetProcAddress) reciben el hook. Se usa
 * cuando winmm.dll implementa las funciones directamente (Wine / Proton), sin
 * stubs que salten por su IAT. En un proceso de 32 bits el RVA puede quedar
 * "negativo" (hook debajo de la base): la suma base + RVA da la vuelta igual.
 */
static int patch_export(HMODULE mod, const char *fn, void *hook) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_EXPORT_DIRECTORY *exp;
    DWORD *names, *funcs, i;
    WORD *ords;
    if (!mod) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!dir->VirtualAddress) return 0;
    exp = (IMAGE_EXPORT_DIRECTORY *)(base + dir->VirtualAddress);
    names = (DWORD *)(base + exp->AddressOfNames);
    ords = (WORD *)(base + exp->AddressOfNameOrdinals);
    funcs = (DWORD *)(base + exp->AddressOfFunctions);
    for (i = 0; i < exp->NumberOfNames; i++) {
        DWORD old, *slot;
        if (strcmp((const char *)(base + names[i]), fn) != 0) continue;
        slot = &funcs[ords[i]];
        if (!VirtualProtect(slot, sizeof *slot, PAGE_READWRITE, &old)) return 0;
        *slot = (DWORD)((ULONG_PTR)hook - (ULONG_PTR)base);
        VirtualProtect(slot, sizeof *slot, old, &old);
        return 1;
    }
    return 0;
}

/*
 * Intercepta waveOutOpen para todo el proceso. En Windows 10 winmm.dll exporta
 * un stub que salta (vía import normal o diferida) a winmmbase.dll. En Wine las
 * funciones están en winmm.dll mismo: se parchea su tabla de exportaciones, así
 * WSOUND32.DLL (que se carga después y abre el audio en su DllMain) usa el hook.
 */
static void hook_winmm_fn(HMODULE winmm, HMODULE base, const char *name, void *hook, void **real) {
    void *orig = NULL;
    *real = base ? (void *)GetProcAddress(base, name) : NULL;
    if (patch_import_any(winmm, name, hook, &orig)) {
        if (!*real) *real = orig;
    } else if (*real && patch_delay_import_any(winmm, name, hook)) {
        /* listo: import diferida hacia winmmbase.dll */
    } else {
        *real = (void *)GetProcAddress(winmm, name);
        if (*real && patch_export(winmm, name, hook)) tlog("%s interceptada en la tabla de exportaciones de winmm.dll", name);
        else tlog("aviso: no se pudo interceptar %s en winmm.dll", name);
    }
}

static void hook_winmm(void) {
    HMODULE winmm = GetModuleHandleA("winmm.dll");
    HMODULE base = GetModuleHandleA("winmmbase.dll");
    if (!winmm) winmm = LoadLibraryA("winmm.dll");
    if (!base) base = LoadLibraryA("winmmbase.dll");
    hook_winmm_fn(winmm, base, "waveOutOpen", hk_waveOutOpen, (void **)&real_waveOutOpen);
    hook_winmm_fn(winmm, base, "waveOutClose", hk_waveOutClose, (void **)&real_waveOutClose);
    hook_winmm_fn(winmm, base, "waveOutReset", hk_waveOutReset, (void **)&real_waveOutReset);
    hook_winmm_fn(winmm, base, "waveOutWrite", hk_waveOutWrite, (void **)&real_waveOutWrite);
    hook_winmm_fn(winmm, base, "waveOutSetVolume", hk_waveOutSetVolume, (void **)&real_waveOutSetVolume);
}

/*
 * DPI: con el escalado de Windows (p. ej. 125 %), a un programa antiguo
 * Windows le "virtualiza" las coordenadas (pantalla de 1536x864 en lugar de
 * 1920x1080), pero no todas las API de mouse lo hacen igual: al arrastrar, el
 * puntero del juego avanzaba ~80 % de lo que avanzaba el mouse real. Declaramos
 * el proceso consciente de DPI antes de que cree ventanas: todas las API hablan
 * en píxeles físicos y nosotros ya escalamos la imagen.
 * CP3D_DPIAWARE=0 lo desactiva (diagnóstico).
 */
static void make_dpi_aware(void) {
    typedef BOOL(WINAPI *SPDAC_t)(HANDLE);
    typedef BOOL(WINAPI *SPDA_t)(void);
    char v[8];
    HMODULE u = GetModuleHandleA("user32.dll");
    SPDAC_t ctx;
    read_env("CP3D_DPIAWARE", v, sizeof v);
    if (v[0] == '0' || !u) return;
    ctx = (SPDAC_t)GetProcAddress(u, "SetProcessDpiAwarenessContext");
    if (ctx && ctx((HANDLE)-4 /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */)) { tlog("DPI: proceso consciente de DPI (por monitor v2)"); return; }
    {
        SPDA_t old = (SPDA_t)GetProcAddress(u, "SetProcessDPIAware");
        if (old && old()) tlog("DPI: proceso consciente de DPI (sistema)");
        else tlog("aviso: no se pudo declarar el proceso consciente de DPI (err %lu)", GetLastError());
    }
}

static int is_system_module(HMODULE m) {
    char path[MAX_PATH], win[MAX_PATH];
    UINT n = GetWindowsDirectoryA(win, sizeof win);
    if (!GetModuleFileNameA(m, path, sizeof path)) return 1;
    return n && _strnicmp(path, win, n) == 0;
}

/* Las DLLs del propio juego (si las hubiera) se cargan luego: también se parchean. */
static HMODULE WINAPI hk_LoadLibraryA(LPCSTR name) {
    HMODULE m = real_LoadLibraryA(name);
    int n = -1;
    if (m && m != g_self && !is_system_module(m)) n = patch_module(m);
    if (g_trace || n > 0) tlog("LoadLibrary %s -> %p (%d hooks)", name ? name : "(null)", m, n);
    return m;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        char exe[MAX_PATH];
        int n;
        g_self = inst;
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&g_logLock);
        InitializeCriticalSection(&g_regLock);
        load_config();
        resolve_reals();
        SetUnhandledExceptionFilter(crash_filter);
        make_dpi_aware();
        n = patch_module(GetModuleHandleA(NULL));
        hook_winmm();
        GetModuleFileNameA(NULL, exe, sizeof exe);
        tlog("cphook cargado en %s: %d funciones interceptadas; registro=%s usuario=%s escala=%d", exe, n,
             g_regFile[0] ? g_regFile : "(sistema)", g_user[0] ? g_user : "(Windows)", g_scale);
    } else if (reason == DLL_PROCESS_DETACH) {
        tlog("cphook descargado");
        if (g_log) fclose(g_log);
        g_log = NULL;
    }
    return TRUE;
}
