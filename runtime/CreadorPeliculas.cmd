@echo off
rem Creador de Peliculas 3D Runtime - doble clic para instalar o abrir 3D Creador de Peliculas.
rem Usa Windows PowerShell 5.1 (incluido en Windows 10/11); no requiere permisos de administrador.
if not exist "%~dp0src\CreadorPeliculas.ps1" (
  echo No se encontraron los archivos del programa. Descomprima el ZIP completo antes de ejecutar.
  pause
  exit /b 1
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\CreadorPeliculas.ps1" %*
