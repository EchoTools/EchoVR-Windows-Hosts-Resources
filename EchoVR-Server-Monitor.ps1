###################################################################
# Code by marshmallow_mia and now mostly berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# Changes 
# v2.1.0 - Fixed python & library auto-install when downloading stat tracker (uses v-env).
# v2.0.0 - Added Stat Tracker integration. Moved Startup/AutoUpdate options to Config GUI.
# v1.1.1 - Added Restore Defaults button, single link code enforcement, Discord redirect on link code.
# v1.1.0 - Removed PS7 dialogue. Added pause spawning option, uptime tracking, unlinked session detection.

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "2.1.0"
$Global:GithubOwner = "EchoTools"
$Global:GithubRepo  = "EchoVR-Windows-Hosts-Resources"
$Global:NotifiedPids = @{}
$Global:LinkCodeActive = $false
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# 0. MODE DETECTION, PS7 CHECK, SINGLE INSTANCE CHECK
# ==============================================================================

# Detect if running as a compiled .exe or a raw .ps1 script
$CurrentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$ProcessName = $CurrentProcess.ProcessName

if ($ProcessName -eq "pwsh" -or $ProcessName -eq "powershell" -or $ProcessName -eq "powershell_ise") {
    $Global:IsBinary = $false
    $Global:ExecutionPath = $MyInvocation.MyCommand.Definition
} else {
    $Global:IsBinary = $true
    $Global:ExecutionPath = $CurrentProcess.MainModule.FileName
}

# If running as a script (not compiled), ensure PowerShell 7 is present
if (-not $Global:IsBinary -and $PSVersionTable.PSVersion.Major -lt 7) {
        try {
            Start-Process -FilePath "winget" -ArgumentList "install --id Microsoft.PowerShell --source winget" -Wait -Verb RunAs
            [System.Windows.Forms.MessageBox]::Show("PowerShell 7 installed. Please restart this script using PowerShell 7 (pwsh).", "Install Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            Exit
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not launch Winget. Please install PowerShell 7 manually.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            Exit
    }
}

$mutexName = "EchoVRServerMonitor_Mutex_Global"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show("The Server Monitor is already running.", "Monitor Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Exit
}

# ==============================================================================
# 1. INITIAL SETUP & PATHS
# ==============================================================================

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { 
    $ScriptRoot = [System.IO.Path]::GetDirectoryName($Global:ExecutionPath) 
}

$EchoProcessName = "echovr"
$EchoExePath = Join-Path $ScriptRoot "bin\win10\echovr.exe"
$DashboardDir = Join-Path $ScriptRoot "dashboard"
$SetupFile = Join-Path $DashboardDir "setup.json"
$MonitorFile = Join-Path $DashboardDir "monitor.json"
$NetConfigPath = Join-Path $ScriptRoot "sourcedb\rad15\json\r14\config\netconfig_dedicatedserver.json"
$LocalConfigPath = Join-Path $ScriptRoot "_local\config.json"
$LogPath = Join-Path $ScriptRoot "_local\r14logs"

# Stat Tracker Filename determination
$StatTrackerName = if ($Global:IsBinary) { "EchoVR-Server-Stat-Tracker.exe" } else { "EchoVR-Server-Stat-Tracker.py" }
$StatTrackerPath = Join-Path $ScriptRoot $StatTrackerName
$VenvPath = Join-Path $ScriptRoot "_local\venv_tracker"

# Known errors
$Global:ErrorList = @(
    "Unable to find MiniDumpWriteDump",
    "[NETGAME] Service status request failed: 400 Bad Request",
    "[NETGAME] Service status request failed: 404 Not Found",
    "[TCP CLIENT] [R14NETCLIENT] connection to ws:///login",
    "[TCP CLIENT] [R14NETCLIENT] connection to failed",
    "[TCP CLIENT] [R14NETCLIENT] connection to established", 
    "[TCP CLIENT] [R14NETCLIENT] connection to restored",
    "[TCP CLIENT] [R14NETCLIENT] connection to closed",
    "[TCP CLIENT] [R14NETCLIENT] Lost connection (okay) to peer",
    "[NETGAME] Service status request failed: 502 Bad Gateway",
    "[NETGAME] Service status request failed: 0 Unknown"
)

$StartupFolder = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupFolder "EchoVR Server Monitor.lnk"

# ==============================================================================
# 2. STARTUP CHECKS
# ==============================================================================

if (-not (Test-Path $EchoExePath)) {
    [System.Windows.Forms.MessageBox]::Show("Error: 'bin\win10\echovr.exe' not found.`nPlace this program in the root ready-at-dawn-echo-arena folder.", "Fatal Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Exit
}

if (-not (Test-Path $DashboardDir)) { New-Item -ItemType Directory -Path $DashboardDir -Force | Out-Null }

# ==============================================================================
# 3. CONFIGURATION MANAGEMENT
# ==============================================================================

Function Get-MonitorConfig {
    if (-not (Test-Path $MonitorFile)) {
        $defaultConfig = @{
            amountOfInstances = 1
            delayExiting = 2000
            delayProcessCheck = 5000
            delayKillStuck = 20000
            numTaskThreads = 2
            timeStep = 120
            additionalArgs = "-server -headless -noovr -fixedtimestep -nosymbollookup"
            suppressSetupWarning = $false
            autoUpdate = $true
            pauseSpawning = $false
        }
        if (Test-Path $SetupFile) {
            $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
            if ($dashData.numInstances) { $defaultConfig.amountOfInstances = $dashData.numInstances }
        }
        $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content $MonitorFile
        return $defaultConfig
    }
    
    # Ensure properties exist for older configs
    $config = Get-Content $MonitorFile -Raw | ConvertFrom-Json
    $saveNeeded = $false

    if ($null -eq $config.autoUpdate) {
        $config | Add-Member -MemberType NoteProperty -Name "autoUpdate" -Value $true
        $saveNeeded = $true
    }
    if ($null -eq $config.pauseSpawning) {
        $config | Add-Member -MemberType NoteProperty -Name "pauseSpawning" -Value $false
        $saveNeeded = $true
    }

    if ($saveNeeded) { Save-MonitorConfig $config }
    return $config
}

Function Save-MonitorConfig ($configObj) {
    $configObj | ConvertTo-Json -Depth 4 | Set-Content $MonitorFile
}

Function Update-ExternalConfigs ($numInstances) {
    if (Test-Path $SetupFile) {
        $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
        $dashData.numInstances = [int]$numInstances
        $dashData.upperPortRange = 6792 + [int]$numInstances
        $dashData | ConvertTo-Json -Depth 4 | Set-Content $SetupFile
    }
    if (Test-Path $NetConfigPath) {
        try {
            $netData = Get-Content $NetConfigPath -Raw | ConvertFrom-Json
            $netData.retries = [int]$numInstances + 1
            $netData | ConvertTo-Json -Depth 4 | Set-Content $NetConfigPath
        } catch {}
    }
}

Function Switch-StartupShortcut ($enable) {
    if ($enable) {
        try {
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
            
            if ($Global:IsBinary) {
                $Shortcut.TargetPath = $Global:ExecutionPath
                $Shortcut.WorkingDirectory = $ScriptRoot
                $Shortcut.Arguments = "" 
            } else {
                $exe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
                $Shortcut.TargetPath = $exe
                $Shortcut.Arguments = "-WindowStyle Hidden -File `"$Global:ExecutionPath`""
                $Shortcut.WorkingDirectory = $ScriptRoot
            }
            
            if (Test-Path $EchoExePath) {
                $Shortcut.IconLocation = $EchoExePath
            }
            
            $Shortcut.Save()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to create startup shortcut.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } else {
        if (Test-Path $ShortcutPath) {
            Remove-Item $ShortcutPath -Force
        }
    }
}

# ==============================================================================
# 4. GUI: CONFIGURATION WINDOW
# ==============================================================================

Function Show-ConfigWindow {
    $monitorData = Get-MonitorConfig
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Server Monitor Configuration"
    $form.Size = New-Object System.Drawing.Size(435, 600)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    [int]$y = 20
    [int]$pad = 30

    # --- Instances ---
    $lblInst = New-Object System.Windows.Forms.Label
    $lblInst.Text = "Number of Instances:"
    $lblInst.Location = New-Object System.Drawing.Point(20, $y)
    $lblInst.AutoSize = $true
    $form.Controls.Add($lblInst)

    $txtInst = New-Object System.Windows.Forms.TextBox
    $txtInst.Location = New-Object System.Drawing.Point(250, ($y - 3))
    $txtInst.Text = "$($monitorData.amountOfInstances)"
    $form.Controls.Add($txtInst)
    
    $y += $pad
    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Default delay values can usually be left alone." 
    $lblNote.Location = New-Object System.Drawing.Point(20, $y)
    $lblNote.ForeColor = [System.Drawing.Color]::Gray
    $lblNote.AutoSize = $true
    $form.Controls.Add($lblNote)

    # --- Delays ---
    $y += $pad
    $lblExit = New-Object System.Windows.Forms.Label
    $lblExit.Text = "Delay Exiting (ms):"
    $lblExit.Location = New-Object System.Drawing.Point(20, $y)
    $lblExit.AutoSize = $true
    $form.Controls.Add($lblExit)

    $txtExit = New-Object System.Windows.Forms.TextBox
    $txtExit.Location = New-Object System.Drawing.Point(250, ($y - 3))
    $txtExit.Text = "$($monitorData.delayExiting)"
    $form.Controls.Add($txtExit)

    $y += $pad
    $lblCheck = New-Object System.Windows.Forms.Label
    $lblCheck.Text = "Delay Process Check (ms):"
    $lblCheck.Location = New-Object System.Drawing.Point(20, $y)
    $lblCheck.AutoSize = $true
    $form.Controls.Add($lblCheck)

    $txtCheck = New-Object System.Windows.Forms.TextBox
    $txtCheck.Location = New-Object System.Drawing.Point(250, ($y - 3))
    $txtCheck.Text = "$($monitorData.delayProcessCheck)"
    $form.Controls.Add($txtCheck)

    $y += $pad
    $lblKill = New-Object System.Windows.Forms.Label
    $lblKill.Text = "Delay Kill if Stuck (ms):"
    $lblKill.Location = New-Object System.Drawing.Point(20, $y)
    $lblKill.AutoSize = $true
    $form.Controls.Add($lblKill)

    $txtKill = New-Object System.Windows.Forms.TextBox
    $txtKill.Location = New-Object System.Drawing.Point(250, ($y - 3))
    $txtKill.Text = "$($monitorData.delayKillStuck)"
    $form.Controls.Add($txtKill)

    # --- Advanced Section ---
    $y += 40
    $chkAdv = New-Object System.Windows.Forms.CheckBox
    $chkAdv.Text = "Allow Advanced Configuration"
    $chkAdv.Location = New-Object System.Drawing.Point(20, $y)
    $chkAdv.AutoSize = $true
    $form.Controls.Add($chkAdv)

    $grpAdv = New-Object System.Windows.Forms.GroupBox
    $grpAdv.Text = "Advanced Settings"
    $grpAdv.Location = New-Object System.Drawing.Point(20, ($y + 25))
    $grpAdv.Size = New-Object System.Drawing.Size(390, 150)
    $grpAdv.Enabled = $false
    $form.Controls.Add($grpAdv)

    $chkAdv.Add_CheckedChanged({ $grpAdv.Enabled = $chkAdv.Checked })

    # Threads
    $lblThreads = New-Object System.Windows.Forms.Label
    $lblThreads.Text = "Num Task Threads:"
    $lblThreads.Location = New-Object System.Drawing.Point(15, 30)
    $lblThreads.AutoSize = $true
    $grpAdv.Controls.Add($lblThreads)

    $txtThreads = New-Object System.Windows.Forms.TextBox
    $txtThreads.Location = New-Object System.Drawing.Point(150, 27)
    $txtThreads.Text = "$($monitorData.numTaskThreads)"
    $txtThreads.Size = New-Object System.Drawing.Size(50, 20)
    $grpAdv.Controls.Add($txtThreads)

    $lblThreadWarn = New-Object System.Windows.Forms.Label
    $lblThreadWarn.Text = "Warning: High CPU Usage"
    $lblThreadWarn.Location = New-Object System.Drawing.Point(210, 30)
    $lblThreadWarn.ForeColor = [System.Drawing.Color]::Red
    $lblThreadWarn.AutoSize = $true
    $lblThreadWarn.Visible = $false
    $grpAdv.Controls.Add($lblThreadWarn)

    $checkThreadWarn = {
        $val = 0
        if ([int]::TryParse($txtThreads.Text, [ref]$val) -and $val -ge 6) {
            $lblThreadWarn.Visible = $true
        } else {
            $lblThreadWarn.Visible = $false
        }
    }
    $txtThreads.Add_TextChanged($checkThreadWarn)
    & $checkThreadWarn

    # Timestep
    $lblTime = New-Object System.Windows.Forms.Label
    $lblTime.Text = "Timestep:"
    $lblTime.Location = New-Object System.Drawing.Point(15, 65)
    $lblTime.AutoSize = $true
    $grpAdv.Controls.Add($lblTime)

    $rbStd = New-Object System.Windows.Forms.RadioButton
    $rbStd.Text = "Standard (120)"
    $rbStd.Location = New-Object System.Drawing.Point(150, 63)
    $rbStd.AutoSize = $true
    $grpAdv.Controls.Add($rbStd)

    $rbComp = New-Object System.Windows.Forms.RadioButton
    $rbComp.Text = "Competitive (180)"
    $rbComp.Location = New-Object System.Drawing.Point(260, 63)
    $rbComp.AutoSize = $true
    $grpAdv.Controls.Add($rbComp)

    if ($monitorData.timeStep -eq 180) { $rbComp.Checked = $true } else { $rbStd.Checked = $true }

    # Args
    $lblArgs = New-Object System.Windows.Forms.Label
    $lblArgs.Text = "Additional Args:"
    $lblArgs.Location = New-Object System.Drawing.Point(15, 100)
    $lblArgs.AutoSize = $true
    $grpAdv.Controls.Add($lblArgs)

    $txtArgs = New-Object System.Windows.Forms.TextBox
    $txtArgs.Location = New-Object System.Drawing.Point(15, 120)
    $txtArgs.Size = New-Object System.Drawing.Size(360, 20)
    $txtArgs.Text = "$($monitorData.additionalArgs)"
    $grpAdv.Controls.Add($txtArgs)

    # --- New Config Options (Moved from Tray) ---
    $y += 190

    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = "Start with Windows"
    $chkStartup.Location = New-Object System.Drawing.Point(25, $y)
    $chkStartup.AutoSize = $true
    $chkStartup.Checked = (Test-Path $ShortcutPath)
    $form.Controls.Add($chkStartup)

    $y += 25
    $chkAutoUpdate = New-Object System.Windows.Forms.CheckBox
    $chkAutoUpdate.Text = "Enable Auto-Update"
    $chkAutoUpdate.Location = New-Object System.Drawing.Point(25, $y)
    $chkAutoUpdate.AutoSize = $true
    $chkAutoUpdate.Checked = $monitorData.autoUpdate
    $form.Controls.Add($chkAutoUpdate)

    # --- Bottom Buttons ---
    $y += 35
    $btnOpenLocal = New-Object System.Windows.Forms.Button
    $btnOpenLocal.Text = "Open Server Config"
    $btnOpenLocal.Location = New-Object System.Drawing.Point(20, $y)
    $btnOpenLocal.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenLocal.Add_Click({ Invoke-Item $LocalConfigPath })
    $form.Controls.Add($btnOpenLocal)

    $btnOpenNet = New-Object System.Windows.Forms.Button
    $btnOpenNet.Text = "Open Net Config"
    $btnOpenNet.Location = New-Object System.Drawing.Point(210, $y)
    $btnOpenNet.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenNet.Add_Click({ Invoke-Item $NetConfigPath })
    $form.Controls.Add($btnOpenNet)

    $y += 40
    
    # Save Button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(70, $y)
    $btnSave.Size = New-Object System.Drawing.Size(80, 25)
    $btnSave.Add_Click({
        if ([int]$txtInst.Text -lt 1) {
            [System.Windows.Forms.MessageBox]::Show("Number of instances must be at least 1.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            $txtInst.Focus()
        } else {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })
    $form.Controls.Add($btnSave)

    # Restore Defaults Button
    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Defaults"
    $btnRestore.Location = New-Object System.Drawing.Point(165, $y)
    $btnRestore.Size = New-Object System.Drawing.Size(80, 25)
    $btnRestore.Add_Click({
        # Reset UI to default values without saving yet
        $txtInst.Text = "1"
        $txtExit.Text = "2000"
        $txtCheck.Text = "5000"
        $txtKill.Text = "20000"
        $txtThreads.Text = "2"
        $rbStd.Checked = $true
        $txtArgs.Text = "-server -headless -noovr -fixedtimestep -nosymbollookup"
        $chkStartup.Checked = $true
        $chkAutoUpdate.Checked = $true
    })
    $form.Controls.Add($btnRestore)

    # Cancel Button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Discard"
    $btnCancel.Location = New-Object System.Drawing.Point(260, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 25)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    # --- Version Label at Bottom ---
    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "v$($Global:Version)"
    $lblVersion.AutoSize = $false
    $lblVersion.Size = New-Object System.Drawing.Size(435, 20) 
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblVersion.ForeColor = [System.Drawing.Color]::Silver
    $lblVersion.Location = New-Object System.Drawing.Point(0, ($y + 35)) 
    $form.Controls.Add($lblVersion)

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        # Validations
        $numInst = [int]$txtInst.Text
        $tStep = if ($rbComp.Checked) { 180 } else { 120 }
        
        $monitorData.amountOfInstances = $numInst
        $monitorData.delayExiting = [int]$txtExit.Text
        $monitorData.delayProcessCheck = [int]$txtCheck.Text
        $monitorData.delayKillStuck = [int]$txtKill.Text
        $monitorData.numTaskThreads = [int]$txtThreads.Text
        $monitorData.timeStep = $tStep
        $monitorData.additionalArgs = $txtArgs.Text
        $monitorData.autoUpdate = $chkAutoUpdate.Checked

        # Handle Startup Shortcut immediately
        Switch-StartupShortcut $chkStartup.Checked

        Save-MonitorConfig $monitorData
        Update-ExternalConfigs $numInst
        
        [System.Windows.Forms.MessageBox]::Show("Configuration Saved.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# ==============================================================================
# 5. STAT TRACKER LOGIC
# ==============================================================================

Function Get-StatTracker {
    $url = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        
        $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        $targetAsset = $response.assets | Where-Object { $_.name -eq $StatTrackerName } | Select-Object -First 1

        if (-not $targetAsset) { 
            [System.Windows.Forms.MessageBox]::Show("Could not find $StatTrackerName in the latest release.", "Download Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return 
        }

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $targetAsset.browser_download_url -OutFile $StatTrackerPath
        
        [System.Windows.Forms.MessageBox]::Show("Stat Tracker downloaded successfully!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        
        # --- Dependency Check for Python Version ---
        if (-not $Global:IsBinary) {
            $pyInstalled = (Get-Command "python" -ErrorAction SilentlyContinue)
            $libsInstalled = $true
            
            if ($pyInstalled) {
                # Check for libraries
                try {
                    $testProc = Start-Process -FilePath "python" -ArgumentList "-c `"import customtkinter, requests, matplotlib`"" -PassThru -WindowStyle Hidden -Wait
                    if ($testProc.ExitCode -ne 0) { $libsInstalled = $false }
                } catch { $libsInstalled = $false }
            }

            if (-not $pyInstalled -or -not $libsInstalled) {
                $dialogResult = [System.Windows.Forms.MessageBox]::Show(
                    "Python is missing or required libraries (customtkinter, requests, matplotlib) are not installed.`n`nDo you want to automatically install them now?", 
                    "Missing Dependencies", 
                    [System.Windows.Forms.MessageBoxButtons]::OKCancel, 
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )

                if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
                    # Create a temporary setup script
                    $setupScriptBlock = @"
Write-Host "Installing Python 3.13 via Winget..." -ForegroundColor Cyan
winget install -e --id Python.Python.3.13 --silent --accept-package-agreements --source winget

Write-Host "Setting up Virtual Environment..." -ForegroundColor Cyan
# Refresh env to find python if just installed
`$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$Global:VenvPath = "$VenvPath"

if (Test-Path `$Global:VenvPath) { Remove-Item `$Global:VenvPath -Recurse -Force }
python -m venv `$Global:VenvPath

Write-Host "Installing Libraries to Virtual Environment..." -ForegroundColor Cyan
& "`$Global:VenvPath\Scripts\pip" install customtkinter requests matplotlib

Write-Host "Installation Complete. You may close this window." -ForegroundColor Green
Start-Sleep -Seconds 3
exit
"@
                    $setupFile = Join-Path $ScriptRoot "setup_tracker.ps1"
                    Set-Content -Path $setupFile -Value $setupScriptBlock
                    
                    Start-Process -FilePath "pwsh" -ArgumentList "-Command & '$setupFile'"
                }
            }
        }

    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to download Stat Tracker: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
}

# ==============================================================================
# 6. SYSTEM TRAY & MENU
# ==============================================================================

$ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip

# 1. STATUS ITEM
$MenuItemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemStatus.Text = "Status: Initializing..."
$MenuItemStatus.Enabled = $false
$ContextMenuStrip.Items.Add($MenuItemStatus) | Out-Null

# 2. SEPARATOR (Marks end of dynamic list)
$MenuItemSeparator1 = New-Object System.Windows.Forms.ToolStripSeparator
$ContextMenuStrip.Items.Add($MenuItemSeparator1) | Out-Null

# 3. CONFIG
$MenuItemConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemConfig.Text = "Edit Monitor Configuration"
$MenuItemConfig.Add_Click({ 
    $MonitorTimer.Stop()
    Show-ConfigWindow 
    $MonitorTimer.Start()
})
$ContextMenuStrip.Items.Add($MenuItemConfig) | Out-Null

# 4. STAT TRACKER (Dynamic)
$MenuItemStatTracker = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemStatTracker.Text = "Checking for Stat Tracker..."
$MenuItemStatTracker.Add_Click({
    if (Test-Path $StatTrackerPath) {
        # Launch Logic
        try {
            if ($Global:IsBinary) {
                Start-Process -FilePath $StatTrackerPath
            } else {
                # Check for venv python first
                $venvPython = Join-Path $VenvPath "Scripts\python.exe"
                if (Test-Path $venvPython) {
                    Start-Process -FilePath $venvPython -ArgumentList "`"$StatTrackerPath`""
                } else {
                    Start-Process -FilePath "python" -ArgumentList "`"$StatTrackerPath`""
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to launch Stat Tracker. Ensure Python is installed if using the script version.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } else {
        # Download Logic
        Get-StatTracker
    }
})
$ContextMenuStrip.Items.Add($MenuItemStatTracker) | Out-Null

$ContextMenuStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# 5. PAUSE SPAWNING
$MenuItemPause = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemPause.Text = "Pause Server Spawning"
$MenuItemPause.CheckOnClick = $true
$initialConfig = Get-MonitorConfig
$MenuItemPause.Checked = $initialConfig.pauseSpawning

$MenuItemPause.Add_Click({
    $conf = Get-MonitorConfig
    $conf.pauseSpawning = $MenuItemPause.Checked
    Save-MonitorConfig $conf
    # Reset Link Code global if we unpause manually
    if (-not $conf.pauseSpawning) {
        $Global:LinkCodeActive = $false
    }
})
$ContextMenuStrip.Items.Add($MenuItemPause) | Out-Null

# 6. EXIT
$MenuItemExit = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemExit.Text = "Exit"
$MenuItemExit.Add_Click({
    $MonitorTimer.Stop()
    $NotifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$ContextMenuStrip.Items.Add($MenuItemExit) | Out-Null

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($EchoExePath)
$NotifyIcon.Text = "EchoVR Server Monitor"
$NotifyIcon.ContextMenuStrip = $ContextMenuStrip
$NotifyIcon.Visible = $true

# ==============================================================================
# 7. MONITORING LOGIC
# ==============================================================================

$MonitorTimer = New-Object System.Windows.Forms.Timer
$MonitorTimer.Interval = 3000

# Helper to clean up background jobs
Function Clear-Jobs {
    Get-Job -State Completed | Remove-Job
}

# 1. STUCK CHECK
Function Start-Stuck-Watchdog ($procId, $timeoutMs) {
    $jobName = "${procId}_stuck"
    $timeoutSeconds = $timeoutMs / 1000

    if (-not (Get-Job -Name $jobName -ErrorAction SilentlyContinue)) {
        $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($logFile) {
            $lastLine = Get-Content -Path $logFile.FullName -Tail 1 -ErrorAction SilentlyContinue
            
            if ($lastLine) {
                Start-Job -Name $jobName -ArgumentList $lastLine, $procId, $timeoutSeconds, $logFile.FullName -ScriptBlock {
                    param($initialLine, $pidToKill, $limitSeconds, $logPath)
                    
                    $startTime = Get-Date
                    while ($true) {
                        if (((Get-Date) - $startTime).TotalSeconds -gt $limitSeconds) {
                            Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
                            break 
                        }
                        if (Test-Path $logPath) {
                            try {
                                $currentLine = Get-Content -Path $logPath -Tail 1 -ErrorAction Stop
                                if ($initialLine -ne $currentLine) { break }
                            } catch {}
                        }
                        Start-Sleep -Seconds 5
                    }
                } | Out-Null
            }
        }
    }
}

# 2. ERROR CHECK
Function Test-LogErrors ($procId) {
    $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    
    if ($logFile) {
        $lastLine = Get-Content -Path $logFile.FullName -Tail 1 -ErrorAction SilentlyContinue
        
        if ($lastLine) {
            $lineClean = $lastLine -replace "^.*\]: ", "" -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
            if ($Global:ErrorList -contains $lineClean) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# 3. LINK CODE CHECK
Function Test-LinkCode ($procId) {
    if ($Global:NotifiedPids.ContainsKey($procId)) { return }
    if ($Global:LinkCodeActive) { return } # Prevent multiple popups

    # Find the log file
    $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
               Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($logFile) {
        $lines = Get-Content -LiteralPath $logFile.FullName -Tail 5 -ErrorAction SilentlyContinue
        
        if ($null -eq $lines) { return }
        
        $content = $lines -join "`n"
        
        # Matches: [NETGAME] [DMO-...] Your Code is: >>> ABCD <<<
        if ($content -match ">>>\s*(?<code>[A-Z0-9]+)\s*<<<") {
            $code = $Matches['code'].Trim()
            
            if (-not [string]::IsNullOrWhiteSpace($code)) {
                $Global:NotifiedPids[$procId] = $true
                $Global:LinkCodeActive = $true
                
                # Halt spawning immediately to protect validity of code
                $conf = Get-MonitorConfig
                $conf.pauseSpawning = $true
                Save-MonitorConfig $conf
                
                # Using Start-Process to ensure the popup is visible over the game
                $msgBody = "Your link code is: $code`n`nClick OK to open command central.`nClick Link EchoVRCE and enter your code.`n`nUnpause server spawning in the system tray after linking."
                $msgTitle = "Link Code Detected"
                $discordUrl = "discord://https://discord.com/channels/779349159852769310/1227795372244729926/1355176306484056084"
                
                $cmd = "Add-Type -AssemblyName System.Windows.Forms; " +
                       "`$res = [System.Windows.Forms.MessageBox]::Show('$msgBody', '$msgTitle', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information); " +
                       "if (`$res -eq [System.Windows.Forms.DialogResult]::OK) { Start-Process '$discordUrl' }"
                
                $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
                $encodedCommand = [Convert]::ToBase64String($bytes)
                
                Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-EncodedCommand $encodedCommand" -WindowStyle Hidden
            }
        }
    }
}

# Process Loop
$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck

    # Update Stat Tracker Menu Text dynamically
    if (Test-Path $StatTrackerPath) {
        $MenuItemStatTracker.Text = "Open Stat Tracker"
    } else {
        $MenuItemStatTracker.Text = "Download Stat Tracker"
    }

    # Update Pause Menu Item based on config read
    if ($MenuItemPause.Checked -ne $config.pauseSpawning) {
        $MenuItemPause.Checked = $config.pauseSpawning
    }

    Clear-Jobs

    $processes = @(Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue)
    $runningCount = $processes.Count

    # --- WATCHDOG CHECKS ---
    if ($processes) {
        foreach ($proc in $processes) {
            Test-LogErrors $proc.Id
            Start-Stuck-Watchdog $proc.Id $config.delayKillStuck
            
            # Check for Link Code
            Test-LinkCode $proc.Id
        }
    }
    
    # ... rest of the MonitorAction block ...

    # --- UPDATE MENU STATUS & UPTIME LIST ---
    $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances)                 v$($Global:Version)"

    # Refresh dynamic process list
    $sepIndex = $ContextMenuStrip.Items.IndexOf($MenuItemSeparator1)
    
    # Remove existing dynamic items (between Status and Separator)
    # Loop backwards to safely remove
    for ($i = $sepIndex - 1; $i -gt 0; $i--) {
        $ContextMenuStrip.Items.RemoveAt($i)
    }

    # Add new process items
    if ($processes) {
        $pIndex = 1
        # Sort by StartTime so the list doesn't jump around
        $sortedProcs = $processes | Sort-Object StartTime
        
        foreach ($proc in $sortedProcs) {
            try {
                $uptime = New-TimeSpan -Start $proc.StartTime -End (Get-Date)
                $txt = "{0}. PID {1} | {2}h {3}m {4}s" -f $pIndex, $proc.Id, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
                
                $item = New-Object System.Windows.Forms.ToolStripMenuItem
                $item.Text = $txt
                $item.Enabled = $false # Just informational
                
                # Insert after Status (index 0)
                $ContextMenuStrip.Items.Insert($pIndex, $item)
                $pIndex++
            } catch {
                # Process might have closed during calculation
            }
        }
    }

    # --- SPAWNING LOGIC ---
    if (-not $config.pauseSpawning) {
        $needed = $config.amountOfInstances - $runningCount

        if ($needed -gt 0) {
            $currentFlags = "-numtaskthreads $($config.numTaskThreads) -timestep $($config.timeStep) $($config.additionalArgs)"
            for ($i = 0; $i -lt $needed; $i++) {
                # If we are spawning multiple, check global pause flag between spawns in case a link code appeared
                $freshConfig = Get-MonitorConfig
                if ($freshConfig.pauseSpawning -or $Global:LinkCodeActive) { break }

                Start-Process -FilePath $EchoExePath -ArgumentList $currentFlags -WindowStyle Minimized
                # Increased delay to catch link codes before spawning next instance
                Start-Sleep -Milliseconds 3000
            }
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 8. AUTO-UPDATE LOGIC
# ==============================================================================

Function Test-ForUpdates {
    $config = Get-MonitorConfig
    if (-not $config.autoUpdate) { return }

    $url = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    $TargetFileName = if ($Global:IsBinary) { "EchoVR-Server-Monitor.exe" } else { "EchoVR-Server-Monitor.ps1" }
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        $targetAsset = $response.assets | Where-Object { $_.name -eq $TargetFileName } | Select-Object -First 1

        if (-not $targetAsset) { return }

        $latestTag = $response.tag_name -replace "^v", ""
        $currentVer = $Global:Version -replace "^v", ""
        
        if ([System.Version]$latestTag -gt [System.Version]$currentVer) {
            Invoke-Update -downloadUrl $targetAsset.browser_download_url
        }
    } catch {
        # Silently fail
    }
}

Function Invoke-Update ($downloadUrl) {
    try {
        $currentFile = $Global:ExecutionPath
        $currentDir = [System.IO.Path]::GetDirectoryName($currentFile)
        
        $newFileName = if ($Global:IsBinary) { "EchoMonitor_New.exe" } else { "EchoMonitor_New.ps1" }
        $newFilePath = Join-Path $currentDir $newFileName
        
        $dashboardDir = Join-Path $currentDir "dashboard"
        if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }
        $batchPath = Join-Path $dashboardDir "updater.bat"

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $newFilePath

        $startCommand = if ($Global:IsBinary) { 
            "start `"`" `"$currentFile`"" 
        } else { 
            "start `"`" pwsh -WindowStyle Hidden -File `"$currentFile`"" 
        }

        $batchContent = @"
@echo off
timeout /t 3 /nobreak > NUL
:LOOP
del "$currentFile"
if exist "$currentFile" goto LOOP
move /y "$newFilePath" "$currentFile"
$startCommand
del "%~f0"
"@
        Set-Content -Path $batchPath -Value $batchContent

        Start-Process -FilePath $batchPath -WindowStyle Hidden
        $NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
        Stop-Process -Id $PID -Force
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Update failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# ==============================================================================
# 9. EXECUTION
# ==============================================================================

# Check for updates synchronously before showing the tray
Test-ForUpdates

$MonitorTimer.Start()
[System.Windows.Forms.Application]::Run()