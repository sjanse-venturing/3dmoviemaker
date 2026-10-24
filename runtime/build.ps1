<#
  Empaqueta Creador de Películas 3D Runtime para distribuir.

  Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 [-SkipNative] [-SkipTests] [-IsoFolder <carpeta>]

  Pasos: compila los componentes nativos (MSVC x86), normaliza la codificación de
  los scripts (UTF-8 con BOM para Windows PowerShell 5.1), verifica la sintaxis,
  ejecuta las pruebas y genera dist\CreadorPeliculasRuntime-<versión>.zip.

  El mismo ZIP sirve para Windows (CreadorPeliculas.cmd) y para Linux / Steam Deck
  (creador.sh + linux\): las rutas usan '/' y las entradas llevan permisos de
  Unix (creador.sh ejecutable). Desde Linux, build.sh arma el mismo paquete.
  La versión por defecto sale del archivo VERSION.
#>
param([switch]$SkipNative, [switch]$SkipTests, [string]$IsoFolder, [string]$Version)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Version) { $Version = (Get-Content (Join-Path $here 'VERSION') -TotalCount 1).Trim() }
function Step([string]$t) { Write-Host "==> $t" -ForegroundColor Cyan }

if (-not $SkipNative) {
    Step 'Compilando componentes nativos (x86)'
    & cmd.exe /c (Join-Path $here 'native\build.cmd')
    if ($LASTEXITCODE -ne 0) { throw "La compilación nativa falló (código $LASTEXITCODE). ¿Están instaladas las Build Tools de Visual Studio con C++?" }
}
foreach ($f in 'cplaunch.exe', 'cphook.dll') {
    if (-not (Test-Path (Join-Path $here "native\bin\$f"))) { throw "Falta native\bin\$f. Ejecutá build.ps1 sin -SkipNative." }
}

Step 'Normalizando codificación (UTF-8 con BOM)'
Get-ChildItem (Join-Path $here 'src'), (Join-Path $here 'tests') -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        [IO.File]::WriteAllBytes($_.FullName, [byte[]](0xEF, 0xBB, 0xBF) + $b)
        Write-Host "   BOM agregado: $($_.Name)"
    }
}

Step 'Verificando sintaxis'
$bad = 0
Get-ChildItem (Join-Path $here 'src'), (Join-Path $here 'tests') -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) { if ($e) { Write-Host ("   {0}:{1} {2}" -f $_.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red; $bad++ } }
}
if ($bad) { throw "Hay $bad errores de sintaxis." }

if (-not $SkipTests) {
    Step 'Ejecutando pruebas (Windows PowerShell 5.1)'
    $testArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'tests\Run-Tests.ps1'))
    if ($IsoFolder) { $testArgs += @('-IsoFolder', $IsoFolder) }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @testArgs
    if ($LASTEXITCODE -ne 0) { throw 'Las pruebas fallaron.' }
}

Step 'Armando el paquete'
$dist = Join-Path $here 'dist'
$name = "CreadorPeliculasRuntime-$Version"
$stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }

# Mismo contenido y mismo orden que build.sh.
# El documento de usuario es README.md en la raíz del repositorio; en el paquete va como LEEME.txt.
$files = @(foreach ($item in 'src', 'linux', 'native/bin', 'CreadorPeliculas.cmd', 'creador.sh', 'LEEME.txt', 'VERSION') {
    if ($item -eq 'LEEME.txt') { [pscustomobject]@{ File = Get-Item (Join-Path (Split-Path -Parent $here) 'README.md'); Rel = $item }; continue }
    $p = Join-Path $here $item
    $found = if (Test-Path $p -PathType Leaf) { Get-Item $p } else { Get-ChildItem $p -Recurse -File }
    $list = [Collections.Generic.List[object]]::new()
    foreach ($f in $found) {
        if ($f.FullName -match '\\__pycache__\\' -or $f.Extension -in '.pyc', '.lib', '.exp', '.pdb') { continue }
        $list.Add([pscustomobject]@{ File = $f; Rel = $f.FullName.Substring($here.Length + 1).Replace('\', '/') })
    }
    $list.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Rel, $b.Rel) })
    $list
})

foreach ($f in $files) {
    $dst = Join-Path $stage $f.Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item $f.File.FullName $dst
}

# El "version made by" del directorio central queda en Unix (3) para que unzip, bsdtar,
# Ark, etc. respeten los permisos; Windows ignora ese byte.
function Set-ZipUnixHost([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge [Math]::Max(0, $b.Length - 65557); $i--) {
        if ([BitConverter]::ToUInt32($b, $i) -eq 0x06054b50) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw "No se encontró el directorio central de $Path." }
    $count = [BitConverter]::ToUInt16($b, $eocd + 10)
    $pos = [int][BitConverter]::ToUInt32($b, $eocd + 16)
    for ($n = 0; $n -lt $count; $n++) {
        if ([BitConverter]::ToUInt32($b, $pos) -ne 0x02014b50) { throw "Directorio central inválido en $Path." }
        $b[$pos + 5] = 3
        $pos += 46 + [BitConverter]::ToUInt16($b, $pos + 28) + [BitConverter]::ToUInt16($b, $pos + 30) + [BitConverter]::ToUInt16($b, $pos + 32)
    }
    [IO.File]::WriteAllBytes($Path, $b)
}

$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in $files) {
        $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.File.FullName, "$name/$($f.Rel)", 'Optimal')
        $mode = if ($f.Rel.EndsWith('.sh')) { 0x81ED } else { 0x81A4 }   # 0100755 / 0100644
        $entry.ExternalAttributes = $mode -shl 16
    }
} finally { $archive.Dispose() }
Set-ZipUnixHost $zip

# Verificación: rutas con '/' y creador.sh ejecutable.
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $bad = @($archive.Entries | Where-Object { $_.FullName.Contains('\') })
    if ($bad) { throw "El ZIP tiene rutas con '\': $($bad[0].FullName)" }
    $sh = $archive.GetEntry("$name/creador.sh")
    if (-not $sh -or (($sh.ExternalAttributes -shr 16) -band 0xFFFF) -ne 0x81ED) { throw 'creador.sh no quedó ejecutable en el ZIP.' }
} finally { $archive.Dispose() }
Step ("Listo: {0} ({1:N1} MB, {2} archivos)" -f $zip, ((Get-Item $zip).Length / 1MB), $files.Count)
