@echo off
rem Compila los componentes nativos (x86) de Creador de Peliculas 3D Runtime con MSVC.
rem Uso: build.cmd            (salida en runtime\native\bin)
rem Las rutas van entre comillas: la carpeta del proyecto puede tener espacios.
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
set "OUT=%HERE%bin"
set "OBJ=%HERE%obj"

if not defined VSCMD_ARG_TGT_ARCH (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo [ERROR] No se encontro Visual Studio / Build Tools. Instale "Desktop development with C++".
    exit /b 2
  )
  for /f "usebackq tokens=*" %%i in (`call "!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
  if not defined VSINSTALL (
    echo [ERROR] No se encontro el compilador de C++ ^(componente VC.Tools.x86.x64^).
    exit /b 2
  )
  call "!VSINSTALL!\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul || (echo [ERROR] vcvarsall fallo & exit /b 2)
)
if /i not "%VSCMD_ARG_TGT_ARCH%"=="x86" (
  echo [ERROR] El entorno de compilacion no es x86 ^(es %VSCMD_ARG_TGT_ARCH%^).
  exit /b 2
)

if not exist "%OUT%" mkdir "%OUT%"
if not exist "%OBJ%" mkdir "%OBJ%"
set "CFLAGS=/nologo /utf-8 /O2 /W3 /MT /GS- /D_CRT_SECURE_NO_WARNINGS"

echo === cphook.dll
cl %CFLAGS% /Fo"%OBJ%\\" /LD "%HERE%cphook\cphook.c" /Fe"%OUT%\cphook.dll" /link gdi32.lib user32.lib kernel32.lib shell32.lib winmm.lib || exit /b 1

echo === cplaunch.exe
cl %CFLAGS% /Fo"%OBJ%\\" "%HERE%cplaunch\cplaunch.c" /Fe"%OUT%\cplaunch.exe" /link /SUBSYSTEM:WINDOWS user32.lib kernel32.lib || exit /b 1

del /q "%OUT%\*.exp" "%OUT%\*.lib" 2>nul
echo OK: binarios en %OUT%
exit /b 0
