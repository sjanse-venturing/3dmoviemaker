# RUNTIME — Ejecutar Microsoft 3D Creador de Películas en Windows 10/11 x64 y en Linux / Steam Deck, sin máquina virtual

> **Objetivo:** que el CD original de **Microsoft 3D Creador de Películas** (edición en español de *3D Movie Maker*, Microsoft Kids, 1995-96; imagen `MS3DMM01E01.ISO`) se instale y funcione en Windows 10/11 de 64 bits **de forma nativa**, sin VM, sin emulador, sin modificar la ISO ni los archivos del juego y sin tocar el sistema (ni el registro de Windows ni `C:\Windows`), con mejoras de calidad de vida: pantalla completa escalada, películas sincronizadas entre equipos, Steam con artwork, Steam Deck.
>
> **Producto final:** *Creador de Películas 3D Runtime* = `CreadorPeliculas.cmd` (doble clic) → asistente gráfico de instalación + ventana del programa con UI, manejo de errores amigable, log técnico, y el documento de usuario `README.md` (en el paquete y en la instalación, `LEEME.txt`). En Linux / Steam Deck, el mismo paquete trae `creador.sh` (Python + Tk) que ejecuta el juego con **Proton** usando las mismas piezas nativas.
>
> **Arquitectura:** catálogo declarativo (`games.json`), núcleo sin UI en PowerShell con un espejo en Python para Linux, capa nativa propia configurada por variables de entorno, catálogo de errores, sincronización, Steam y empaquetado portable.

---

## 0. Estado de la implementación (validado el 2026-10-24)

> **Implementado y funcionando en Windows 10 x64** (equipo de desarrollo, monitor 1366×768, escala 100 %): instalación desde la ISO con el asistente y por línea de comandos, bienvenida de McZee de primera vez, menú, Imaginópolis, vídeos, estudio (escenarios, actores 3D, arrastre), guardar y abrir películas, salida limpia, en pantalla completa escalada y en ventana. **Linux / Steam Deck**: implementado y con pruebas automáticas en Windows; **falta validar a mano en el Deck** (ver §11.3). Esta sección manda sobre el resto cuando difieren.

### 0.1 Qué se construyó

| Pieza | Archivo(s) | Función |
|---|---|---|
| Instalador + ventana del programa (UI) | `runtime/CreadorPeliculas.cmd`, `runtime/src/CreadorPeliculas.ps1`, `runtime/src/UI/*.ps1` | Asistente WinForms (bienvenida, disco, confirmación, carpeta + jugador, pantalla/Steam/`.3MM`, resumen, progreso, final), ventana con tarjeta «▶ Crear películas», películas, sincronización, Steam, opciones |
| Núcleo | `runtime/src/Core/CreadorPeliculas.Core.psm1`, `.Errors.psm1`, `.Sync.psm1`, `.Steam.psm1`, `CpIso.cs` | Lector ISO9660/Joliet propio (sin montar), receta de instalación, registro virtual, lanzamiento, películas (copias, importar/exportar), sincronización, Steam + artwork, autoactualización local, log |
| Catálogo | `runtime/src/data/games.json`, `strings.es.json`, `sync.json` | Receta validada (`layout`, `registry`, `saves`, `art`…), errores `3DM-*` en español, límites de la sincronización |
| `cphook.dll` | `runtime/native/cphook/cphook.c` | Capa de compatibilidad por IAT: registro virtual, usuario estable, pantalla completa escalada (redirección del DC), vídeo MCI, diálogos, paleta en Wine, fallos |
| `cplaunch.exe` | `runtime/native/cplaunch/cplaunch.c` | Crea el juego suspendido, inyecta `cphook.dll`, espera |
| Linux / Steam Deck | `runtime/creador.sh`, `runtime/linux/` | Espejo en Python + Tk del núcleo y la UI; Proton |
| Pruebas / empaquetado | `runtime/tests/Run-Tests.ps1`, `runtime/tests/test_linux.py`, `runtime/build.ps1`, `runtime/build.sh` | Pruebas unitarias + integración con la ISO; `dist\CreadorPeliculasRuntime-<v>.zip` |

### 0.2 Causas reales encontradas y su corrección

| # | Síntoma | Causa (confirmada con el código fuente publicado por Microsoft, trazas y pruebas) | Corrección |
|---|---|---|---|
| 1 | El instalador no corre | `INSTALAR.EXE` / `SETUP\ACMSETUP.EXE` es el *Microsoft ACME Setup* de 16 bits: Windows x64 no tiene NTVDM. `3DMOVIE.EXE` en cambio es PE32 (i386) | No se ejecuta el instalador: la **receta** `layout` de `games.json` reproduce lo que hacía (`SETUP\INSTALAR.STF/.INF`), ver §4 |
| 2 | «No se encuentra un archivo… Microsoft Kids» al abrir | `_FFindMsKidsDir` lee `InstallDirectory` de **HKLM** `Software\Microsoft\Microsoft Kids\3D Movie Maker`; si falta, busca `\Microsoft Kids` o `\MSKIDS` en la **raíz de la unidad**. Además `_FReadTitlesFromReg` abre `HKLM\...\Products` con `RegCreateKeyEx(KEY_ALL_ACCESS)`, que sin administrador falla y el juego no arranca | **Registro virtual** en `cphook`: esa clave (HKLM y HKCU, con subclaves) se sirve desde `games\3DMM\registro.ini` (`CP3D_REGFILE`). El registro real no se toca. Verificado: después de usarlo, ni HKLM ni HKCU tienen `Microsoft Kids` |
| 3 | Diálogo «no se encuentra» con la carpeta del producto | `_FQueryProductExists` busca primero los nombres por omisión del recurso del exe (largo «3D Creador de Películas», corto «3D Creador») y muestra el diálogo si no existe la carpeta, antes de probar los productos del registro | Se respeta la estructura original: `MSKIDS\3D Creador de Películas\` (con tilde) y `Products\2 = "3D Creador de Películas/3DMovie"` (la carpeta coincide con el nombre largo y el archivo `3DMOVIE.CHK` con el corto) |
| 4 | «Error interno: 11000» al entrar a Imaginópolis o en la bienvenida | 11000 = `ercCantOpenVideo` (`kauai\SRC\FRAMEDEF.H`). Los vídeos se abren con **MCI `avivideo`**, que rechaza rutas de **más de 127 caracteres** (error 304; medido con rutas de 100 a 200 caracteres) | La raíz de instalación se limita a **64 caracteres** (`$MaxRootLength`): el AVI más largo suma 55. Error `3DM-DSK-004` con sugerencia `C:\CreadorPeliculas` |
| 5 | Ventana chica de 640×480 | En NT el juego no cambia de resolución (`_FDisplaySwitchSupported` = falso): solo usa pantalla completa si la pantalla **ya mide** 640×480 (`_FDisplayIs640480` con `GetSystemMetrics`) | `GetSystemMetrics(SM_CX/CYSCREEN)` informa 640×480 al juego, que crea su ventana emergente de pantalla completa; `cphook` la crea del tamaño real del monitor (modo **pantalla**, §5.3). `CP3D_SCALE=1` deja la ventana original |
| 6 | (diseño) El motor dibuja siempre en el mismo DC | Kauai (`GPT::PgptNewHwnd`) pide `GetDC(hwnd)` **una vez** y dibuja ahí toda la sesión: `StretchBlt`, `DrawDibDraw`, `ScrollDC`, `InvertRect`, `FillRect`, texto, regiones de recorte | **Redirección del DC**: `GetDC`/`BeginPaint` de la ventana principal devuelven una **sombra** de 640×480 en memoria; todo se dibuja ahí en coordenadas lógicas (los recortes funcionan solos) y lo que cambió (`GetBoundsRect`) se presenta escalado tras cada copia y con un temporizador de 15 ms |
| 7 | El vídeo de McZee se ve chico arriba a la izquierda | Los AVI se reproducen con MCI en una **ventana hija** propia que el motor ubica con `MoveWindow` en coordenadas lógicas; MCIAVI no estira | `MoveWindow` de ventanas hijas se traduce a coordenadas reales y, al reproducir (`MCI_PLAY`/`MCI_WINDOW`), `MCI_PUT` fija el destino escalado |
| 8 | El cuadro de guardar/abrir película aparece arriba a la izquierda | El juego ubica sus ventanas emergentes (el diálogo común con plantilla propia) en coordenadas de su «pantalla» de 640×480 | `SetWindowPos`/`MoveWindow` de ventanas de nivel superior cuyo dueño es la principal: se lleva su centro al punto equivalente de la vista escalada (tamaño original) |
| 9 | No aparecía la bienvenida de primera vez | El juego considera «primera vez» si `HomeDirectory` (HKCU) falta o apunta a una carpeta inexistente; el lanzador la escribía siempre | Si la carpeta del jugador no existe, los valores con `{USERDIR}` se escriben vacíos (`sz:`): el juego crea la carpeta, la anota y da la bienvenida, como en 1996 |
| 10 | (sincronización) La carpeta de películas cambia por equipo | La carpeta es `MSKIDS\Users\<WNetGetUser()>`: el usuario de Windows en la PC, `steamuser` en Proton | `WNetGetUserA` devuelve el **nombre de jugador** configurado (`CP3D_USER`, por omisión «Jugador»), igual en todos los equipos |
| 11 | Aviso «configurada para más de 256 colores» | Chequeo de profundidad de color | `GreaterThan8bppMsg = 0` en el registro virtual (también `WaveOutMsg`/`MidiOutMsg = 0` y `SwitchResolution = 0`) |
| 12 | En pantalla completa, al cambiar de ventana se minimiza | `APP::_Activate` minimiza si la pantalla es de 640×480 (que es lo que informamos) | Argumento `-m` (`_fDontMinimize`) |
| 13 | `build.cmd` falla en esta carpeta | La ruta del proyecto tiene espacios (`3D Movie maker`) y `/Fo` no iba entre comillas | Rutas entre comillas en `native\build.cmd` |

Comportamientos **originales** verificados (no son errores de la capa): al arrastrar un actor recién agregado, avanza poco y el juego reubica el puntero sobre él (`SetCursorPos`); se comprobó igual en la ventana original sin escalar (`CP3D_SCALE=1`).

### 0.3 Cómo usarlo

- **Usuario final:** descomprimir `runtime\dist\CreadorPeliculasRuntime-<versión>.zip` y hacer doble clic en `CreadorPeliculas.cmd` (Windows) o ejecutar `creador.sh` (Linux / Steam Deck). Ver `README.md` (en el paquete, `LEEME.txt`).
- **Desarrollo:** `runtime\native\build.cmd` (Build Tools de VS con C++ x86) y `powershell -File runtime\build.ps1 -IsoFolder <carpeta de la ISO>` (compila, normaliza a UTF-8 con BOM, verifica sintaxis, prueba y empaqueta). La versión sale de `runtime\VERSION`.
- **Diagnóstico:** `CP3D_TRACE=1` registra en `logs\juego-3DMM.log` cada acceso al registro virtual, archivo, ventana, `GetDC`, mouse, MCI y audio. `CP3D_VIEW=1152x864` fuerza el tamaño de la vista. `CP3D_SCALE=1` = ventana original. `CP3D_DPIAWARE=0` desactiva la declaración de DPI. Si el juego se cae, las líneas `FALLO` (módulo+desplazamiento, registros, pila) van al informe de error.

---

## Índice

1. [Diagnóstico](#1-diagnóstico)
2. [Estrategia](#2-estrategia)
3. [Arquitectura](#3-arquitectura)
4. [Receta de instalación](#4-receta-de-instalación)
5. [cphook.dll en detalle](#5-cphookdll-en-detalle)
6. [Instalador y ventana del programa](#6-instalador-y-ventana-del-programa)
7. [Manejo de errores](#7-manejo-de-errores)
8. [Películas (partidas)](#8-películas-partidas)
9. [Diagnóstico y resolución de problemas](#9-diagnóstico-y-resolución-de-problemas)
10. [Riesgos y pendientes](#10-riesgos-y-pendientes)
11. [Pruebas](#11-pruebas)
12. [Linux / Steam Deck](#12-linux--steam-deck)
13. [Sincronización](#13-sincronización)
14. [Steam (Windows y Linux) y artwork](#14-steam-windows-y-linux-y-artwork)
15. [Apéndices](#15-apéndices)

---

## 1. Diagnóstico

### 1.1 La imagen

| Dato | Valor |
|---|---|
| Archivo | `MS3DMM01E01.ISO` |
| Tamaño exacto | 346 884 096 bytes |
| Etiqueta | `MS3DMM01E01` (preparada por WCD, 1996-02-22) |
| Archivo clave | `3DMOVIE\3DMOVIE.EXE` (1 118 208 bytes, versión 1.0.0.1010, idioma 1034 = español) |

Contenido relevante:

| Carpeta | Contenido | ¿Se usa? |
|---|---|---|
| `3DMOVIE\` | `3DMOVIE.EXE`, `*.CHK` (datos Kauai «chunky»), `*.3TH`/`*.3CN` (contenido 3D: escenarios, actores, sonidos), 30 `*.AVI` | Sí, **todo** (el instalador copiaba solo lo chico; ver §4) |
| `SETUP\` | ACME Setup de 16 bits (`ACMSETUP.EXE`, `MSSETUP.DLL`, `3DMSETUP.DLL`), `INSTALAR.STF/.INF`, `COMIC*.TTF`, 6 proyectos `.3MM` de Melanie | Solo los `.3MM` y las fuentes (Linux) |
| `EXEMPLES\` | 17 películas de ejemplo (McZee) | Sí |
| `PSS\` | Ayuda `3DMM.HLP` (WinHelp), `MSINFO32` | Solo la ayuda |
| `MMCAT\` | Catálogo de Microsoft Kids (Visual Basic 3, 16 bits) | Solo `DIBS4\3DMVMAIN.DIB` para el artwork de Steam |
| raíz | `AUTORUN.INF`, `INSTALAR.EXE`, `SETUP.INI` | No |

### 1.2 El ejecutable

- **PE32 i386**, MSVC (`C:\soc\obj\wins\3dmovie.pdb`), secciones normales (tamaños de sección coherentes: el cargador de Windows 10 lo acepta sin retoques).
- **Gráficos:** GDI puro (`CreateDIBSection`, `SetDIBColorTable`, `CreatePalette`/`RealizePalette`/`AnimatePalette`, `GetSystemPaletteEntries`, `StretchBlt`; **sin `BitBlt`**, sin WinG ni DirectDraw). El render 3D es BRender por software.
- **Vídeo:** `AVIFIL32`/`MSVFW32` (`DrawDibDraw`) y **MCI** (`mciSendCommandA`, dispositivo `avivideo`). Los AVI son **Microsoft Video 1 (CRAM, 8 bpp)**: Windows 10 (`msvidc32.dll`) y Wine lo traen.
- **Audio:** `waveOut*`, `waveIn*` (graba con el micrófono), `midiOut*`, `MSACM32`.
- **Registro:** `RegCreateKeyExA`, `RegQueryValueExA`, `RegSetValueExA`, `RegEnumValueA`, `RegCloseKey`.
- **Otros:** `MPR!WNetGetUserA` (nombre de usuario → carpeta), `comdlg32!GetOpenFileNameA/GetSaveFileNameA` (Portafolio), `GetSystemMetrics`, `ClipCursor`, `ScrollDC`, `ScrollWindowEx`.

### 1.3 El código fuente

Microsoft publicó el código de 3D Movie Maker (`github.com/microsoft/Microsoft-3D-Movie-Maker`, MIT). Lo usamos para confirmar causas sin depurar a ciegas:

| Archivo | Qué confirma |
|---|---|
| `INC\UTEST.H` | Claves: `Software\Microsoft\Microsoft Kids\3D Movie Maker` (+ `\Products`); valores `InstallDirectory`, `HomeDirectory`, `UserData`, `SwitchResolution`, `BetterSpeed`, `WaveOutMsg`, `MidiOutMsg`, `GreaterThan8bppMsg` |
| `SRC\STUDIO\UTEST.CPP` | `_FFindMsKidsDir`, `_FReadTitlesFromReg` (HKLM con `KEY_ALL_ACCESS`), `_FFindProductDir`/`_FQueryProductExists`, `FGetSetRegKey` (tipos REG_SZ/DWORD/BINARY, `fregSetDefault`), `_FGetUserDirectories` (Users, Melanie, `HomeDirectory`, primera vez), `_FEnsureDisplayResolution`, `_GetWindowProps`, `_Activate` (`-m`), línea de comandos (`-f`, `-s`, `-p`, `-t`, `-m`) |
| `SRC\ENGINE\TAGMAN.CPP` | El contenido se busca **primero en el disco** y después en el CD: con todo copiado no hace falta CD ni unidad virtual |
| `kauai\SRC\GFXWIN.CPP` | El DC de la ventana se pide una vez (`GPT::PgptNewHwnd`) y se conserva |
| `kauai\SRC\VIDEO.CPP` | Vídeo por MCI con ventana hija (`GVDW`) o por AVIFile + DrawDib (`GVDS`); `ercCantOpenVideo` |
| `kauai\SRC\FRAMEDEF.H` | Códigos de error (11000 = `ercCantOpenVideo`) |

### 1.4 El instalador original (`SETUP\INSTALAR.STF` / `.INF`)

- Copia `3DMOVIE.EXE` y los `.CHK`/`.3TH` chicos a `<MSKIDS>\3D Creador de Películas`; el resto (`*.3CN`, `BLDGDATA.CHK`, `BUILDING.CHK`, `HELPAUD.CHK`, `SHARECD.CHK`, AVI) quedaba en el CD.
- Crea `<MSKIDS>\Users\Melanie\` con los 6 `.3MM` de `SETUP\` (solo lectura) y `Users\McZee\` con un acceso a `EXEMPLES`.
- Instala Comic Sans (`COMIC.TTF`, `COMICBD.TTF`).
- Registro: `HKLM\...\3D Movie Maker` `InstallDirectory=<MSKIDS>`, `InstallSubDir`, `Products\2="3D Creador de Películas/3DMovie"`; `App Paths\3DMovie.exe`; desinstalación; asociación `.3MM` → `3D Movie Maker` (`<exe> %1`).

---

## 2. Estrategia

**Nunca** ejecutar el instalador de 16 bits; reproducir su resultado con una receta de datos y resolver todo lo demás en una capa propia de *hooks* (sin DxWnd, sin capas de compatibilidad de Windows, sin VirtualStore, sin admin).

- **Sin CD:** se copia todo el contenido al disco (el motor busca primero en el disco). Por eso no hay modo «usar la ISO», ni unidad virtual (`DefineDosDevice`), ni etiqueta simulada, ni `R:` en Proton.
- **Sin registro real:** registro virtual en un INI (§5.1). Ventaja extra: es portable y funciona igual en Proton.
- **Sin cambiar la resolución:** el juego cree que la pantalla mide 640×480 y dibuja en una sombra que se escala (§5.3).

## 3. Arquitectura

### 3.1 Repositorio

```
3D Movie maker/
├─ README.md                  ← documento para el usuario final (en el paquete, LEEME.txt)
├─ RUNTIME.md                 ← este documento
├─ MS3DMM01E01.ISO            ← la imagen (no va al repositorio: .gitignore)
└─ runtime/
   ├─ VERSION · CreadorPeliculas.cmd · creador.sh
   ├─ build.ps1 · build.sh    ← empaquetado (zip con '/' y permisos de Unix)
   ├─ src/
   │  ├─ CreadorPeliculas.ps1 ← arranque (--install, --play <ID> [--file <.3MM>])
   │  ├─ Core/                ← CreadorPeliculas.{Core,Errors,Sync,Steam}.psm1, CpIso.cs
   │  ├─ UI/                  ← Theme, Dialogs, Wizard, Launcher, Sync, Steam
   │  └─ data/                ← games.json, strings.es.json, sync.json
   ├─ native/
   │  ├─ build.cmd · build.sh ← MSVC x86 / Zig (Linux)
   │  ├─ cphook/cphook.c      ← capa de compatibilidad
   │  ├─ cplaunch/cplaunch.c  ← lanzador con inyección
   │  └─ bin/                 ← cphook.dll, cplaunch.exe (compilados)
   ├─ linux/                  ← main.py + creador/{core,iso,proton,steam,sync,art,icons,ui,errors}.py
   └─ tests/                  ← Run-Tests.ps1, test_linux.py, fixtures/
```

### 3.2 Instalación en la máquina del usuario

Por defecto `%LOCALAPPDATA%\CreadorPeliculas` (sin admin; ≤ 64 caracteres, ANSI).

```
%LOCALAPPDATA%\CreadorPeliculas\
├─ CreadorPeliculas.cmd · LEEME.txt
├─ app\                                   ← copia del programa (src, native\bin, VERSION)
├─ games\3DMM\
│  ├─ registro.ini                        ← registro virtual (ANSI, CRLF)
│  ├─ art\3DMVMAIN.DIB · art\steam\*.png  ← fuente y artwork de Steam generado
│  └─ MSKIDS\
│     ├─ 3D Creador de Películas\         ← todo 3DMOVIE\ del CD + 3DMM.HLP/.CNT
│     └─ Users\
│        ├─ Melanie\  (proyectos guiados) · McZee\ (ejemplos)
│        └─ <Jugador>\                    ← películas del usuario (se sincronizan)
├─ manifest.json · logs\
```

Configuración (compartida por todas las copias del programa): `%LOCALAPPDATA%\CreadorPeliculas\config.json` (`installRoot`, `scale`, `player`, `fileAssociation`, `desktopShortcuts`, `steamShortcuts`, `sync`, `newerCopy`).

Accesos directos: menú Inicio → *Creador de Películas 3D* → **3D Creador de Películas** (`--play 3DMM`) y **Creador de Películas 3D - opciones** (ventana del programa). Todos abren `powershell … CreadorPeliculas.ps1`, nunca el exe directo.

## 4. Receta de instalación

`games.json` → entrada `3DMM`:

| Campo | Valor / función |
|---|---|
| `iso` | `size`, `keyFile`, `label` para reconocer la imagen |
| `layout` | `3DMOVIE` → `MSKIDS\3D Creador de Películas`; `PSS` (`3DMM.HLP`, `3DMM.CNT`) → idem; `SETUP` (`*.3MM`) → `MSKIDS\Users\Melanie`; `EXEMPLES` → `MSKIDS\Users\McZee`; `MMCAT\DIBS4` (`3DMVMAIN.DIB`) → `art`. Se quita el atributo de solo lectura de todo |
| `exe` / `args` | `MSKIDS\3D Creador de Películas\3DMOVIE.EXE` `-m` (+ ruta `.3MM` si se abre un archivo) |
| `registry` | `registro.ini`: `[HKLM]` `InstallDirectory=sz:{HD}\MSKIDS`, `InstallSubDir`, `WaveOutMsg=dw:0`, `MidiOutMsg=dw:0`; `[HKLM\Products]` `2=sz:3D Creador de Películas/3DMovie`; `[HKCU]` `HomeDirectory=sz:{USERDIR}\` (vacío la primera vez, #9), `GreaterThan8bppMsg=dw:0`, `SwitchResolution=dw:0`. Se reescribe antes de cada inicio |
| `saves` / `savesDir` / `saveMagic` | `*.3MM` en `MSKIDS\Users\{PLAYER}`; firma `CHN2` (archivo chunky de Kauai) obligatoria en lo que llega por sincronización |
| `fonts` | `SETUP\COMIC.TTF`, `COMICBD.TTF` (se copian al prefijo de Proton; Windows 10 ya las trae) |
| `art` | receta del artwork de Steam (§14.2) |

Variables: `{HD}` = `<raíz>\games\3DMM`, `{PLAYER}`, `{USERDIR}` = `{HD}\MSKIDS\Users\{PLAYER}`.

No se instala: el catálogo `MMCAT` (VB3 de 16 bits), `MSINFO32`, la asociación `.3MM` del sistema (la opcional es por usuario, `HKCU\Software\Classes`, y abre el lanzador), ni `App Paths`/desinstalación (no hay nada en el registro de Windows que desinstalar).

## 5. cphook.dll en detalle

Configuración por variables de entorno heredadas: `CP3D_LOG`, `CP3D_TRACE`, `CP3D_REGFILE`, `CP3D_USER`, `CP3D_SCALE` (0 ajustar, 1 ventana original, ≥2 escala entera), `CP3D_VIEW`, `CP3D_DPIAWARE`. Se parchea la IAT de `3DMOVIE.EXE` (y de DLLs no del sistema que se carguen después). Tabla `g_hooks[]` en `cphook.c`.

### 5.1 Registro virtual

`RegCreateKeyExA`/`RegOpenKeyExA` sobre `HKLM|HKCU\Software\Microsoft\Microsoft Kids\3D Movie Maker[\sub]` devuelven un *handle* falso (dirección dentro de la DLL, nunca coincide con uno real) asociado a la sección `HKLM`, `HKCU`, `HKLM\Products`… del INI. `RegQueryValueExA`, `RegSetValueExA`, `RegEnumValueA` y `RegCloseKey` operan sobre el INI con la semántica de Windows (`ERROR_FILE_NOT_FOUND`, `ERROR_MORE_DATA`, consulta de tamaño con datos nulos). Formato de valores: `sz:texto`, `dw:123`, `bin:A1B2…`. Siempre se informa `REG_OPENED_EXISTING_KEY`: con `fregSetDefault` el juego escribe igual los valores que falten. Cualquier otra clave pasa al registro real.

### 5.2 Usuario estable

`WNetGetUserA` → `CP3D_USER`. Validación del nombre en el lanzador (`Test-CpPlayerName`): ≤ 24 caracteres, cp1252, sin `\/:*?"<>|`, no `McZee`/`Melanie` ni nombres reservados de DOS.

### 5.3 Pantalla completa escalada (modo «pantalla»)

1. `GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN)` → 640/480 (solo para el exe).
2. `CreateWindowExA` de la ventana emergente 640×480 en 0,0 → se crea del tamaño del monitor principal; se calcula la vista (`pick_size`: 4:3 ajustado, entero o fijo) centrada con bandas negras.
3. **Sombra:** DC de memoria 640×480 (`CreateCompatibleBitmap`) con `SetBoundsRect(DCB_ENABLE)`. `GetDC(principal)` y `BeginPaint` devuelven la sombra (con `SaveDC`/`RestoreDC` para los `GetDC` anidados); `ReleaseDC`/`EndPaint` presentan.
4. **Presentar:** `GetBoundsRect(DCB_RESET)` → `StretchBlt` (COLORONCOLOR) del rectángulo cambiado con 1 px lógico de margen. Se presenta tras `StretchBlt`, `DrawDibDraw`, `FillRect`, `InvertRect`, `ScrollDC` y cada 15 ms (temporizador propio `0x7C3D` interceptado en el procedimiento de la ventana). `WM_PAINT` presenta todo.
5. `GetClientRect`/`GetWindowRect` de la principal = 0,0,640,480; `InvalidateRect`/`ValidateRect`/`GetUpdateRect` traducen; `SetWindowPos`/`MoveWindow` no la mueven; `ScrollWindowEx` se emula sobre la sombra.
6. **Mouse:** la ventana real está en 0,0 como cree el juego, así que solo se escala: `WM_MOUSE*` (subclase), `GetCursorPos`, `SetCursorPos`, `GetMessagePos`, `MSG.pt` (`GetMessageA`/`PeekMessageA`), `WindowFromPoint`, `ClipCursor`.
7. **Vídeo MCI:** ventanas hijas → `MoveWindow` escalado; `MCI_PLAY`/`MCI_WINDOW` → `MCI_PUT` destino escalado (dispositivos abiertos con la principal como padre).
8. **Diálogos:** ventanas de nivel superior con dueño = principal → se centran en el punto equivalente de la vista.
9. **DPI:** `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` antes de crear ventanas.

### 5.4 Protecciones generales

Paleta del sistema emulada con `NUMRESERVED=20` (en Wine la paleta del sistema no refleja la del juego), filtro de `WM_*PALETTE*` en Wine (evita bucles de realización de paleta), `waveOutOpen/Close/Reset` serializados con el *loader lock* y en un hilo auxiliar (evita bloqueos de controladores de audio; inofensivo aquí), atributos oculto/sistema ocultos al juego (la instalación está bajo `AppData`, que es oculta), tope de `GetDiskFreeSpaceA` (los programas de 32 bits viejos desbordan con discos grandes), `ChangeDisplaySettingsA`/`SetSysColors`/`SetSystemPaletteUse` sin efecto, registro de fallos `FALLO`.

## 6. Instalador y ventana del programa

- **Asistente** (`UI/Wizard.ps1`): requisitos (Windows 10/11 x64, PowerShell 5.1, `cplaunch.exe`/`cphook.dll`, códec `msvidc32.dll`) → carpeta de la ISO (o ZIP con la ISO) → confirmación → carpeta (≤ 64, ANSI) + **nombre del jugador** → pantalla, accesos, Steam, `.3MM` → resumen → instalación en segundo plano con cancelación y *rollback* → final (abre Steam si se pidió).
- **Ventana del programa** (`UI/Launcher.ps1`): tarjeta con ícono del exe, cantidad de películas del jugador, **▶ Crear películas** y **···** (Reparar, Copia de las películas, Importar, Abrir carpeta, Desinstalar); abajo Instalar, **Películas ▾** (Abrir «Mis películas», Exportar, Importar, carpeta de copias), Sincronización, Agregar a Steam, Opciones (pantalla, jugador, `.3MM`), Ayuda, Registro.
- **Autoactualización local:** cada copia del programa compara su `VERSION` con la instalada; si es más nueva lo anota en la configuración (`newerCopy`) y la instalada ofrece «Actualizar» («La versión instalada es más vieja»), que copia `app\` desde esa carpeta.

## 7. Manejo de errores

Cada paso pasa por `Invoke-CpStep` (log INICIO/OK/FALLO, *rollback*, código), el usuario ve títulos y mensajes del catálogo `strings.es.json` con acciones (*Reintentar*, *Reparar*, *Ver detalles*, *Copiar informe*…), nunca una traza. Códigos: `3DM-ENV/ISO/DSK/CPY/CFG/RUN/SAV/SYN/STM/GEN-NNN`. `3DM-CFG-002` valida el nombre de jugador; no hay errores de CD ni de unidad virtual porque no se usan. `3DM-DSK-004` explica el límite de MCI.

## 8. Películas (partidas)

- Son los `*.3MM` de `MSKIDS\Users\<jugador>\` (lo que el juego propone al guardar). Lo guardado en otras carpetas con el diálogo no se sincroniza (documentado).
- Copias: `Documentos\Creador de Películas 3D - copias\3DMM-<fecha>.zip` y `creador-peliculas-<fecha>.zip` (todas), con `creador-saves.json`. Un `.zip` cualquiera con `.3MM` sueltos también se importa (catálogo de un solo juego).
- `UserData` (preferencias del juego) queda en `registro.ini` y no se sincroniza.

## 9. Diagnóstico y resolución de problemas

| Síntoma | Dónde mirar |
|---|---|
| Diálogo «No se encuentra un archivo» | `CP3D_TRACE=1` → líneas `REG leer`, `FIND`, `FILE … FAIL` del log del juego |
| «Error interno: N» | Buscar N en `kauai\SRC\FRAMEDEF.H` y `INC\SOCDEF.H` del código fuente; con traza, líneas `MCI_OPEN` |
| Imagen corrida / restos | `CP3D_VIEW=WxH` para reproducir otra resolución; `CP3D_SCALE=1` para comparar con la original |
| El juego se cierra | Líneas `FALLO` en `logs\juego-3DMM.log` (también en *Copiar informe*) |

## 10. Riesgos y pendientes

- **MIDI en Proton:** la música usa `midiOut`; en el Steam Deck depende del sintetizador de Wine/Proton. Falta validar (§11.3).
- **Micrófono** (grabar sonidos): `waveIn` sin probar en el Deck.
- **Diálogos de Windows** (abrir/guardar) se ven a su tamaño original sobre la vista escalada.
- **Ayuda `3DMM.HLP`:** Windows 10 no trae WinHelp; la ayuda hablada de McZee (dentro del juego) funciona. En Wine existe `winhlp32`.
- **Monitores múltiples:** se usa el principal.
- Rutas con caracteres fuera de cp1252 (la carpeta del producto lleva «í»): en sistemas con otra página de códigos ANSI no se probó.

## 11. Pruebas

### 11.1 Automáticas

- `runtime\tests\Run-Tests.ps1 [-IsoFolder <carpeta>]` (Windows PowerShell 5.1): catálogo, errores, carpeta de instalación (incluye el cálculo del límite de MCI), nombres de jugador, INI ANSI, registro virtual y primera vez, versión instalada, películas (exportar/importar/zip suelto/entradas peligrosas), sincronización (validación, firma `CHN2`, carpeta, conflictos, Google Drive simulado), Steam (VDF y appid iguales a Python, conservación de accesos ajenos). Con la ISO: reconocimiento, instalación completa y artwork con las medidas de Steam.
- `runtime\tests\test_linux.py` (Python, corre también en Windows; con `CP3D_ISOS=<carpeta>` instala desde la ISO real): espejo de lo anterior + fixtures cruzados (`sync-windows-3DMM.zip` lo genera Windows y lo valida Python; `sync-linux-3DMM.zip`, `shortcuts-linux.vdf`, `appid.txt` al revés).

### 11.2 Manuales en Windows (hechas el 2026-10-24)

| # | Prueba | Resultado |
|---|---|---|
| W1 | Instalar desde la ISO (núcleo y asistente) | ✅ 322 MB, estructura de §3.2 |
| W2 | Primer inicio: bienvenida de McZee (vídeo escalado) | ✅ |
| W3 | Menú, Imaginópolis (vídeo `LOGN1.AVI` escalado a 1024×768) | ✅ |
| W4 | Estudio: escenario, actor 3D, arrastre | ✅ (arrastre igual que el original) |
| W5 | Portafolio → Guardar: diálogo centrado, guarda en `Users\Jugador` | ✅ |
| W6 | Salir desde el menú del juego: código 0, vuelve la ventana del programa | ✅ |
| W7 | Ventana original (`CP3D_SCALE=1`) | ✅ |
| W8 | El registro real de Windows queda sin `Microsoft Kids` | ✅ |
| W9 | Steam real (accesos + artwork en Big Picture) | Falta validar a mano |

### 11.3 Steam Deck (falta validar a mano)

D1 instalar con `creador.sh` (Modo Escritorio) · D2 abrir en Modo Juego con Proton 10.0 · D3 colores y escalado · D4 vídeos · D5 voces, efectos y **música MIDI** · D6 trackpad, pantalla táctil y Steam+X para escribir · D7 guardar una película en la PC y verla en el Deck (sincronización) · D8 artwork en la biblioteca de Steam.

## 12. Linux / Steam Deck

`creador.sh` → `linux/main.py`: Python 3 + Tk, solo biblioteca estándar (SteamOS ya lo trae), mismo catálogo (`src/data`) y mismas piezas nativas que en Windows, ejecutadas con **Proton**. La ventana y el asistente replican los de Windows; en Modo Juego (`XDG_CURRENT_DESKTOP=gamescope`) se ocultan los diálogos de archivos y «Agregar a Steam». Particularidades:

- Instalación en `~/CreadorPeliculas` (configuración en `~/.local/share/creador/config.json`); siempre copia, sin unidad de CD.
- Prefijo `~/CreadorPeliculas/proton/pfx`; `drive_c/CreadorPeliculas/games` es un enlace a la instalación, así el juego ve rutas cortas (`C:\CreadorPeliculas\games\3DMM\…`, muy por debajo del límite de MCI).
- Fuentes Comic Sans del CD: se guardan en `games/3DMM/fonts` al instalar y se copian a `pfx/drive_c/windows/Fonts` cada vez que se prepara el prefijo.
- Lanzamiento: `proton run cplaunch.exe --wait --cwd <carpeta del exe> -- <exe> -m` con las mismas `CP3D_*` (rutas `C:\`).
- Proton: se buscan `steamapps/common/Proton*` en todas las bibliotecas de Steam (`libraryfolders.vdf`, incluida la tarjeta SD) y en `compatibilitytools.d`; se prefiere **Proton 10.0** (con 11.0 y Experimental se observaron pantallas en negro en juegos GDI de 256 colores) y se puede elegir otra versión en Opciones.

## 13. Sincronización

Dos modos: una **carpeta sincronizada** (Drive para escritorio, OneDrive, Dropbox, Syncthing, un pendrive) o **Google Drive** directo (carpeta oculta `appDataFolder`, permiso `drive.appdata`, autorización con *device flow* y cliente OAuth de tipo «TVs y dispositivos de entrada limitada»; el token se guarda cifrado con DPAPI en Windows y con permisos `0600` en Linux). Antes de abrir el juego se baja la versión remota si es más nueva; al cerrarlo se sube. Gana siempre la más reciente y la que pierde queda como `3DMM-conflicto-<equipo>-<fecha>.zip`, importable. Todo lo descargado se valida antes de escribir (tamaños, cantidad de entradas, nombres sin rutas, hashes del manifiesto, sin ejecutables ni comprimidos). Particularidades:

- carpeta `CreadorPeliculas-sync/3DMM.zip`;
- archivos = películas del jugador (`*.3MM`), que deben empezar con `CHN2` (`saveMagic`);
- límites mayores (`sync.json`): 32 MB por película, 256 MB por paquete, 512 entradas.

## 14. Steam (Windows y Linux) y artwork

### 14.1 Accesos

Accesos «no de Steam» en `userdata\<id>\config\shortcuts.vdf` (VDF binario) de cada usuario de Steam, escrito con Steam cerrado (Steam lo reescribe al salir), *appid* = `crc32(exe + nombre) | 0x80000000`, `AllowDesktopConfig=1`, copia `shortcuts.vdf.creador.bak`, conservación de `LastPlayTime` y de los accesos ajenos. Entradas: **3D Creador de Películas** (`--play 3DMM`) y **Creador de Películas 3D - opciones**; colección **Creador de Películas 3D**.

### 14.2 Artwork

Se genera desde el CD (no se distribuye ninguna imagen): `MMCAT\DIBS4\3DMVMAIN.DIB` (512×384, promo del catálogo) tiene el **logo en español** en (1,11, 223×55) sobre crema `F0F0E0` y una **ilustración** en (229,0, 283×382) sobre un tramado de `FFFFFF`/`F0F0E0`. Fondo de composición: `F8F8F0` (promedio del tramado, para que no se note el recuadro). Logo con el crema vuelto transparente (tolerancia 40).

| Archivo en `userdata\<id>\config\grid` | Medida | Composición |
|---|---|---|
| `<appid>p.png` (portada) | 600×900 | logo arriba (540×140), ilustración (560×690) |
| `<appid>.png` (cabecera) | 920×430 | logo a la izquierda, ilustración a la derecha |
| `<appid>_hero.png` (fondo) | 1920×620 | ilustración a la derecha |
| `<appid>_logo.png` | 900×230 | logo transparente |

`<appid>` sin signo. Se copia al agregar a Steam (no hace falta cerrar Steam para el artwork). En Linux lo genera `linux/creador/art.py` solo con la biblioteca estándar: `3DMVMAIN.DIB` viene comprimido en **RLE8**, que el decodificador soporta; la cabecera generada es igual a la de Windows.

## 15. Apéndices

### 15.1 Comandos de referencia

```powershell
# Compilar, probar y empaquetar
runtime\native\build.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File runtime\build.ps1 -IsoFolder <carpeta de la ISO>
# Solo pruebas
powershell -NoProfile -ExecutionPolicy Bypass -File runtime\tests\Run-Tests.ps1 -IsoFolder <carpeta>
python -I runtime\tests\test_linux.py
# Diagnóstico de una sesión
$env:CP3D_TRACE = '1'; & "$env:LOCALAPPDATA\CreadorPeliculas\CreadorPeliculas.cmd" --play 3DMM
```

### 15.2 Límite de MCI medido

`mciSendString("open \"<ruta>\" type avivideo")` en un proceso de 32 bits: 100–127 caracteres → 0; 128, 129, 140, 200 → 304.
