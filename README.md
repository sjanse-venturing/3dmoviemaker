# Creador de Películas 3D Runtime — Guía para el usuario

Creador de Películas 3D Runtime permite usar el clásico **Microsoft 3D Creador de Películas** (1996, la edición en español de *3D Movie Maker*) en **Windows 10 y Windows 11** de 64 bits y en el **Steam Deck** (o en Linux con Steam), sin máquinas virtuales y sin cambiar la configuración de tu computadora.

Mejoras respecto de 1996:

- **Pantalla completa escalada** a tu monitor (en 1996 era una ventana de 640×480), con los vídeos de McZee también agrandados.
- **Tus películas se sincronizan solas entre equipos** (por ejemplo, la PC con Windows y el Steam Deck), con una carpeta compartida o con Google Drive (sección 6), o se pasan **a mano** con un archivo (sección 7).
- **Steam**: se agrega como juego «no de Steam», con portada y logo hechos con las imágenes del propio CD, para abrirlo desde Big Picture, **Steam Link** o el **Steam Deck** (secciones 3 y 5).
- **Doble clic en una película `.3MM`** la abre (opcional).

Necesitás el CD original como imagen `.iso` (por ejemplo `MS3DMM01E01.ISO`). La imagen no se modifica.

---

## 1. Qué necesitás

- Windows 10 u 11 de 64 bits, **o** un Steam Deck (ver la sección 5 para el Steam Deck).
- La imagen del CD (`.iso`).
- Espacio libre: unos **450 MB** (el contenido completo del CD se copia a la computadora, así que después no hace falta el `.iso`).
- **No** hace falta ser administrador ni instalar nada más.

## 2. Instalar

1. Descomprimí el archivo `CreadorPeliculasRuntime-x.y.z.zip` en cualquier carpeta (por ejemplo, en *Descargas*).
2. Hacé **doble clic en `CreadorPeliculas.cmd`**.
3. Seguí el asistente:
   1. **Bienvenida**: revisa que la computadora sea compatible. Si todo está en verde, presioná *Siguiente*.
   2. **¿Dónde está el disco?**: elegí la carpeta con el `.iso` y presioná *Buscar*.
   3. **Confirmá qué instalar**.
   4. **¿Dónde instalarlo?**: dejá la carpeta sugerida o elegí otra con una **ruta corta y sin caracteres especiales** (por ejemplo, `C:\CreadorPeliculas`). Escribí también el **nombre de quien va a hacer películas**: las películas se guardan en una carpeta con ese nombre. Usá el mismo nombre en todos tus equipos.
   5. **Pantalla**: *Pantalla completa, ajustada* (recomendado), *al doble exacto* o *Ventana de 640×480* (como en 1996). Si tenés Steam, podés marcar **Agregar también a Steam**. Podés marcar también **Abrir las películas (.3MM) con doble clic**.
   6. **Resumen** → *Instalar*.
4. Al terminar, presioná **Abrir la biblioteca**.

## 3. Usarlo

- Desde la ventana **Creador de Películas 3D** (menú Inicio → *Creador de Películas 3D*): presioná **▶ Crear películas**.
- O directamente desde el acceso directo **3D Creador de Películas** del menú Inicio o del Escritorio.

La primera vez, McZee te da la bienvenida. Para salir, usá **Salir** en el menú del programa (o el cartel de salida de Imaginópolis). Al cerrarse, vuelve la ventana del programa.

> Se ve en pantalla completa con bordes a los costados: es normal, el programa es de formato 4:3. Los cuadros para abrir y guardar películas son ventanas de Windows y se ven en su tamaño original, centrados.

### Dónde quedan tus películas

En **Películas ▾ → Abrir «Mis películas»**. Es la carpeta que el programa abre al **Guardar** o **Abrir** una película (dentro de la instalación, en `games\3DMM\MSKIDS\Users\<tu nombre>`). Las películas que guardes en esa carpeta son las que se sincronizan y se copian. Las películas de ejemplo (de McZee) y los proyectos guiados (de Melanie) vienen con el CD y no se tocan.

### Desde Steam, Big Picture o Steam Link (Windows)

1. Marcá **Agregar también a Steam** al instalar, o presioná **Agregar a Steam** en la ventana del programa. Si Steam está abierto, se cierra un momento y se vuelve a abrir.
2. En Steam aparece **3D Creador de Películas** en *No de Steam* y en la colección **Creador de Películas 3D**, con su portada.
3. **Control:** el programa se maneja con el mouse. En Steam elegilo → ⚙ → *Administrar* → *Configuración del control* y usá la plantilla **Teclado y mouse** (o **Gamepad con mouse**). Para escribir títulos y diálogos hace falta un teclado (en Steam Link o en el Deck: *Steam* + *X*).

## 4. Opciones y mantenimiento

En la ventana del programa, el botón **···** ofrece:

- **Reparar**: vuelve a copiar los archivos del CD sin tocar tus películas.
- **Copia de seguridad de las películas**: guarda un `.zip` en *Documentos\Creador de Películas 3D - copias*.
- **Importar películas…**: trae películas desde un `.zip` (sección 7).
- **Abrir la carpeta del programa**.
- **Desinstalar…**: borra el programa (antes guarda una copia de tus películas).

Abajo hay botones para **Instalar…**, **Películas ▾** (*Abrir «Mis películas»*, *Exportar las películas…*, *Importar películas…*, *Abrir la carpeta de copias*), **Sincronización…** (sección 6), **Agregar a Steam**, **Opciones…** (pantalla, nombre del jugador, abrir `.3MM` con doble clic), esta **Ayuda** y **Ver registro** (para pedir ayuda técnica).

> **Cambiar el nombre del jugador** cambia la carpeta de películas: las películas del nombre anterior siguen en su carpeta (`Users\<nombre anterior>`). Si querés llevarlas, usá *Exportar* con el nombre viejo e *Importar* con el nuevo.

## 5. Steam Deck (y Linux)

### Qué necesitás

- Un Steam Deck (o una computadora con Linux y Steam).
- **Proton 10.0**, que se instala desde Steam: *Biblioteca* → *Herramientas* (o buscá «Proton 10.0») → *Instalar*.
- El `.iso` y unos **450 MB** libres.

### Instalar (en el Modo Escritorio)

1. Pasá al **Modo Escritorio**: botón *Steam* → *Apagar* → *Cambiar al escritorio*.
2. Copiá el `.iso` al Steam Deck (por ejemplo, en *Descargas*) con un pendrive, una tarjeta SD o por la red.
3. Descomprimí `CreadorPeliculasRuntime-x.y.z.zip` (clic derecho → *Extraer* → *Extraer aquí*).
4. Entrá en la carpeta y abrí **`creador.sh`** (doble clic → *Ejecutar*). Si en vez de abrirse se muestra el texto del archivo: clic derecho → *Propiedades* → *Permisos* → marcá *Es ejecutable*, o abrí *Konsole* en esa carpeta y escribí `sh creador.sh`.
5. Seguí el asistente, igual que en Windows. La carpeta sugerida es `/home/deck/CreadorPeliculas`. **Usá el mismo nombre de jugador que en la PC** si vas a sincronizar.
6. Dejá marcado **Agregar a Steam**. Al terminar, el asistente cierra Steam un momento y lo vuelve a abrir.

### Usarlo en el Modo Juego

- Volvé al Modo Juego. Está en *Biblioteca* → *No de Steam* (y en la colección **Creador de Películas 3D**), con su portada.
- **Controles:** el **trackpad derecho** mueve el puntero y se hace clic **presionando el trackpad**. También podés **tocar la pantalla**. Para escribir el título de una película o un diálogo, apretá *Steam* + *X*.
- Si los controles no responden como mouse: en Steam, ⚙ → *Controlador* → plantilla de **teclado y mouse**.
- Para salir, usá **Salir** en el programa o el botón *Steam* → *Salir del juego*.

## 6. Sincronizar las películas entre equipos (automático)

Con la sincronización activada, **al abrir el programa** se traen las películas más recientes de todos tus equipos (Windows, Linux o Steam Deck), y **al cerrarlo** se guardan las tuyas. Así se puede empezar una película en la PC y seguirla en el Steam Deck.

Se configura en la ventana del programa → **Sincronización…**, en cada equipo. Hay dos formas:

### Opción A: una carpeta sincronizada (la más simple)

Elegí una carpeta que ya se copie sola entre tus equipos: la de **Google Drive para escritorio**, **OneDrive**, **Dropbox**, **Syncthing**, una carpeta de red o un **pendrive**. Se guarda ahí una subcarpeta `CreadorPeliculas-sync`. El programa no se conecta a internet: de eso se encarga el programa de sincronización.

1. **Sincronización…** → **Carpeta sincronizada**. Se propone una (la de Google Drive para escritorio, OneDrive o Dropbox si se encuentran; en el Steam Deck, `~/Sync` de Syncthing). Si querés otra, usá **Examinar…**.
2. Presioná **Probar conexión** y después **Guardar**.
3. Repetí lo mismo en los otros equipos, eligiendo la misma carpeta sincronizada.

### Opción B: Google Drive

El programa se conecta directamente con tu cuenta de Google. Las películas se guardan en una **carpeta privada de la app**: no aparecen en tu Drive ni las puede ver nadie más.

1. **Sincronización…** → **Google Drive** → **Vincular…**.
2. Aparece un código. En el celular o en la computadora, entrá a `google.com/device`, iniciá sesión y escribí el código (funciona también en el Steam Deck en Modo Juego).
3. Presioná **Guardar**. Repetí en los otros equipos con **la misma cuenta**.

> **Si dice «Falta habilitar el acceso a Google»:** hay que registrar el programa en Google Cloud una sola vez (es gratis). Tocá **Cómo habilitarlo…** y seguí los pasos: crear un proyecto, habilitar **Google Drive API**, configurar la **Pantalla de consentimiento de OAuth** (tipo *Externo*, permiso `https://www.googleapis.com/auth/drive.appdata`, **Publicar app**) y crear un **ID de cliente de OAuth** de tipo **TVs y dispositivos de entrada limitada**. Pegá el ID y el secreto en el programa.

### Cómo funciona

- **Gana la versión más reciente** del conjunto de películas, según la última vez que se guardó en algún equipo.
- **Nunca se pierde una película:** antes de reemplazar las películas de un equipo se guarda una copia en *Documentos\Creador de Películas 3D - copias*. Si dos equipos se usaron sin conexión, la versión que pierde también queda ahí (`3DMM-conflicto-<equipo>-<fecha>.zip`) y se puede importar.
- **Si no hay conexión al abrir**, aparece un aviso con la causa. Podés **Reintentar**, **Jugar igual** con las películas de ese equipo, o **Cerrar**.
- **Seguridad:** todo lo que llega de la sincronización se revisa antes de usarlo: tienen que ser películas de 3D Creador de Películas (archivos `.3MM` válidos), con los nombres, tamaños y contenido esperados, y nada puede ser un programa. Si algo no pasa el control, no se usa y se avisa.
- Las películas pueden pesar varios MB si tienen sonidos importados o grabados: el límite es de 32 MB por película.

## 7. Pasar las películas a otra computadora (a mano)

1. En la computadora **de origen**: **Películas ▾** → **Exportar las películas…** y elegí dónde guardarlas (por ejemplo, un pendrive). Se crea `creador-peliculas-<fecha>.zip`.
2. Copiá ese archivo a la otra computadora.
3. En la **de destino**: **Películas ▾** → **Importar películas…** y elegí el `.zip`. También sirve un `.zip` cualquiera con archivos `.3MM` sueltos.

Al importar, las películas que ya había **se reemplazan**, pero antes se guarda una copia en *Documentos\Creador de Películas 3D - copias*. Cerrá el programa antes de importar.

## 8. Problemas frecuentes

| Problema | Qué hacer |
|---|---|
| **«No encontramos el disco»** | Elegí la carpeta que contiene el archivo `.iso`. |
| **«El archivo … no parece un disco válido»** | La imagen está dañada o incompleta. Volvé a copiarla. |
| **«Ruta demasiado larga»** | Los vídeos del programa (de 1996) no se abren desde rutas largas. Usá una carpeta corta, como `C:\CreadorPeliculas`. |
| **«Carpeta no compatible»** | Usá una carpeta sin símbolos ni letras de otros idiomas. |
| **«Nombre no válido»** | El nombre del jugador es una carpeta: hasta 24 letras, números o espacios, sin `\ / : * ? " < > \|`. |
| **«El programa se cerró al iniciar»** | Usá **Reparar**. Si sigue pasando, mirá la fila siguiente. |
| **«No se pudo iniciar» / un antivirus avisa** | Para funcionar en Windows moderno se agrega una pequeña capa de compatibilidad (`cphook.dll`). Algunos antivirus la confunden con algo peligroso: agregá la carpeta de instalación a las excepciones. |
| **«La versión instalada es más vieja»** | Descomprimiste una versión nueva, pero los accesos directos y Steam siguen abriendo la instalada. Presioná **Actualizar** (el programa y tus películas no se tocan). |
| **No se escucha la música** | Verificá el volumen y que haya un dispositivo de salida de audio activo. En el Steam Deck, la música MIDI depende de Proton (ver *RUNTIME.md*). |
| **No encuentro una película que guardé** | Si la guardaste fuera de «Mis películas», usá *Abrir* en el programa y buscala donde la dejaste. Solo lo que está en «Mis películas» se sincroniza. |
| **El programa ya está abierto** | Cerralo antes de volver a abrirlo o de importar películas. |
| **Steam Deck: pantalla negra o no abre** | Instalá **Proton 10.0** desde Steam y elegilo en *Opciones…* → *Versión de Proton*. |
| **«Sin conexión a Internet»** (sincronización) | Revisá la conexión. Podés presionar *Jugar igual*: al cerrar se intenta guardar de nuevo. |
| **«Películas rechazadas por seguridad»** | Lo que hay en la sincronización está dañado o no es una película válida. Tus películas no se tocaron. Al cerrar el programa se reemplaza por las tuyas. |
| **Cualquier otro error** | En el mensaje de error presioná **Copiar informe** y envialo a quien te ayude con la computadora. El registro completo está en `<carpeta de instalación>\logs`. |

## 9. Desinstalar todo

1. En la ventana del programa: *···* → *Desinstalar…*. Tus películas quedan en *Documentos\Creador de Películas 3D - copias*.
2. Borrá la carpeta de instalación (por defecto `%LOCALAPPDATA%\CreadorPeliculas` en Windows, `/home/deck/CreadorPeliculas` en el Steam Deck).
3. Windows: si quedó la carpeta del menú Inicio *Creador de Películas 3D*, borrala. Si lo agregaste a Steam: clic derecho → *Administrar* → *Eliminar acceso directo*. La configuración está en `%LOCALAPPDATA%\CreadorPeliculas\config.json`. Steam Deck: borrá también `~/.local/share/creador`.

El programa **no** modifica el registro de Windows (salvo, si lo pediste, la asociación de `.3MM` para tu usuario), la carpeta `C:\Windows` ni la configuración de pantalla.

## 10. Privacidad y aviso legal

- Todo funciona sin conexión a internet. No se envía ningún dato, salvo que actives la sincronización con **Google Drive**: en ese caso se envían a **tu** cuenta de Google solo tus películas, a una carpeta privada de la app. El permiso se guarda cifrado en el equipo y se quita con *Desvincular*.
- *Microsoft 3D Creador de Películas* es propiedad de Microsoft. Este programa **no incluye el juego**: usa el CD que vos aportás, sin modificarlo.
- `cphook.dll` y `cplaunch.exe` son componentes propios de compatibilidad: adaptan el programa al Windows actual (pantalla, registro y archivos) sin modificar el original. En el Steam Deck se ejecutan dentro de **Proton**, la capa de compatibilidad de Steam.
