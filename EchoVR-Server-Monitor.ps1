###################################################################
# Code by marshmallow_mia and now mostly berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# Changes 
# v3.0.0 - Added Port/API management, DLL updates & hash checks. Removed Stat Tracker, Logfile Error Parsing.
# v2.1.1 - Auto-cleanup of setup_tracker.ps1 after installation.

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "3.0.0"
$Global:GithubOwner = "EchoTools"
$Global:GithubRepo  = "EchoVR-Windows-Hosts-Resources"

# Port Management & Tracking
# Structure: @{ PID = @{ GS=1234; API=1235 } }
$Global:PortMap = @{}
$Global:BasePort = 6792

# DLL Hash Targets (MD5)
$Global:Hash_PNSRAD = "67E6E9B3BE315EA784D69E5A31815B89"
$Global:Hash_DBGCORE = "7E7998C29A1E588AF659E19C3DD27265"

$Global:NotifiedPids = @{}
$Global:LinkCodeActive = $false
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# 0. MODE DETECTION, PS7 CHECK, SINGLE INSTANCE CHECK
# ==============================================================================

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
$LocalConfigPath = Join-Path $ScriptRoot "_local\config.json"
$LogPath = Join-Path $ScriptRoot "_local\r14logs"

# DLL Paths
$Path_PNSRAD = Join-Path $ScriptRoot "bin\win10\pnsradgameserver.dll"
$Path_DBGCORE = Join-Path $ScriptRoot "bin\win10\dbgcore.dll"

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
    # Only update setup.json for dashboard compatibility
    if (Test-Path $SetupFile) {
        $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
        $dashData.numInstances = [int]$numInstances
        $dashData.upperPortRange = 6792 + ([int]$numInstances * 2) # Adjusted for GS+API pairs
        $dashData | ConvertTo-Json -Depth 4 | Set-Content $SetupFile
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
# 5. PORT MANAGEMENT
# ==============================================================================

Function Get-AvailablePortPair {
    # Start checking from BasePort
    # We step by 2: (6792,6793), (6794,6795), etc.
    $maxChecks = 100 
    
    for ($i = 0; $i -lt $maxChecks; $i++) {
        $gsPort = $Global:BasePort + ($i * 2)
        $apiPort = $gsPort + 1
        
        $inUse = $false
        foreach ($pidKey in $Global:PortMap.Keys) {
            $entry = $Global:PortMap[$pidKey]
            if ($entry.GS -eq $gsPort -or $entry.API -eq $apiPort) {
                $inUse = $true
                break
            }
        }
        
        if (-not $inUse) {
            return @{ GS=$gsPort; API=$apiPort }
        }
    }
    return $null
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

# 4. MANUAL UPDATE CHECK
$MenuItemUpdate = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemUpdate.Text = "Check for Updates"
$MenuItemUpdate.Add_Click({
    Test-ForUpdates -ManualCheck $true
})
$ContextMenuStrip.Items.Add($MenuItemUpdate) | Out-Null

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

# 1. WATCHDOG & LOG SCANNER
Function Start-Watchdog ($procId, $timeoutMs) {
    $jobName = "${procId}_watch"
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
                        # Stuck Check
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

Function Search-LogForInfo ($procId) {
    # This scans for Port Verification and Link Codes
    $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
               Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($logFile) {
        $lines = Get-Content -LiteralPath $logFile.FullName -Tail 15 -ErrorAction SilentlyContinue
        if ($null -eq $lines) { return }
        $content = $lines -join "`n"

        # --- Port Verification ---
        # 1. Dedicated: broadcaster initialized at [XXX.XXX.XXX.XXX:GSPORT]
        if ($content -match "Dedicated: broadcaster initialized at \[[0-9\.]+:(\d+)\]") {
            $foundGS = [int]$Matches[1]
            if ($Global:PortMap.ContainsKey($procId)) {
                $Global:PortMap[$procId].GS_Confirmed = $foundGS
            }
        }
        
        # 2. [NETGAME] Bound HTTP listener to 127.0.0.1:APIPORT
        if ($content -match "\[NETGAME\] Bound HTTP listener to [0-9\.]+:(\d+)") {
            $foundAPI = [int]$Matches[1]
            if ($Global:PortMap.ContainsKey($procId)) {
                $Global:PortMap[$procId].API_Confirmed = $foundAPI
            }
        }

        # --- Link Code Check ---
        if (-not $Global:LinkCodeActive -and -not $Global:NotifiedPids.ContainsKey($procId)) {
            if ($content -match ">>>\s*(?<code>[A-Z0-9]+)\s*<<<") {
                $code = $Matches['code'].Trim()
                if (-not [string]::IsNullOrWhiteSpace($code)) {
                    $Global:NotifiedPids[$procId] = $true
                    $Global:LinkCodeActive = $true
                    
                    $conf = Get-MonitorConfig
                    $conf.pauseSpawning = $true
                    Save-MonitorConfig $conf
                    
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
}

# Process Loop
$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck

    # Update Pause Menu Item based on config read
    if ($MenuItemPause.Checked -ne $config.pauseSpawning) {
        $MenuItemPause.Checked = $config.pauseSpawning
    }

    Clear-Jobs

    $processes = @(Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue)
    $runningCount = $processes.Count
    $runningIds = $processes.Id

    # --- PORT MAP CLEANUP ---
    # Remove entries for PIDs that no longer exist
    $trackedPids = @($Global:PortMap.Keys)
    foreach ($pidKey in $trackedPids) {
        if ($runningIds -notcontains $pidKey) {
            $Global:PortMap.Remove($pidKey)
        }
    }

    # --- WATCHDOG CHECKS ---
    if ($processes) {
        foreach ($proc in $processes) {
            Start-Watchdog $proc.Id $config.delayKillStuck
            Search-LogForInfo $proc.Id
        }
    }
    
    # --- UPDATE MENU STATUS & UPTIME LIST ---
    $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances)                 v$($Global:Version)"

    # Refresh dynamic process list
    $sepIndex = $ContextMenuStrip.Items.IndexOf($MenuItemSeparator1)
    
    # Remove existing dynamic items (between Status and Separator)
    for ($i = $sepIndex - 1; $i -gt 0; $i--) {
        $ContextMenuStrip.Items.RemoveAt($i)
    }

    # Add new process items
    if ($processes) {
        $pIndex = 1
        $sortedProcs = $processes | Sort-Object StartTime
        
        foreach ($proc in $sortedProcs) {
            try {
                $uptime = New-TimeSpan -Start $proc.StartTime -End (Get-Date)
                
                # Get Ports for display
                $pData = $Global:PortMap[$proc.Id]
                $portStr = if ($pData) { " [GS:$($pData.GS) API:$($pData.API)]" } else { "" }

                $txt = "{0}. PID {1}{2} | {3}h {4}m" -f $pIndex, $proc.Id, $portStr, $uptime.Hours, $uptime.Minutes
                
                $item = New-Object System.Windows.Forms.ToolStripMenuItem
                $item.Text = $txt
                $item.Enabled = $false 
                
                $ContextMenuStrip.Items.Insert($pIndex, $item)
                $pIndex++
            } catch { }
        }
    }

    # --- SPAWNING LOGIC ---
    if (-not $config.pauseSpawning) {
        $needed = $config.amountOfInstances - $runningCount

        if ($needed -gt 0) {
            
            for ($i = 0; $i -lt $needed; $i++) {
                $freshConfig = Get-MonitorConfig
                if ($freshConfig.pauseSpawning -or $Global:LinkCodeActive) { break }

                # Port Allocation
                $portPair = Get-AvailablePortPair
                if ($null -eq $portPair) { 
                    # Safety valve if somehow run out of ports
                    break 
                }

                # Construct Args
                # User args + our mandatory port args
                $launchArgs = "-numtaskthreads $($config.numTaskThreads) -timestep $($config.timeStep) $($config.additionalArgs) -port $($portPair.GS) -httpport $($portPair.API)"
                
                $newProc = Start-Process -FilePath $EchoExePath -ArgumentList $launchArgs -WindowStyle Minimized -PassThru
                
                # Register Ports immediately
                if ($newProc) {
                    $Global:PortMap[$newProc.Id] = @{
                        GS = $portPair.GS
                        API = $portPair.API
                        GS_Confirmed = $null
                        API_Confirmed = $null
                    }
                }

                Start-Sleep -Milliseconds 3000
            }
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 8. UPDATE LOGIC (Monitor + DLLs)
# ==============================================================================

Function Test-FileHash ($path, $targetHash) {
    if (-not (Test-Path $path)) { return $false }
    $hash = Get-FileHash -Path $path -Algorithm MD5
    return ($hash.Hash -eq $targetHash)
}

Function Update-DLLs {
    # Helper function to handle the safe download of DLLs
    # Returns $true if update succeeded, $false if failed/cancelled
    
    # URL construction (Adjust 'main' or 'master' if needed)
    $rawBaseUrl = "https://raw.githubusercontent.com/$Global:GithubOwner/$Global:GithubRepo/main/dll"
    $urlPNSRAD = "$rawBaseUrl/pnsradgameserver.dll"
    $urlDBG    = "$rawBaseUrl/dbgcore.dll"

    # 1. Safety Check: Running Instances
    $running = Get-Process -Name $Script:EchoProcessName -ErrorAction SilentlyContinue
    if ($running) {
        # Pause Spawning automatically
        $conf = Get-MonitorConfig
        $conf.pauseSpawning = $true
        Save-MonitorConfig $conf
        
        # We must interrupt here to prevent file locking errors
        $msg = "Cannot update DLLs while instances are running.`n`nSpawning has been PAUSED.`nPlease manually close all EchoVR instances now, then click OK to proceed."
        $res = [System.Windows.Forms.MessageBox]::Show($msg, "Action Required", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
        
        if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        
        # Re-check after user clicks OK
        $running = Get-Process -Name $Script:EchoProcessName -ErrorAction SilentlyContinue
        if ($running) {
             [System.Windows.Forms.MessageBox]::Show("Instances are still running. Update aborted.", "Aborted", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
             return $false
        }
    }

    # 2. Download
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $urlPNSRAD -OutFile $Script:Path_PNSRAD
        Invoke-WebRequest -Uri $urlDBG -OutFile $Script:Path_DBGCORE
        
        [System.Windows.Forms.MessageBox]::Show("DLLs updated successfully.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to download DLLs. Check internet or repo path.`nError: $_", "Download Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

Function Test-ForUpdates ($ManualCheck = $false) {
    $config = Get-MonitorConfig
    if (-not $config.autoUpdate -and -not $ManualCheck) { return }

    $apiUrl = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    $TargetFileName = if ($Global:IsBinary) { "EchoVR-Server-Monitor.exe" } else { "EchoVR-Server-Monitor.ps1" }
    
    $monitorUpdateAvailable = $false
    $monitorAssetUrl = $null
    $dllUpdateAvailable = $false

    try {
        if ($ManualCheck) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor }
        
        # --- PHASE 1: SILENT CHECKS ---

        # A. Check Monitor Version
        try {
            $response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop
            $monitorAsset = $response.assets | Where-Object { $_.name -eq $TargetFileName } | Select-Object -First 1
            
            if ($monitorAsset) {
                $latestTag = $response.tag_name -replace "^v", ""
                $currentVer = $Global:Version -replace "^v", ""
                if ([System.Version]$latestTag -gt [System.Version]$currentVer) {
                    $monitorUpdateAvailable = $true
                    $monitorAssetUrl = $monitorAsset.browser_download_url
                }
            }
        } catch {
            if ($ManualCheck) { Write-Warning "Could not connect to GitHub API." }
        }

        # B. Check DLL Hashes
        $pnsradValid = Test-FileHash $Script:Path_PNSRAD $Global:Hash_PNSRAD
        $dbgValid = Test-FileHash $Script:Path_DBGCORE $Global:Hash_DBGCORE
        
        if (-not $pnsradValid -or -not $dbgValid) {
            $dllUpdateAvailable = $true
        }

        # --- PHASE 2: SINGLE USER PROMPT ---

        # Scenario 1: BOTH Monitor and DLLs needed
        if ($monitorUpdateAvailable -and $dllUpdateAvailable) {
            $msg = "Updates Available:`n`n1. New Monitor Version ($($response.tag_name))`n2. New Server DLLs (Hash Mismatch)`n`nUpdate ALL components now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Critical Updates Found", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Exclamation)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                # Update DLLs first (safest, as Monitor update kills the process)
                if (Update-DLLs) {
                    Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl
                }
            }
            return
        }

        # Scenario 2: Monitor Only
        if ($monitorUpdateAvailable) {
            $msg = "New Monitor Version Available: $($response.tag_name)`n`nUpdate now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Monitor Update", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl
            }
            return
        }

        # Scenario 3: DLLs Only
        if ($dllUpdateAvailable) {
            $msg = "Your local server DLLs do not match the required versions.`n`nUpdate pnsradgameserver.dll and dbgcore.dll now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "DLL Integrity Check", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                Update-DLLs
            }
            return
        }

        # Scenario 4: All Good (Manual Check Only)
        if ($ManualCheck) {
            [System.Windows.Forms.MessageBox]::Show("Everything is up to date.`n`nMonitor: v$($Global:Version)`nDLLs: Verified", "Up to Date", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }

    } catch {
        if ($ManualCheck) {
            [System.Windows.Forms.MessageBox]::Show("Update check failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } finally {
        if ($ManualCheck) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    }
}

Function Invoke-MonitorUpdate ($downloadUrl) {
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