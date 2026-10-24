# Theme.ps1 — estilo visual común de las ventanas de Creador de Películas 3D Runtime.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$global:CpTheme = @{
    Font       = New-Object System.Drawing.Font('Segoe UI', 10)
    FontSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
    FontBold   = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    FontBig    = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    Primary    = [System.Drawing.Color]::FromArgb(92, 52, 160)     # violeta McZee
    Secondary  = [System.Drawing.Color]::FromArgb(255, 196, 37)    # amarillo
    Accent     = [System.Drawing.Color]::FromArgb(45, 120, 210)    # azul
    Ok         = [System.Drawing.Color]::FromArgb(40, 150, 70)
    Warn       = [System.Drawing.Color]::FromArgb(200, 130, 0)
    Bad        = [System.Drawing.Color]::FromArgb(200, 40, 40)
    Back       = [System.Drawing.Color]::FromArgb(250, 248, 244)
    Card       = [System.Drawing.Color]::White
    Muted      = [System.Drawing.Color]::FromArgb(110, 110, 110)
}

function New-CpForm {
    param([string]$Title, [int]$Width = 760, [int]$Height = 560, [switch]$Resizable)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.ClientSize = New-Object System.Drawing.Size($Width, $Height)
    $f.StartPosition = 'CenterScreen'
    $f.Font = $global:CpTheme.Font
    $f.BackColor = $global:CpTheme.Back
    $f.AutoScaleMode = 'Dpi'
    if (-not $Resizable) { $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false }
    $iconPath = Join-Path $PSScriptRoot '..\data\creador.ico'
    if (Test-Path -LiteralPath $iconPath) { $f.Icon = New-Object System.Drawing.Icon($iconPath) }
    $f
}

function New-CpHeader {
    <# Franja superior de color con título y subtítulo. #>
    param([string]$Title, [string]$Subtitle)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Top'; $p.Height = 78; $p.BackColor = $global:CpTheme.Primary
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title; $t.Font = $global:CpTheme.FontTitle; $t.ForeColor = [System.Drawing.Color]::White
    $t.AutoSize = $true; $t.Location = New-Object System.Drawing.Point(20, 10)
    $s = New-Object System.Windows.Forms.Label
    $s.Text = $Subtitle; $s.ForeColor = [System.Drawing.Color]::FromArgb(255, 235, 200)
    $s.AutoSize = $true; $s.Location = New-Object System.Drawing.Point(22, 46)
    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Dock = 'Bottom'; $stripe.Height = 5; $stripe.BackColor = $global:CpTheme.Secondary
    $p.Controls.AddRange(@($t, $s, $stripe))
    $p | Add-Member -NotePropertyName TitleLabel -NotePropertyValue $t
    $p | Add-Member -NotePropertyName SubtitleLabel -NotePropertyValue $s
    $p
}

function New-CpButton {
    param([string]$Text, [int]$Width = 120, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 34
    $b.FlatStyle = 'Flat'; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor = $global:CpTheme.Primary; $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0; $b.Font = $global:CpTheme.FontBold
    } else {
        $b.BackColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    }
    $b
}

function New-CpLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [int]$Height = 0, $Font = $null, $Color = $null)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($Width -gt 0) { $l.Width = $Width; $l.AutoSize = $false; if ($Height -gt 0) { $l.Height = $Height } else { $l.Height = 24 } }
    else { $l.AutoSize = $true }
    if ($Font) { $l.Font = $Font }
    if ($Color) { $l.ForeColor = $Color }
    $l
}

function Get-CpGameIcon {
    <# Ícono del ejecutable original del juego (o $null). #>
    param([string]$Path, [int]$Size = 48)
    try {
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
            if ($ico) { return New-Object System.Drawing.Bitmap($ico.ToBitmap(), $Size, $Size) }
        }
    } catch { }
    $null
}
