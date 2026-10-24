# CreadorPeliculas.Sync.psm1 — sincronización de partidas entre equipos (Windows, Linux y Steam Deck).
# Compatible con Windows PowerShell 5.1. Refleja linux/creador/sync.py: mismo formato de paquete,
# mismas reglas de validación (data\sync.json) y mismas decisiones.
#
#   Paquete:  <ID>.zip con los archivos de partida sueltos + creador-saves.json (format 2)
#   Destino:  modo 'folder': <carpeta>\CreadorPeliculas-sync\<ID>.zip
#             modo 'drive':  appDataFolder de Google Drive (carpeta privada de la app)
#   Regla:    gana siempre la partida más reciente (fecha de modificación de sus archivos);
#             la que pierde queda como copia en «Creador de Películas 3D - copias».

Set-StrictMode -Version 2.0

$script:SrcRoot = Split-Path -Parent $PSScriptRoot
$script:ConfigDir = Join-Path $env:LOCALAPPDATA 'CreadorPeliculas'
$script:StateFile = Join-Path $script:ConfigDir 'sync-state.json'
$script:TokenFile = Join-Path $script:ConfigDir 'sync-token.json'
$script:ClientFile = Join-Path $script:ConfigDir 'google-client.json'
$script:GoogleConsoleUrl = 'https://console.cloud.google.com/apis/library/drive.googleapis.com'
$script:DriveScope = 'https://www.googleapis.com/auth/drive.appdata'
$script:Settings = $null
$script:Format = 2
$script:NoHash = '0' * 64
$script:Epoch = '1970-01-01T00:00:00Z'
$script:IsoFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
$script:IsoRegex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
$script:HashRegex = '^[0-9a-f]{64}$'
$script:IniLine = '^\s*(\[[^\]]*\]|[;#].*|[^=\[]+=.*)?\s*$'

Add-Type -AssemblyName System.IO.Compression, System.Web.Extensions, System.Security, System.Net.Http

# ---------------------------------------------------------------------------
# Datos, configuración y estado local
# ---------------------------------------------------------------------------

function ConvertTo-CpStrictValue {
    # Dictionary -> Hashtable que distingue mayúsculas (tiene Contains y ContainsKey); object[] se conserva.
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $h = New-Object Collections.Hashtable([StringComparer]::Ordinal)
        foreach ($k in $Value.Keys) { $h[$k] = ConvertTo-CpStrictValue $Value[$k] }
        return $h
    }
    if ($Value -is [Array]) {
        $list = New-Object object[] $Value.Length
        for ($i = 0; $i -lt $Value.Length; $i++) { $list[$i] = ConvertTo-CpStrictValue $Value[$i] }
        return , $list
    }
    $Value
}

function ConvertTo-CpPlain {
    # Copia sin envoltorios PSObject (JavaScriptSerializer no los entiende: los serializa como objetos circulares).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [psobject]) { $Value = $Value.psobject.BaseObject }
    if ($Value -is [Collections.IDictionary]) {
        $d = New-Object 'Collections.Generic.Dictionary[string,object]'
        foreach ($k in $Value.Keys) { $d.Add([string]$k, (ConvertTo-CpPlain $Value[$k])) }
        return , $d
    }
    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string])) {
        $l = New-Object 'Collections.Generic.List[object]'
        foreach ($x in $Value) { $l.Add((ConvertTo-CpPlain $x)) }
        return , $l.ToArray()
    }
    $Value
}

function ConvertTo-CpJsonText {
    param($Value)
    (New-Object System.Web.Script.Serialization.JavaScriptSerializer).Serialize((ConvertTo-CpPlain $Value))
}

function ConvertFrom-CpJsonStrict {
    <# JSON a Hashtable/object[] sin conversiones de fechas ni de mayúsculas (para validar con exactitud). #>
    param([string]$Text)
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = 16MB
    , (ConvertTo-CpStrictValue $js.DeserializeObject($Text))
}

function Get-CpSyncSettings {
    if (-not $script:Settings) { $script:Settings = ConvertFrom-CpJsonStrict ([IO.File]::ReadAllText((Join-Path $script:SrcRoot 'data\sync.json'), [Text.Encoding]::UTF8)) }
    $script:Settings
}

function Get-CpSyncLimits { (Get-CpSyncSettings)['limits'] }

function Get-CpGoogleSettings {
    <# Cliente OAuth: variables de entorno > google-client.json del equipo (lo carga «Cómo habilitarlo…») > sync.json. #>
    $g = @{}
    $src = (Get-CpSyncSettings)['google']
    foreach ($k in $src.Keys) { $g[$k] = $src[$k] }
    if (Test-Path -LiteralPath $script:ClientFile) {
        try {
            $local = ConvertFrom-CpJsonStrict ([IO.File]::ReadAllText($script:ClientFile, [Text.Encoding]::UTF8))
            if ($local -is [Collections.IDictionary]) {
                if ($local['clientId']) { $g.clientId = [string]$local['clientId'] }
                if ($local['clientSecret']) { $g.clientSecret = [string]$local['clientSecret'] }
            }
        } catch { Write-CpLog Warn "google-client.json ilegible: $_" }
    }
    if ($env:CP3D_GOOGLE_CLIENT_ID) { $g.clientId = $env:CP3D_GOOGLE_CLIENT_ID }
    if ($env:CP3D_GOOGLE_CLIENT_SECRET) { $g.clientSecret = $env:CP3D_GOOGLE_CLIENT_SECRET }
    $g
}

function Save-CpGoogleClient {
    <# Guarda el cliente OAuth pegado en la interfaz. Devuelve un mensaje si los datos no parecen válidos, o $null. #>
    param([string]$ClientId, [string]$ClientSecret)
    $ClientId = ([string]$ClientId).Trim(); $ClientSecret = ([string]$ClientSecret).Trim()
    if ($ClientId -cnotmatch '^[0-9]+-[0-9a-z]+\.apps\.googleusercontent\.com$') { return 'El ID de cliente tiene que terminar en «.apps.googleusercontent.com».' }
    if ($ClientSecret -cnotmatch '^[A-Za-z0-9_-]{10,100}$') { return 'Pegá el secreto del cliente completo (por ejemplo, «GOCSPX-…»).' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:ClientFile) | Out-Null
    $tmp = "$($script:ClientFile).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-CpJsonText @{ clientId = $ClientId; clientSecret = $ClientSecret }), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $script:ClientFile -Force
    Write-CpLog Info 'Cliente OAuth de Google configurado en este equipo'
    $null
}

function Get-CpGoogleHelpInfo { @{ ConsoleUrl = $script:GoogleConsoleUrl; Scope = $script:DriveScope } }

function Test-CpDriveAvailable { [bool](Get-CpGoogleSettings).clientId }

function Get-CpSyncConfig {
    <# La sección 'sync' de config.json, completa (genera el identificador del equipo la primera vez). #>
    param([Parameter(Mandatory)]$Config)
    $s = $null
    if ($Config.Contains('sync') -and $Config['sync'] -is [Collections.IDictionary]) { $s = $Config['sync'] }
    if (-not $s) { $s = [ordered]@{} }
    foreach ($k in 'mode', 'folder', 'deviceId', 'deviceName') { if (-not $s.Contains($k)) { $s[$k] = $null } }
    if ($s.mode -notin 'off', 'folder', 'drive') { $s.mode = 'off' }
    if (-not $s.deviceId) { $s.deviceId = [guid]::NewGuid().ToString('N') }
    if (-not $s.deviceName) { $s.deviceName = ([string]$env:COMPUTERNAME).Substring(0, [Math]::Min(64, ([string]$env:COMPUTERNAME).Length)) }
    if (-not $s.deviceName) { $s.deviceName = 'equipo' }
    $Config['sync'] = $s
    $s
}

function Get-CpSuggestedSyncFolder {
    <#
      Carpeta para proponer en «Carpeta sincronizada»: la de un programa de sincronización instalado
      (Google Drive para escritorio, OneDrive, Dropbox) o, si no hay, la carpeta de partidas de Windows.
      Devuelve @{ Path; Source }.
    #>
    $candidates = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if (-not $d.IsReady) { continue } } catch { continue }
        foreach ($n in 'Mi unidad', 'My Drive') { $candidates += @{ Path = (Join-Path $d.RootDirectory.FullName $n); Source = 'Google Drive para escritorio' } }
    }
    foreach ($n in 'Mi unidad', 'My Drive', '') { $candidates += @{ Path = (Join-Path (Join-Path $env:USERPROFILE 'Google Drive') $n); Source = 'Google Drive para escritorio' } }
    if ($env:OneDrive) { $candidates += @{ Path = $env:OneDrive; Source = 'OneDrive' } }
    $candidates += @{ Path = (Join-Path $env:USERPROFILE 'Dropbox'); Source = 'Dropbox' }
    foreach ($c in $candidates) {
        if ($c.Path -and (Test-Path -LiteralPath $c.Path -PathType Container)) { return @{ Path = $c.Path.TrimEnd('\'); Source = $c.Source } }
    }
    @{ Path = (Get-CpSavesFolder); Source = '' }
}

function Test-CpSyncEnabled {
    param($Config)
    $Config -and $Config.Contains('sync') -and $Config['sync'] -is [Collections.IDictionary] -and $Config['sync'].mode -in 'folder', 'drive'
}

function Get-CpSyncState {
    $st = $null
    if (Test-Path -LiteralPath $script:StateFile) {
        try { $st = ConvertFrom-CpJsonStrict ([IO.File]::ReadAllText($script:StateFile, [Text.Encoding]::UTF8)) } catch { Write-CpLog Warn "sync-state.json ilegible: $_" }
    }
    $out = @{}
    if ($st -is [Collections.IDictionary]) { foreach ($k in $st.Keys) { if ($st[$k] -is [Collections.IDictionary]) { $out[$k] = $st[$k] } } }
    $out
}

function Save-CpSyncState {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:StateFile) | Out-Null
    $tmp = "$($script:StateFile).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-CpJsonText $State), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $script:StateFile -Force
}

function Set-CpSyncSynced {
    param([string]$Id, [string]$Hash, [string]$UpdatedAt, [string]$Device)
    $st = Get-CpSyncState
    $st[$Id] = @{ lastSyncedHash = $Hash; lastSyncedUpdatedAt = $UpdatedAt; lastSyncAt = (Get-CpSyncNow); pendingUpload = $false; lastDevice = $Device }
    Save-CpSyncState $st
}

function Set-CpSyncPending {
    param([string]$Id, [bool]$Pending = $true)
    $st = Get-CpSyncState
    if (-not $st.ContainsKey($Id)) { $st[$Id] = @{} }
    $st[$Id]['pendingUpload'] = $Pending
    Save-CpSyncState $st
}

# ---------------------------------------------------------------------------
# Fechas y hash
# ---------------------------------------------------------------------------

function Get-CpSyncNow { [DateTime]::UtcNow.ToString($script:IsoFormat, [Globalization.CultureInfo]::InvariantCulture) }

function ConvertTo-CpSyncIso { param([DateTime]$Utc) $Utc.ToString($script:IsoFormat, [Globalization.CultureInfo]::InvariantCulture) }

function ConvertFrom-CpSyncIso {
    param([string]$Text)
    [DateTime]::ParseExact($Text, $script:IsoFormat, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
}

function Format-CpSyncDate {
    <# Fecha ISO (UTC) en hora local legible. #>
    param([string]$Iso)
    if (-not $Iso) { return '—' }
    (ConvertFrom-CpSyncIso $Iso).ToLocalTime().ToString('dd/MM/yyyy HH:mm')
}

function Get-CpSha256 {
    param([byte[]]$Bytes)
    $h = [Security.Cryptography.SHA256]::Create()
    try { -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}

function Get-CpBundleHash {
    <# Hash del conjunto de archivos (sin distinguir mayúsculas en los nombres; igual en Linux). #>
    param($Files)
    [string[]]$lines = @($Files | ForEach-Object { '{0}:{1}' -f ([string]$_['name']).ToLowerInvariant(), ([string]$_['sha256']).ToLowerInvariant() })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    Get-CpSha256 ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
}

# ---------------------------------------------------------------------------
# Partidas locales
# ---------------------------------------------------------------------------

function Test-CpSyncName {
    <# ¿Es un archivo de partida que se sincroniza? (las partidas menos los INI de configuración de cada equipo). #>
    param([Parameter(Mandatory)]$Game, [string]$Name)
    if (-not (Test-CpSaveName $Game $Name)) { return $false }
    $exclude = @()
    if ($Game.PSObject.Properties.Name -contains 'syncExclude') { $exclude = @($Game.syncExclude) }
    -not ($exclude | Where-Object { $_ -ieq $Name })
}

function Test-CpSaveMagic {
    <# Si el juego declara "saveMagic" (hex), cada archivo tiene que empezar con alguna de esas firmas (lista blanca). #>
    param([Parameter(Mandatory)]$Game, [byte[]]$Data)
    $magic = @(Get-CpOptional $Game 'saveMagic')
    if (-not $magic.Count) { return $true }
    foreach ($hex in $magic) {
        $n = $hex.Length / 2
        if ($Data.Length -lt $n) { continue }
        $ok = $true
        for ($i = 0; $i -lt $n; $i++) { if ($Data[$i] -ne [Convert]::ToByte($hex.Substring(2 * $i, 2), 16)) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    $false
}

function Get-CpSyncFiles {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    $game = Get-CpGame $Id
    @(Get-CpSaveFiles -Id $Id -Root $Root | Where-Object { Test-CpSyncName $game $_.Name })
}

function Get-CpSyncLocalInfo {
    <# Descripción de las partidas locales: @{ files; bundleHash; updatedAt } o $null si no hay. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    $files = @(foreach ($f in Get-CpSyncFiles -Id $Id -Root $Root) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        [ordered]@{ name = $f.Name; size = $bytes.Length; sha256 = (Get-CpSha256 $bytes); mtime = (ConvertTo-CpSyncIso $f.LastWriteTimeUtc); path = $f.FullName }
    })
    if (-not $files.Count) { return $null }
    [string[]]$times = @($files | ForEach-Object { $_.mtime })
    [Array]::Sort($times, [StringComparer]::Ordinal)
    @{ files = $files; bundleHash = (Get-CpBundleHash $files); updatedAt = $times[$times.Count - 1] }
}

function New-CpSyncBundle {
    <# Arma el paquete con las partidas locales. Devuelve @{ Data = byte[]; Manifest }. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Info)
    if (-not $Info) { $Info = Get-CpSyncLocalInfo -Id $Id -Root $Root }
    $s = Get-CpSyncConfig $Config
    $manifest = [ordered]@{
        format = $script:Format; createdAt = (Get-CpSyncNow); platform = 'windows'; games = @($Id); gameId = $Id
        updatedAt = $Info.updatedAt; deviceId = $s.deviceId; deviceName = $s.deviceName; bundleHash = $Info.bundleHash
        files = @($Info.files | ForEach-Object { [ordered]@{ name = $_.name; size = $_.size; sha256 = $_.sha256; mtime = $_.mtime } })
    }
    $ms = New-Object IO.MemoryStream
    $archive = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $w = New-Object IO.StreamWriter($archive.CreateEntry('creador-saves.json').Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write((ConvertTo-CpJsonText $manifest)) } finally { $w.Dispose() }
        foreach ($f in $Info.files) {
            $bytes = [IO.File]::ReadAllBytes($f.path)
            $s2 = $archive.CreateEntry($f.name, [IO.Compression.CompressionLevel]::Optimal).Open()
            try { $s2.Write($bytes, 0, $bytes.Length) } finally { $s2.Dispose() }
        }
    } finally { $archive.Dispose() }
    @{ Data = $ms.ToArray(); Manifest = $manifest }
}

# ---------------------------------------------------------------------------
# Validación de lo descargado (la carpeta o la cuenta pueden tener contenido ajeno)
# ---------------------------------------------------------------------------

function Stop-CpSyncRejected {
    param([string]$Id, [string]$Reason)
    throw (New-CpError '3DM-SYN-005' @{ game = (Get-CpGame $Id).name; reason = $Reason })
}

function Test-CpExecutableBytes {
    param([byte[]]$Data)
    if ($Data.Length -ge 0x40 -and $Data[0] -eq 0x4D -and $Data[1] -eq 0x5A) {
        $off = [BitConverter]::ToUInt32($Data, 0x3C)
        if ($off -gt 0 -and $off -le $Data.Length - 2) {
            $sig = [Text.Encoding]::ASCII.GetString($Data, [int]$off, 2)
            if ($sig -in 'PE', 'NE', 'LE', 'LX') { return $true }
        }
    }
    foreach ($hex in (Get-CpSyncSettings)['forbiddenMagic']) {
        $n = $hex.Length / 2
        if ($Data.Length -lt $n) { continue }
        $match = $true
        for ($i = 0; $i -lt $n; $i++) { if ($Data[$i] -ne [Convert]::ToByte($hex.Substring(2 * $i, 2), 16)) { $match = $false; break } }
        if ($match) { return $true }
    }
    $false
}

function Test-CpIniBytes {
    <# Texto INI: sin bytes de control (salvo tab/CR/LF), líneas cortas, solo secciones, claves y comentarios. Devuelve el problema o $null. #>
    param([byte[]]$Data)
    $text = [Text.Encoding]::GetEncoding(28591).GetString($Data)
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return 'tiene bytes binarios' }
    $max = (Get-CpSyncLimits)['maxIniLine']
    foreach ($line in $text.Split("`n")) {
        $line = $line.TrimEnd("`r")
        if ($line.Length -gt $max) { return 'tiene una línea demasiado larga' }
        if ($line -notmatch $script:IniLine) { return 'tiene líneas que no son de un INI' }
    }
    $null
}

function Test-CpSyncString { param($Value, [int]$Max = 200) ($Value -is [string]) -and $Value.Length -gt 0 -and $Value.Length -le $Max }

function Test-CpSyncBundle {
    <#
      Controla un paquete descargado. Devuelve @{ Manifest; Contents = @{ nombre = byte[] } }. Ante cualquier
      problema lanza 3DM-SYN-005 con el motivo; nunca escribe nada en disco.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][byte[]]$Data, [string]$ExpectedHash)
    $lim = Get-CpSyncLimits
    $game = Get-CpGame $Id
    if ($Data.Length -gt $lim['maxZipBytes']) { Stop-CpSyncRejected $Id "el paquete pesa demasiado ($($Data.Length) bytes)" }
    try { $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $Data)), [IO.Compression.ZipArchiveMode]::Read) }
    catch { Stop-CpSyncRejected $Id "no es un zip válido ($($_.Exception.InnerException.Message))" }
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -gt $lim['maxEntries']) { Stop-CpSyncRejected $Id "tiene demasiados archivos ($($entries.Count))" }
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $byName = New-Object Collections.Hashtable([StringComparer]::Ordinal)
        foreach ($e in $entries) {
            $n = $e.FullName
            if (-not $n -or $n.EndsWith('/') -or $n.IndexOfAny([char[]]'/\:') -ge 0 -or $n -in '.', '..' -or $n -match '[\x00-\x1F\x7F]') {
                Stop-CpSyncRejected $Id ('tiene una ruta o un nombre no permitido («{0}»)' -f $n.Substring(0, [Math]::Min(80, $n.Length)))
            }
            if (-not $seen.Add($n)) { Stop-CpSyncRejected $Id "tiene archivos repetidos («$n»)" }
            $byName[$n] = $e
        }
        if (-not $byName.ContainsKey('creador-saves.json')) { Stop-CpSyncRejected $Id 'le falta el manifiesto creador-saves.json' }

        $readLimited = {
            param($Entry, [long]$Limit)
            if ($Entry.Length -gt $Limit) { Stop-CpSyncRejected $Id "«$($Entry.FullName)» pesa demasiado" }
            if ($Entry.Length -gt $lim['ratioMinBytes'] -and $Entry.Length -gt $lim['maxRatio'] * [Math]::Max(1, $Entry.CompressedLength)) {
                Stop-CpSyncRejected $Id "«$($Entry.FullName)» está comprimido de forma sospechosa"
            }
            $out = New-Object IO.MemoryStream
            try {
                $st = $Entry.Open()
                try {
                    $buf = New-Object byte[] 65536
                    while (($r = $st.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $r)
                        if ($out.Length -gt $Limit) { break }
                    }
                } finally { $st.Dispose() }
            } catch [CreadorException] { throw } catch { Stop-CpSyncRejected $Id "«$($Entry.FullName)» no se pudo leer ($($_.Exception.Message))" }
            if ($out.Length -gt $Limit) { Stop-CpSyncRejected $Id "«$($Entry.FullName)» pesa demasiado" }
            , $out.ToArray()
        }

        $meta = $null
        try { $meta = ConvertFrom-CpJsonStrict ([Text.Encoding]::UTF8.GetString((& $readLimited $byName['creador-saves.json'] $lim['maxManifestBytes'])).TrimStart([char]0xFEFF)) }
        catch [CreadorException] { throw } catch { Stop-CpSyncRejected $Id 'el manifiesto está dañado' }
        $keys = @('format', 'createdAt', 'platform', 'games', 'gameId', 'updatedAt', 'deviceId', 'deviceName', 'bundleHash', 'files')
        if (-not ($meta -is [Collections.IDictionary]) -or $meta.Count -ne $keys.Count -or @($keys | Where-Object { -not $meta.ContainsKey($_) }).Count) {
            Stop-CpSyncRejected $Id 'el manifiesto no tiene el formato esperado'
        }
        $games = $meta['games']
        if (-not ($meta['format'] -is [int]) -or $meta['format'] -ne $script:Format -or -not ($meta['gameId'] -is [string]) -or $meta['gameId'] -cne $Id -or
            -not ($games -is [Array]) -or $games.Count -ne 1 -or -not ($games[0] -is [string]) -or $games[0] -cne $Id) {
            Stop-CpSyncRejected $Id 'el paquete no es de este juego o es de otra versión'
        }
        if ($meta['platform'] -notin 'windows', 'linux' -or -not ($meta['platform'] -is [string]) -or -not (Test-CpSyncString $meta['deviceId'] 64) -or -not (Test-CpSyncString $meta['deviceName'] 64)) {
            Stop-CpSyncRejected $Id 'el manifiesto tiene datos del equipo inválidos'
        }
        foreach ($k in 'createdAt', 'updatedAt') {
            if (-not ($meta[$k] -is [string]) -or $meta[$k] -notmatch $script:IsoRegex) { Stop-CpSyncRejected $Id 'el manifiesto tiene fechas inválidas' }
        }
        if ((ConvertFrom-CpSyncIso $meta['updatedAt']) -gt [DateTime]::UtcNow.AddSeconds($lim['futureToleranceSeconds'])) {
            Stop-CpSyncRejected $Id "la partida tiene fecha en el futuro ($($meta['updatedAt']))"
        }
        if (-not ($meta['bundleHash'] -is [string]) -or $meta['bundleHash'] -cnotmatch $script:HashRegex) { Stop-CpSyncRejected $Id 'el manifiesto tiene un hash inválido' }
        $filesMeta = $meta['files']
        if (-not ($filesMeta -is [Array]) -or $filesMeta.Count -eq 0) { Stop-CpSyncRejected $Id 'el manifiesto no lista archivos' }
        $listed = [ordered]@{}
        $listedSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $filesMeta) {
            if (-not ($f -is [Collections.IDictionary]) -or $f.Count -ne 4 -or @('name', 'size', 'sha256', 'mtime' | Where-Object { -not $f.ContainsKey($_) }).Count) {
                Stop-CpSyncRejected $Id 'el manifiesto lista archivos con formato inválido'
            }
            $name = $f['name']
            if (-not ($name -is [string]) -or -not (Test-CpSyncName $game $name)) { Stop-CpSyncRejected $Id ('«{0}» no es un archivo de partida de este juego' -f ([string]$name).Substring(0, [Math]::Min(80, ([string]$name).Length))) }
            if (-not $listedSet.Add($name)) { Stop-CpSyncRejected $Id "el manifiesto repite «$name»" }
            if (-not ($f['size'] -is [int]) -or $f['size'] -lt 0 -or $f['size'] -gt $lim['maxFileBytes']) { Stop-CpSyncRejected $Id "«$name» tiene un tamaño inválido" }
            if (-not ($f['sha256'] -is [string]) -or $f['sha256'] -cnotmatch $script:HashRegex) { Stop-CpSyncRejected $Id "«$name» tiene un hash inválido" }
            if (-not ($f['mtime'] -is [string]) -or $f['mtime'] -notmatch $script:IsoRegex -or [string]::CompareOrdinal($f['mtime'], $meta['updatedAt']) -gt 0) {
                Stop-CpSyncRejected $Id "«$name» tiene una fecha inválida"
            }
            $listed[$name] = $f
        }
        $zipNames = @($byName.Keys | Where-Object { $_ -cne 'creador-saves.json' })
        if ($zipNames.Count -ne $listed.Count -or @($listed.Keys | Where-Object { -not $byName.ContainsKey($_) }).Count) {
            Stop-CpSyncRejected $Id 'los archivos del zip no coinciden con el manifiesto'
        }
        if ((Get-CpBundleHash $filesMeta) -cne $meta['bundleHash'] -or ($ExpectedHash -and $ExpectedHash -cne $meta['bundleHash'])) {
            Stop-CpSyncRejected $Id 'el hash del paquete no coincide'
        }
        $total = 0L
        $contents = [ordered]@{}
        foreach ($name in $listed.Keys) {
            $f = $listed[$name]
            [byte[]]$body = & $readLimited $byName[$name] $lim['maxFileBytes']
            $total += $body.Length
            if ($total -gt $lim['maxTotalBytes']) { Stop-CpSyncRejected $Id 'el paquete descomprimido pesa demasiado' }
            if ($body.Length -ne $f['size'] -or (Get-CpSha256 $body) -cne $f['sha256']) { Stop-CpSyncRejected $Id "«$name» está dañado o fue modificado" }
            if (Test-CpExecutableBytes $body) { Stop-CpSyncRejected $Id "«$name» contiene un programa o un archivo comprimido" }
            if (-not (Test-CpSaveMagic $game $body)) { Stop-CpSyncRejected $Id "«$name» no es una película válida" }
            if ($name -like '*.ini') {
                $why = Test-CpIniBytes $body
                if ($why) { Stop-CpSyncRejected $Id "«$name» $why" }
            }
            $contents[$name] = $body
        }
    } finally { $archive.Dispose() }
    @{ Manifest = $meta; Contents = $contents }
}

function Install-CpSyncBundle {
    <# Reemplaza las partidas locales por las descargadas (ya validadas). Antes guarda una copia. Devuelve la copia o $null. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Bundle)
    if (Get-CpRunningGame -Root $Root) { throw (New-CpError '3DM-RUN-001') }
    $hd = Get-CpSavesDir -Id $Id -Root $Root
    if (-not (Test-Path -LiteralPath $hd)) { New-Item -ItemType Directory -Force -Path $hd | Out-Null }
    $mtimes = @{}
    foreach ($f in $Bundle.Manifest['files']) { $mtimes[$f['name']] = ConvertFrom-CpSyncIso $f['mtime'] }
    try {
        $backup = Backup-CpSaves -Id $Id -Root $Root
        foreach ($f in @(Get-CpSyncFiles -Id $Id -Root $Root)) { $f.IsReadOnly = $false; Remove-Item -LiteralPath $f.FullName -Force }
        foreach ($name in $Bundle.Contents.Keys) {
            $tmp = Join-Path $hd ".$name.sync.tmp"
            [IO.File]::WriteAllBytes($tmp, $Bundle.Contents[$name])
            (Get-Item -LiteralPath $tmp).LastWriteTimeUtc = $mtimes[$name]
            Move-Item -LiteralPath $tmp -Destination (Join-Path $hd $name) -Force
        }
        Write-CpLog Info ("Partida de {0} descargada ({1}, de «{2}»)" -f $Id, $Bundle.Manifest['updatedAt'], $Bundle.Manifest['deviceName'])
        $backup
    } catch {
        if ($_.Exception -is [CreadorException]) { throw }
        Write-CpLog Error "No se pudo aplicar la partida de ${Id}: $_"
        throw (New-CpError '3DM-SYN-007' @{ game = (Get-CpGame $Id).name; detail = $_.Exception.Message } $_.Exception)
    }
}

# ---------------------------------------------------------------------------
# Destinos: carpeta común o Google Drive
# ---------------------------------------------------------------------------

function New-CpRemoteInfo {
    param([string]$Hash, [string]$UpdatedAt, [string]$DeviceName, [string]$Ref, $ErrorObject)
    @{ bundleHash = $Hash; updatedAt = $UpdatedAt; deviceName = $DeviceName; ref = $Ref; error = $ErrorObject }
}

function New-CpFolderBackend {
    <# Una carpeta común (Google Drive para escritorio, OneDrive, Dropbox, Syncthing, pendrive, red). #>
    param([string]$Folder)
    @{ kind = 'folder'; folder = $Folder; dir = (Join-Path ([string]$Folder) (Get-CpSyncSettings)['folderName']); cache = @{} }
}

function Stop-CpFolderFailure {
    param($Backend, [string]$Id, [string]$Op, $Exception)
    $game = $(if ($Id) { (Get-CpGame $Id).name } else { 'los juegos' })
    throw (New-CpError '3DM-SYN-002' @{ game = $game; op = $Op; path = $Backend.folder; detail = $Exception.Message } $Exception)
}

function New-CpDriveBackend {
    <# Google Drive, en la carpeta privada de la app (appDataFolder). $Transport sirve para las pruebas. #>
    param([string]$TokenPath = $script:TokenFile, [scriptblock]$Transport = $null, [hashtable]$Conf = $null)
    if (-not $Conf) { $Conf = Get-CpGoogleSettings }
    if (-not $Transport) { $Transport = ${function:Invoke-CpHttp} }
    @{ kind = 'drive'; conf = $Conf; tokenPath = $TokenPath; transport = $Transport; access = $null; accessUntil = [DateTime]::MinValue }
}

function Get-CpSyncBackend {
    <# El destino configurado, o $null si la sincronización está desactivada. #>
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-CpSyncEnabled $Config)) { return $null }
    $s = $Config['sync']
    if ($s.mode -eq 'folder') { return New-CpFolderBackend -Folder $s.folder }
    New-CpDriveBackend
}

function Invoke-CpHttp {
    <# Transporte HTTP real (TLS 1.2). Devuelve @{ Status; Body }. Lanza una excepción si no hubo respuesta. #>
    param([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body, [int]$Timeout = 15)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    try {
        $req = New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod($Method)), $Url)
        $ctype = $null
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                if ($k -ieq 'Content-Type') { $ctype = $Headers[$k] } else { [void]$req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
            }
        }
        if ($null -ne $Body) {
            $req.Content = New-Object Net.Http.ByteArrayContent(, $Body)
            if ($ctype) { [void]$req.Content.Headers.Remove('Content-Type'); [void]$req.Content.Headers.TryAddWithoutValidation('Content-Type', $ctype) }
        }
        try { $resp = $client.SendAsync($req).GetAwaiter().GetResult() }
        catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            if ($_.Exception -is [Threading.Tasks.TaskCanceledException]) { throw (New-Object Net.Http.HttpRequestException("no hubo respuesta en $Timeout segundos")) }
            throw (New-Object Net.Http.HttpRequestException($e.Message))
        }
        try { @{ Status = [int]$resp.StatusCode; Body = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() } }
        finally { $resp.Dispose() }
    } finally { $client.Dispose() }
}

function ConvertFrom-CpHttpJson {
    param($Response)
    try {
        $o = ConvertFrom-CpJsonStrict ([Text.Encoding]::UTF8.GetString($Response.Body))
        if ($o -is [Collections.IDictionary]) { return $o }
    } catch { }
    @{}
}

function Invoke-CpDriveTransport {
    param($Backend, [string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body, [string]$GameName)
    try { & $Backend.transport $Method $Url $Headers $Body ([int]$Backend.conf.timeoutSeconds) }
    catch {
        if ($_.Exception -is [CreadorException]) { throw }
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        throw (New-CpError '3DM-SYN-001' @{ game = $GameName; detail = $e.Message } $_.Exception)
    }
}

function Invoke-CpDriveForm {
    param($Backend, [string]$Path, [hashtable]$Fields)
    $body = ($Fields.Keys | ForEach-Object { '{0}={1}' -f [Uri]::EscapeDataString($_), [Uri]::EscapeDataString([string]$Fields[$_]) }) -join '&'
    Invoke-CpDriveTransport $Backend 'POST' ($Backend.conf.authBase + $Path) @{ 'Content-Type' = 'application/x-www-form-urlencoded' } ([Text.Encoding]::ASCII.GetBytes($body)) 'los juegos'
}

function Read-CpDriveToken {
    param($Backend)
    if (-not (Test-Path -LiteralPath $Backend.tokenPath)) { return $null }
    try {
        $wrap = ConvertFrom-CpJsonStrict ([IO.File]::ReadAllText($Backend.tokenPath, [Text.Encoding]::UTF8))
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($wrap['protected']), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $t = ConvertFrom-CpJsonStrict ([Text.Encoding]::UTF8.GetString($plain))
        if ($t -is [Collections.IDictionary] -and $t['refresh_token']) { return $t }
    } catch { Write-CpLog Warn "No se pudo leer el token de Google: $_" }
    $null
}

function Save-CpDriveToken {
    <# Guarda el token cifrado con DPAPI: solo lo puede leer este usuario de Windows en este equipo. #>
    param($Backend, [hashtable]$Token)
    $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes((ConvertTo-CpJsonText $Token)), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Backend.tokenPath) | Out-Null
    $tmp = "$($Backend.tokenPath).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-CpJsonText @{ protected = [Convert]::ToBase64String($enc) }), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Backend.tokenPath -Force
}

function Get-CpDriveEmail {
    <# Correo de la cuenta vinculada ('tu cuenta' si no se conoce) o $null si no hay ninguna. #>
    param($Backend)
    $t = Read-CpDriveToken $Backend
    if (-not $t) { return $null }
    if ($t['email']) { $t['email'] } else { 'tu cuenta' }
}

function Get-CpEmailFromIdToken {
    param([string]$IdToken)
    try {
        $part = $IdToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $part += '=' * ((4 - $part.Length % 4) % 4)
        (ConvertFrom-CpJsonStrict ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part))))['email']
    } catch { $null }
}

function Start-CpDriveLink {
    <# Pide un código para vincular. Devuelve @{ device_code; user_code; verification_url; interval; expires_in }. #>
    param($Backend)
    if (-not $Backend.conf.clientId) { throw (New-CpError '3DM-SYN-008') }
    $r = Invoke-CpDriveForm $Backend '/device/code' @{ client_id = $Backend.conf.clientId; scope = $Backend.conf.scope }
    $d = ConvertFrom-CpHttpJson $r
    if ($r.Status -ne 200 -or -not $d.Contains('device_code')) {
        $msg = 'HTTP {0} {1}' -f $r.Status, $(if ($d.Contains('error_description')) { $d['error_description'] } elseif ($d.Contains('error')) { $d['error'] } else { '' })
        throw (New-CpError '3DM-SYN-006' @{ game = 'los juegos'; detail = $msg } (New-Object Exception($msg)))
    }
    $out = @{}; foreach ($k in $d.Keys) { $out[$k] = $d[$k] }
    if (-not $out.Contains('verification_url')) { $out.verification_url = $(if ($out.Contains('verification_uri')) { $out.verification_uri } else { 'https://www.google.com/device' }) }
    if (-not $out.Contains('interval')) { $out.interval = 5 }
    if (-not $out.Contains('expires_in')) { $out.expires_in = 900 }
    $out
}

function Get-CpDriveLinkResult {
    <# Un intento: devuelve 'pending', 'slow_down' o el correo vinculado (y guarda el token). #>
    param($Backend, [string]$DeviceCode)
    $r = Invoke-CpDriveForm $Backend '/token' @{ client_id = $Backend.conf.clientId; client_secret = $Backend.conf.clientSecret; device_code = $DeviceCode
        grant_type = 'urn:ietf:params:oauth:grant-type:device_code' }
    $d = ConvertFrom-CpHttpJson $r
    if ($r.Status -eq 200 -and $d.Contains('refresh_token')) {
        $email = $(if ($d.Contains('id_token')) { Get-CpEmailFromIdToken $d['id_token'] } else { $null })
        Save-CpDriveToken $Backend @{ refresh_token = $d['refresh_token']; email = [string]$email; linkedAt = (Get-CpSyncNow) }
        $Backend.access = $d['access_token']; $Backend.accessUntil = [DateTime]::UtcNow.AddSeconds([int]$d['expires_in'] - 60)
        if ($email) { return $email } else { return 'tu cuenta' }
    }
    $e = $(if ($d.Contains('error')) { [string]$d['error'] } else { '' })
    if ($e -eq 'authorization_pending') { return 'pending' }
    if ($e -eq 'slow_down') { return 'slow_down' }
    $msg = ('{0} {1}' -f $e, $(if ($d.Contains('error_description')) { $d['error_description'] } else { '' })).Trim()
    if ($e -in 'access_denied', 'expired_token') {
        throw (New-CpError '3DM-SYN-003' @{ detail = $(if ($e -eq 'expired_token') { 'no se autorizó el acceso a tiempo' } else { 'se rechazó el acceso' }) } (New-Object Exception($msg)))
    }
    if (-not $msg) { $msg = "HTTP $($r.Status)" }
    throw (New-CpError '3DM-SYN-006' @{ game = 'los juegos'; detail = $msg } (New-Object Exception($msg)))
}

function Remove-CpDriveLink {
    param($Backend)
    $t = Read-CpDriveToken $Backend
    Remove-Item -LiteralPath $Backend.tokenPath -Force -ErrorAction SilentlyContinue
    $Backend.access = $null
    if ($t) {
        try { [void](Invoke-CpDriveForm $Backend '/revoke' @{ token = $t['refresh_token'] }) } catch { Write-CpLog Warn "No se pudo revocar el token de Google: $_" }
    }
}

function Get-CpDriveAccessToken {
    param($Backend, [string]$GameName = 'los juegos')
    if ($Backend.access -and $Backend.accessUntil -gt [DateTime]::UtcNow) { return $Backend.access }
    if (-not $Backend.conf.clientId) { throw (New-CpError '3DM-SYN-008') }
    $t = Read-CpDriveToken $Backend
    if (-not $t) { throw (New-CpError '3DM-SYN-003' @{ detail = 'no hay una cuenta vinculada' }) }
    $r = Invoke-CpDriveForm $Backend '/token' @{ client_id = $Backend.conf.clientId; client_secret = $Backend.conf.clientSecret; refresh_token = $t['refresh_token']; grant_type = 'refresh_token' }
    $d = ConvertFrom-CpHttpJson $r
    if ($r.Status -eq 200 -and $d.Contains('access_token')) {
        $Backend.access = $d['access_token']
        $Backend.accessUntil = [DateTime]::UtcNow.AddSeconds($(if ($d.Contains('expires_in')) { [int]$d['expires_in'] } else { 3600 }) - 60)
        return $Backend.access
    }
    $e = $(if ($d.Contains('error')) { [string]$d['error'] } else { "HTTP $($r.Status)" })
    $msg = ('{0} {1}' -f $e, $(if ($d.Contains('error_description')) { $d['error_description'] } else { '' })).Trim()
    if ($e -in 'invalid_grant', 'unauthorized_client', 'invalid_client' -or $r.Status -in 400, 401) {
        throw (New-CpError '3DM-SYN-003' @{ detail = $msg } (New-Object Exception($msg)))
    }
    throw (New-CpError '3DM-SYN-006' @{ game = $GameName; detail = $msg } (New-Object Exception($msg)))
}

function Invoke-CpDriveApi {
    <# Petición a Drive con reintentos ante 429/5xx y renovación del token ante 401. Devuelve la respuesta 2xx. #>
    param($Backend, [string]$Method, [string]$Url, [string]$Id, [hashtable]$Headers = @{}, [byte[]]$Body = $null)
    $gameName = $(if ($Id) { (Get-CpGame $Id).name } else { 'los juegos' })
    $retries = [int]$Backend.conf.retries
    $delay = $(if ($Backend.conf.Contains('retryDelay')) { [double]$Backend.conf.retryDelay } else { 0.5 })
    $last = ''
    for ($attempt = 0; $attempt -le $retries; $attempt++) {
        $h = @{}; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
        $h['Authorization'] = 'Bearer ' + (Get-CpDriveAccessToken $Backend $gameName)
        $r = Invoke-CpDriveTransport $Backend $Method $Url $h $Body $gameName
        if ($r.Status -ge 200 -and $r.Status -lt 300) { return $r }
        $d = ConvertFrom-CpHttpJson $r
        $err = $(if ($d.Contains('error') -and $d['error'] -is [Collections.IDictionary]) { $d['error'] } else { @{} })
        $reason = -join @($(if ($err.Contains('errors')) { @($err['errors']) | Where-Object { $_ -is [Collections.IDictionary] -and $_.Contains('reason') } | ForEach-Object { $_['reason'] } }))
        $text = $(if ($err.Contains('message')) { [string]$err['message'] } else { [Text.Encoding]::UTF8.GetString($r.Body, 0, [Math]::Min(200, $r.Body.Length)) })
        $last = ('HTTP {0} {1}' -f $r.Status, $text).Trim()
        if ($r.Status -eq 401 -and $attempt -eq 0) { $Backend.access = $null; continue }
        if ($r.Status -eq 401) { throw (New-CpError '3DM-SYN-003' @{ detail = $last } (New-Object Exception($last))) }
        if ($r.Status -eq 403 -and $reason -like '*storageQuotaExceeded*') { throw (New-CpError '3DM-SYN-004' @{ game = $gameName } (New-Object Exception($last))) }
        if ($r.Status -eq 429 -or $r.Status -ge 500 -or ($r.Status -eq 403 -and $reason -like '*ateLimitExceeded*')) {
            Start-Sleep -Milliseconds ([int](1000 * [Math]::Min(8, $delay * [Math]::Pow(2, $attempt))))
            continue
        }
        throw (New-CpError '3DM-SYN-006' @{ game = $gameName; detail = $last } (New-Object Exception($last)))
    }
    throw (New-CpError '3DM-SYN-006' @{ game = $gameName; detail = $last } (New-Object Exception($last)))
}

function Get-CpDriveFiles {
    param($Backend, [string]$Id)
    $q = 'spaces=appDataFolder&pageSize=100&orderBy=' + [Uri]::EscapeDataString('modifiedTime desc') + '&fields=' + [Uri]::EscapeDataString('files(id,name,size,modifiedTime,appProperties)')
    $r = Invoke-CpDriveApi $Backend 'GET' ($Backend.conf.apiBase + '/drive/v3/files?' + $q) $Id
    $d = ConvertFrom-CpHttpJson $r
    @($(if ($d.Contains('files')) { @($d['files']) | Where-Object { $_ -is [Collections.IDictionary] } }))
}

function Test-CpSyncBackend {
    <# «Probar conexión»: lanza el error correspondiente si el destino no sirve. #>
    param([Parameter(Mandatory)]$Backend)
    if ($Backend.kind -eq 'drive') { [void](Get-CpDriveFiles $Backend $null); return }
    if (-not $Backend.folder -or -not (Test-Path -LiteralPath $Backend.folder -PathType Container)) {
        Stop-CpFolderFailure $Backend $null 'usar' (New-Object IO.DirectoryNotFoundException('la carpeta no existe'))
    }
    try {
        New-Item -ItemType Directory -Force -Path $Backend.dir -ErrorAction Stop | Out-Null
        $probe = Join-Path $Backend.dir ('.creador-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force
    } catch { Stop-CpFolderFailure $Backend $null 'escribir' $_.Exception }
}

function Get-CpRemoteMeta {
    <# Lo que hay del otro lado para un juego, o $null. 'error' tiene el 3DM-SYN-005 si el paquete no pasó la validación. #>
    param([Parameter(Mandatory)]$Backend, [Parameter(Mandatory)][string]$Id)
    if ($Backend.kind -eq 'folder') {
        if (-not $Backend.folder -or -not (Test-Path -LiteralPath $Backend.folder -PathType Container)) {
            Stop-CpFolderFailure $Backend $Id 'leer' (New-Object IO.DirectoryNotFoundException('la carpeta no existe'))
        }
        $p = Join-Path $Backend.dir "$Id.zip"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try {
            $fs = [IO.File]::OpenRead($p)
            try {
                $len = [int][Math]::Min($fs.Length, (Get-CpSyncLimits)['maxZipBytes'] + 1)
                $data = New-Object byte[] $len
                $read = 0; while ($read -lt $len -and ($n = $fs.Read($data, $read, $len - $read)) -gt 0) { $read += $n }
            } finally { $fs.Dispose() }
        } catch { Stop-CpFolderFailure $Backend $Id 'leer' $_.Exception }
        try { $b = Test-CpSyncBundle -Id $Id -Data $data }
        catch {
            if ($_.Exception -is [CreadorException] -and $_.Exception.Code -eq '3DM-SYN-005') { return (New-CpRemoteInfo $script:NoHash $script:Epoch '?' $null $_.Exception) }
            throw
        }
        $Backend.cache[$Id] = $data
        return (New-CpRemoteInfo $b.Manifest['bundleHash'] $b.Manifest['updatedAt'] $b.Manifest['deviceName'] $null $null)
    }
    $f = Get-CpDriveFiles $Backend $Id | Where-Object { $_['name'] -ceq "$Id.zip" } | Select-Object -First 1
    if (-not $f) { return $null }
    $p = $(if ($f.Contains('appProperties') -and $f['appProperties'] -is [Collections.IDictionary]) { $f['appProperties'] } else { @{} })
    $h = $(if ($p.Contains('bundleHash')) { [string]$p['bundleHash'] } else { '' })
    $u = $(if ($p.Contains('updatedAt')) { [string]$p['updatedAt'] } else { '' })
    if ($h -cnotmatch $script:HashRegex -or $u -notmatch $script:IsoRegex) { $h = $script:NoHash; $u = '9999-12-31T23:59:59Z' }   # sin metadatos: se decide después de validarlo
    New-CpRemoteInfo $h $u $(if ($p.Contains('deviceName')) { [string]$p['deviceName'] } else { '?' }) ([string]$f['id']) $null
}

function Receive-CpRemote {
    param([Parameter(Mandatory)]$Backend, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Remote)
    if ($Backend.kind -eq 'folder') {
        if ($Backend.cache.ContainsKey($Id)) { $d = $Backend.cache[$Id]; $Backend.cache.Remove($Id); return , $d }
        try { return , [IO.File]::ReadAllBytes((Join-Path $Backend.dir "$Id.zip")) } catch { Stop-CpFolderFailure $Backend $Id 'leer' $_.Exception }
    }
    $r = Invoke-CpDriveApi $Backend 'GET' ($Backend.conf.apiBase + '/drive/v3/files/' + [Uri]::EscapeDataString($Remote.ref) + '?alt=media') $Id
    , $r.Body
}

function Send-CpRemote {
    param([Parameter(Mandatory)]$Backend, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][byte[]]$Data, [Parameter(Mandatory)]$Manifest, $Remote)
    if ($Backend.kind -eq 'folder') {
        try {
            New-Item -ItemType Directory -Force -Path $Backend.dir -ErrorAction Stop | Out-Null
            $tmp = Join-Path $Backend.dir ".$Id.zip.tmp"
            [IO.File]::WriteAllBytes($tmp, $Data)
            Move-Item -LiteralPath $tmp -Destination (Join-Path $Backend.dir "$Id.zip") -Force -ErrorAction Stop
        } catch { Stop-CpFolderFailure $Backend $Id 'guardar' $_.Exception }
        return
    }
    $dn = [string]$Manifest.deviceName
    $meta = [ordered]@{ name = "$Id.zip"; appProperties = [ordered]@{ bundleHash = $Manifest.bundleHash; updatedAt = $Manifest.updatedAt; deviceName = $dn.Substring(0, [Math]::Min(60, $dn.Length)); gameId = $Id } }
    $hasRef = $Remote -and $Remote.ref
    if (-not $hasRef) { $meta.parents = @('appDataFolder') }
    $boundary = 'creador' + [guid]::NewGuid().ToString('N')
    $ms = New-Object IO.MemoryStream
    foreach ($chunk in @(
        [Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Type: application/json; charset=UTF-8`r`n`r`n"),
        [Text.Encoding]::UTF8.GetBytes((ConvertTo-CpJsonText $meta)),
        [Text.Encoding]::ASCII.GetBytes("`r`n--$boundary`r`nContent-Type: application/zip`r`n`r`n"),
        $Data,
        [Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n"))) { $ms.Write($chunk, 0, $chunk.Length) }
    $headers = @{ 'Content-Type' = "multipart/related; boundary=$boundary" }
    if ($hasRef) { [void](Invoke-CpDriveApi $Backend 'PATCH' ($Backend.conf.apiBase + '/upload/drive/v3/files/' + [Uri]::EscapeDataString($Remote.ref) + '?uploadType=multipart') $Id $headers $ms.ToArray()) }
    else { [void](Invoke-CpDriveApi $Backend 'POST' ($Backend.conf.apiBase + '/upload/drive/v3/files?uploadType=multipart') $Id $headers $ms.ToArray()) }
}

# ---------------------------------------------------------------------------
# Decisiones
# ---------------------------------------------------------------------------

function New-CpSyncResult {
    param([string]$Id, [string]$Action, [string]$Message, [string]$Backup = $null, [string]$Conflict = $null)
    [pscustomobject]@{ Id = $Id; Action = $Action; Message = $Message; Backup = $Backup; Conflict = $Conflict }
}

function Save-CpSyncConflict {
    <# Guarda en «Creador de Películas 3D - copias» la versión que va a perder (ya validada; es un zip importable). #>
    param([string]$Id, [byte[]]$Data, $Remote)
    $dest = Get-CpSavesFolder
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $device = ([string]$Remote.deviceName) -replace '[^A-Za-z0-9_-]+', '_'
    $device = $device.Substring(0, [Math]::Min(30, $device.Length)); if (-not $device) { $device = 'otro' }
    $path = Join-Path $dest ('{0}-conflicto-{1}-{2:yyyyMMdd-HHmmss}.zip' -f $Id, $device, (Get-Date))
    $base = $path.Substring(0, $path.Length - 4)
    for ($n = 2; Test-Path -LiteralPath $path; $n++) { $path = "$base-$n.zip" }
    [IO.File]::WriteAllBytes($path, $Data)
    Write-CpLog Info "Partida de $Id en conflicto guardada en $path"
    $path
}

function Sync-CpGame {
    <#
      Sincroniza un juego. Antes de jugar: -Download. Al cerrar: -Upload. «Sincronizar ahora»: los dos.
      Devuelve el resultado (Action: same, downloaded, uploaded, local-newer, remote-newer, nothing, off).
      Lanza un error TR-SYN-* con la causa si algo falla.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config,
        [switch]$Download, [switch]$Upload, $Backend = $null)
    if (-not $Backend) { $Backend = Get-CpSyncBackend -Config $Config }
    $name = (Get-CpGame $Id).name
    if (-not $Backend) { return (New-CpSyncResult $Id 'off' 'La sincronización está desactivada.') }
    [void](Get-CpSyncConfig $Config)
    $all = Get-CpSyncState
    $st = $(if ($all.ContainsKey($Id)) { $all[$Id] } else { @{} })
    $lastHash = $(if ($st.Contains('lastSyncedHash')) { [string]$st['lastSyncedHash'] } else { '' })
    $local = Get-CpSyncLocalInfo -Id $Id -Root $Root
    $localChanged = $local -and $local.bundleHash -cne $lastHash
    if ($localChanged -and $Upload) { Set-CpSyncPending $Id }
    $remote = Get-CpRemoteMeta -Backend $Backend -Id $Id
    $bad = $(if ($remote) { $remote.error } else { $null })     # hay un paquete, pero no pasó la validación
    if ($remote -and -not $bad -and $local -and $remote.bundleHash -ceq $local.bundleHash) {
        Set-CpSyncSynced $Id $local.bundleHash $local.updatedAt $remote.deviceName
        return (New-CpSyncResult $Id 'same' "${name}: ya estaba al día.")
    }
    $remoteData = $null
    if ($remote -and -not $bad -and (-not $local -or [string]::CompareOrdinal($remote.updatedAt, $local.updatedAt) -gt 0)) {
        # Parece más nueva: se descarga y se valida antes de decidir (aunque solo vayamos a subir,
        # para que un paquete dañado con fecha falsa no impida guardar la partida buena).
        $bundle = $null
        try {
            $remoteData = Receive-CpRemote -Backend $Backend -Id $Id -Remote $remote
            $expected = $(if ($remote.bundleHash -ceq $script:NoHash) { $null } else { $remote.bundleHash })
            $bundle = Test-CpSyncBundle -Id $Id -Data $remoteData -ExpectedHash $expected
        } catch {
            if (-not ($_.Exception -is [CreadorException]) -or $_.Exception.Code -ne '3DM-SYN-005' -or -not $Upload -or -not $local) { throw }
            $bad = $_.Exception; $remoteData = $null
        }
        if ($bundle) {
            $m = $bundle.Manifest
            if ($local -and [string]::CompareOrdinal($m['updatedAt'], $local.updatedAt) -le 0) {
                $remote = New-CpRemoteInfo $m['bundleHash'] $m['updatedAt'] $m['deviceName'] $remote.ref $null
            } elseif (-not $Download) {
                return (New-CpSyncResult $Id 'remote-newer' ("{0}: hay una partida más nueva de «{1}»; se va a usar la próxima vez." -f $name, $m['deviceName']))
            } else {
                $backup = Install-CpSyncBundle -Id $Id -Root $Root -Bundle $bundle
                Set-CpSyncSynced $Id $m['bundleHash'] $m['updatedAt'] $m['deviceName']
                return (New-CpSyncResult $Id 'downloaded' ("{0}: se usó la partida de «{1}» ({2})." -f $name, $m['deviceName'], (Format-CpSyncDate $m['updatedAt'])) $backup)
            }
        }
    }
    if ($bad -and (-not $Upload -or -not $local)) { throw $bad }
    if (-not $local) { return (New-CpSyncResult $Id 'nothing' "${name}: todavía no hay partidas.") }
    if (-not $Upload) {
        if ($localChanged) { Set-CpSyncPending $Id }
        return (New-CpSyncResult $Id 'local-newer' "${name}: la partida de este equipo es la más nueva.")
    }
    $conflict = $null
    if ($bad) { Write-CpLog Warn "Se reemplaza el paquete inválido de ${Id}: $($bad.Data2['reason'])" }
    elseif ($remote -and $remote.bundleHash -cne $lastHash) {
        # Otro equipo subió algo después de nuestra última sincronización: gana la más reciente (la nuestra),
        # pero la otra queda guardada.
        try {
            $data = $(if ($remoteData) { $remoteData } else { Receive-CpRemote -Backend $Backend -Id $Id -Remote $remote })
            [void](Test-CpSyncBundle -Id $Id -Data $data)
            $conflict = Save-CpSyncConflict $Id $data $remote
        } catch {
            if (-not ($_.Exception -is [CreadorException])) { throw }
            Write-CpLog Warn "No se guardó la versión en conflicto de ${Id}: $($_.Exception.Code)"
        }
    }
    $b = New-CpSyncBundle -Id $Id -Root $Root -Config $Config -Info $local
    Send-CpRemote -Backend $Backend -Id $Id -Data $b.Data -Manifest $b.Manifest -Remote $remote
    Set-CpSyncSynced $Id $local.bundleHash $local.updatedAt $b.Manifest.deviceName
    Write-CpLog Info "Partida de $Id subida ($($local.updatedAt))"
    New-CpSyncResult $Id 'uploaded' "${name}: partida guardada en la sincronización." $null $conflict
}

function Sync-CpBeforePlay {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Backend = $null)
    Sync-CpGame -Id $Id -Root $Root -Config $Config -Download -Backend $Backend
}

function Sync-CpAfterPlay {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Backend = $null)
    Sync-CpGame -Id $Id -Root $Root -Config $Config -Upload -Backend $Backend
}

function Sync-CpAll {
    <# Sincroniza todos los juegos instalados. Devuelve @( @{ Id; Result; Error } ). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Backend = $null, [scriptblock]$OnProgress)
    if (-not $Backend) { $Backend = Get-CpSyncBackend -Config $Config }
    $games = @(Get-CpInstalledGames -Root $Root)
    $out = @()
    for ($i = 0; $i -lt $games.Count; $i++) {
        $g = $games[$i]
        if ($OnProgress) { & $OnProgress ([int](100 * $i / [Math]::Max(1, $games.Count))) "Sincronizando $($g.Name)…" }
        try { $out += [pscustomobject]@{ Id = $g.Id; Result = (Sync-CpGame -Id $g.Id -Root $Root -Config $Config -Download -Upload -Backend $Backend); Error = $null } }
        catch {
            $info = Get-CpErrorInfo $_
            $out += [pscustomobject]@{ Id = $g.Id; Result = $null; Error = $info }
            if ($info.Code -in '3DM-SYN-001', '3DM-SYN-003', '3DM-SYN-008') { break }   # sin red o sin cuenta: no tiene sentido seguir
        }
    }
    $out
}

function Get-CpSyncStatus {
    <# Para la tabla de «Sincronización…»: un objeto por juego instalado. #>
    param([Parameter(Mandatory)][string]$Root)
    $st = Get-CpSyncState
    foreach ($g in @(Get-CpInstalledGames -Root $Root)) {
        $info = Get-CpSyncLocalInfo -Id $g.Id -Root $Root
        $s = $(if ($st.ContainsKey($g.Id)) { $st[$g.Id] } else { @{} })
        $last = $(if ($s.Contains('lastSyncedHash')) { [string]$s['lastSyncedHash'] } else { '' })
        $pending = ($s.Contains('pendingUpload') -and [bool]$s['pendingUpload']) -or ($info -and $info.bundleHash -cne $last)
        [pscustomobject]@{ Id = $g.Id; Name = $g.Name; LocalUpdatedAt = $(if ($info) { $info.updatedAt } else { $null })
            LastSyncAt = $(if ($s.Contains('lastSyncAt')) { [string]$s['lastSyncAt'] } else { $null }); Pending = [bool]$pending }
    }
}

Export-ModuleMember -Function Get-CpSuggestedSyncFolder, Save-CpGoogleClient, Get-CpGoogleHelpInfo, ConvertTo-CpJsonText, Get-CpSyncSettings, Get-CpGoogleSettings, Test-CpDriveAvailable, Get-CpSyncConfig, Test-CpSyncEnabled,
    Get-CpSyncState, Format-CpSyncDate, ConvertFrom-CpSyncIso, ConvertTo-CpSyncIso, Get-CpBundleHash, Get-CpSha256, Test-CpSyncName, Test-CpSaveMagic, Get-CpSyncFiles,
    Get-CpSyncLocalInfo, New-CpSyncBundle, Test-CpSyncBundle, Install-CpSyncBundle, New-CpFolderBackend, New-CpDriveBackend, Get-CpSyncBackend,
    Invoke-CpHttp, Test-CpSyncBackend, Get-CpRemoteMeta, Receive-CpRemote, Send-CpRemote, Start-CpDriveLink, Get-CpDriveLinkResult, Get-CpDriveEmail,
    Remove-CpDriveLink, Sync-CpGame, Sync-CpBeforePlay, Sync-CpAfterPlay, Sync-CpAll, Get-CpSyncStatus
