# CreadorPeliculas.ps1 — punto de entrada de Creador de Películas 3D Runtime.
#
#   CreadorPeliculas.ps1                              abre la biblioteca (o el asistente si no hay nada instalado)
#   CreadorPeliculas.ps1 --install                    abre el asistente de instalación
#   CreadorPeliculas.ps1 --play <ID>                  abre el juego directamente (lo usan los accesos directos y Steam)
#   CreadorPeliculas.ps1 --play <ID> --file <.3MM>    abre una película (doble clic en un .3MM, si se asoció)
#
# Requiere Windows PowerShell 5.1 en modo STA (CreadorPeliculas.cmd ya lo invoca así).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# WinForms necesita STA: si no lo estamos, nos relanzamos.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath)) + $args
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList
    return
}

$here = $PSScriptRoot
try {
    Import-Module (Join-Path $here 'Core\CreadorPeliculas.Errors.psm1') -Force
    Import-Module (Join-Path $here 'Core\CreadorPeliculas.Core.psm1') -Force
    Import-Module (Join-Path $here 'Core\CreadorPeliculas.Sync.psm1') -Force
    Import-Module (Join-Path $here 'Core\CreadorPeliculas.Steam.psm1') -Force
    . (Join-Path $here 'UI\Theme.ps1')
    . (Join-Path $here 'UI\Dialogs.ps1')
    . (Join-Path $here 'UI\Sync.ps1')
    . (Join-Path $here 'UI\Steam.ps1')
    . (Join-Path $here 'UI\Wizard.ps1')
    . (Join-Path $here 'UI\Launcher.ps1')
    Import-CpStrings (Join-Path $here 'data\strings.es.json')
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "Faltan archivos de Creador de Películas 3D Runtime o están dañados. Volvé a descomprimir el programa completo.`r`n`r`nDetalle: $($_.Exception.Message)",
        'Creador de Películas 3D', 'OK', 'Error')
    exit 1
}

# Argumentos
$mode = 'auto'; $playId = $null; $playFile = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^--?play$' { $mode = 'play'; $playId = $args[$i + 1]; $i++ }
        '^--?install$' { $mode = 'install' }
        '^--?file$' { $playFile = $args[$i + 1]; $i++ }
    }
}

$config = Get-CpConfig
$logRoot = $(if ($config.installRoot) { Join-Path $config.installRoot 'logs' } else { Join-Path $env:LOCALAPPDATA 'CreadorPeliculas\logs' })
Initialize-CpLog $logRoot

# Si esta copia es más nueva que la instalada, se anota para que los accesos directos y Steam lo avisen.
if ($config.installRoot) {
    try { if (Register-CpRuntimeCopy -Config $config -Root $config.installRoot) { Save-CpConfig $config } }
    catch { Write-CpLog Warn "No se pudo anotar la versión de esta copia: $_" }
}

# Último recurso: cualquier error no previsto se muestra amigablemente.
trap {
    Write-CpLog Error "Error no controlado: $_`n$($_.ScriptStackTrace)"
    try { [void](Show-CpError $_) } catch { }
    exit 1
}

function Invoke-CpPlay {
    param([string]$Id, [string]$File)
    $cfg = Get-CpConfig
    if (-not $cfg.installRoot) { throw (New-CpError '3DM-RUN-006' @{ game = $Id }) }
    Invoke-CpRuntimeUpdateUI -Root $cfg.installRoot -Config $cfg -Quiet
    if (-not (Invoke-CpSyncBeforePlayUI -Id $Id -Root $cfg.installRoot -Config $cfg)) { return }
    $session = $null
    try {
        $session = Start-CpGame -Id $Id -Root $cfg.installRoot -Scale ([int]$cfg.scale) -Player (Get-CpPlayer $cfg) -File $File
    } catch {
        $action = Show-CpError $_
        if ($action -in @('locate', 'repair')) { Invoke-CpMain -Mode 'auto' }
        return
    }
    $diag = Complete-CpGame -Session $session
    Invoke-CpSyncAfterPlayUI -Id $Id -Root $cfg.installRoot -Config $cfg
    if ($diag) {
        $action = Show-CpError (Get-CpErrorInfo $diag)
        if ($action -eq 'repair') { Invoke-CpMain -Mode 'auto' }
    }
}

function Invoke-CpMain {
    param([string]$Mode)
    $openWizard = ($Mode -eq 'install')
    while ($true) {
        $cfg = Get-CpConfig
        $hasGames = $cfg.installRoot -and @(Get-CpInstalledGames -Root $cfg.installRoot).Count -gt 0
        if ($openWizard -or -not $hasGames) {
            $installed = Show-CpWizard -Config $cfg
            $openWizard = $false
            $cfg = Get-CpConfig
            $hasGames = $cfg.installRoot -and @(Get-CpInstalledGames -Root $cfg.installRoot).Count -gt 0
            if (-not $hasGames) { return }
            if ($cfg.installRoot) { Initialize-CpLog (Join-Path $cfg.installRoot 'logs') }
        }
        $r = Show-CpLauncher -Config $cfg
        if ($r -ne 'wizard') { return }
        $openWizard = $true
    }
}

switch ($mode) {
    'play' { Invoke-CpPlay -Id $playId -File $playFile }
    default { Invoke-CpMain -Mode $mode }
}
