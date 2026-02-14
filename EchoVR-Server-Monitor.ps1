###################################################################
# Code by marshmallow_mia and berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "1.0.0"
$Global:GithubOwner = "EchoTools"
$Global:GithubRepo  = "EchoVR-Windows-Hosts-Resources"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# 0. MODE DETECTION & PS7 CHECK
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
    $msgResult = [System.Windows.Forms.MessageBox]::Show("This monitor runs best on PowerShell 7.`n`nWould you like to install it now?", "Upgrade Recommended", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    
    if ($msgResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            # Attempt to install via Winget
            Start-Process -FilePath "winget" -ArgumentList "install --id Microsoft.PowerShell --source winget" -Wait -Verb RunAs
            [System.Windows.Forms.MessageBox]::Show("PowerShell 7 installed. Please restart this script using PowerShell 7 (pwsh).", "Install Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            Exit
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not launch Winget. Please install PowerShell 7 manually from https://github.com/PowerShell/PowerShell", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            Exit
        }
    }
}

# ==============================================================================
# 0.5 SINGLE INSTANCE CHECK
# ==============================================================================
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
    # Fallback for binary mode or if PSScriptRoot is empty
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

# Removed setup.json validation check here

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
        }
        if (Test-Path $SetupFile) {
            $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
            if ($dashData.numInstances) { $defaultConfig.amountOfInstances = $dashData.numInstances }
        }
        $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content $MonitorFile
        return $defaultConfig
    }
    
    # Ensure autoUpdate exists for older configs
    $config = Get-Content $MonitorFile -Raw | ConvertFrom-Json
    if ($null -eq $config.autoUpdate) {
        $config | Add-Member -MemberType NoteProperty -Name "autoUpdate" -Value $true
        Save-MonitorConfig $config
    }
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
            
            # If binary, point to EXE. If script, point to pwsh executing the script
            if ($Global:IsBinary) {
                $Shortcut.TargetPath = $Global:ExecutionPath
                $Shortcut.WorkingDirectory = $ScriptRoot
                $Shortcut.Arguments = "" # Ensure no leftover script args
            } else {
                # Prefer pwsh (PS7), fall back to powershell
                $exe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
                $Shortcut.TargetPath = $exe
                # Force Hidden WindowStyle so no console pops up
                $Shortcut.Arguments = "-WindowStyle Hidden -File `"$Global:ExecutionPath`""
                $Shortcut.WorkingDirectory = $ScriptRoot
            }
            
            # Set Icon to EchoVR.exe so it looks nice in Startup
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
    $form.Size = New-Object System.Drawing.Size(435, 550)
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
    $grpAdv.Size = New-Object System.Drawing.Size(390, 180)
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

    # --- Bottom Buttons ---
    $y += 220
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

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(125, $y)
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

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Discard"
    $btnCancel.Location = New-Object System.Drawing.Point(210, $y)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    # --- Version Label at Bottom ---
    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "v$($Global:Version)"
    $lblVersion.AutoSize = $false
    $lblVersion.Size = New-Object System.Drawing.Size(435, 20) # Width matches form width
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblVersion.ForeColor = [System.Drawing.Color]::Silver
    $lblVersion.Location = New-Object System.Drawing.Point(0, ($y + 35)) # 35px below buttons
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

        Save-MonitorConfig $monitorData
        Update-ExternalConfigs $numInst
        
        [System.Windows.Forms.MessageBox]::Show("Configuration Saved.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# ==============================================================================
# 5. SYSTEM TRAY & MENU
# ==============================================================================

$ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip

$MenuItemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemStatus.Text = "Status: Initializing..."
$MenuItemStatus.Enabled = $false
$ContextMenuStrip.Items.Add($MenuItemStatus) | Out-Null

$ContextMenuStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$MenuItemConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemConfig.Text = "Edit Monitor Configuration"
$MenuItemConfig.Add_Click({ 
    $MonitorTimer.Stop()
    Show-ConfigWindow 
    $MonitorTimer.Start()
})
$ContextMenuStrip.Items.Add($MenuItemConfig) | Out-Null

# --- Auto-Update Toggle ---
$MenuItemAutoUpdate = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemAutoUpdate.Text = "Enable Auto-Update"
$MenuItemAutoUpdate.CheckOnClick = $true
$initialConfig = Get-MonitorConfig
$MenuItemAutoUpdate.Checked = $initialConfig.autoUpdate

$MenuItemAutoUpdate.Add_Click({
    $conf = Get-MonitorConfig
    $conf.autoUpdate = $MenuItemAutoUpdate.Checked
    Save-MonitorConfig $conf
})
$ContextMenuStrip.Items.Add($MenuItemAutoUpdate) | Out-Null

$MenuItemStartup = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemStartup.Text = "Start with Windows"
$MenuItemStartup.CheckOnClick = $true

# FORCE SHORTCUT UPDATE ON START
# This ensures that if the user moved from EXE to PS1, the old shortcut is overwritten 
# with the correct arguments for the PS1 script.
Switch-StartupShortcut $true
$MenuItemStartup.Checked = $true

$MenuItemStartup.Add_Click({
    Switch-StartupShortcut $MenuItemStartup.Checked
})
$ContextMenuStrip.Items.Add($MenuItemStartup) | Out-Null

$ContextMenuStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

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
# 6. MONITORING LOGIC
# ==============================================================================

$MonitorTimer = New-Object System.Windows.Forms.Timer
$MonitorTimer.Interval = 3000

# Helper to clean up background jobs so memory doesn't leak
Function Clear-Jobs {
    Get-Job -State Completed | Remove-Job
}

# 1. STUCK CHECK: Restarts server if log hasn't changed in X seconds
Function Start-Stuck-Watchdog ($procId, $timeoutMs) {
    $jobName = "${procId}_stuck"
    $timeoutSeconds = $timeoutMs / 1000

    # Only start a watcher if one isn't already running for this PID
    if (-not (Get-Job -Name $jobName -ErrorAction SilentlyContinue)) {
        $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($logFile) {
            $lastLine = Get-Content -Path $logFile.FullName -Tail 1 -ErrorAction SilentlyContinue
            
            # Only start job if we successfully read a line
            if ($lastLine) {
                Start-Job -Name $jobName -ArgumentList $lastLine, $procId, $timeoutSeconds, $logFile.FullName -ScriptBlock {
                    param($initialLine, $pidToKill, $limitSeconds, $logPath)
                    
                    $startTime = Get-Date
                    while ($true) {
                        # 1. Timeout Check
                        if (((Get-Date) - $startTime).TotalSeconds -gt $limitSeconds) {
                            Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
                            break 
                        }
                        
                        # 2. Activity Check
                        if (Test-Path $logPath) {
                            try {
                                # Use ErrorAction Stop to trigger catch block if read fails
                                $currentLine = Get-Content -Path $logPath -Tail 1 -ErrorAction Stop
                                if ($initialLine -ne $currentLine) {
                                    break # Server updated the log, it's alive.
                                }
                            } catch {
                                # File locked or deleted? Just wait and retry.
                            }
                        }
                        Start-Sleep -Seconds 5
                    }
                } | Out-Null
            }
        }
    }
}

# 2. ERROR CHECK: Kills server if specific errors appear in log
Function Test-LogErrors ($procId) {
    $logFile = Get-ChildItem -Path $LogPath -Filter "*_${procId}.log" -ErrorAction SilentlyContinue | 
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    
    if ($logFile) {
        $lastLine = Get-Content -Path $logFile.FullName -Tail 1 -ErrorAction SilentlyContinue
        
        if ($lastLine) {
            # Clean the line (remove timestamp/IPs) for matching
            $lineClean = $lastLine -replace "^.*\]: ", "" -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
            
            if ($Global:ErrorList -contains $lineClean) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck

    Clear-Jobs

    $currentFlags = "-numtaskthreads $($config.numTaskThreads) -timestep $($config.timeStep) $($config.additionalArgs)"
    
    $processes = Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue
    
    if ($processes) {
        foreach ($proc in $processes) {
            Test-LogErrors $proc.Id
            Start-Stuck-Watchdog $proc.Id $config.delayKillStuck
        }
    }

    $processes = Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue
    $runningCount = if ($processes) { @($processes).Count } else { 0 }
    
    $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances)"

    $needed = $config.amountOfInstances - $runningCount

    if ($needed -gt 0) {
        for ($i = 0; $i -lt $needed; $i++) {
            Start-Process -FilePath $EchoExePath -ArgumentList $currentFlags -WindowStyle Minimized
            Start-Sleep -Milliseconds 1000
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 7. AUTO-UPDATE LOGIC
# ==============================================================================

Function Test-ForUpdates {
    $config = Get-MonitorConfig
    if (-not $config.autoUpdate) { return }

    $url = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    
    # DETERMINE TARGET FILE BASED ON EXECUTION MODE
    $TargetFileName = if ($Global:IsBinary) { "EchoVR-Server-Monitor.exe" } else { "EchoVR-Server-Monitor.ps1" }
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        
        # 1. Check if release contains our target asset
        $targetAsset = $response.assets | Where-Object { $_.name -eq $TargetFileName } | Select-Object -First 1

        if (-not $targetAsset) { return }

        # 2. Version Check
        $latestTag = $response.tag_name -replace "^v", ""
        $currentVer = $Global:Version -replace "^v", ""
        
        if ([System.Version]$latestTag -gt [System.Version]$currentVer) {
            # Update detected
            Invoke-Update -downloadUrl $targetAsset.browser_download_url
        }
    } catch {
        # Silently fail
    }
}

Function Invoke-Update ($downloadUrl) {
    try {
        # Determine Current File to replace and New File Name
        $currentFile = $Global:ExecutionPath
        $currentDir = [System.IO.Path]::GetDirectoryName($currentFile)
        
        $newFileName = if ($Global:IsBinary) { "EchoMonitor_New.exe" } else { "EchoMonitor_New.ps1" }
        $newFilePath = Join-Path $currentDir $newFileName
        
        $dashboardDir = Join-Path $currentDir "dashboard"
        if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }
        $batchPath = Join-Path $dashboardDir "updater.bat"

        # 1. Download
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $newFilePath

        # 2. Build Batch Command based on mode
        $startCommand = if ($Global:IsBinary) { 
            # Binary restart command
            "start `"`" `"$currentFile`"" 
        } else { 
            # Script restart command (Force pwsh)
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

        # 3. Execute
        Start-Process -FilePath $batchPath -WindowStyle Hidden
        $NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
        Stop-Process -Id $PID -Force
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Update failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# ==============================================================================
# 8. EXECUTION
# ==============================================================================

# Check for updates synchronously before showing the tray
Test-ForUpdates

$MonitorTimer.Start()
[System.Windows.Forms.Application]::Run()