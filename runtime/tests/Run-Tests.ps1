<#
  Pruebas automáticas del núcleo de Creador de Películas 3D Runtime (sin interfaz gráfica).
  Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-IsoFolder <carpeta con la .iso>]
  Con -IsoFolder se ejecutan también las pruebas de integración contra la imagen real.
  Devuelve código de salida 0 si todo pasa.
#>
param([string]$IsoFolder)

$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $src 'Core\CreadorPeliculas.Errors.psm1') -Force
Import-Module (Join-Path $src 'Core\CreadorPeliculas.Core.psm1') -Force
Import-Module (Join-Path $src 'Core\CreadorPeliculas.Sync.psm1') -Force
Import-Module (Join-Path $src 'Core\CreadorPeliculas.Steam.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.Web.Extensions
Import-CpStrings (Join-Path $src 'data\strings.es.json')

$script:passed = 0; $script:failed = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "  OK   $Name" -ForegroundColor Green }
    catch {
        $script:failed++; Write-Host "  FALLA $Name :: $($_.Exception.Message)" -ForegroundColor Red
        if ($env:CP3D_TEST_VERBOSE) { Write-Host (Get-CpErrorInfo $_).Details }
    }
}
function Assert-True { param($Cond, [string]$Msg = 'condición falsa') if (-not $Cond) { throw $Msg } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Code)
    try { & $Body } catch { $info = Get-CpErrorInfo $_; if ($Code -and $info.Code -ne $Code) { throw "se esperaba $Code y se obtuvo $($info.Code)" }; return }
    throw "se esperaba un error $Code"
}

$tmp = Join-Path $env:TEMP ('creador-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$Id = '3DMM'
# Una película válida empieza con la firma de los archivos "chunky" de Kauai.
function New-Movie { param([string]$Text = '') , ([byte[]](0x43, 0x48, 0x4E, 0x32, 0x20, 0x43, 0x4F, 0x53) + [Text.Encoding]::UTF8.GetBytes($Text)) }

Write-Host 'Catálogo'
Test-Case 'games.json describe el juego con todos los campos de la receta' {
    $c = @(Get-CpCatalog)
    Assert-True ($c.Count -eq 1 -and $c[0].id -eq $Id) "catálogo: $($c.id -join ',')"
    $g = $c[0]
    foreach ($f in 'id', 'name', 'age', 'engine', 'iso', 'layout', 'exe', 'args', 'icon', 'registry', 'saves', 'savesDir', 'saveMagic', 'art') {
        Assert-True ($g.PSObject.Properties.Name -contains $f) "sin '$f'"
    }
    Assert-True ($g.iso.size -eq 346884096 -and $g.iso.keyFile -eq '3DMOVIE\3DMOVIE.EXE') 'datos de la ISO'
    Assert-True (@($g.layout | Where-Object { $_.from -eq '3DMOVIE' -and $_.to -eq 'MSKIDS\3D Creador de Películas' }).Count -eq 1) 'falta la carpeta del producto'
    Assert-True ($g.registry.values.'HKLM\Products'.'2' -eq 'sz:3D Creador de Películas/3DMovie') 'Products'
}
Test-Case 'strings.es.json cubre todos los códigos usados' {
    $codes = Select-String -Path (Join-Path $src 'Core\*.psm1'), (Join-Path $src 'UI\*.ps1'), (Join-Path $src '*.ps1') -Pattern "3DM-[A-Z]{3}-\d{3}" -AllMatches |
        ForEach-Object { $_.Matches.Value } | Select-Object -Unique
    $json = Get-Content -LiteralPath (Join-Path $src 'data\strings.es.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($code in $codes) { Assert-True ($json.errors.PSObject.Properties.Name -contains $code) "falta $code" }
}

Write-Host 'Errores'
Test-Case 'Get-CpErrorInfo reemplaza variables del mensaje' {
    $i = Get-CpErrorInfo (New-CpError '3DM-DSK-001' @{ drive = 'C:'; need = '2 GB'; free = '1 GB' })
    Assert-True ($i.Message -like '*C:*2 GB*1 GB*') $i.Message
}
Test-Case 'Errores desconocidos se muestran como 3DM-GEN-001' {
    $i = Get-CpErrorInfo ([Exception]::new('algo raro'))
    Assert-True ($i.Code -eq '3DM-GEN-001')
}
Test-Case 'Invoke-CpStep traduce excepciones y ejecuta el rollback' {
    $flag = @{ rolled = $false }
    Assert-Throws { Invoke-CpStep -Name 'prueba' -ErrorCode '3DM-CFG-001' -Action { throw 'x' } -Rollback { $flag.rolled = $true } } '3DM-CFG-001'
    Assert-True $flag.rolled 'no hubo rollback'
}

Write-Host 'Carpeta de instalación y jugador'
Test-Case 'Acepta una carpeta temporal' { Assert-True ((Test-CpInstallRoot -Path (Join-Path $tmp 'ok')) -like '*ok') }
Test-Case 'Rechaza rutas largas: MCI no abre los vídeos con más de 127 caracteres (3DM-DSK-004)' {
    Assert-Throws { Test-CpInstallRoot -Path ('C:\' + ('x' * 70)) } '3DM-DSK-004'
    $longest = 'C:\' + ('x' * 61) + '\games\3DMM\MSKIDS\3D Creador de Películas\BACKSTAG.AVI'
    Assert-True ($longest.Length -le 127) "con la raíz más larga permitida el AVI mide $($longest.Length)"
}
Test-Case 'Rechaza caracteres fuera de la página de códigos (3DM-DSK-003)' { Assert-Throws { Test-CpInstallRoot -Path (Join-Path $tmp ([string][char]0x65E5 + [char]0x672C)) } '3DM-DSK-003' }
Test-Case 'Rechaza carpetas de red (3DM-DSK-002)' { Assert-Throws { Test-CpInstallRoot -Path '\\servidor\juegos' } '3DM-DSK-002' }
Test-Case 'Nombres de jugador: carpeta válida, corta y ANSI' {
    foreach ($ok in 'Jugador', 'Ana', 'Martín 2', 'Sofía') { Assert-True (Test-CpPlayerName $ok) "rechazó «$ok»" }
    foreach ($bad in '', ' Ana', 'Ana.', 'a/b', 'a:b', 'McZee', 'Melanie', 'CON', 'COM1', ('x' * 25), ([string][char]0x65E5)) {
        Assert-True (-not (Test-CpPlayerName $bad)) "aceptó «$bad»"
    }
    Assert-True ((Get-CpPlayer @{ player = 'con' }) -eq 'Jugador') 'no volvió al nombre por omisión'
}

Write-Host 'INI y registro virtual'
Test-Case 'Set-CpIniValues agrega y reemplaza conservando el resto' {
    $p = Join-Path $tmp 'a.ini'
    [IO.File]::WriteAllLines($p, @('[HKLM]', 'InstallDirectory=sz:viejo', 'Otra=dw:1', '', '[HKCU]', 'X=dw:2'))
    Set-CpIniValues -Path $p -Values @{ HKLM = @{ InstallDirectory = 'sz:{HD}\MSKIDS'; WaveOutMsg = 'dw:0' }; 'HKLM\Products' = @{ '2' = 'sz:P/3DMovie' } } -Vars @{ HD = 'C:\J' }
    $t = [IO.File]::ReadAllText($p)
    Assert-True ($t -match 'InstallDirectory=sz:C:\\J\\MSKIDS') 'InstallDirectory'
    Assert-True ($t -match 'Otra=dw:1') 'clave preservada'
    Assert-True ($t -match 'WaveOutMsg=dw:0') 'clave nueva'
    Assert-True ($t -match '\[HKLM\\Products\]\s+2=sz:P/3DMovie') 'sección nueva'
    Assert-True ($t -match 'X=dw:2') 'otra sección preservada'
}
Test-Case 'Set-CpIniValues escribe en ANSI (cphook usa las APIs "A")' {
    $p = Join-Path $tmp 'b.ini'
    Set-CpIniValues -Path $p -Values @{ S = @{ Nombre = 'sz:3D Creador de Películas' } }
    $bytes = [IO.File]::ReadAllBytes($p)
    Assert-True ($bytes -contains 0xED) 'la í no se guardó como byte ANSI 0xED'
}
Test-Case 'Registro virtual: rutas actuales y primera vez de cada jugador' {
    $root = Join-Path $tmp 'reg'
    $vars = Get-CpGameVars -Id $Id -Root $root -Player 'Ana'
    Assert-True ($vars.USERDIR -eq (Join-Path $root 'games\3DMM\MSKIDS\Users\Ana')) "USERDIR: $($vars.USERDIR)"
    Write-CpGameConfig -Game (Get-CpGame $Id) -Root $root -Vars $vars
    $t = [IO.File]::ReadAllText((Get-CpRegistryFile -Id $Id -Root $root), [Text.Encoding]::GetEncoding(1252))
    Assert-True ($t -match ('InstallDirectory=sz:' + [regex]::Escape((Join-Path $root 'games\3DMM\MSKIDS')) + '\r?\n')) 'InstallDirectory'
    Assert-True ($t -match 'HomeDirectory=sz:\r?\n') 'la primera vez HomeDirectory tiene que ir vacío (el juego crea la carpeta y da la bienvenida)'
    New-Item -ItemType Directory -Force -Path $vars.USERDIR | Out-Null
    Write-CpGameConfig -Game (Get-CpGame $Id) -Root $root -Vars $vars
    $t = [IO.File]::ReadAllText((Get-CpRegistryFile -Id $Id -Root $root), [Text.Encoding]::GetEncoding(1252))
    Assert-True ($t -match ('HomeDirectory=sz:' + [regex]::Escape($vars.USERDIR) + '\\')) 'con la carpeta creada HomeDirectory apunta a ella'
    Assert-True (([regex]::Matches($t, 'HomeDirectory=')).Count -eq 1) 'HomeDirectory repetido'
}

Write-Host 'Versión instalada'
Test-Case 'Avisa si la instalación es más vieja que esta copia y deja de avisar al actualizar' {
    $root = Join-Path $tmp 'version'
    $app = Join-Path $root 'app'
    $current = Get-CpRuntimeVersion
    Assert-True ($current -is [version]) 'esta copia no informa su versión (falta VERSION)'
    Assert-True ($null -eq (Get-CpOutdatedInstall -Root $root)) 'avisó sin nada instalado'
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'src\CreadorPeliculas.ps1'), '#')
    $old = Get-CpOutdatedInstall -Root $root
    Assert-True ($old -and $null -eq $old.Installed -and $old.Newer -eq $current -and $old.SourceExists) 'no avisó con una instalación sin VERSION'
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "0.9.0`n")
    Assert-True ((Get-CpOutdatedInstall -Root $root).Installed -eq [version]'0.9.0') 'no avisó con una instalación 0.9.0'
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "99.0.0`n")
    Assert-True ($null -eq (Get-CpOutdatedInstall -Root $root)) 'avisó con una instalación más nueva'
    Remove-Item -LiteralPath (Join-Path $app 'VERSION')
    Install-CpRuntimeFiles -Root $root | Out-Null
    Assert-True ((Get-CpRuntimeVersion -AppRoot $app) -eq $current) 'la instalación no guardó su versión'
    Assert-True ($null -eq (Get-CpOutdatedInstall -Root $root)) 'siguió avisando después de actualizar'
}

Test-Case 'Desde un acceso directo (la instalada) avisa de la copia más nueva anotada y se actualiza desde ella' {
    $core = Get-Module CreadorPeliculas.Core
    $self = & $core { $script:AppRoot }
    $root = Join-Path $tmp 'version2'
    $app = Join-Path $root 'app'
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'src\CreadorPeliculas.ps1'), '#')
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "0.9.0`n")
    $cfg = [ordered]@{ newerCopy = $null }
    Assert-True (Register-CpRuntimeCopy -Config $cfg -Root $root) 'esta copia no se anotó'
    Assert-True (-not (Register-CpRuntimeCopy -Config $cfg -Root $root)) 'se volvió a anotar sin cambios'
    $cfg.newerCopy.declined = $true
    Assert-True (-not (Register-CpRuntimeCopy -Config $cfg -Root $root)) 'abrir la misma copia borró el «no actualizar»'
    $cfg.newerCopy.declined = $false
    try {
        & $core { param($p) $script:AppRoot = $p } $app          # ahora "somos" la instalada
        Assert-True (-not (Register-CpRuntimeCopy -Config $cfg -Root $root)) 'la instalada se anotó a sí misma'
        $old = Get-CpOutdatedInstall -Root $root -Config $cfg
        Assert-True ($old -and $old.Installed -eq [version]'0.9.0' -and (Test-CpSamePath $old.Source $self) -and $old.SourceExists -and -not $old.Declined) 'la instalada no avisó'
        Assert-True ($null -eq (Get-CpOutdatedInstall -Root $root -Config ([ordered]@{ newerCopy = $null }))) 'avisó sin nada anotado'
        $gone = [ordered]@{ newerCopy = [ordered]@{ version = '9.9.9'; path = (Join-Path $tmp 'borrada'); declined = $false } }
        $old = Get-CpOutdatedInstall -Root $root -Config $gone
        Assert-True ($old -and -not $old.SourceExists -and $old.Newer -eq [version]'9.9.9') 'no detectó la copia borrada'
    } finally { & $core { param($p) $script:AppRoot = $p } $self }
    Install-CpRuntimeFiles -Root $root -Source $self | Out-Null
    Assert-True ((Get-CpRuntimeVersion -AppRoot $app) -eq (Get-CpRuntimeVersion)) 'no se actualizó desde la copia anotada'
    & $core { param($p) $script:AppRoot = $p } $app
    try { Assert-True ($null -eq (Get-CpOutdatedInstall -Root $root -Config $cfg)) 'siguió avisando después de actualizar' }
    finally { & $core { param($p) $script:AppRoot = $p } $self }
}

Write-Host 'Películas (exportar / importar, mismo formato que Linux)'
function New-FakeInstall {
    <# Instalación mínima: manifiesto y el exe, sin copiar el disco. #>
    param([string]$Name)
    $root = Join-Path $tmp $Name
    $hd = Join-Path $root "games\$Id"
    $exe = Join-Path $hd (Get-CpGame $Id).exe
    New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
    [IO.File]::WriteAllText($exe, 'MZ')
    $m = [ordered]@{ version = 1; games = [ordered]@{ $Id = [ordered]@{ id = $Id; hd = $hd; isoPath = ''; label = '' } } }
    Save-CpManifest -Root $root -Manifest $m
    $root
}
function Get-MovieDir { param([string]$Root) $d = Get-CpSavesDir -Id $Id -Root $Root -Player 'Jugador'; New-Item -ItemType Directory -Force -Path $d | Out-Null; $d }
$env:CP3D_SAVES_DIR = Join-Path $tmp 'copias'
$cfgFile = Join-Path $tmp 'config.json'
& (Get-Module CreadorPeliculas.Core) { param($p) $script:ConfigFile = $p } $cfgFile   # el jugador por omisión, sin tocar la configuración real

Test-Case 'Solo las películas del jugador son partidas' {
    $a = New-FakeInstall 'savesA'
    $d = Get-MovieDir $a
    [IO.File]::WriteAllBytes((Join-Path $d 'Mi película.3MM'), (New-Movie 'a'))
    [IO.File]::WriteAllBytes((Join-Path $d 'notas.txt'), [byte[]](1))
    $melanie = Join-Path $a 'games\3DMM\MSKIDS\Users\Melanie'; New-Item -ItemType Directory -Force -Path $melanie | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $melanie 'MOMIA.3MM'), (New-Movie))
    $files = @(Get-CpSaveFiles -Id $Id -Root $a)
    Assert-True ($files.Count -eq 1 -and $files[0].Name -eq 'Mi película.3MM') "archivos: $($files.Name -join ',')"
}
Test-Case 'Exportar e importar en otra instalación (con copia previa)' {
    $a = Join-Path $tmp 'savesA'
    $zip = Export-CpAllSaves -Root $a -Destination (Join-Path $tmp 'out')
    Assert-True ($zip -and (Split-Path -Leaf $zip) -like 'creador-peliculas-*.zip') "nombre del zip: $zip"
    $content = Read-CpSavesZip -Zip $zip
    Assert-True ($content.Games[$Id].Count -eq 1) 'tendría que haber 1 película'
    $b = New-FakeInstall 'savesB'
    [IO.File]::WriteAllBytes((Join-Path (Get-MovieDir $b) 'vieja.3mm'), (New-Movie 'vieja'))
    $r = Import-CpSaves -Root $b -Zip $zip -BackupDestination (Join-Path $tmp 'bk')
    Assert-True (@($r.Imported[$Id]).Count -eq 1) 'no importó'
    Assert-True (@($r.Backups).Count -eq 1) 'no guardó la copia de las películas anteriores'
    $names = @(Get-ChildItem (Get-MovieDir $b) | ForEach-Object Name)
    Assert-True ($names.Count -eq 1 -and $names[0] -ceq 'Mi película.3MM') "archivos: $($names -join ',')"
}
Test-Case 'Importa un zip cualquiera con películas sueltas' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $srcDir = Join-Path $tmp 'sueltas'; New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $srcDir 'CUENTO.3MM'), (New-Movie 'cuento'))
    $zip = Join-Path $tmp 'mis-peliculas.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zip)
    $b = New-FakeInstall 'savesC'
    [void](Import-CpSaves -Root $b -Zip $zip -BackupDestination (Join-Path $tmp 'bk'))
    Assert-True (Test-Path (Join-Path (Get-MovieDir $b) 'CUENTO.3MM')) 'no se importó'
}
Test-Case 'Rechaza zips que no son películas y entradas peligrosas (3DM-SAV-001)' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $tmp 'otro.zip'
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($n in @('../evil.3mm', '3DMM/../../x.3mm', '3DMM/sub/A.3MM', '3DMM/3DMOVIE.EXE', 'leeme.txt')) {
            $w = New-Object IO.StreamWriter($archive.CreateEntry($n).Open()); $w.Write('x'); $w.Dispose()
        }
    } finally { $archive.Dispose() }
    Assert-Throws { Read-CpSavesZip -Zip $zip } '3DM-SAV-001'
}

Write-Host 'Sincronización de películas (mismo formato y reglas que Linux)'
$syncModule = Get-Module CreadorPeliculas.Sync
function Use-Device { param([string]$Name) & $syncModule { param($p) $script:StateFile = $p } (Join-Path $tmp "sync-state-$Name.json") }
function Set-Save {
    param([string]$Root, [string]$Name, [string]$Text, [string]$When)
    $p = Join-Path (Get-MovieDir $Root) $Name
    [IO.File]::WriteAllBytes($p, (New-Movie $Text))
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = ConvertFrom-CpSyncIso $When
    $p
}
function Read-Save { param([string]$Root, [string]$Name) [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path (Get-MovieDir $Root) $Name)), 8, ((Get-Item (Join-Path (Get-MovieDir $Root) $Name)).Length - 8)) }
function New-TestZip {
    <# Zip de prueba: $Entries = @{ nombre = byte[] }; $Manifest = hashtable o $null. #>
    param([hashtable]$Entries, $Manifest)
    $ms = New-Object IO.MemoryStream
    $a = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        if ($Manifest) {
            $w = New-Object IO.StreamWriter($a.CreateEntry('creador-saves.json').Open())
            $w.Write((ConvertTo-CpJsonText $Manifest)); $w.Dispose()
        }
        foreach ($k in $Entries.Keys) { $s = $a.CreateEntry($k).Open(); $s.Write($Entries[$k], 0, $Entries[$k].Length); $s.Dispose() }
    } finally { $a.Dispose() }
    , $ms.ToArray()
}
function New-TestManifest {
    param([string]$GameId, [hashtable]$Entries, [string]$Updated = '2026-01-01T10:00:00Z', [hashtable]$Over = @{})
    $files = @(foreach ($k in $Entries.Keys) { @{ name = $k; size = $Entries[$k].Length; sha256 = (Get-CpSha256 $Entries[$k]); mtime = $Updated } })
    $m = @{ format = 2; createdAt = $Updated; platform = 'linux'; games = @($GameId); gameId = $GameId; updatedAt = $Updated; deviceId = 'abc'; deviceName = 'Deck'
        bundleHash = (Get-CpBundleHash $files); files = $files }
    foreach ($k in $Over.Keys) { $m[$k] = $Over[$k] }
    $m
}
function Assert-Rejected {
    param([byte[]]$Data)
    try { [void](Test-CpSyncBundle -Id $Id -Data $Data) } catch { $i = Get-CpErrorInfo $_; if ($i.Code -ne '3DM-SYN-005') { throw "se esperaba 3DM-SYN-005 y se obtuvo $($i.Code): $($i.Details)" }; return $i.Message }
    throw 'se esperaba 3DM-SYN-005'
}
$exeBytes = [byte[]](@(0x4D, 0x5A) + @(0) * 0x3A + @(0x40, 0, 0, 0, 0x50, 0x45, 0, 0))

Test-Case 'Un paquete válido pasa la validación (también uno hecho en Linux)' {
    $e = @{ 'Película.3MM' = (New-Movie 'x'); 'OTRA.3mm' = (New-Movie 'y') }
    $r = Test-CpSyncBundle -Id $Id -Data (New-TestZip $e (New-TestManifest $Id $e))
    Assert-True ($r.Contents.Count -eq 2) 'contenido'
    $fx = Join-Path $PSScriptRoot 'fixtures\sync-linux-3DMM.zip'
    if (Test-Path $fx) {
        $r = Test-CpSyncBundle -Id $Id -Data ([IO.File]::ReadAllBytes($fx))
        Assert-True ($r.Manifest['platform'] -eq 'linux' -and $r.Contents.Count -ge 1) 'paquete de Linux'
    } else { Write-Host '       (falta fixtures\sync-linux-3DMM.zip: lo genera test_linux.py)' -ForegroundColor Yellow }
}
Test-Case 'Rechaza paquetes peligrosos o manipulados (3DM-SYN-005)' {
    $g = @{ 'A.3MM' = (New-Movie 'a'); 'B.3MM' = (New-Movie 'b') }
    $plus = { param($extra) $h = @{}; foreach ($k in $g.Keys) { $h[$k] = $g[$k] }; foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }; $h }
    $notMovie = [byte[]](1, 2, 3, 4, 5, 6)
    $cases = [ordered]@{
        'ruta'           = New-TestZip (& $plus @{ '../x.3mm' = (New-Movie) }) (New-TestManifest $Id $g)
        'carpeta'        = New-TestZip @{ '3DMM/A.3MM' = (New-Movie) } (New-TestManifest $Id @{ '3DMM/A.3MM' = (New-Movie) })
        'otro juego'     = New-TestZip $g (New-TestManifest 'OTRO' $g)
        'no es película' = New-TestZip @{ 'X.EXE' = [byte[]](1) } (New-TestManifest $Id @{ 'X.EXE' = [byte[]](1) })
        'sin firma CHN2' = New-TestZip @{ 'A.3MM' = $notMovie } (New-TestManifest $Id @{ 'A.3MM' = $notMovie })
        'sin manifiesto' = New-TestZip $g $null
        'archivo extra'  = New-TestZip (& $plus @{ 'C.3MM' = (New-Movie) }) (New-TestManifest $Id $g)
        'hash'           = New-TestZip @{ 'A.3MM' = $g['A.3MM']; 'B.3MM' = (New-Movie 'cambiada') } (New-TestManifest $Id $g)
        'futuro'         = New-TestZip $g (New-TestManifest $Id $g '2099-01-01T00:00:00Z')
        'clave extra'    = New-TestZip $g (New-TestManifest $Id $g -Over @{ extra = 1 })
        'ejecutable'     = New-TestZip @{ 'A.3MM' = $exeBytes } (New-TestManifest $Id @{ 'A.3MM' = $exeBytes })
        'zip adentro'    = New-TestZip @{ 'A.3MM' = [byte[]](0x50, 0x4B, 3, 4, 1) } (New-TestManifest $Id @{ 'A.3MM' = [byte[]](0x50, 0x4B, 3, 4, 1) })
        'no zip'         = [Text.Encoding]::ASCII.GetBytes('hola')
    }
    foreach ($k in $cases.Keys) { try { [void](Assert-Rejected $cases[$k]) } catch { throw "caso '$k': $($_.Exception.Message)" } }
    $big = New-Movie; $big = [byte[]]($big + (New-Object byte[] (33MB)))
    Assert-True ((Assert-Rejected (New-TestZip @{ 'A.3MM' = $big } (New-TestManifest $Id @{ 'A.3MM' = $big }))) -like '*') 'película demasiado grande'
    $two = New-Object Collections.Hashtable([StringComparer]::Ordinal); $two['a.3mm'] = (New-Movie '1'); $two['A.3MM'] = (New-Movie '2')
    $dup = New-TestZip $two (New-TestManifest $Id @{ 'a.3mm' = (New-Movie '1') })
    Assert-True ((Assert-Rejected $dup) -like '*repetidos*') 'nombres repetidos por mayúsculas'
}
Test-Case 'Carpeta: la película más reciente gana y viaja entre equipos' {
    $a = New-FakeInstall 'syncA'; $bb = New-FakeInstall 'syncB'
    $cloud = Join-Path $tmp 'nube'; New-Item -ItemType Directory -Force -Path $cloud | Out-Null
    $ca = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('a' * 32); deviceName = 'PC' } }
    $cb = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('b' * 32); deviceName = 'Deck' } }
    Use-Device 'a'
    [void](Set-Save $a 'Mi película.3MM' 'Ana' '2026-01-01T10:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $ca).Action -eq 'uploaded') 'no subió'
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $ca).Action -eq 'same') 'debería estar al día'
    Use-Device 'b'
    $r = Sync-CpBeforePlay -Id $Id -Root $bb -Config $cb
    Assert-True ($r.Action -eq 'downloaded') "acción: $($r.Action)"
    Assert-True ((Read-Save $bb 'Mi película.3MM') -eq 'Ana') 'contenido'
    $p = Join-Path (Get-MovieDir $bb) 'Mi película.3MM'
    Assert-True ((ConvertTo-CpSyncIso (Get-Item $p).LastWriteTimeUtc) -eq '2026-01-01T10:00:00Z') 'fecha'
    [void](Set-Save $bb 'Mi película.3MM' 'Ana2' '2026-01-02T10:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $bb -Config $cb).Action -eq 'uploaded') 'B no subió'
    Use-Device 'a'
    $r = Sync-CpBeforePlay -Id $Id -Root $a -Config $ca
    Assert-True ($r.Action -eq 'downloaded' -and $r.Backup -and (Test-Path $r.Backup)) 'A no bajó la de B o no guardó copia'
    # Conflicto: B usa el programa sin red después que A.
    [void](Set-Save $a 'Mi película.3MM' 'A3' '2026-01-03T10:00:00Z')
    [void](Sync-CpAfterPlay -Id $Id -Root $a -Config $ca)
    Use-Device 'b'
    [void](Set-Save $bb 'Mi película.3MM' 'B4' '2026-01-04T10:00:00Z')
    $r = Sync-CpAfterPlay -Id $Id -Root $bb -Config $cb
    Assert-True ($r.Action -eq 'uploaded' -and $r.Conflict -like '*3DMM-conflicto-PC-*') "conflicto: $($r.Conflict)"
    Assert-True ((Read-CpSavesZip -Zip $r.Conflict).Games[$Id].Contains('Mi película.3MM')) 'la copia en conflicto no se puede importar'
    # La local más nueva no se pisa al abrir; la remota más nueva no se pisa al cerrar.
    Use-Device 'a'
    [void](Set-Save $a 'Mi película.3MM' 'A5' '2026-01-05T10:00:00Z')
    Assert-True ((Sync-CpBeforePlay -Id $Id -Root $a -Config $ca).Action -eq 'local-newer') 'local más nueva'
    Assert-True (@(Get-CpSyncStatus -Root $a | Where-Object { $_.Id -eq $Id -and $_.Pending }).Count -eq 1) 'debería quedar pendiente'
    [void](Set-Save $a 'Mi película.3MM' 'A0' '2026-01-01T09:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $ca).Action -eq 'remote-newer') 'no debe pisar una más nueva'
}
Test-Case 'Carpeta: un paquete inválido frena el programa pero no impide guardar' {
    $a = New-FakeInstall 'syncC'
    $cloud = Join-Path $tmp 'nube2'; New-Item -ItemType Directory -Force -Path (Join-Path $cloud 'CreadorPeliculas-sync') | Out-Null
    $c = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('c' * 32); deviceName = 'PC' } }
    $e = @{ 'A.3MM' = $exeBytes }
    [IO.File]::WriteAllBytes((Join-Path $cloud 'CreadorPeliculas-sync\3DMM.zip'), (New-TestZip $e (New-TestManifest $Id $e)))
    Use-Device 'c'
    Assert-Throws { Sync-CpBeforePlay -Id $Id -Root $a -Config $c } '3DM-SYN-005'
    [void](Set-Save $a 'A.3MM' 'A' '2026-01-01T10:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $c).Action -eq 'uploaded') 'no reemplazó el paquete inválido'
    Assert-True ((Sync-CpBeforePlay -Id $Id -Root $a -Config $c).Action -eq 'same') 'quedó distinto'
    # Este paquete es el fixture que valida test_linux.py (paquete hecho en Windows).
    $fx = Join-Path $PSScriptRoot 'fixtures\sync-windows-3DMM.zip'
    if (-not (Test-Path $fx)) {
        $w = New-FakeInstall 'syncFixture'
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'nubeFx') | Out-Null
        $cw = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = (Join-Path $tmp 'nubeFx'); deviceId = ('f' * 32); deviceName = 'PC' } }
        Use-Device 'fx'
        [void](Set-Save $w 'Película de PC.3MM' 'hecha en Windows' '2026-01-01T10:00:00Z')
        [void](Sync-CpAfterPlay -Id $Id -Root $w -Config $cw)
        Copy-Item (Join-Path $tmp 'nubeFx\CreadorPeliculas-sync\3DMM.zip') $fx
        Write-Host '       (se generó fixtures\sync-windows-3DMM.zip)' -ForegroundColor Yellow
    }
}
Test-Case 'Propone una carpeta para sincronizar (la de un programa de sincronización o la de copias)' {
    $sg = Get-CpSuggestedSyncFolder
    Assert-True ($sg.Path) 'no propuso nada'
    Assert-True (($sg.Source -and (Test-Path -LiteralPath $sg.Path)) -or (-not $sg.Source -and $sg.Path -eq (Get-CpSavesFolder))) "propuesta: $($sg.Path) ($($sg.Source))"
}
Test-Case 'Carpeta inexistente: 3DM-SYN-002 y queda pendiente' {
    $a = Join-Path $tmp 'syncC'
    $c = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = (Join-Path $tmp 'no-existe'); deviceId = ('c' * 32); deviceName = 'PC' } }
    [void](Set-Save $a 'A.3MM' 'Z' '2026-02-01T10:00:00Z')
    Assert-Throws { Sync-CpAfterPlay -Id $Id -Root $a -Config $c } '3DM-SYN-002'
    Assert-True (@(Get-CpSyncStatus -Root $a | Where-Object { $_.Id -eq $Id -and $_.Pending }).Count -eq 1) 'no quedó pendiente'
}
Test-Case 'El paquete de Windows coincide con el fixture que valida Linux' {
    $r = Test-CpSyncBundle -Id $Id -Data ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\sync-windows-3DMM.zip')))
    Assert-True ($r.Manifest['platform'] -eq 'windows') 'plataforma'
}

function New-FakeGoogle {
    <# Transporte HTTP falso que imita OAuth y Drive. $State.fail: códigos a devolver; $State.down: sin red. #>
    $state = @{ files = @{}; fail = New-Object Collections.ArrayList; tokensOk = $true; down = $false }
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $reply = { param($status, $obj) @{ Status = $status; Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-CpJsonText $obj)) } }
    $transport = {
        param($Method, $Url, $Headers, $Body, $Timeout)
        if ($state.down) { throw (New-Object Net.Http.HttpRequestException('No se puede resolver el nombre remoto')) }
        $u = [Uri]$Url
        $form = $(if ($Body) { [Text.Encoding]::ASCII.GetString($Body) } else { '' })
        switch ($u.AbsolutePath) {
            '/device/code' { return (& $reply 200 @{ device_code = 'DEV'; user_code = 'ABCD-EFGH'; verification_url = 'https://www.google.com/device'; interval = 1; expires_in = 600 }) }
            '/token' {
                if ($form -like '*device_code*') {
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"email":"ana@example.com"}')).TrimEnd('=')
                    return (& $reply 200 @{ access_token = 'AT'; refresh_token = 'RT'; expires_in = 3600; id_token = "x.$payload.y" })
                }
                if (-not $state.tokensOk) { return (& $reply 400 @{ error = 'invalid_grant'; error_description = 'Token has been expired or revoked.' }) }
                return (& $reply 200 @{ access_token = 'AT'; expires_in = 3600 })
            }
            '/revoke' { return (& $reply 200 @{}) }
        }
        if ($Headers['Authorization'] -ne 'Bearer AT') { return (& $reply 401 @{ error = @{ message = 'Invalid Credentials' } }) }
        if ($state.fail.Count) {
            $code = $state.fail[0]; $state.fail.RemoveAt(0)
            return (& $reply $code @{ error = @{ message = 'falla simulada'; errors = @(@{ reason = $(if ($code -eq 403) { 'storageQuotaExceeded' } else { 'backendError' }) }) } })
        }
        if ($u.AbsolutePath -eq '/drive/v3/files' -and $Method -eq 'GET') {
            return (& $reply 200 @{ files = @($state.files.Keys | ForEach-Object { @{ id = $_; name = $state.files[$_].name; appProperties = $state.files[$_].appProperties } }) })
        }
        if ($u.AbsolutePath -like '/drive/v3/files/*' -and $Method -eq 'GET') {
            return @{ Status = 200; Body = $state.files[$u.Segments[-1]].data }
        }
        if ($u.AbsolutePath -like '/upload/drive/v3/files*') {
            $ct = $Headers['Content-Type']; $boundary = $ct.Substring($ct.IndexOf('boundary=') + 9)
            $text = [Text.Encoding]::GetEncoding(28591).GetString($Body)
            $parts = $text.Split(@("--$boundary"), [StringSplitOptions]::None)
            $meta = $js.DeserializeObject($parts[1].Substring($parts[1].IndexOf("`r`n`r`n") + 4).TrimEnd("`r", "`n"))
            $zipText = $parts[2].Substring($parts[2].IndexOf("`r`n`r`n") + 4); $zipText = $zipText.Substring(0, $zipText.Length - 2)
            $id = $(if ($Method -eq 'PATCH') { $u.Segments[-1] } else { 'id' + ($state.files.Count + 1) })
            if ($Method -eq 'POST' -and -not ($meta.ContainsKey('parents'))) { throw 'faltó parents=appDataFolder' }
            $state.files[$id] = @{ name = $meta['name']; appProperties = $meta['appProperties']; data = [Text.Encoding]::GetEncoding(28591).GetBytes($zipText) }
            return (& $reply 200 @{ id = $id })
        }
        & $reply 404 @{ error = @{ message = 'ruta desconocida' } }
    }.GetNewClosure()
    @{ State = $state; Transport = $transport }
}
$googleConf = @{ clientId = 'cid'; clientSecret = 'sec'; scope = 'drive.appdata'; authBase = 'https://oauth.test'; apiBase = 'https://api.test'; timeoutSeconds = 5; retries = 3; retryDelay = 0.01 }
$googleConf = @{ clientId = 'cid'; clientSecret = 'sec'; scope = 'drive.appdata'; authBase = 'https://oauth.test'; apiBase = 'https://api.test'; timeoutSeconds = 5; retries = 3; retryDelay = 0.01 }
Test-Case 'Google Drive: vincular, subir, actualizar y bajar en otro equipo' {
    $g = New-FakeGoogle
    $da = New-CpDriveBackend -TokenPath (Join-Path $tmp 'token-a.json') -Transport $g.Transport -Conf $googleConf
    $db = New-CpDriveBackend -TokenPath (Join-Path $tmp 'token-b.json') -Transport $g.Transport -Conf $googleConf
    $code = Start-CpDriveLink $da
    Assert-True ($code.user_code -eq 'ABCD-EFGH') 'código'
    Assert-True ((Get-CpDriveLinkResult $da $code.device_code) -eq 'ana@example.com') 'correo'
    Assert-True ((Get-CpDriveEmail $da) -eq 'ana@example.com') 'token guardado'
    Assert-True (-not ([IO.File]::ReadAllText((Join-Path $tmp 'token-a.json')) -like '*refresh_token*')) 'el token debe quedar cifrado'
    [void](Get-CpDriveLinkResult $db 'DEV')
    $a = New-FakeInstall 'driveA'; $bb = New-FakeInstall 'driveB'
    $ca = [ordered]@{ sync = [ordered]@{ mode = 'drive'; deviceId = ('a' * 32); deviceName = 'PC' } }
    Use-Device 'da'
    [void](Set-Save $a 'Mi película.3MM' 'Ana' '2026-01-01T10:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $ca -Backend $da).Action -eq 'uploaded') 'no subió'
    [void](Set-Save $a 'Mi película.3MM' 'Ana2' '2026-01-02T10:00:00Z')
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $ca -Backend $da).Action -eq 'uploaded') 'no actualizó'
    Assert-True ($g.State.files.Count -eq 1) "debería haber un solo archivo en Drive: $($g.State.files.Count)"
    Use-Device 'db'
    Assert-True ((Sync-CpBeforePlay -Id $Id -Root $bb -Config $ca -Backend $db).Action -eq 'downloaded') 'no bajó'
    Assert-True ((Read-Save $bb 'Mi película.3MM') -eq 'Ana2') 'contenido'
    Remove-CpDriveLink $db
    Assert-True (-not (Get-CpDriveEmail $db)) 'no se desvinculó'
}
Test-Case 'Google Drive: errores con su causa (reintentos, cuota, permiso vencido, sin red)' {
    $g = New-FakeGoogle
    $d = New-CpDriveBackend -TokenPath (Join-Path $tmp 'token-e.json') -Transport $g.Transport -Conf $googleConf
    [void](Get-CpDriveLinkResult $d 'DEV')
    $a = New-FakeInstall 'driveE'
    $c = [ordered]@{ sync = [ordered]@{ mode = 'drive'; deviceId = ('e' * 32); deviceName = 'PC' } }
    Use-Device 'de'
    [void](Set-Save $a 'A.3MM' '1' '2026-01-01T10:00:00Z')
    [void]$g.State.fail.AddRange(@(503, 500))
    Assert-True ((Sync-CpAfterPlay -Id $Id -Root $a -Config $c -Backend $d).Action -eq 'uploaded') 'no reintentó'
    [void]$g.State.fail.AddRange(@(500, 500, 500, 500, 500))
    Assert-Throws { Sync-CpBeforePlay -Id $Id -Root $a -Config $c -Backend $d } '3DM-SYN-006'
    $g.State.fail.Clear(); [void]$g.State.fail.Add(403)
    [void](Set-Save $a 'A.3MM' '2' '2026-01-02T10:00:00Z')
    Assert-Throws { Sync-CpAfterPlay -Id $Id -Root $a -Config $c -Backend $d } '3DM-SYN-004'
    $d.access = $null; $g.State.tokensOk = $false
    Assert-Throws { Sync-CpAfterPlay -Id $Id -Root $a -Config $c -Backend $d } '3DM-SYN-003'
    $g.State.tokensOk = $true; $g.State.down = $true
    $info = $null
    try { [void](Sync-CpAfterPlay -Id $Id -Root $a -Config $c -Backend $d) } catch { $info = Get-CpErrorInfo $_ }
    Assert-True ($info -and $info.Code -eq '3DM-SYN-001' -and $info.Message -like '*No se puede resolver*') "sin red: $($info.Code) $($info.Message)"
    $nc = @{}; foreach ($k in $googleConf.Keys) { $nc[$k] = $googleConf[$k] }; $nc.clientId = ''
    Assert-Throws { Start-CpDriveLink (New-CpDriveBackend -TokenPath (Join-Path $tmp 't.json') -Conf $nc) } '3DM-SYN-008'
}

Test-Case 'Google Drive: el cliente OAuth se puede cargar desde la interfaz' {
    & $syncModule { param($p) $script:ClientFile = $p } (Join-Path $tmp 'google-client.json')
    Assert-True ((Save-CpGoogleClient -ClientId 'no-es-un-id' -ClientSecret 'GOCSPX-abcdefghijkl') -like '*googleusercontent*') 'aceptó un ID inválido'
    Assert-True ([bool](Save-CpGoogleClient -ClientId '123-abc.apps.googleusercontent.com' -ClientSecret 'corto')) 'aceptó un secreto inválido'
    Assert-True ($null -eq (Save-CpGoogleClient -ClientId ' 123-abc.apps.googleusercontent.com ' -ClientSecret 'GOCSPX-abcdefghijkl')) 'no guardó'
    Assert-True ((Get-CpGoogleSettings).clientId -eq '123-abc.apps.googleusercontent.com') 'no lo lee'
    Assert-True (Test-CpDriveAvailable) 'no quedó disponible'
}

Write-Host 'Steam (accesos para Big Picture y Steam Link)'
$gameName = (Get-CpGame $Id).name
Test-Case 'VDF compatible con Linux y appid igual al de Python' {
    $fx = Join-Path $PSScriptRoot 'fixtures\shortcuts-linux.vdf'
    $doc = ConvertFrom-CpVdf ([IO.File]::ReadAllBytes($fx))
    $e = $doc['shortcuts']['0']
    Assert-True ($e['AppName'] -eq 'Otro juego' -and $e['appid'] -eq -123 -and $e['LastPlayTime'] -eq 5 -and $e['tags']['0'] -eq 'X') 'lectura'
    $big = $doc['shortcuts']['1']
    Assert-True ($big['AppName'] -eq $gameName -and $big['grande'] -eq [uint64]5000000000) 'texto UTF-8 y entero de 64 bits'
    $again = ConvertTo-CpVdf $doc
    Assert-True ([Convert]::ToBase64String($again) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($fx))) 'no queda idéntico al reescribirlo'
    # Mismo valor que steam.shortcut_appid('"C:\x\powershell.exe"', '3D Creador de Películas') en Python.
    Assert-True ((Get-CpShortcutAppId '"C:\x\powershell.exe"' $gameName) -eq [int](Get-Content (Join-Path $PSScriptRoot 'fixtures\appid.txt'))) 'appid'
}
Test-Case 'Update-CpSteamShortcutsFile conserva los accesos ajenos y la última vez que se usó' {
    $root = New-FakeInstall 'steam'
    $p = Join-Path $tmp 'shortcuts.vdf'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\shortcuts-linux.vdf') $p
    $doc = ConvertFrom-CpVdf ([IO.File]::ReadAllBytes($p)); $doc['shortcuts'].Remove('1'); [IO.File]::WriteAllBytes($p, (ConvertTo-CpVdf $doc))
    $wanted = @(Get-CpWantedSteamShortcuts -Root $root)
    Assert-True ($wanted.Count -eq 2 -and $wanted[1].LaunchOptions -like '*CreadorPeliculas.ps1" --play 3DMM' -and $wanted[1].tags['0'] -eq 'Creador de Películas 3D') 'accesos'
    [void](Update-CpSteamShortcutsFile -Path $p -Wanted $wanted)
    $doc = ConvertFrom-CpVdf ([IO.File]::ReadAllBytes($p))
    $mine = @($doc['shortcuts'].Values | Where-Object { $_['AppName'] -eq $gameName })[0]
    $mine['LastPlayTime'] = 1234
    [IO.File]::WriteAllBytes($p, (ConvertTo-CpVdf $doc))
    [void](Update-CpSteamShortcutsFile -Path $p -Wanted @(Get-CpWantedSteamShortcuts -Root $root))
    $doc = ConvertFrom-CpVdf ([IO.File]::ReadAllBytes($p))
    $names = @($doc['shortcuts'].Values | ForEach-Object { $_['AppName'] })
    Assert-True ($names.Count -eq 3 -and $names -contains 'Creador de Películas 3D - opciones' -and $names -contains 'Otro juego' -and $names -contains $gameName) "accesos: $($names -join '|')"
    $mine = @($doc['shortcuts'].Values | Where-Object { $_['AppName'] -eq $gameName })[0]
    Assert-True ($mine['LastPlayTime'] -eq 1234) 'perdió LastPlayTime'
    Assert-True ($mine['appid'] -eq (Get-CpShortcutAppId $mine['Exe'] $mine['AppName'])) 'appid'
    Assert-True (Test-Path "$p.creador.bak") 'falta la copia del original'
}

if ($IsoFolder) {
    Write-Host 'Integración con la imagen real'
    Test-Case 'Find-CpIsos reconoce la imagen, su archivo clave y su etiqueta' {
        $script:found = Find-CpIsos -Folder $IsoFolder
        $script:iso = @($script:found.Isos | Where-Object { $_.Status -eq 'ok' -and $_.GameId -eq $Id })[0]
        Assert-True $script:iso 'no se reconoció la imagen'
        Assert-True ($script:iso.Label -eq (Get-CpGame $Id).iso.label) "etiqueta: $($script:iso.Label)"
    }
    Test-Case 'Install-CpGame reproduce la instalación original sin el instalador de 16 bits' {
        $root = Join-Path $tmp 'inst'
        Install-CpGame -Id $Id -IsoPath $script:iso.Path -Root $root
        $hd = Join-Path $root 'games\3DMM'
        Assert-True (Test-Path (Join-Path $hd (Get-CpGame $Id).exe)) 'falta el exe'
        foreach ($f in 'MSKIDS\3D Creador de Películas\BUILDING.CHK', 'MSKIDS\3D Creador de Películas\LOGN1.AVI', 'MSKIDS\3D Creador de Películas\3DMM.HLP',
            'MSKIDS\Users\Melanie\MOMIA.3MM', 'MSKIDS\Users\McZee\CABEZAZO.3MM', 'art\3DMVMAIN.DIB') {
            Assert-True (Test-Path -LiteralPath (Join-Path $hd $f)) "falta $f"
        }
        Assert-True (-not (Test-Path (Join-Path $hd 'MSKIDS\Users\Melanie\3DMSETUP.DLL'))) 'copió archivos del instalador'
        Assert-True (@(Get-ChildItem $hd -Recurse -File | Where-Object IsReadOnly).Count -eq 0) 'quedaron archivos de solo lectura'
        Assert-True (Test-Path (Get-CpRegistryFile -Id $Id -Root $root)) 'falta el registro virtual'
        Assert-True ((Get-CpManifest -Root $root).games.Contains($Id)) 'no quedó en el manifiesto'
        $script:instRoot = $root
    }
    Test-Case 'Artwork de Steam generado desde el CD con las medidas de Steam' {
        Add-Type -AssemblyName System.Drawing
        $dir = New-CpArtImages -Id $Id -Root $script:instRoot
        foreach ($s in @(@('portrait.png', 600, 900), @('header.png', 920, 430), @('hero.png', 1920, 620), @('logo.png', 900, 230))) {
            $img = [Drawing.Image]::FromFile((Join-Path $dir $s[0]))
            try { Assert-True ($img.Width -eq $s[1] -and $img.Height -eq $s[2]) "$($s[0]): $($img.Width)x$($img.Height)" } finally { $img.Dispose() }
        }
    }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Resultado: {0} correctas, {1} con fallas" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
