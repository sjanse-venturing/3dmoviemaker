/*
 * cplaunch.exe — lanza el juego con cphook.dll inyectado.
 *
 * Uso:
 *   cplaunch.exe [--nohook] [--affinity N] [--wait] --cwd <dir> -- <exe> [argumentos...]
 *
 * La configuración del hook se pasa por variables de entorno CP3D_*
 * (ver cphook.c), que el proceso hijo hereda.
 *
 * Códigos de salida:
 *   0..N  código de salida del juego (con --wait)
 *   9001  argumentos inválidos
 *   9002  no se pudo crear el proceso
 *   9003  no se pudo inyectar cphook.dll
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* msg está en UTF-8 (este archivo fuente es UTF-8); se muestra con la API W para que los acentos se vean bien. */
static void fail_box(const char *msg, DWORD err) {
    WCHAR text[2048], sys[512] = L"";
    int n;
    if (GetEnvironmentVariableA("CP3D_QUIET", NULL, 0)) return;
    n = MultiByteToWideChar(CP_UTF8, 0, msg, -1, text, 1500);
    if (n <= 0) text[0] = 0;
    if (err && FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, err, 0, sys, 512, NULL)) {
        lstrcatW(text, L"\n\n");
        lstrcatW(text, sys);
    }
    MessageBoxW(NULL, text, L"Creador de Pel\x00edculas 3D", MB_ICONERROR | MB_OK);
}

static int inject(HANDLE proc, const char *dll) {
    SIZE_T len = strlen(dll) + 1, written = 0;
    LPVOID mem = VirtualAllocEx(proc, NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    HANDLE th;
    DWORD code = 0;
    LPTHREAD_START_ROUTINE loadLib = (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA");
    if (!mem) return 0;
    if (!WriteProcessMemory(proc, mem, dll, len, &written) || written != len) return 0;
    th = CreateRemoteThread(proc, NULL, 0, loadLib, mem, 0, NULL);
    if (!th) return 0;
    WaitForSingleObject(th, 30000);
    GetExitCodeThread(th, &code);
    CloseHandle(th);
    VirtualFreeEx(proc, mem, 0, MEM_RELEASE);
    return code != 0;
}

/* Copia el resto de la línea de comandos original a partir del token "--". */
static const char *after_dashdash(const char *cmd) {
    const char *p = strstr(cmd, " -- ");
    return p ? p + 4 : NULL;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdLine, int show) {
    int argc = __argc, i, hook = 1, wait = 0;
    char **argv = __argv;
    const char *cwd = NULL, *rest;
    DWORD_PTR affinity = 0;
    char dll[MAX_PATH], *slash, cmd[4096];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD exitCode = 0;
    (void)inst; (void)prev; (void)cmdLine; (void)show;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nohook")) hook = 0;
        else if (!strcmp(argv[i], "--wait")) wait = 1;
        else if (!strcmp(argv[i], "--affinity") && i + 1 < argc) affinity = (DWORD_PTR)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--cwd") && i + 1 < argc) cwd = argv[++i];
        else if (!strcmp(argv[i], "--")) break;
    }
    rest = after_dashdash(GetCommandLineA());
    if (i >= argc || !rest || !*rest) {
        fail_box("Uso: cplaunch.exe [--nohook] [--wait] [--affinity N] --cwd <dir> -- <exe> [args]", 0);
        return 9001;
    }
    lstrcpynA(cmd, rest, sizeof cmd);

    GetModuleFileNameA(NULL, dll, sizeof dll);
    slash = strrchr(dll, '\\');
    if (slash) lstrcpyA(slash + 1, "cphook.dll");

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, cwd, &si, &pi)) {
        DWORD e = GetLastError();
        char msg[1200];
        _snprintf(msg, sizeof msg, "No se pudo iniciar 3D Creador de Películas:\n%s", cmd);
        msg[sizeof msg - 1] = 0;
        fail_box(msg, e);
        return 9002;
    }
    if (affinity) SetProcessAffinityMask(pi.hProcess, affinity);
    if (hook && !inject(pi.hProcess, dll)) {
        DWORD e = GetLastError();
        TerminateProcess(pi.hProcess, 9003);
        fail_box("No se pudo activar la capa de compatibilidad (cphook.dll). Es posible que un antivirus la esté bloqueando.", e);
        return 9003;
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    if (wait) {
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &exitCode);
    }
    CloseHandle(pi.hProcess);
    return (int)exitCode;
}
