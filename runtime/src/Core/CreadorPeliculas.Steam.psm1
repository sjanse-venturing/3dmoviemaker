# CreadorPeliculas.Steam.psm1 — accesos «no de Steam» (shortcuts.vdf) para abrir el programa desde Steam,
# Big Picture y Steam Link, con su artwork (grid, hero, logo) generado desde el CD.
# Compatible con Windows PowerShell 5.1. Refleja linux/creador/steam.py (mismo formato binario, mismo appid,
# mismos campos y mismas imágenes).

Set-StrictMode -Version 2.0

$script:Tag = 'Creador de Películas 3D'
$script:LibraryName = 'Creador de Películas 3D - opciones'

function Initialize-CpVdf {
    # Se compila recién cuando hace falta, para no demorar el arranque de la biblioteca.
    if ('CpVdf' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Specialized;
using System.IO;
using System.Text;

public static class CpVdf {
    // VDF binario de Steam: 0x00 mapa, 0x01 texto, 0x02 entero de 32 bits, 0x07 entero de 64 bits, 0x08 fin.
    public static OrderedDictionary Load(byte[] data) {
        if (data == null || data.Length == 0) return new OrderedDictionary();
        int pos = 0;
        return ReadMap(data, ref pos);
    }

    static string CStr(byte[] d, ref int pos) {
        int end = Array.IndexOf(d, (byte)0, pos);
        if (end < 0) throw new InvalidDataException("VDF truncado");
        string s = Encoding.UTF8.GetString(d, pos, end - pos);
        pos = end + 1;
        return s;
    }

    static OrderedDictionary ReadMap(byte[] d, ref int pos) {
        var map = new OrderedDictionary();
        while (true) {
            if (pos >= d.Length) throw new InvalidDataException("VDF truncado");
            byte t = d[pos++];
            if (t == 0x08) return map;
            string key = CStr(d, ref pos);
            switch (t) {
                case 0x00: map[key] = ReadMap(d, ref pos); break;
                case 0x01: map[key] = CStr(d, ref pos); break;
                case 0x02: map[key] = BitConverter.ToInt32(d, pos); pos += 4; break;
                case 0x07: map[key] = BitConverter.ToUInt64(d, pos); pos += 8; break;
                default: throw new InvalidDataException(string.Format("Tipo VDF desconocido 0x{0:X2}", t));
            }
        }
    }

    public static byte[] Dump(IDictionary map) {
        var ms = new MemoryStream();
        Write(ms, map);
        return ms.ToArray();
    }

    static void Bytes(MemoryStream ms, byte[] b) { ms.Write(b, 0, b.Length); }

    static void Write(MemoryStream ms, IDictionary map) {
        foreach (DictionaryEntry e in map) {
            byte[] key = Encoding.UTF8.GetBytes(Convert.ToString(e.Key) + "\0");
            object v = e.Value;
            if (v is System.Management.Automation.PSObject) v = ((System.Management.Automation.PSObject)v).BaseObject;
            if (v is IDictionary) { ms.WriteByte(0x00); Bytes(ms, key); Write(ms, (IDictionary)v); }
            else if (v is ulong) { ms.WriteByte(0x07); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((ulong)v)); }
            else if (v is bool || v is int || v is short || v is byte || v is long || v is uint) {
                long n = (v is bool) ? (((bool)v) ? 1 : 0) : Convert.ToInt64(v);
                if (n > int.MaxValue || n < int.MinValue) { ms.WriteByte(0x07); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((ulong)n)); }
                else { ms.WriteByte(0x02); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((int)n)); }
            }
            else { ms.WriteByte(0x01); Bytes(ms, key); Bytes(ms, Encoding.UTF8.GetBytes(Convert.ToString(v) + "\0")); }
        }
        ms.WriteByte(0x08);
    }

    static uint[] table;

    public static uint Crc32(byte[] data) {
        if (table == null) {
            var t = new uint[256];
            for (uint i = 0; i < 256; i++) {
                uint c = i;
                for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                t[i] = c;
            }
            table = t;
        }
        uint crc = 0xFFFFFFFFu;
        foreach (byte b in data) crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    // El appid que Steam calcula para un acceso no-Steam (entero de 32 bits con signo en el VDF).
    public static int ShortcutAppId(string exe, string name) {
        uint v = Crc32(Encoding.UTF8.GetBytes(exe + name)) | 0x80000000u;
        return unchecked((int)v);
    }
}
'@ -ReferencedAssemblies ([psobject].Assembly.Location)
}

function ConvertFrom-CpVdf { param([byte[]]$Bytes) Initialize-CpVdf; [CpVdf]::Load($Bytes) }
function ConvertTo-CpVdf { param([Parameter(Mandatory)][Collections.IDictionary]$Map) Initialize-CpVdf; , [CpVdf]::Dump($Map) }
function Get-CpShortcutAppId { param([string]$Exe, [string]$Name) Initialize-CpVdf; [CpVdf]::ShortcutAppId($Exe, $Name) }

# ---------------------------------------------------------------------------
# Steam instalado
# ---------------------------------------------------------------------------

function Get-CpSteamRoot {
    <# Carpeta de Steam (o $null si no está instalado). #>
    foreach ($k in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'), @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'), @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath'))) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k[0] -Name $k[1] -ErrorAction Stop).($k[1])
            if ($v) {
                $p = [IO.Path]::GetFullPath(($v -replace '/', '\'))
                if (Test-Path -LiteralPath (Join-Path $p 'steam.exe')) { return $p }
            }
        } catch { }
    }
    $null
}

function Get-CpSteamUserConfigDirs {
    <# userdata\<id>\config de cada usuario de Steam que inició sesión en este equipo. #>
    $root = Get-CpSteamRoot
    if (-not $root) { return @() }
    @(Get-ChildItem -LiteralPath (Join-Path $root 'userdata') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'config')) } |
        ForEach-Object { Join-Path $_.FullName 'config' })
}

function Test-CpSteamInstalled { [bool](Get-CpSteamRoot) }

function Test-CpSteamRunning { [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }

function Stop-CpSteam {
    <# Pide a Steam que se cierre y espera hasta $Timeout segundos. Devuelve $true si se cerró. #>
    param([int]$Timeout = 60)
    $root = Get-CpSteamRoot
    if (-not $root) { return $true }
    Start-Process -FilePath (Join-Path $root 'steam.exe') -ArgumentList '-shutdown' | Out-Null
    $end = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $end) {
        if (-not (Test-CpSteamRunning)) { Start-Sleep -Seconds 1; return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Start-CpSteam {
    $root = Get-CpSteamRoot
    if ($root) { Start-Process -FilePath (Join-Path $root 'steam.exe') | Out-Null }
}

# ---------------------------------------------------------------------------
# Accesos
# ---------------------------------------------------------------------------

function Get-CpWantedSteamShortcuts {
    <# La biblioteca y un acceso por juego instalado, con los mismos argumentos que los .lnk del menú Inicio. #>
    param([Parameter(Mandatory)][string]$Root)
    $exe = '"{0}"' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $ps1 = Join-Path $Root 'app\src\CreadorPeliculas.ps1'
    $base = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $ps1
    $items = @(@{ name = $script:LibraryName; opts = $base; icon = '' })
    foreach ($g in @(Get-CpInstalledGames -Root $Root)) {
        $icon = $(if (Test-Path -LiteralPath $g.Icon) { $g.Icon } else { '' })
        $items += @{ name = $g.Name; opts = "$base --play $($g.Id)"; icon = $icon; id = $g.Id }
    }
    foreach ($i in $items) {
        $script:LastArtIds[(Get-CpShortcutAppId $exe $i.name)] = $(if ($i.Contains('id')) { $i.id } else { $null })
        [ordered]@{
            appid = (Get-CpShortcutAppId $exe $i.name); AppName = $i.name; Exe = $exe; StartDir = ('"{0}"' -f $Root); icon = $i.icon
            ShortcutPath = ''; LaunchOptions = $i.opts; IsHidden = 0; AllowDesktopConfig = 1; AllowOverlay = 1; OpenVR = 0; Devkit = 0
            DevkitGameID = ''; DevkitOverrideAppID = 0; LastPlayTime = 0; FlatpakAppID = ''; tags = [ordered]@{ '0' = $script:Tag }
        }
    }
}

function Test-CpOurShortcut {
    param($Entry)
    foreach ($k in 'LaunchOptions', 'launchoptions') { if ($Entry.Contains($k) -and ([string]$Entry[$k]) -like '*CreadorPeliculas.ps1*') { return $true } }
    foreach ($k in 'Exe', 'exe') { if ($Entry.Contains($k) -and ([string]$Entry[$k]).Trim('"') -like '*/creador.sh') { return $true } }
    $false
}

function Update-CpSteamShortcutsFile {
    <# Reemplaza nuestros accesos en un shortcuts.vdf conservando los demás. Devuelve cuántos escribió. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Wanted)
    $data = $null
    if (Test-Path -LiteralPath $Path) { $data = [IO.File]::ReadAllBytes($Path) }
    $doc = ConvertFrom-CpVdf $data
    $current = @()
    if ($doc.Contains('shortcuts') -and $doc['shortcuts'] -is [Collections.IDictionary]) { $current = @($doc['shortcuts'].Values) }
    $keep = @($current | Where-Object { -not (Test-CpOurShortcut $_) })
    $old = @{}
    foreach ($e in @($current | Where-Object { Test-CpOurShortcut $_ })) {
        $n = $(if ($e.Contains('AppName')) { $e['AppName'] } elseif ($e.Contains('appname')) { $e['appname'] } else { '' })
        $old[[string]$n] = $e
    }
    $merged = New-Object Collections.Specialized.OrderedDictionary
    $i = 0
    foreach ($e in $keep) { $merged[[string]$i] = $e; $i++ }
    foreach ($w in @($Wanted)) {
        $prev = $old[$w.AppName]
        if ($prev -and $prev.Contains('LastPlayTime')) { $w.LastPlayTime = $prev['LastPlayTime'] }   # conservar la última vez que se jugó
        $merged[[string]$i] = $w; $i++
    }
    $out = New-Object Collections.Specialized.OrderedDictionary
    $out['shortcuts'] = $merged
    $bytes = ConvertTo-CpVdf $out
    if ($data -and -not (Test-Path -LiteralPath "$Path.creador.bak")) { Copy-Item -LiteralPath $Path -Destination "$Path.creador.bak" }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    @($Wanted).Count
}

# ---------------------------------------------------------------------------
# Artwork (config\grid): portada vertical, cabecera, fondo y logo
# ---------------------------------------------------------------------------

$script:LastArtIds = @{}

function Get-CpHexColor { param([string]$Hex) [Drawing.Color]::FromArgb([Convert]::ToInt32($Hex.Substring(0, 2), 16), [Convert]::ToInt32($Hex.Substring(2, 2), 16), [Convert]::ToInt32($Hex.Substring(4, 2), 16)) }

function New-CpArtImages {
    <#
      Genera las imágenes de Steam a partir de la imagen del catálogo del CD que copió la instalación
      (receta "art" de games.json) en <Root>\games\<ID>\art\steam. Mismas medidas y composición que
      linux/creador/steam.py. Devuelve la carpeta, o $null si el juego no tiene receta o falta la imagen.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    $game = Get-CpGame $Id
    $art = Get-CpOptional $game 'art'
    if (-not $art) { return $null }
    $hd = Join-Path $Root "games\$Id"
    $src = Join-Path $hd $art.source
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $out = Join-Path $hd 'art\steam'
    if ((Test-Path -LiteralPath (Join-Path $out 'hero.png')) -and (Get-Item -LiteralPath (Join-Path $out 'hero.png')).LastWriteTime -ge (Get-Item -LiteralPath $src).LastWriteTime) { return $out }
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $img = New-Object Drawing.Bitmap $src
    try {
        $lr = @($art.logo.rect); $pr = @($art.picture.rect)
        # Logo con el fondo del catálogo vuelto transparente.
        $logo = New-Object Drawing.Bitmap ([int]$lr[2]), ([int]$lr[3]), ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $key = Get-CpHexColor $art.logo.key; $tol = [int]$art.logo.tolerance
        for ($y = 0; $y -lt $lr[3]; $y++) {
            for ($x = 0; $x -lt $lr[2]; $x++) {
                $c = $img.GetPixel($lr[0] + $x, $lr[1] + $y)
                $d = [Math]::Abs($c.R - $key.R) + [Math]::Abs($c.G - $key.G) + [Math]::Abs($c.B - $key.B)
                $logo.SetPixel($x, $y, $(if ($d -le $tol) { [Drawing.Color]::Transparent } else { $c }))
            }
        }
        $rect = New-Object Drawing.Rectangle ([int]$pr[0]), ([int]$pr[1]), ([int]$pr[2]), ([int]$pr[3])
        $pic = $img.Clone($rect, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bg = Get-CpHexColor $art.background
        $compose = {
            param([int]$W, [int]$H, $Parts, [string]$Name, [bool]$Transparent = $false)
            $c = New-Object Drawing.Bitmap $W, $H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($c)
            try {
                $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.Clear($(if ($Transparent) { [Drawing.Color]::Transparent } else { $bg }))
                foreach ($p in $Parts) {
                    $s = [Math]::Min($p.w / $p.img.Width, $p.h / $p.img.Height)
                    $w = [int]($p.img.Width * $s); $h = [int]($p.img.Height * $s)
                    $x = $p.x + [int](($p.w - $w) / 2); $y = $p.y + [int](($p.h - $h) / 2)
                    $g.DrawImage($p.img, (New-Object Drawing.Rectangle $x, $y, $w, $h))
                }
                $c.Save((Join-Path $out $Name), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $g.Dispose(); $c.Dispose() }
        }
        # Medidas recomendadas por Steam: portada 600x900, cabecera 920x430, fondo 1920x620, logo 1280x720 como máximo.
        & $compose 600 900 @(@{ img = $logo; x = 30; y = 30; w = 540; h = 140 }, @{ img = $pic; x = 20; y = 190; w = 560; h = 690 }) 'portrait.png'
        & $compose 920 430 @(@{ img = $logo; x = 30; y = 20; w = 520; h = 390 }, @{ img = $pic; x = 560; y = 10; w = 340; h = 410 }) 'header.png'
        & $compose 1920 620 @(@{ img = $pic; x = 1260; y = 10; w = 560; h = 600 }) 'hero.png'
        & $compose 900 230 @(@{ img = $logo; x = 0; y = 0; w = 900; h = 230 }) 'logo.png' $true
        $logo.Dispose(); $pic.Dispose()
    } finally { $img.Dispose() }
    Write-CpLog Info "Artwork de Steam generado en $out"
    $out
}

function Install-CpSteamArt {
    <# Copia el artwork de cada juego a userdata\<id>\config\grid con los nombres que espera Steam. No requiere cerrar Steam. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Wanted)
    foreach ($w in @($Wanted)) {
        $id = $script:LastArtIds[$w.appid]
        if (-not $id) { continue }
        $dir = $null
        try { $dir = New-CpArtImages -Id $id -Root $Root } catch { Write-CpLog Warn "No se pudo generar el artwork de ${id}: $_" }
        if (-not $dir) { continue }
        $appid = [uint32]([int64]$w.appid -band 0xFFFFFFFFL)
        foreach ($cfg in @(Get-CpSteamUserConfigDirs)) {
            $grid = Join-Path $cfg 'grid'
            New-Item -ItemType Directory -Force -Path $grid | Out-Null
            foreach ($pair in @(@('portrait.png', "${appid}p.png"), @('header.png', "$appid.png"), @('hero.png', "${appid}_hero.png"), @('logo.png', "${appid}_logo.png"))) {
                Copy-Item -LiteralPath (Join-Path $dir $pair[0]) -Destination (Join-Path $grid $pair[1]) -Force
            }
        }
    }
}

function Add-CpToSteam {
    <# Escribe los accesos en todos los usuarios de Steam. Steam tiene que estar cerrado. Devuelve los archivos. #>
    param([Parameter(Mandatory)][string]$Root)
    $dirs = @(Get-CpSteamUserConfigDirs)
    if (-not $dirs.Count) { throw (New-CpError '3DM-STM-001') }
    $wanted = @(Get-CpWantedSteamShortcuts -Root $Root)
    $written = @()
    foreach ($d in $dirs) {
        $path = Join-Path $d 'shortcuts.vdf'
        try {
            [void](Update-CpSteamShortcutsFile -Path $path -Wanted @($wanted | ForEach-Object { $c = [ordered]@{}; foreach ($k in $_.Keys) { $c[$k] = $_[$k] }; $c }))
        } catch {
            Remove-Item -LiteralPath "$path.tmp" -Force -ErrorAction SilentlyContinue
            throw (New-CpError '3DM-STM-003' @{ file = $path; detail = $_.Exception.Message } $_.Exception)
        }
        Write-CpLog Info "Accesos de Steam actualizados en $path ($($wanted.Count))"
        $written += $path
    }
    try { Install-CpSteamArt -Root $Root -Wanted $wanted } catch { Write-CpLog Warn "No se pudo copiar el artwork de Steam: $_" }
    $written
}

function Update-CpSteamShortcuts {
    <#
      Tras instalar o desinstalar: actualiza los accesos solo donde ya se habían agregado y solo si Steam está
      cerrado (si está abierto, al cerrarse pisaría el archivo). Devuelve $true si no quedó nada pendiente.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $targets = @(foreach ($d in @(Get-CpSteamUserConfigDirs)) {
        $p = Join-Path $d 'shortcuts.vdf'
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $doc = ConvertFrom-CpVdf ([IO.File]::ReadAllBytes($p))
            if ($doc.Contains('shortcuts') -and @($doc['shortcuts'].Values | Where-Object { Test-CpOurShortcut $_ }).Count) { $p }
        } catch { Write-CpLog Warn "shortcuts.vdf ilegible ($p): $_" }
    })
    if (-not $targets.Count) { return $true }
    if (Test-CpSteamRunning) { return $false }
    $wanted = @(Get-CpWantedSteamShortcuts -Root $Root)
    foreach ($p in $targets) {
        try { [void](Update-CpSteamShortcutsFile -Path $p -Wanted $wanted); Write-CpLog Info "Accesos de Steam actualizados en $p" }
        catch { Write-CpLog Warn "No se pudieron actualizar los accesos de Steam en ${p}: $_"; return $false }
    }
    $true
}

Export-ModuleMember -Function New-CpArtImages, Install-CpSteamArt, Update-CpSteamShortcuts, ConvertFrom-CpVdf, ConvertTo-CpVdf, Get-CpShortcutAppId, Get-CpSteamRoot, Get-CpSteamUserConfigDirs, Test-CpSteamInstalled,
    Test-CpSteamRunning, Stop-CpSteam, Start-CpSteam, Get-CpWantedSteamShortcuts, Update-CpSteamShortcutsFile, Add-CpToSteam
