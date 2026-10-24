# CreadorPeliculas.Core.psm1 — lógica de Creador de Películas 3D Runtime (sin interfaz gráfica).
# Compatible con Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

$script:SrcRoot = Split-Path -Parent $PSScriptRoot           # ...\src
$script:AppRoot = Split-Path -Parent $script:SrcRoot          # ...\runtime  (o <instalación>\app)
$script:ConfigDir = Join-Path $env:LOCALAPPDATA 'CreadorPeliculas'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'
$script:Catalog = $null
# MCI (el vídeo del juego) no abre AVIs con rutas de más de 127 caracteres (error 304, medido en Windows 10).
# "\games\3DMM\MSKIDS\3D Creador de Películas\BACKSTAG.AVI" suma 55 a la raíz: con 64 queda margen.
$script:MaxRootLength = 64
$script:DefaultPlayer = 'Jugador'
$script:ProductName = 'Creador de Películas 3D'

if (-not ('CpIso' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'CpIso.cs') }
if (-not ('CpNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpNative {
    [DllImport("kernel32.dll")]
    public static extern int GetACP();
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
}
'@
}

# ---------------------------------------------------------------------------
# Rutas y configuración
# ---------------------------------------------------------------------------

function Get-CpAppRoot { $script:AppRoot }

function Get-CpProductName { $script:ProductName }

function Get-CpNativeBin {
    $candidates = @((Join-Path $script:AppRoot 'native\bin'), (Join-Path $script:AppRoot 'bin'))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath (Join-Path $c 'cplaunch.exe')) { return $c } }
    $candidates[0]
}

function Get-CpCatalog {
    if (-not $script:Catalog) {
        $json = Get-Content -LiteralPath (Join-Path $script:SrcRoot 'data\games.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Catalog = @($json.games | Sort-Object order)
    }
    $script:Catalog
}

function Get-CpGame {
    param([Parameter(Mandatory)][string]$Id)
    $g = Get-CpCatalog | Where-Object { $_.id -eq $Id }
    if (-not $g) { throw "Juego desconocido: $Id" }
    $g
}

function ConvertTo-CpHashtable {
    # ConvertFrom-Json en PS 5.1 devuelve PSCustomObject; esto lo pasa a hashtable (recursivo).
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-CpHashtable $p.Value }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        return @($Object | ForEach-Object { ConvertTo-CpHashtable $_ })
    }
    $Object
}

function Read-CpJson {
    param([Parameter(Mandatory)][string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return ConvertTo-CpHashtable (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-CpLog Warn "JSON ilegible ($Path): $_"; return $Default }
}

function Write-CpJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-CpConfig {
    $cfg = Read-CpJson -Path $script:ConfigFile -Default $null
    if (-not $cfg) {
        $cfg = [ordered]@{ installRoot = $null; isoFolder = $null; scale = 0; desktopShortcuts = $true }
    }
    foreach ($k in @('installRoot', 'isoFolder', 'scale', 'desktopShortcuts', 'steamShortcuts', 'player', 'fileAssociation', 'sync', 'newerCopy')) {
        if (-not $cfg.Contains($k)) { $cfg[$k] = $null }
    }
    if ($null -eq $cfg.scale) { $cfg.scale = 0 }
    if ($null -eq $cfg.desktopShortcuts) { $cfg.desktopShortcuts = $true }
    if ($null -eq $cfg.steamShortcuts) { $cfg.steamShortcuts = $true }
    if ($null -eq $cfg.fileAssociation) { $cfg.fileAssociation = $false }
    if (-not (Test-CpPlayerName ([string]$cfg.player))) { $cfg.player = $script:DefaultPlayer }
    if (-not ($cfg.sync -is [Collections.IDictionary])) { $cfg.sync = [ordered]@{ mode = 'off'; folder = $null; deviceId = $null; deviceName = $null } }
    $cfg
}

function Save-CpConfig { param([Parameter(Mandatory)]$Config) Write-CpJson -Path $script:ConfigFile -Value $Config }

function Get-CpDefaultInstallRoot { Join-Path $env:LOCALAPPDATA 'CreadorPeliculas' }

function Get-CpManifest {
    param([Parameter(Mandatory)][string]$Root)
    $m = Read-CpJson -Path (Join-Path $Root 'manifest.json') -Default $null
    if (-not $m) { $m = [ordered]@{ version = 1; games = [ordered]@{} } }
    if (-not $m.games) { $m.games = [ordered]@{} }
    $m
}

function Save-CpManifest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Manifest)
    Write-CpJson -Path (Join-Path $Root 'manifest.json') -Value $Manifest
}

# ---------------------------------------------------------------------------
# Jugador (carpeta de películas)
# ---------------------------------------------------------------------------

function Test-CpPlayerName {
    <#
      El juego guarda las películas en MSKIDS\Users\<nombre>: tiene que ser un nombre de carpeta
      válido, corto y en la página de códigos ANSI (el juego usa la API ANSI de Windows).
    #>
    param([string]$Name)
    if (-not $Name -or $Name.Length -gt 24 -or $Name -ne $Name.Trim() -or $Name.EndsWith('.')) { return $false }
    if ($Name -match '[\\/:*?"<>|]' -or $Name -match '[\x00-\x1F]') { return $false }
    if ($Name -in @('McZee', 'Melanie', 'CON', 'PRN', 'AUX', 'NUL') -or $Name -match '^(COM|LPT)\d$') { return $false }
    $ansi = [Text.Encoding]::GetEncoding(1252)
    $ansi.GetString($ansi.GetBytes($Name)) -ceq $Name
}

function Get-CpPlayer { param($Config) $(if ($Config -and (Test-CpPlayerName ([string]$Config.player))) { [string]$Config.player } else { $script:DefaultPlayer }) }

function Get-CpGameVars {
    <# Variables de las recetas: {HD}, {PLAYER}, {USERDIR}. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [string]$Player = $script:DefaultPlayer)
    $game = Get-CpGame $Id
    $hd = Join-Path $Root "games\$Id"
    $vars = @{ HD = $hd; PLAYER = $Player }
    $vars.USERDIR = Join-Path $hd (Expand-CpTemplate ([string]$game.savesDir) $vars)
    $vars
}

function Get-CpSavesDir {
    <# Carpeta de películas (partidas) del jugador. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [string]$Player)
    if (-not $Player) { $Player = Get-CpPlayer (Get-CpConfig) }
    (Get-CpGameVars -Id $Id -Root $Root -Player $Player).USERDIR
}

# ---------------------------------------------------------------------------
# Requisitos previos
# ---------------------------------------------------------------------------

function Test-CpPrerequisites {
    $items = New-Object Collections.Generic.List[object]
    $os = [Environment]::OSVersion.Version
    $is64 = [Environment]::Is64BitOperatingSystem
    $items.Add([pscustomobject]@{ Name = 'Windows 10/11 de 64 bits'; Ok = ($os.Major -ge 10 -and $is64); Blocking = $true
        Detail = ('Windows {0} ({1})' -f $os, $(if ($is64) { '64 bits' } else { '32 bits' })) })
    $items.Add([pscustomobject]@{ Name = 'Windows PowerShell 5.1 o superior'; Ok = ($PSVersionTable.PSVersion.Major -ge 5); Blocking = $true
        Detail = "PowerShell $($PSVersionTable.PSVersion)" })
    $bin = Get-CpNativeBin
    $missing = @('cplaunch.exe', 'cphook.dll') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bin $_)) }
    $items.Add([pscustomobject]@{ Name = 'Componentes de compatibilidad'; Ok = (@($missing).Count -eq 0); Blocking = $true
        Detail = $(if (@($missing).Count) { 'Faltan: ' + ($missing -join ', ') } else { $bin }) })
    $codec = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'SysWOW64\msvidc32.dll')
    $items.Add([pscustomobject]@{ Name = 'Códec de vídeo Microsoft Video 1'; Ok = $codec; Blocking = $false
        Detail = $(if ($codec) { 'Disponible' } else { 'No se encontró msvidc32.dll: los vídeos podrían no verse' }) })
    $items
}

# ---------------------------------------------------------------------------
# Discos (ISO)
# ---------------------------------------------------------------------------

function Find-CpIsos {
    <# Busca imágenes del juego en una carpeta (y un nivel de subcarpetas). #>
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { throw (New-CpError '3DM-ISO-001' @{ path = $Folder }) }
    $catalog = Get-CpCatalog
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.iso' -File -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.iso' -File -ErrorAction SilentlyContinue })
    $result = New-Object Collections.Generic.List[object]
    foreach ($f in $files) {
        $game = $catalog | Where-Object { $_.iso.size -eq $f.Length } | Select-Object -First 1
        if (-not $game) { $game = $catalog | Where-Object { $_.iso.file -eq $f.Name } | Select-Object -First 1 }
        $entry = [ordered]@{ GameId = $null; Path = $f.FullName; Name = $f.Name; Size = $f.Length; Label = $null; Status = 'unknown'; Message = '' }
        try {
            $iso = New-Object CpIso($f.FullName)
            try {
                $entry.Label = $iso.VolumeLabel
                if (-not $game) {
                    foreach ($g in $catalog) { if ($iso.Find($g.iso.keyFile)) { $game = $g; break } }
                }
                if ($game) {
                    $entry.GameId = $game.id
                    if ($iso.Find($game.iso.keyFile)) {
                        $entry.Status = 'ok'
                        if ($f.Length -ne $game.iso.size) { $entry.Message = 'Edición distinta de la probada; probablemente funcione.' }
                    } else { $entry.Status = 'invalid'; $entry.Message = 'Falta un archivo clave del juego.' }
                } else { $entry.Message = 'No es un disco de 3D Creador de Películas.' }
            } finally { $iso.Dispose() }
        } catch {
            $entry.Status = 'invalid'
            $entry.Message = "No se pudo leer: $($_.Exception.Message)"
        }
        $result.Add([pscustomobject]$entry)
    }
    $zips = @(Get-ChildItem -LiteralPath $Folder -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    # Arrays comunes: PowerShell 5.1 falla al aplicar @() a una List[object] guardada en un objeto.
    [pscustomobject]@{ Isos = [object[]]$result.ToArray(); Zips = [object[]]$zips }
}

function Expand-CpZipIsos {
    <# Extrae las imágenes .iso de un ZIP. #>
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination, [scriptblock]$OnProgress, $Cancel)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -like '*.iso' })
        $total = ($entries | Measure-Object Length -Sum).Sum; $done = 0
        foreach ($e in $entries) {
            $target = Join-Path $Destination ([IO.Path]::GetFileName($e.FullName))
            if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $e.Length) { $done += $e.Length; continue }
            $in = $e.Open(); $out = [IO.File]::Create($target)
            try {
                $buf = New-Object byte[] (1MB)
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
                    $out.Write($buf, 0, $n); $done += $n
                    if ($OnProgress) { & $OnProgress ([int](100 * $done / [Math]::Max(1, $total))) "Extrayendo $($e.Name)…" }
                }
            } finally { $in.Dispose(); $out.Dispose() }
        }
    } finally { $archive.Dispose() }
}

# ---------------------------------------------------------------------------
# Validaciones de la carpeta de instalación
# ---------------------------------------------------------------------------

function Test-CpInstallRoot {
    <# Lanza un error del catálogo si la carpeta no sirve. Devuelve la ruta normalizada. #>
    param([Parameter(Mandatory)][string]$Path, [long]$RequiredBytes = 0)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -gt $script:MaxRootLength) { throw (New-CpError '3DM-DSK-004' @{ max = $script:MaxRootLength }) }
    $ansi = [Text.Encoding]::GetEncoding([CpNative]::GetACP())
    $bad = @($full.ToCharArray() | Where-Object { $ansi.GetString($ansi.GetBytes([string]$_)) -ne [string]$_ } | Select-Object -Unique)
    if ($bad.Count) { throw (New-CpError '3DM-DSK-003' @{ chars = (-join $bad) }) }
    if ($full.StartsWith('\\')) { throw (New-CpError '3DM-DSK-002' @{ path = $full }) }
    try {
        if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Force -Path $full -ErrorAction Stop | Out-Null }
        $probe = Join-Path $full ('.creador-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force
    } catch { throw (New-CpError '3DM-DSK-002' @{ path = $full } $_.Exception) }
    if ($RequiredBytes -gt 0) {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
        if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
            throw (New-CpError '3DM-DSK-001' @{ drive = $drive.Name.TrimEnd('\'); need = (Format-CpSize $RequiredBytes); free = (Format-CpSize $drive.AvailableFreeSpace) })
        }
    }
    $full
}

function Format-CpSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    ('{0:N0} MB' -f [Math]::Ceiling($Bytes / 1MB))
}

function Get-CpRequiredBytes {
    <# Espacio necesario aproximado para instalar los juegos indicados (todo el contenido se copia al disco). #>
    param([Parameter(Mandatory)][string[]]$GameIds)
    $total = 0L
    foreach ($id in $GameIds) { $total += [long](Get-CpGame $id).iso.size }
    $total + 100MB   # películas del usuario y margen
}

# ---------------------------------------------------------------------------
# INI (en ANSI, como los lee el juego) y registro virtual
# ---------------------------------------------------------------------------

function Expand-CpTemplate {
    param([string]$Text, [hashtable]$Vars)
    if ($null -eq $Text) { return $Text }
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace('{' + $k + '}', [string]$Vars[$k]) }
    $Text
}

function Set-CpIniValues {
    <# Fusiona secciones/claves en un INI conservando el resto del contenido. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Values, [hashtable]$Vars = @{})
    $enc = [Text.Encoding]::GetEncoding([CpNative]::GetACP())
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($l in [IO.File]::ReadAllLines($Path, $enc)) { $lines.Add($l) }
        (Get-Item -LiteralPath $Path).IsReadOnly = $false
    }
    foreach ($section in $Values.Keys) {
        $kv = $Values[$section]
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -ieq "[$section]") { $start = $i; break }
        }
        if ($start -lt 0) {
            if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
            $lines.Add("[$section]"); $start = $lines.Count - 1
        }
        foreach ($key in $kv.Keys) {
            $value = Expand-CpTemplate ([string]$kv[$key]) $Vars
            $end = $lines.Count
            for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break } }
            $found = $false
            for ($i = $start + 1; $i -lt $end; $i++) {
                $t = $lines[$i]
                $eq = $t.IndexOf('=')
                if ($eq -gt 0 -and $t.Substring(0, $eq).Trim() -ieq $key) { $lines[$i] = "$key=$value"; $found = $true; break }
            }
            if (-not $found) {
                $insert = $end
                while ($insert -gt $start + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
                $lines.Insert($insert, "$key=$value")
            }
        }
    }
    [IO.File]::WriteAllLines($Path, $lines.ToArray(), $enc)
}

function Get-CpRegistryFile {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    Join-Path (Join-Path $Root "games\$Id") ([string](Get-CpGame $Id).registry.file)
}

function Write-CpGameConfig {
    <#
      Escribe el registro virtual (lo lee cphook.dll en lugar del registro de Windows) con las rutas
      actuales y crea las carpetas de la receta ("dirs"). Se ejecuta antes de cada inicio: así una
      carpeta movida o un nombre de jugador nuevo se corrigen solos.
    #>
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Vars)
    $hd = $Vars.HD
    foreach ($d in @($Game.dirs)) {
        $p = Join-Path $hd (Expand-CpTemplate ([string]$d) $Vars)
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
    $reg = ConvertTo-CpHashtable $Game.registry.values
    if (-not $reg) { return }
    # Primera vez de un jugador (su carpeta no existe): los valores que apuntan a ella van vacíos y el juego
    # la crea y la anota él mismo, con su bienvenida de primera vez, como hacía en 1996.
    if ($Vars.USERDIR -and -not (Test-Path -LiteralPath $Vars.USERDIR)) {
        foreach ($section in @($reg.Keys)) {
            foreach ($key in @($reg[$section].Keys)) {
                $v = [string]$reg[$section][$key]
                if ($v.Contains('{USERDIR}')) { $reg[$section][$key] = $v.Substring(0, $v.IndexOf(':') + 1) }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $hd)) { New-Item -ItemType Directory -Force -Path $hd | Out-Null }
    Set-CpIniValues -Path (Join-Path $hd ([string]$Game.registry.file)) -Values $reg -Vars $Vars
}

# ---------------------------------------------------------------------------
# Copia de archivos desde la ISO
# ---------------------------------------------------------------------------

function Copy-CpFromIso {
    <#
      Copia desde la ISO: cada carpeta de $Sources se copia "aplanada" en $Destination
      (su contenido, con subcarpetas). Con $Sources vacío copia el disco entero.
      $Include: si se indica, solo los archivos cuyo nombre coincide con algún patrón.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)][string]$Destination,
        [string[]]$Sources = @(), [string[]]$Exclude = @(), [string[]]$Include = @(), [scriptblock]$OnBytes, $Cancel
    )
    $Include = @($Include | Where-Object { $_ }); $Exclude = @($Exclude | Where-Object { $_ })   # $null -> lista vacía (modo estricto)
    $iso = New-Object CpIso($IsoPath)
    $copied = 0L
    try {
        $jobs = New-Object Collections.Generic.List[object]
        if (-not $Sources -or $Sources.Count -eq 0) {
            foreach ($e in $iso.List('')) { $jobs.Add(@($e, $e.Path)) }
        } else {
            foreach ($src in $Sources) {
                $prefix = $src.Trim('\') + '\'
                foreach ($e in $iso.List($src)) { $jobs.Add(@($e, $e.Path.Substring($prefix.Length))) }
            }
        }
        foreach ($job in $jobs) {
            $e = $job[0]; $rel = $job[1]
            if ($Exclude | Where-Object { ('\' + $rel + '\') -like ('*\' + $_ + '\*') }) { continue }
            if ($Include.Count -and -not $e.IsDirectory -and -not ($Include | Where-Object { [IO.Path]::GetFileName($rel) -like $_ })) { continue }
            if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
            $target = Join-Path $Destination $rel
            if ($e.IsDirectory) { if (-not $Include.Count -and -not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }; continue }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $e.Size) { $copied += $e.Size; continue }
            try { $copied += $iso.Extract($e, $target) }
            catch [UnauthorizedAccessException] { throw (New-CpError '3DM-CPY-002' @{ file = $rel } $_.Exception) }
            catch [IO.IOException] { throw (New-CpError '3DM-CPY-001' @{ game = [IO.Path]::GetFileName($IsoPath); file = $rel } $_.Exception) }
            if ($OnBytes) { & $OnBytes $e.Size $rel }
        }
    } finally { $iso.Dispose() }
    $copied
}

function Get-CpCopySize {
    param([Parameter(Mandatory)][string]$IsoPath, [string[]]$Sources = @(), [string[]]$Include = @())
    $Include = @($Include | Where-Object { $_ })
    $iso = New-Object CpIso($IsoPath)
    try {
        $entries = @()
        if (-not $Sources -or $Sources.Count -eq 0) { $entries = @($iso.List('')) }
        else { foreach ($s in $Sources) { $entries += @($iso.List($s)) } }
        if ($Include.Count) { $entries = @($entries | Where-Object { $n = [IO.Path]::GetFileName($_.Path); $Include | Where-Object { $n -like $_ } }) }
        $total = 0L
        foreach ($e in $entries) { if (-not $e.IsDirectory) { $total += [long]$e.Size } }
        return $total
    } finally { $iso.Dispose() }
}

# ---------------------------------------------------------------------------
# Instalación del runtime y del juego
# ---------------------------------------------------------------------------

function Install-CpRuntimeFiles {
    <#
      Copia el programa a <Root>\app para que la instalación no dependa de la carpeta de descarga.
      $Source: carpeta de la copia a instalar (por defecto, esta; la instalada la usa para actualizarse
      desde una copia más nueva).
    #>
    param([Parameter(Mandatory)][string]$Root, [string]$Source = $script:AppRoot)
    $app = Join-Path $Root 'app'
    $src = $Source
    if (Test-CpSamePath $src $app) { return $app }
    $binSrc = @((Join-Path $src 'native\bin'), (Join-Path $src 'bin')) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'cplaunch.exe') } | Select-Object -First 1
    if (-not $binSrc) { $binSrc = Join-Path $src 'native\bin' }
    New-Item -ItemType Directory -Force -Path $app | Out-Null
    Copy-Item -LiteralPath (Join-Path $src 'src') -Destination $app -Recurse -Force
    $binDst = Join-Path $app 'native\bin'
    New-Item -ItemType Directory -Force -Path $binDst | Out-Null
    Copy-Item -Path (Join-Path $binSrc '*') -Destination $binDst -Force
    foreach ($f in @('CreadorPeliculas.cmd', 'VERSION')) {
        $p = Join-Path $src $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $app -Force }
    }
    $cmd = @(
        '@echo off',
        'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\src\CreadorPeliculas.ps1" %*'
    )
    [IO.File]::WriteAllLines((Join-Path $Root 'CreadorPeliculas.cmd'), $cmd, [Text.Encoding]::ASCII)
    # Documento de usuario: LEEME.txt en un paquete, README.md de la raíz del repositorio en desarrollo.
    $doc = @((Join-Path $src 'LEEME.txt'), (Join-Path (Split-Path -Parent $src) 'README.md')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($doc) { foreach ($d in $app, $Root) { Copy-Item -LiteralPath $doc -Destination (Join-Path $d 'LEEME.txt') -Force } }
    foreach ($d in $app, $Root) { Remove-Item -LiteralPath (Join-Path $d 'LEEME-RUNTIME.md') -Force -ErrorAction SilentlyContinue }   # nombre anterior
    $app
}

function Get-CpGuidePath {
    <# Documento de usuario: el de la instalación, el de esta copia (LEEME.txt) o el README.md del repositorio. #>
    param([string]$Root)
    $c = @()
    if ($Root) { $c += Join-Path $Root 'LEEME.txt' }
    $c += (Join-Path $script:AppRoot 'LEEME.txt'), (Join-Path (Split-Path -Parent $script:AppRoot) 'README.md')
    $c | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Get-CpRuntimeVersion {
    <# Versión de una copia del programa (archivo VERSION en su carpeta); $null si no se conoce. #>
    param([string]$AppRoot = $script:AppRoot)
    $p = Join-Path $AppRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $v = $null
    if ([version]::TryParse("$(Get-Content -LiteralPath $p -TotalCount 1)".Trim(), [ref]$v)) { return $v }
    $null
}

function Test-CpSamePath {
    param([string]$A, [string]$B)
    $A -and $B -and ([IO.Path]::GetFullPath($A).TrimEnd('\') -ieq [IO.Path]::GetFullPath($B).TrimEnd('\'))
}

function Test-CpRuntimeCopy { param([string]$Path) $Path -and (Test-Path -LiteralPath (Join-Path $Path 'src\CreadorPeliculas.ps1')) }

function Register-CpRuntimeCopy {
    <#
      Si esta copia (por ejemplo, un ZIP recién descomprimido) es más nueva que la instalada en
      <Root>\app, anota su versión y carpeta en la configuración, que comparten todas las copias.
      Así la instalada —la que abren los accesos directos y Steam— puede ofrecer actualizarse.
      Devuelve $true si cambió $Config (hay que guardarla).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root)
    $app = Join-Path $Root 'app'
    if ((Test-CpSamePath $script:AppRoot $app) -or -not (Test-CpRuntimeCopy $app)) { return $false }
    $current = Get-CpRuntimeVersion
    if (-not $current) { return $false }
    $installed = Get-CpRuntimeVersion -AppRoot $app
    if ($installed -and $installed -ge $current) { return $false }
    $known = $Config.newerCopy
    if ($known -is [Collections.IDictionary] -and (Test-CpRuntimeCopy $known.path)) {
        $v = $null
        if ([version]::TryParse([string]$known.version, [ref]$v)) {
            if ($v -gt $current) { return $false }                                     # ya hay una más nueva anotada
            if ($v -eq $current -and (Test-CpSamePath $known.path $script:AppRoot)) { return $false }
        }
    }
    $Config.newerCopy = [ordered]@{ version = $current.ToString(); path = $script:AppRoot; declined = $false }
    $true
}

function Get-CpOutdatedInstall {
    <#
      ¿La instalación en <Root>\app —la que abren los accesos directos y Steam— es más vieja que
      otra copia del programa? Desde otra copia se compara con ella misma; desde la instalada, con
      la copia más nueva anotada por Register-CpRuntimeCopy en $Config.
      Devuelve $null si no hay nada que avisar, o Newer, Installed, Source, SourceExists y Declined.
    #>
    param([Parameter(Mandatory)][string]$Root, $Config)
    $app = Join-Path $Root 'app'
    if (-not (Test-CpRuntimeCopy $app)) { return $null }
    $declined = $false
    if (Test-CpSamePath $script:AppRoot $app) {
        $known = $(if ($Config) { $Config.newerCopy })
        if (-not ($known -is [Collections.IDictionary])) { return $null }
        $newer = $null
        if (-not [version]::TryParse([string]$known.version, [ref]$newer)) { return $null }
        $source = [string]$known.path
        $exists = Test-CpRuntimeCopy $source
        if ($exists) { $v = Get-CpRuntimeVersion -AppRoot $source; if ($v) { $newer = $v } }   # pudo cambiar desde que se anotó
        $declined = [bool]$known.declined
    } else {
        $newer = Get-CpRuntimeVersion
        if (-not $newer) { return $null }
        $source = $script:AppRoot
        $exists = $true
    }
    $installed = Get-CpRuntimeVersion -AppRoot $app
    if ($installed -and $installed -ge $newer) { return $null }
    [pscustomobject]@{ Newer = $newer; Installed = $installed; Source = $source; SourceExists = [bool]$exists; Declined = $declined }
}

function Install-CpGame {
    <#
      Instala (o repara) el juego siguiendo la receta "layout" de games.json, que reemplaza al
      instalador original de 16 bits. Todo el contenido del CD que usa el juego se copia al disco:
      el juego busca primero en el disco y no necesita el CD. $OnProgress recibe (porcentaje, texto).
    #>
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)][string]$Root,
        [scriptblock]$OnProgress, $Cancel, [switch]$Repair
    )
    $game = Get-CpGame $Id
    $hd = Join-Path $Root "games\$Id"
    $existedBefore = Test-Path -LiteralPath $hd
    $progress = { param($p, $t) if ($OnProgress) { & $OnProgress $p $t } }

    $rollback = {
        if (-not $existedBefore -and -not $Repair) { Remove-Item -LiteralPath $hd -Recurse -Force -ErrorAction SilentlyContinue }
    }.GetNewClosure()

    Invoke-CpStep -Name "Instalar $Id" -ErrorCode '3DM-CPY-001' -ErrorData @{ game = $game.name; file = '' } -Rollback $rollback -Action {
        & $progress 0 "Preparando $($game.name)…"
        $label = $null
        $iso = New-Object CpIso($IsoPath)
        try {
            $label = $iso.VolumeLabel
            if (-not $iso.Find($game.iso.keyFile)) { throw (New-CpError '3DM-ISO-002' @{ file = [IO.Path]::GetFileName($IsoPath) }) }
        } finally { $iso.Dispose() }

        $layout = @($game.layout)
        $total = 0L
        # @($null) tiene un elemento: los patrones opcionales se filtran para que "sin include" sea una lista vacía.
        $includeOf = { param($item) [string[]]@(@(Get-CpOptional $item 'include') | Where-Object { $_ }) }
        foreach ($item in $layout) { $total += [long](Get-CpCopySize -IsoPath $IsoPath -Sources @($item.from) -Include (& $includeOf $item)) }
        $counter = @{ done = 0L }
        # Sin GetNewClosure: el bloque se ejecuta dentro de Copy-CpFromIso y resuelve $counter/$progress por ámbito dinámico.
        $onBytes = { param($n, $rel) $counter.done += $n; & $progress ([int](95 * $counter.done / [Math]::Max(1, $total))) "Copiando $($game.name): $rel" }

        New-Item -ItemType Directory -Force -Path $hd | Out-Null
        foreach ($item in $layout) {
            $dest = Join-Path $hd ([string]$item.to)
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-CpFromIso -IsoPath $IsoPath -Destination $dest -Sources @($item.from) -Include (& $includeOf $item) -OnBytes $onBytes -Cancel $Cancel | Out-Null
        }
        & $progress 96 'Preparando la configuración…'
        # Los archivos copiados de un CD quedan de solo lectura y el juego no podría escribir sus datos.
        Get-ChildItem -LiteralPath $hd -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
        Write-CpGameConfig -Game $game -Root $Root -Vars (Get-CpGameVars -Id $Id -Root $Root -Player (Get-CpPlayer (Get-CpConfig)))

        $manifest = Get-CpManifest -Root $Root
        $manifest.games[$Id] = [ordered]@{
            id = $Id; name = $game.name; isoPath = $IsoPath; label = $label; hd = $hd; installedAt = (Get-Date -Format s)
        }
        Save-CpManifest -Root $Root -Manifest $manifest
        & $progress 100 "$($game.name): listo."
    }
}

function Get-CpOptional {
    <# Propiedad opcional de un objeto de games.json (o $null). #>
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { $Object.$Name } else { $null }
}

function Get-CpLauncherArgs {
    param([string]$Id, [string]$Root, [string]$File)
    $a = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root 'app\src\CreadorPeliculas.ps1')
    if ($Id) { $a += " --play $Id" }
    if ($File) { $a += " --file `"$File`"" }
    $a
}

function Get-CpShortcutDir { [Environment]::GetFolderPath('Programs') + '\' + $script:ProductName }

function New-CpShortcuts {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [bool]$Desktop = $true)
    $game = Get-CpGame $Id
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(Get-CpShortcutDir)
    if ($Desktop) { $targets += [Environment]::GetFolderPath('Desktop') }
    $icon = Join-Path $Root "games\$Id\$($game.icon)"
    foreach ($dir in $targets) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $lnk = $shell.CreateShortcut((Join-Path $dir ("{0}.lnk" -f ($game.name -replace '[\\/:*?"<>|]', '-'))))
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = Get-CpLauncherArgs -Id $Id -Root $Root
        $lnk.WorkingDirectory = $Root
        if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
        $lnk.Description = "$($game.name) ($($game.age))"
        $lnk.WindowStyle = 7
        $lnk.Save()
    }
    $lib = $shell.CreateShortcut((Join-Path ($targets[0]) "$($script:ProductName) - opciones.lnk"))
    $lib.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lib.Arguments = Get-CpLauncherArgs -Root $Root
    $lib.WorkingDirectory = $Root
    $lib.WindowStyle = 7
    $lib.Save()
}

function Remove-CpShortcuts {
    param([Parameter(Mandatory)][string]$Id)
    $game = Get-CpGame $Id
    $name = "{0}.lnk" -f ($game.name -replace '[\\/:*?"<>|]', '-')
    foreach ($dir in @((Get-CpShortcutDir), [Environment]::GetFolderPath('Desktop'))) {
        Remove-Item -LiteralPath (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue
    }
}

function Get-CpInstalledGames {
    param([Parameter(Mandatory)][string]$Root)
    $m = Get-CpManifest -Root $Root
    foreach ($g in Get-CpCatalog) {
        if ($m.games.Contains($g.id)) {
            $e = $m.games[$g.id]
            $ok = Test-Path -LiteralPath (Join-Path $e.hd $g.exe)
            [pscustomobject]@{ Id = $g.id; Name = $g.name; Age = $g.age; Engine = $g.engine; Entry = $e; Healthy = $ok
                Icon = (Join-Path $e.hd $g.icon) }
        }
    }
}

# ---------------------------------------------------------------------------
# Asociación de archivos .3MM (opcional, solo para el usuario actual)
# ---------------------------------------------------------------------------

function Set-CpFileAssociation {
    <#
      Doble clic en una película .3MM la abre con el lanzador (que aplica la capa de compatibilidad).
      Se escribe en HKCU\Software\Classes: no requiere administrador y no afecta a otros usuarios.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [bool]$Enabled = $true)
    $game = Get-CpGame $Id
    $ext = Get-CpOptional $game 'fileExtension'
    if (-not $ext) { $ext = '.3mm' }
    $progId = 'CreadorPeliculas.Pelicula'
    $classes = 'HKCU:\Software\Classes'
    if ($Enabled) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        New-Item -Path "$classes\$progId\shell\open\command" -Force | Out-Null
        Set-Item -Path "$classes\$progId" -Value 'Película de 3D Creador de Películas'
        Set-Item -Path "$classes\$progId\shell\open\command" -Value ('"{0}" {1}' -f $ps, (Get-CpLauncherArgs -Id $Id -Root $Root -File '%1'))
        New-Item -Path "$classes\$progId\DefaultIcon" -Force | Out-Null
        Set-Item -Path "$classes\$progId\DefaultIcon" -Value ('"{0}",1' -f (Join-Path $Root "games\$Id\$($game.icon)"))
        New-Item -Path "$classes\$ext" -Force | Out-Null
        Set-Item -Path "$classes\$ext" -Value $progId
    } else {
        if ((Get-Item -Path "$classes\$ext" -ErrorAction SilentlyContinue) -and (Get-ItemProperty -Path "$classes\$ext").'(default)' -eq $progId) {
            Remove-Item -Path "$classes\$ext" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path "$classes\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    }
    [CpNative]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)   # SHCNE_ASSOCCHANGED
}

# ---------------------------------------------------------------------------
# Partidas (películas): copia de seguridad, exportación e importación
# Mismo formato que la versión de Linux / Steam Deck (linux/creador/core.py):
#   - de un juego:  <ID>-AAAAMMDD-HHMMSS.zip con los archivos sueltos
#   - de todos:     creador-peliculas-AAAAMMDD-HHMMSS.zip con <ID>/<archivo>
#   - ambos llevan creador-saves.json ({ format, createdAt, platform, games })
# ---------------------------------------------------------------------------

$script:SavesManifest = 'creador-saves.json'

function Get-CpSavesFolder {
    if ($env:CP3D_SAVES_DIR) { return $env:CP3D_SAVES_DIR }   # para las pruebas
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Creador de Películas 3D - copias'
}

function Test-CpSaveName {
    <# ¿Es un nombre de archivo de partida de este juego? Solo nombres simples, sin rutas (sin distinguir mayúsculas). #>
    param([Parameter(Mandatory)]$Game, [string]$Name)
    if (-not $Name -or $Name -in @('.', '..') -or $Name.IndexOfAny([char[]]'\/:') -ge 0) { return $false }
    foreach ($pat in @($Game.saves)) { if ($Name -like $pat) { return $true } }
    $false
}

function Get-CpSaveFiles {
    <# Archivos de partidas (películas del jugador) de un juego instalado. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    $game = Get-CpGame $Id
    $dir = Get-CpSavesDir -Id $Id -Root $Root
    @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { Test-CpSaveName $game $_.Name } | Sort-Object Name)
}

function New-CpSavesZip {
    <# Crea un zip de partidas. $Entries: lista de @{ Path; Name } (Name puede ser '<ID>/<archivo>'). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GameIds, [Parameter(Mandatory)]$Entries)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        $meta = [ordered]@{ format = 1; createdAt = (Get-Date -Format s); platform = 'windows'; games = @($GameIds) } | ConvertTo-Json
        $w = New-Object IO.StreamWriter($archive.CreateEntry($script:SavesManifest).Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write($meta) } finally { $w.Dispose() }
        foreach ($e in $Entries) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $e.Path, $e.Name) }
    } finally { $archive.Dispose() }
}

function Get-CpUniquePath {
    param([Parameter(Mandatory)][string]$Path)
    $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Path), [IO.Path]::GetFileNameWithoutExtension($Path))
    $ext = [IO.Path]::GetExtension($Path)
    for ($n = 2; Test-Path -LiteralPath $Path; $n++) { $Path = '{0}-{1}{2}' -f $base, $n, $ext }
    $Path
}

function Backup-CpSaves {
    <# Comprime las películas del jugador en Documentos\Creador de Películas 3D - copias (o en $Destination). Devuelve la ruta del zip (o $null). #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [string]$Destination)
    $files = @(Get-CpSaveFiles -Id $Id -Root $Root)
    if (-not $files.Count) { return $null }
    $destDir = $(if ($Destination) { $Destination } else { Get-CpSavesFolder })
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $zip = Get-CpUniquePath (Join-Path $destDir ('{0}-{1:yyyyMMdd-HHmmss}.zip' -f $Id, (Get-Date)))
    New-CpSavesZip -Path $zip -GameIds @($Id) -Entries @($files | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } })
    Write-CpLog Info "Copia de películas de ${Id}: $zip"
    $zip
}

function Export-CpAllSaves {
    <# Un solo zip con las películas de todos los juegos instalados (<ID>/<archivo>). Devuelve la ruta o $null. #>
    param([Parameter(Mandatory)][string]$Root, [string]$Destination)
    $ids = @(); $entries = @()
    foreach ($g in @(Get-CpInstalledGames -Root $Root)) {
        $files = @(Get-CpSaveFiles -Id $g.Id -Root $Root)
        if (-not $files.Count) { continue }
        $ids += $g.Id
        $entries += @($files | ForEach-Object { @{ Path = $_.FullName; Name = ('{0}/{1}' -f $g.Id, $_.Name) } })
    }
    if (-not $ids.Count) { return $null }
    $destDir = $(if ($Destination) { $Destination } else { Get-CpSavesFolder })
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $zip = Get-CpUniquePath (Join-Path $destDir ('creador-peliculas-{0:yyyyMMdd-HHmmss}.zip' -f (Get-Date)))
    New-CpSavesZip -Path $zip -GameIds $ids -Entries $entries
    Write-CpLog Info "Exportación de todas las películas: $zip"
    $zip
}

function Find-CpGameId {
    param([string]$Text)
    $g = Get-CpCatalog | Where-Object { $_.id -ieq $Text } | Select-Object -First 1
    if ($g) { $g.id } else { $null }
}

function Read-CpSavesZip {
    <#
      Analiza un zip de películas (de Windows o de Linux). Devuelve @{ Games = @{ ID = @{ nombre = entrada } }; Ignored = @() }.
      El ID de los archivos sueltos sale de creador-saves.json o del nombre del zip (<ID>-AAAAMMDD-HHMMSS.zip).
    #>
    param([Parameter(Mandatory)][string]$Zip)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { $archive = [IO.Compression.ZipFile]::OpenRead($Zip) }
    catch { throw (New-CpError '3DM-SAV-001' @{ file = [IO.Path]::GetFileName($Zip) } $_.Exception) }
    try {
        $flatId = $null
        $metaEntry = $archive.Entries | Where-Object { $_.FullName -eq $script:SavesManifest } | Select-Object -First 1
        if ($metaEntry) {
            try {
                $r = New-Object IO.StreamReader($metaEntry.Open(), [Text.Encoding]::UTF8)
                try { $meta = $r.ReadToEnd() | ConvertFrom-Json } finally { $r.Dispose() }
                $metaIds = @(@($meta.games) | ForEach-Object { Find-CpGameId $_ } | Where-Object { $_ })
                if ($metaIds.Count -eq 1) { $flatId = $metaIds[0] }
            } catch { Write-CpLog Warn "creador-saves.json ilegible en ${Zip}: $_" }
        }
        if (-not $flatId -and [IO.Path]::GetFileName($Zip) -match '^(.+?)-\d{8}-\d{6}(-\d+)?\.zip$') { $flatId = Find-CpGameId $Matches[1] }
        # Un zip cualquiera con películas sueltas: si hay un solo juego en el catálogo, son de ese juego.
        if (-not $flatId -and @(Get-CpCatalog).Count -eq 1) { $flatId = @(Get-CpCatalog)[0].id }
        $games = @{}; $ignored = @()
        foreach ($e in $archive.Entries) {
            $name = $e.FullName.Replace('\', '/')
            if ($name.EndsWith('/') -or $name -eq $script:SavesManifest) { continue }
            $parts = $name.Split('/')
            $id = $null; $file = $name
            if ($parts.Count -eq 1) { $id = $flatId; $file = $parts[0] }
            elseif ($parts.Count -eq 2) { $id = Find-CpGameId $parts[0]; $file = $parts[1] }
            if (-not $id -or -not (Test-CpSaveName (Get-CpGame $id) $file)) { $ignored += $name; continue }
            if (-not $games.ContainsKey($id)) { $games[$id] = @{} }
            if (@($games[$id].Keys | Where-Object { $_ -ieq $file }).Count) { $ignored += $name; continue }
            $games[$id][$file] = $name
        }
    } finally { $archive.Dispose() }
    if (-not $games.Count) { throw (New-CpError '3DM-SAV-001' @{ file = [IO.Path]::GetFileName($Zip) }) }
    [pscustomobject]@{ Games = $games; Ignored = $ignored }
}

function Import-CpSaves {
    <#
      Importa películas desde un zip. Para cada juego instalado que aparece en el zip guarda antes una copia
      de las películas actuales y las reemplaza. Devuelve @{ Imported = @{ ID = archivos }; Skipped = @{ ID = motivo }; Backups; Ignored }.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Zip, [string]$BackupDestination)
    $content = Read-CpSavesZip -Zip $Zip
    if (Get-CpRunningGame -Root $Root) { throw (New-CpError '3DM-RUN-001') }
    $installed = @(Get-CpInstalledGames -Root $Root | Where-Object { $_.Healthy } | ForEach-Object { $_.Id })
    $result = [pscustomobject]@{ Imported = [ordered]@{}; Skipped = [ordered]@{}; Backups = @(); Ignored = @($content.Ignored) }
    Invoke-CpStep -Name "Importar películas $([IO.Path]::GetFileName($Zip))" -ErrorCode '3DM-SAV-002' -ErrorData @{ file = [IO.Path]::GetFileName($Zip) } -Action {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($g in @(Get-CpCatalog | Where-Object { $content.Games.ContainsKey($_.id) })) {
                $id = $g.id
                if ($installed -notcontains $id) { $result.Skipped[$id] = 'no está instalado'; continue }
                $dir = Get-CpSavesDir -Id $id -Root $Root
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $b = Backup-CpSaves -Id $id -Root $Root -Destination $BackupDestination
                if ($b) { $result.Backups += $b }
                foreach ($f in @(Get-CpSaveFiles -Id $id -Root $Root)) { $f.IsReadOnly = $false; Remove-Item -LiteralPath $f.FullName -Force }
                foreach ($file in $content.Games[$id].Keys) {
                    $entry = $archive.GetEntry($content.Games[$id][$file])
                    if (-not $entry) { $entry = $archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $content.Games[$id][$file] } | Select-Object -First 1 }
                    $target = Join-Path $dir $file
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                    (Get-Item -LiteralPath $target).LastWriteTime = $entry.LastWriteTime.DateTime
                }
                $result.Imported[$id] = @($content.Games[$id].Keys | Sort-Object)
                Write-CpLog Info ("Películas importadas en {0}: {1}" -f $id, ($result.Imported[$id] -join ', '))
            }
        } finally { $archive.Dispose() }
    }
    $result
}

function Uninstall-CpGame {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [switch]$KeepSaves)
    Invoke-CpStep -Name "Desinstalar $Id" -ErrorCode '3DM-CFG-001' -ErrorData @{ game = (Get-CpGame $Id).name } -Action {
        $backup = $null
        if ($KeepSaves) { $backup = Backup-CpSaves -Id $Id -Root $Root }
        Remove-CpShortcuts -Id $Id
        Set-CpFileAssociation -Id $Id -Root $Root -Enabled $false
        Remove-Item -LiteralPath (Join-Path $Root "games\$Id") -Recurse -Force -ErrorAction Stop
        $m = Get-CpManifest -Root $Root
        if ($m.games.Contains($Id)) { $m.games.Remove($Id) }
        Save-CpManifest -Root $Root -Manifest $m
        $backup
    }
}

# ---------------------------------------------------------------------------
# Lanzamiento
# ---------------------------------------------------------------------------

function Get-CpRunningGame {
    param([Parameter(Mandatory)][string]$Root)
    $games = (Join-Path $Root 'games').TrimEnd('\') + '\'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($games, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    } | Select-Object -First 1
}

function Start-CpGame {
    <#
      Escribe la configuración (registro virtual) y lanza el juego con la capa de compatibilidad.
      $File: película .3MM para abrir directamente (asociación de archivos).
      Devuelve una "sesión" que hay que cerrar con Complete-CpGame.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [int]$Scale = 0, [string]$Player, [string]$File)
    $game = Get-CpGame $Id
    $m = Get-CpManifest -Root $Root
    if (-not $m.games.Contains($Id)) { throw (New-CpError '3DM-RUN-006' @{ game = $game.name }) }
    $entry = $m.games[$Id]
    $hd = $entry.hd
    $exe = Join-Path $hd $game.exe
    if (-not (Test-Path -LiteralPath $exe)) { throw (New-CpError '3DM-RUN-006' @{ game = $game.name }) }
    if (Get-CpRunningGame -Root $Root) { throw (New-CpError '3DM-RUN-001') }
    if (-not (Test-CpPlayerName $Player)) { $Player = $script:DefaultPlayer }

    $session = [pscustomobject]@{ Id = $Id; Game = $game; Root = $Root; Process = $null; Started = $null; ExitCode = $null }
    $vars = Get-CpGameVars -Id $Id -Root $Root -Player $Player
    Write-CpLog Info "Juego ${Id}: carpeta $hd, jugador $Player"
    Invoke-CpStep -Name "Configurar $Id" -ErrorCode '3DM-CFG-001' -ErrorData @{ game = $game.name } -Action {
        Write-CpGameConfig -Game $game -Root $Root -Vars $vars
    }

    $bin = Get-CpNativeBin
    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $env:CP3D_LOG = Join-Path $logDir "juego-$Id.log"
    if ($env:CP3D_TRACE -ne '1') { $env:CP3D_TRACE = '0' }   # diagnóstico: definir CP3D_TRACE=1 antes de abrir
    $env:CP3D_REGFILE = Get-CpRegistryFile -Id $Id -Root $Root
    $env:CP3D_USER = $Player
    $env:CP3D_SCALE = [string]$Scale
    $env:CP3D_QUIET = $null
    if (Test-Path -LiteralPath $env:CP3D_LOG) { Clear-Content -LiteralPath $env:CP3D_LOG -ErrorAction SilentlyContinue }

    $workDir = Split-Path -Parent $exe
    $gameArgs = Expand-CpTemplate ([string]$game.args) $vars
    if ($File) { $gameArgs = ('{0} "{1}"' -f $gameArgs, $File).Trim() }
    $argLine = ('--wait --cwd "{0}" -- "{1}" {2}' -f $workDir, $exe, $gameArgs).Trim()
    Write-CpLog Info "Lanzando: cplaunch.exe $argLine"
    $session.Process = Start-Process -FilePath (Join-Path $bin 'cplaunch.exe') -ArgumentList $argLine -WorkingDirectory $workDir -PassThru
    $session.Started = Get-Date
    $session
}

function Complete-CpGame {
    <# Espera a que el juego termine y devuelve $null o un error diagnóstico. #>
    param([Parameter(Mandatory)]$Session, [switch]$NoDiagnose)
    $diag = $null
    if ($Session.Process) {
        try { $Session.Process.WaitForExit() } catch { }
        $Session.ExitCode = $Session.Process.ExitCode
        $elapsed = ((Get-Date) - $Session.Started).TotalSeconds
        Write-CpLog Info ("Juego {0} terminó: código {1} (0x{1:X8}) tras {2:N0} s" -f $Session.Id, $Session.ExitCode, $elapsed)
        if (-not $NoDiagnose) {
            $code = [int64]$Session.ExitCode
            if ($code -in 9001, 9002, 9003) { $diag = New-CpError '3DM-RUN-005' @{ game = $Session.Game.name } }
            elseif ($code -eq 0xC0000005 -or $code -eq -1073741819) {
                # cphook deja en el log del juego dónde ocurrió el fallo (líneas "FALLO"): va al informe.
                $crash = $null
                $gameLog = Join-Path $Session.Root "logs\juego-$($Session.Id).log"
                if (Test-Path -LiteralPath $gameLog) {
                    $lines = @(Get-Content -LiteralPath $gameLog -Encoding UTF8 | Where-Object { $_ -match '\] FALLO ' })
                    if ($lines.Count) {
                        $text = ($lines | ForEach-Object { $_ -replace '^\[\s*\d+\] FALLO ', '' }) -join [Environment]::NewLine
                        Write-CpLog Error "Detalle del fallo de $($Session.Id):$([Environment]::NewLine)$text"
                        $crash = New-Object Exception("Detalle del fallo:$([Environment]::NewLine)$text")
                    }
                }
                $diag = New-CpError '3DM-RUN-004' @{ game = $Session.Game.name; code = ('0x{0:X8}' -f $Session.ExitCode) } $crash
            }
            elseif ($elapsed -lt 5 -and $code -ne 0) { $diag = New-CpError '3DM-RUN-003' @{ game = $Session.Game.name } }
        }
    }
    $diag
}

Export-ModuleMember -Function Get-CpAppRoot, Get-CpProductName, Get-CpNativeBin, Get-CpCatalog, Get-CpGame, ConvertTo-CpHashtable, Get-CpConfig, Save-CpConfig,
    Get-CpDefaultInstallRoot, Get-CpManifest, Save-CpManifest, Test-CpPlayerName, Get-CpPlayer, Get-CpGameVars, Get-CpSavesDir, Test-CpPrerequisites,
    Find-CpIsos, Expand-CpZipIsos, Test-CpInstallRoot, Format-CpSize, Get-CpRequiredBytes, Expand-CpTemplate, Set-CpIniValues, Get-CpRegistryFile,
    Write-CpGameConfig, Copy-CpFromIso, Get-CpCopySize, Install-CpRuntimeFiles, Get-CpGuidePath, Get-CpRuntimeVersion, Test-CpSamePath, Register-CpRuntimeCopy,
    Get-CpOutdatedInstall, Install-CpGame, Get-CpOptional, New-CpShortcuts, Remove-CpShortcuts, Get-CpInstalledGames, Set-CpFileAssociation,
    Backup-CpSaves, Get-CpSavesFolder, Test-CpSaveName, Get-CpSaveFiles, Export-CpAllSaves, Read-CpSavesZip, Import-CpSaves,
    Uninstall-CpGame, Get-CpRunningGame, Start-CpGame, Complete-CpGame
