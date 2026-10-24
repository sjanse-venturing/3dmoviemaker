# Launcher.ps1 — ventana principal de Creador de Películas 3D Runtime: abrir el programa, películas, opciones.

function Invoke-CpRuntimeUpdateUI {
    <#
      Si se descomprimió una versión nueva sin instalarla, los accesos directos y Steam siguen
      abriendo la vieja: ofrece actualizar la instalación. Con -Quiet (accesos directos y Steam) no
      vuelve a preguntar por una versión que el usuario ya rechazó.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Owner = $null, [switch]$Quiet)
    $old = Get-CpOutdatedInstall -Root $Root -Config $Config
    if (-not $old -or ($Quiet -and $old.Declined)) { return }
    $was = $(if ($old.Installed) { "la $($old.Installed)" } else { 'una anterior' })
    $remember = {
        if ($Config.newerCopy -is [Collections.IDictionary]) { $Config.newerCopy.declined = $true; Save-CpConfig $Config }
    }
    if (-not $old.SourceExists) {
        Show-CpInfo -Title 'Hay una versión más nueva' -Owner $Owner -Message ("Creador de Películas 3D $($old.Newer) se abrió desde «$($old.Source)», pero esa carpeta ya no está. " +
            'Para actualizar, descomprimí de nuevo esa versión, abrí su CreadorPeliculas.cmd y elegí «Actualizar».')
        Write-CpLog Warn "Instalación desactualizada ($was); la copia $($old.Newer) ya no está en $($old.Source)"
        & $remember
        return
    }
    $intro = $(if (Test-CpSamePath (Get-CpAppRoot) $old.Source) { "Estás usando Creador de Películas 3D $($old.Newer), pero la versión instalada es $was." }
        else { "Hay una versión más nueva de Creador de Películas 3D ($($old.Newer)) en «$($old.Source)», pero la instalada es $was." })
    $msg = "$intro Los accesos directos, el menú Inicio y Steam abren la versión instalada, así que ahí no vas a ver las correcciones nuevas.`r`n`r`n" +
        '¿Actualizar la instalación ahora? El programa y tus películas no se tocan.'
    if (-not (Show-CpConfirm -Title 'La versión instalada es más vieja' -Message $msg -Yes 'Actualizar' -No 'Seguir sin actualizar' -Owner $Owner)) {
        Write-CpLog Warn "Instalación desactualizada ($was, hay $($old.Newer) en $($old.Source)): el usuario eligió no actualizar"
        & $remember
        return
    }
    try {
        Install-CpRuntimeFiles -Root $Root -Source $old.Source | Out-Null
        Write-CpLog Info "Instalación actualizada a $($old.Newer) desde $($old.Source)"
        Show-CpInfo -Title 'Instalación actualizada' -Message "Creador de Películas 3D $($old.Newer) quedó instalado. Los accesos directos y Steam ya usan esta versión." -Owner $Owner
    } catch {
        [void](Show-CpError $_ $Owner)
    }
}

function Show-CpLauncher {
    param([Parameter(Mandatory)]$Config)

    $state = @{ session = $null; reopenWizard = $false; preselect = @(); versionChecked = $false }
    $form = New-CpForm -Title 'Creador de Películas 3D' -Width 1060 -Height 460 -Resizable
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $header = New-CpHeader -Title 'Creador de Películas 3D' -Subtitle 'Microsoft 3D Creador de Películas (1996) en Windows 10/11'
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.AutoScroll = $true; $flow.Padding = New-Object System.Windows.Forms.Padding(16)
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 56; $bottom.BackColor = [System.Drawing.Color]::FromArgb(238, 234, 226)
    $btnAdd = New-CpButton -Text 'Instalar…' -Width 150; $btnAdd.Location = New-Object System.Drawing.Point(16, 11)
    $btnSaves = New-CpButton -Text 'Películas ▾' -Width 110; $btnSaves.Location = New-Object System.Drawing.Point(174, 11)
    $btnSync = New-CpButton -Text 'Sincronización…' -Width 140; $btnSync.Location = New-Object System.Drawing.Point(292, 11)
    $btnSteam = New-CpButton -Text 'Agregar a Steam' -Width 140; $btnSteam.Location = New-Object System.Drawing.Point(440, 11)
    $btnOptions = New-CpButton -Text 'Opciones…' -Width 110; $btnOptions.Location = New-Object System.Drawing.Point(588, 11)
    $btnHelp = New-CpButton -Text 'Ayuda' -Width 90; $btnHelp.Location = New-Object System.Drawing.Point(706, 11)
    $btnLog = New-CpButton -Text 'Ver registro' -Width 110; $btnLog.Location = New-Object System.Drawing.Point(804, 11)
    $lblStatus = New-CpLabel -Text '' -X 926 -Y 19 -Width 120 -Color $global:CpTheme.Muted
    $lblStatus.AutoEllipsis = $true; $lblStatus.Anchor = 'Left,Right,Top'
    $bottom.Controls.AddRange(@($btnAdd, $btnSaves, $btnSync, $btnSteam, $btnOptions, $btnHelp, $btnLog, $lblStatus))
    $form.Controls.AddRange(@($flow, $bottom, $header))
    $tip = New-Object System.Windows.Forms.ToolTip

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRepair = $menu.Items.Add('Reparar')
    $miBackup = $menu.Items.Add('Copia de seguridad de las películas')
    $miImport = $menu.Items.Add('Importar películas…')
    $miFolder = $menu.Items.Add('Abrir la carpeta del programa')
    [void]$menu.Items.Add('-')
    $miUninstall = $menu.Items.Add('Desinstalar…')

    $savesMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miMovies = $savesMenu.Items.Add('Abrir «Mis películas»')
    $miExportAll = $savesMenu.Items.Add('Exportar las películas…')
    $miImportAll = $savesMenu.Items.Add('Importar películas…')
    [void]$savesMenu.Items.Add('-')
    $miSavesFolder = $savesMenu.Items.Add('Abrir la carpeta de copias')

    $root = $Config.installRoot

    $refresh = {
        $flow.SuspendLayout()
        $flow.Controls.Clear()
        $games = @(Get-CpInstalledGames -Root $root)
        if (-not $games.Count) {
            $empty = New-Object System.Windows.Forms.Panel
            $empty.Size = New-Object System.Drawing.Size(800, 200)
            $empty.Controls.Add((New-CpLabel -Text 'Todavía no está instalado.' -X 10 -Y 20 -Font $global:CpTheme.FontBig))
            $b = New-CpButton -Text 'Instalar' -Width 200 -Primary; $b.Location = New-Object System.Drawing.Point(10, 64)
            $b.Add_Click({ $state.reopenWizard = $true; $form.Close() })
            $empty.Controls.Add($b)
            $flow.Controls.Add($empty)
        }
        foreach ($g in $games) {
            $card = New-Object System.Windows.Forms.Panel
            $card.Size = New-Object System.Drawing.Size(300, 200); $card.Margin = New-Object System.Windows.Forms.Padding(8)
            $card.BackColor = $global:CpTheme.Card; $card.BorderStyle = 'FixedSingle'
            $pic = New-Object System.Windows.Forms.PictureBox
            $pic.Location = New-Object System.Drawing.Point(14, 14); $pic.Size = New-Object System.Drawing.Size(48, 48); $pic.SizeMode = 'Zoom'
            $img = Get-CpGameIcon -Path $g.Icon; if ($img) { $pic.Image = $img }
            $name = New-CpLabel -Text $g.Name -X 70 -Y 12 -Width 220 -Height 48 -Font $global:CpTheme.FontBold
            $age = New-CpLabel -Text $g.Age -X 70 -Y 62 -Width 220 -Color $global:CpTheme.Muted
            $mode = "Películas de «$(Get-CpPlayer $Config)»: $(@(Get-CpSaveFiles -Id $g.Id -Root $root).Count)"
            $st = New-CpLabel -Text $(if ($g.Healthy) { $mode } else { 'Instalación incompleta: usá «Reparar»' }) -X 14 -Y 96 -Width 275 -Font $global:CpTheme.FontSmall -Color $(if ($g.Healthy) { $global:CpTheme.Muted } else { $global:CpTheme.Bad })
            $play = New-CpButton -Text '▶  Crear películas' -Width 215 -Primary; $play.Location = New-Object System.Drawing.Point(14, 140); $play.Height = 40
            $play.Tag = $g.Id
            $more = New-CpButton -Text '···' -Width 56; $more.Location = New-Object System.Drawing.Point(233, 140); $more.Height = 40
            $more.Tag = $g.Id
            $play.Add_Click({ param($sender, $e) & $startGame $sender.Tag })
            $more.Add_Click({ param($sender, $e) $menu.Tag = $sender.Tag; $menu.Show($sender, 0, $sender.Height) })
            $card.Controls.AddRange(@($pic, $name, $age, $st, $play, $more))
            $flow.Controls.Add($card)
        }
        $flow.ResumeLayout()
        $lblStatus.Text = "Jugador: $(Get-CpPlayer $Config)"
        $tip.SetToolTip($lblStatus, $root + $(if (Test-CpSyncEnabled $Config) { "`r`nSincronización: " + $(if ($Config.sync.mode -eq 'folder') { $Config.sync.folder } else { 'Google Drive' }) } else { '' }))
    }

    $locateIso = {
        param([string]$Id)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Imagen de disco (*.iso)|*.iso'; $dlg.Title = "Buscá el disco de «$((Get-CpGame $Id).name)»"
        if ($dlg.ShowDialog($form) -ne 'OK') { return $false }
        $found = (Find-CpIsos -Folder (Split-Path -Parent $dlg.FileName)).Isos | Where-Object { $_.Path -eq $dlg.FileName -and $_.GameId -eq $Id -and $_.Status -eq 'ok' }
        if (-not $found) { [void](Show-CpError (Get-CpErrorInfo (New-CpError '3DM-ISO-002' @{ file = [IO.Path]::GetFileName($dlg.FileName) })) $form); return $false }
        $m = Get-CpManifest -Root $root; $m.games[$Id].isoPath = $dlg.FileName; Save-CpManifest -Root $root -Manifest $m
        $true
    }

    $repairGame = {
        param([string]$Id)
        $entry = (Get-CpManifest -Root $root).games[$Id]
        if (-not (Test-Path -LiteralPath $entry.isoPath)) {
            Show-CpInfo -Title 'Necesitamos el disco' -Message "Para reparar «$((Get-CpGame $Id).name)» necesitamos su archivo .iso. Indicanos dónde está." -Owner $form
            if (-not (& $locateIso $Id)) { return }
            $entry = (Get-CpManifest -Root $root).games[$Id]
        }
        $sync = Invoke-CpWithProgress -Title "Reparando «$((Get-CpGame $Id).name)»…" -Owner $form -Arguments @{ id = $Id; iso = $entry.isoPath; root = $root } -Script {
            param($sync, $a)
            Install-CpGame -Id $a.id -IsoPath $a.iso -Root $a.root -Repair -Cancel $sync -OnProgress { param($p, $m) $sync.Percent = $p; $sync.Message = $m }
        }
        if ($sync.Error) { [void](Show-CpError $sync.Error $form) } else { Show-CpInfo -Title 'Reparación terminada' -Message 'El programa se reparó correctamente. Tus películas no se modificaron.' -Owner $form }
        & $refresh
    }

    $startGame = {
        param([string]$Id)
        if (-not $state.versionChecked) { $state.versionChecked = $true; Invoke-CpRuntimeUpdateUI -Root $root -Config $Config -Owner $form }
        if (-not (Invoke-CpSyncBeforePlayUI -Id $Id -Root $root -Config $Config -Owner $form)) { return }
        $attempt = 0
        while ($attempt -lt 3) {
            $attempt++
            try {
                $state.session = Start-CpGame -Id $Id -Root $root -Scale ([int]$Config.scale) -Player (Get-CpPlayer $Config)
                $lblStatus.Text = "Abierto: $((Get-CpGame $Id).name)…"
                $form.WindowState = 'Minimized'
                $gameTimer.Start()
                return
            } catch {
                $info = Get-CpErrorInfo $_
                $action = Show-CpError $info $form
                if ($action -eq 'locate') { if (& $locateIso $Id) { continue } }
                elseif ($action -eq 'repair') { & $repairGame $Id; return }
                elseif ($action -eq 'retry') { continue }
                return
            }
        }
    }

    $gameTimer = New-Object System.Windows.Forms.Timer
    $gameTimer.Interval = 500
    $gameTimer.Add_Tick({
        $s = $state.session
        if (-not $s -or -not $s.Process.HasExited) { return }
        $gameTimer.Stop()
        $diag = Complete-CpGame -Session $s
        $state.session = $null
        $form.WindowState = 'Normal'; $form.Activate()
        Invoke-CpSyncAfterPlayUI -Id $s.Id -Root $root -Config $Config -Owner $form
        & $refresh
        if ($diag) {
            $action = Show-CpError (Get-CpErrorInfo $diag) $form
            if ($action -eq 'repair') { & $repairGame $s.Id }
        }
    })

    $miRepair.Add_Click({ & $repairGame $menu.Tag })
    $miFolder.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $root "games\$($menu.Tag)")) })
    $miBackup.Add_Click({
        try {
            $zip = Backup-CpSaves -Id $menu.Tag -Root $root
            if ($zip) { Show-CpInfo -Title 'Copia de seguridad lista' -Message "Las películas se guardaron en:`r`n$zip" -Owner $form }
            else { Show-CpInfo -Title 'No hay películas' -Message 'Todavía no guardaste ninguna película en «Mis películas».' -Owner $form }
        } catch { [void](Show-CpError $_ $form) }
    })
    $importSaves = {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Copias de películas (*.zip)|*.zip'; $dlg.Title = 'Elegí la copia de películas (.zip)'
        if (Test-Path -LiteralPath (Get-CpSavesFolder)) { $dlg.InitialDirectory = Get-CpSavesFolder }
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        try { $content = Read-CpSavesZip -Zip $dlg.FileName } catch { [void](Show-CpError $_ $form); return }
        $names = @(Get-CpCatalog | Where-Object { $content.Games.ContainsKey($_.id) } | ForEach-Object { $_.name }) -join ', '
        if (-not (Show-CpConfirm -Title '¿Importar estas películas?' -Message "Las películas que tengas ahora en «Mis películas» se reemplazan (antes guardamos una copia en «Creador de Películas 3D - copias»)." -Yes 'Importar' -No 'Cancelar' -Owner $form)) { return }
        try { $r = Import-CpSaves -Root $root -Zip $dlg.FileName } catch { [void](Show-CpError $_ $form); return }
        $lines = @(foreach ($id in $r.Imported.Keys) { '✔ {0}: {1} archivo(s)' -f (Get-CpGame $id).name, @($r.Imported[$id]).Count })
        $lines += @(foreach ($id in $r.Skipped.Keys) { '–  {0}: {1}' -f (Get-CpGame $id).name, $r.Skipped[$id] })
        Show-CpInfo -Title $(if ($r.Imported.Count) { 'Películas importadas' } else { 'No se importó nada' }) -Message ($lines -join "`r`n") -Owner $form
        & $refresh
    }
    $miImport.Add_Click({ & $importSaves })
    $miImportAll.Add_Click({ & $importSaves })
    $miExportAll.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '¿Dónde guardar las películas? (por ejemplo, un pendrive)'
        $folder = Get-CpSavesFolder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $dlg.SelectedPath = $folder
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        try {
            $zip = Export-CpAllSaves -Root $root -Destination $dlg.SelectedPath
            if ($zip) { Show-CpInfo -Title 'Películas exportadas' -Message "Las películas quedaron en:`r`n$zip`r`n`r`nCopiá ese archivo a la otra computadora (o al Steam Deck) y usá «Importar películas…»." -Owner $form }
            else { Show-CpInfo -Title 'No hay películas' -Message 'Todavía no guardaste ninguna película en «Mis películas».' -Owner $form }
        } catch { [void](Show-CpError $_ $form) }
    })
    $miSavesFolder.Add_Click({
        $folder = Get-CpSavesFolder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $folder)
    })
    $miMovies.Add_Click({
        $g = @(Get-CpInstalledGames -Root $root) | Select-Object -First 1
        if (-not $g) { return }
        $dir = Get-CpSavesDir -Id $g.Id -Root $root -Player (Get-CpPlayer $Config)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir)
    })
    $btnSaves.Add_Click({ $savesMenu.Show($btnSaves, (New-Object System.Drawing.Point(0, 0)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveRight) })
    $miUninstall.Add_Click({
        $id = $menu.Tag; $name = (Get-CpGame $id).name
        if (-not (Show-CpConfirm -Title "¿Desinstalar «$name»?" -Message 'Se borrarán los archivos del programa de esta computadora. Antes guardaremos una copia de tus películas en Documentos.' -Yes 'Desinstalar' -No 'Cancelar' -Owner $form)) { return }
        try {
            $zip = Uninstall-CpGame -Id $id -Root $root -KeepSaves
            $msg = $(if ($zip) { "Tus películas quedaron guardadas en:`r`n$zip" } else { 'No había películas para guardar.' })
            if (-not (Update-CpSteamShortcuts -Root $root)) { $msg += "`r`n`r`nSteam está abierto: cuando lo cierres, usá «Agregar a Steam» para quitarlo de la lista." }
            Show-CpInfo -Title 'Programa desinstalado' -Message $msg -Owner $form
        } catch { [void](Show-CpError $_ $form) }
        & $refresh
    })

    $btnAdd.Add_Click({ $state.reopenWizard = $true; $form.Close() })
    $btnSync.Add_Click({
        if ($state.session) { [void](Show-CpError (Get-CpErrorInfo (New-CpError '3DM-RUN-001')) $form); return }
        if (Show-CpSyncDialog -Config $Config -Root $root -Owner $form) { & $refresh }
    })
    $btnSteam.Add_Click({
        if (Invoke-CpAddToSteamUI -Root $root -Owner $form) { $Config.steamShortcuts = $true; Save-CpConfig $Config }
    })
    $btnHelp.Add_Click({
        $doc = Get-CpGuidePath -Root $root
        if ($doc) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $doc) }
    })
    $btnLog.Add_Click({
        $log = Get-CpLogFile
        if ($log -and (Test-Path -LiteralPath $log)) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $log) }
    })
    $btnOptions.Add_Click({
        $f = New-CpForm -Title 'Opciones' -Width 480 -Height 360
        $f.Controls.Add((New-CpLabel -Text 'Pantalla' -X 20 -Y 16 -Font $global:CpTheme.FontBold))
        $opts = @(@{ v = 0; t = 'Pantalla completa, ajustada (recomendado)' }, @{ v = 2; t = 'Pantalla completa, al doble exacto si entra' }, @{ v = 1; t = 'Ventana de 640×480 (como en 1996)' })
        $y = 48; $rbs = @()
        foreach ($o in $opts) {
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = $o.t; $rb.Tag = $o.v; $rb.Location = New-Object System.Drawing.Point(24, $y); $rb.Width = 400
            $rb.Checked = ([int]$Config.scale -eq $o.v); $f.Controls.Add($rb); $rbs += $rb; $y += 30
        }
        $f.Controls.Add((New-CpLabel -Text 'Nombre del jugador (carpeta de películas)' -X 20 -Y 148 -Width 440 -Font $global:CpTheme.FontBold))
        $txtPlayer = New-Object System.Windows.Forms.TextBox
        $txtPlayer.Location = New-Object System.Drawing.Point(24, 176); $txtPlayer.Width = 240; $txtPlayer.MaxLength = 24; $txtPlayer.Text = (Get-CpPlayer $Config)
        $f.Controls.Add($txtPlayer)
        $chkAssoc = New-Object System.Windows.Forms.CheckBox
        $chkAssoc.Text = 'Abrir las películas (.3MM) con doble clic'; $chkAssoc.Location = New-Object System.Drawing.Point(24, 220); $chkAssoc.Width = 420
        $chkAssoc.Checked = [bool]$Config.fileAssociation
        $f.Controls.Add($chkAssoc)
        $ok = New-CpButton -Text 'Guardar' -Primary; $ok.Location = New-Object System.Drawing.Point(336, 300); $ok.DialogResult = 'OK'
        $f.Controls.Add($ok); $f.AcceptButton = $ok
        if ($f.ShowDialog($form) -eq 'OK') {
            foreach ($rb in $rbs) { if ($rb.Checked) { $Config.scale = [int]$rb.Tag } }
            $name = $txtPlayer.Text.Trim()
            if (Test-CpPlayerName $name) { $Config.player = $name }
            else { [void](Show-CpError (Get-CpErrorInfo (New-CpError '3DM-CFG-002' @{ name = $name })) $form) }
            if ([bool]$Config.fileAssociation -ne $chkAssoc.Checked) {
                try { foreach ($g in @(Get-CpInstalledGames -Root $root)) { Set-CpFileAssociation -Id $g.Id -Root $root -Enabled $chkAssoc.Checked } ; $Config.fileAssociation = $chkAssoc.Checked }
                catch { [void](Show-CpError $_ $form) }
            }
            Save-CpConfig $Config
            & $refresh
        }
        $f.Dispose()
    })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($state.session) {
            Show-CpInfo -Title 'El programa está abierto' -Message 'Cerrá 3D Creador de Películas antes de salir de esta ventana.' -Owner $form
            $e.Cancel = $true
        }
    })
    $form.Add_Shown({ & $refresh })

    [void]$form.ShowDialog()
    $gameTimer.Dispose(); $form.Dispose()
    if ($state.reopenWizard) { return 'wizard' }
    'exit'
}
