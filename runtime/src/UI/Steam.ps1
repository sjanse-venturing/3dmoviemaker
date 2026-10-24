# Steam.ps1 — «Agregar a Steam»: el programa y sus opciones como accesos «no de Steam», para abrirlos
# desde Steam, Big Picture o Steam Link (mismo comportamiento que add_to_steam de linux/creador/ui.py).

function Invoke-CpAddToSteamUI {
    <# Agrega los accesos (cierra Steam un momento si está abierto). Devuelve $true si quedaron agregados. #>
    param([Parameter(Mandatory)][string]$Root, $Owner = $null)
    if (-not @(Get-CpSteamUserConfigDirs).Count) { [void](Show-CpError (Get-CpErrorInfo (New-CpError '3DM-STM-001')) $Owner); return $false }
    $running = Test-CpSteamRunning
    if ($running -and -not (Show-CpConfirm -Title '¿Cerrar Steam un momento?' -Message 'Para agregar el programa a Steam hay que cerrarlo. Lo volvemos a abrir enseguida.' -Yes 'Cerrar Steam y agregar' -No 'Cancelar' -Owner $Owner)) {
        return $false
    }
    while ($true) {
        $sync = Invoke-CpWithProgress -Title 'Agregando a Steam…' -Owner $Owner -Marquee -Arguments @{ root = $Root; running = $running } -Script {
            param($sync, $a)
            if ($a.running) {
                $sync.Message = 'Cerrando Steam…'
                if (-not (Stop-CpSteam)) { throw (New-CpError '3DM-STM-002') }
            }
            $sync.Message = 'Agregando los accesos y las imágenes…'
            $files = @(Add-CpToSteam -Root $a.root)
            if ($a.running) { $sync.Message = 'Abriendo Steam…'; Start-CpSteam }
            $files
        }
        if (-not $sync.Error) { break }
        if ((Show-CpError $sync.Error $Owner) -ne 'retry') { return $false }
    }
    Show-CpInfo -Title 'Listo' -Owner $Owner -Message ("3D Creador de Películas aparece en tu biblioteca de Steam (en «No de Steam», colección «Creador de Películas 3D»), con su portada. Podés abrirlo desde Big Picture o desde Steam Link en el celular o la TV." +
        "`r`n`r`nPara usarlo con el control, en Steam elegilo → Administrar → Configuración del control y usá la plantilla «Teclado y mouse» (o «Gamepad con mouse»). Para escribir títulos, Steam + X abre el teclado en pantalla.")
    $true
}
