# Dialogs.ps1 — diálogos amigables (error, confirmación, progreso en segundo plano).

function Get-CpExtraHeight {
    <# Cuánto más alto tiene que ser un texto de $Width píxeles que no entra en $Height (máximo 360). #>
    param([string]$Text, [int]$Width, [int]$Height)
    $size = [System.Windows.Forms.TextRenderer]::MeasureText([string]$Text, $global:CpTheme.Font, (New-Object System.Drawing.Size($Width, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    [Math]::Min(360, [Math]::Max(0, $size.Height + 8 - $Height))
}

function Show-CpError {
    <#
      Muestra un error en lenguaje simple, con detalles técnicos plegados y
      botones de acción. Devuelve la acción elegida ('retry', 'skip', ... o 'close').
    #>
    param([Parameter(Mandatory)]$ErrorObject, $Owner = $null)
    $info = $ErrorObject
    if (-not ($ErrorObject.PSObject.Properties.Name -contains 'Code' -and $ErrorObject.PSObject.Properties.Name -contains 'Details')) {
        $info = Get-CpErrorInfo $ErrorObject
    }
    Write-CpLog Error ("Se mostró al usuario {0}: {1}" -f $info.Code, $info.Message)

    $extra = Get-CpExtraHeight -Text $info.Message -Width 470 -Height 90
    $f = New-CpForm -Title 'Creador de Películas 3D' -Width 560 -Height (250 + $extra)
    $f.TopMost = $true
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Image = [System.Drawing.SystemIcons]::Warning.ToBitmap()
    $pic.Location = New-Object System.Drawing.Point(20, 22); $pic.Size = New-Object System.Drawing.Size(32, 32)
    $title = New-CpLabel -Text $info.Title -X 66 -Y 20 -Width 470 -Font $global:CpTheme.FontBig
    $msg = New-CpLabel -Text $info.Message -X 66 -Y 52 -Width 470 -Height (90 + $extra)
    $details = New-Object System.Windows.Forms.TextBox
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $details.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $details.Text = $info.Details -replace "`r?`n", "`r`n"
    $details.Location = New-Object System.Drawing.Point(20, (196 + $extra)); $details.Size = New-Object System.Drawing.Size(520, 160)
    $details.Visible = $false
    $f.Controls.AddRange(@($pic, $title, $msg, $details))

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.FlowDirection = 'RightToLeft'; $panel.Location = New-Object System.Drawing.Point(20, (150 + $extra))
    $panel.Size = New-Object System.Drawing.Size(520, 42)
    $f.Controls.Add($panel)

    $result = @{ action = 'close' }
    $close = New-CpButton -Text 'Cerrar' -Width 110 -Primary
    $close.Add_Click({ $result.action = 'close'; $f.Close() }.GetNewClosure())
    $panel.Controls.Add($close)
    foreach ($a in $info.Actions) {
        if ($a -eq 'close') { continue }
        $b = New-CpButton -Text (Get-CpActionLabel $a) -Width 150
        $act = $a
        if ($a -eq 'details') {
            $b.Add_Click({
                $details.Visible = -not $details.Visible
                $f.ClientSize = New-Object System.Drawing.Size(560, ($extra + $(if ($details.Visible) { 370 } else { 250 })))
            }.GetNewClosure())
        } elseif ($a -eq 'copy') {
            $b.Add_Click({ [System.Windows.Forms.Clipboard]::SetText((Get-CpReport $info)); $b.Text = 'Copiado ✓' }.GetNewClosure())
        } else {
            $b.Add_Click({ $result.action = $act; $f.Close() }.GetNewClosure())
        }
        $panel.Controls.Add($b)
    }
    if ($info.Actions -notcontains 'copy') {
        $cp = New-CpButton -Text 'Copiar informe' -Width 130
        $cp.Add_Click({ [System.Windows.Forms.Clipboard]::SetText((Get-CpReport $info)); $cp.Text = 'Copiado ✓' }.GetNewClosure())
        $panel.Controls.Add($cp)
    }
    $f.AcceptButton = $close
    [void]$f.ShowDialog($Owner)
    $f.Dispose()
    $result.action
}

function Show-CpConfirm {
    param([string]$Title, [string]$Message, [string]$Yes = 'Sí', [string]$No = 'No', $Owner = $null)
    $extra = Get-CpExtraHeight -Text $Message -Width 460 -Height 80
    $f = New-CpForm -Title 'Creador de Películas 3D' -Width 500 -Height (200 + $extra)
    $t = New-CpLabel -Text $Title -X 20 -Y 18 -Width 460 -Font $global:CpTheme.FontBig
    $m = New-CpLabel -Text $Message -X 20 -Y 52 -Width 460 -Height (80 + $extra)
    $by = New-CpButton -Text $Yes -Width 140 -Primary; $by.Location = New-Object System.Drawing.Point(340, (145 + $extra))
    $bn = New-CpButton -Text $No -Width 160; $bn.Location = New-Object System.Drawing.Point(170, (145 + $extra))
    $by.DialogResult = 'Yes'; $bn.DialogResult = 'No'
    $f.Controls.AddRange(@($t, $m, $by, $bn)); $f.AcceptButton = $by; $f.CancelButton = $bn
    $r = $f.ShowDialog($Owner); $f.Dispose()
    $r -eq 'Yes'
}

function Show-CpInfo {
    param([string]$Title, [string]$Message, $Owner = $null)
    $extra = Get-CpExtraHeight -Text $Message -Width 460 -Height 80
    $f = New-CpForm -Title 'Creador de Películas 3D' -Width 500 -Height (190 + $extra)
    $t = New-CpLabel -Text $Title -X 20 -Y 18 -Width 460 -Font $global:CpTheme.FontBig
    $m = New-CpLabel -Text $Message -X 20 -Y 52 -Width 460 -Height (80 + $extra)
    $ok = New-CpButton -Text 'Aceptar' -Width 120 -Primary; $ok.Location = New-Object System.Drawing.Point(360, (140 + $extra)); $ok.DialogResult = 'OK'
    $f.Controls.AddRange(@($t, $m, $ok)); $f.AcceptButton = $ok
    [void]$f.ShowDialog($Owner); $f.Dispose()
}

function Start-CpBackground {
    <#
      Ejecuta $Script en otro runspace (con los módulos del programa cargados) para
      no congelar la ventana. $Script recibe ($Sync, $Arguments). $Sync es un
      hashtable sincronizado con: Percent, Message, Done, Error, Result, Cancel.
    #>
    param([Parameter(Mandatory)][scriptblock]$Script, $Arguments = $null)
    $sync = [hashtable]::Synchronized(@{ Percent = 0; Message = ''; Done = $false; Error = $null; Result = $null; Cancel = $false; Lines = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)) })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $core = Join-Path $PSScriptRoot '..\Core'
    $strings = Join-Path $PSScriptRoot '..\data\strings.es.json'
    $logFile = Get-CpLogFile
    [void]$ps.AddScript({
        param($core, $strings, $logFile, $sync, $body, $arguments)
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module (Join-Path $core 'CreadorPeliculas.Errors.psm1')
            Import-Module (Join-Path $core 'CreadorPeliculas.Core.psm1')
            Import-Module (Join-Path $core 'CreadorPeliculas.Sync.psm1')
            Import-Module (Join-Path $core 'CreadorPeliculas.Steam.psm1')
            Import-CpStrings $strings
            if ($logFile) { Initialize-CpLog (Split-Path -Parent $logFile) }
            $sync.Result = & ([scriptblock]::Create($body)) $sync $arguments
        } catch {
            $sync.Error = Get-CpErrorInfo $_
        } finally { $sync.Done = $true }
    }).AddArgument($core).AddArgument($strings).AddArgument($logFile).AddArgument($sync).AddArgument($Script.ToString()).AddArgument($Arguments)
    $handle = $ps.BeginInvoke()
    $sync.PowerShell = $ps; $sync.Handle = $handle; $sync.Runspace = $rs
    $sync
}

function Stop-CpBackground {
    param($Sync)
    try { $Sync.PowerShell.EndInvoke($Sync.Handle) } catch { }
    try { $Sync.PowerShell.Dispose(); $Sync.Runspace.Dispose() } catch { }
}

function Invoke-CpWithProgress {
    <# Ventanita modal de progreso para tareas cortas (reparar, copia de seguridad...). Devuelve $Sync. #>
    param([string]$Title, [scriptblock]$Script, $Arguments, $Owner = $null, [switch]$Marquee)
    $f = New-CpForm -Title 'Creador de Películas 3D' -Width 460 -Height 140
    $f.ControlBox = $false
    $l = New-CpLabel -Text $Title -X 20 -Y 18 -Width 420
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(20, 52); $bar.Size = New-Object System.Drawing.Size(420, 22)
    if ($Marquee) { $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30 }
    $sub = New-CpLabel -Text '' -X 20 -Y 84 -Width 420 -Font $global:CpTheme.FontSmall -Color $global:CpTheme.Muted
    $f.Controls.AddRange(@($l, $bar, $sub))
    $sync = Start-CpBackground -Script $Script -Arguments $Arguments
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 150
    $timer.Add_Tick({
        if (-not $Marquee) { $bar.Value = [Math]::Max(0, [Math]::Min(100, [int]$sync.Percent)) }; $sub.Text = $sync.Message
        if ($sync.Done) { $timer.Stop(); $f.Close() }
    }.GetNewClosure())
    $f.Add_Shown({ $timer.Start() }.GetNewClosure())
    [void]$f.ShowDialog($Owner)
    $timer.Dispose(); $f.Dispose()
    Stop-CpBackground $sync
    $sync
}
