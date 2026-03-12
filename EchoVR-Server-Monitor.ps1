###################################################################
# Code by marshmallow_mia and now berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# Changes 
# v5.0.0 - EchoVR API telemetry, customizable UI/Tray tags, Soft Shutdowns, and port-state persistence. Removed PS7 Requirement.
# v4.0.3 - Added some bling to the about tab, download fonts from repo main/misc and place them in \content\engine\core\fonts\ to use them. <3
# v4.0.2 - Added function to repair netconfig json files, should fix broadcaster init failures

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "5.0.0"
$Global:GithubOwner = "EchoTools"
$Global:GithubRepo  = "EchoVR-Windows-Hosts-Resources"

# Port Management & Tracking
# Structure: @{ PID = @{ GS=1234; API=1235; LogPath="..."; ShutdownQueued=$false; PlayerCount=0; ... } }
$Global:PortMap = @{}

# DLL Hash Targets (MD5)
$Global:Hash_PNSRAD = "67E6E9B3BE315EA784D69E5A31815B89"
$Global:Hash_DBGCORE = "7E7998C29A1E588AF659E19C3DD27265"

$Global:NotifiedPids = @{}
$Global:LinkCodeActive = $false
$Global:LastLogMaintenanceDay = -1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Window {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool SetWindowText(IntPtr hWnd, string text);
}
"@

# ==============================================================================
# 0. MODE DETECTION, SINGLE INSTANCE CHECK
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
$TempDir = Join-Path $DashboardDir "temp"
$PortsFile = Join-Path $TempDir "ports.json"
$SetupFile = Join-Path $DashboardDir "setup.json"
$MonitorFile = Join-Path $DashboardDir "monitor.json"
$LocalConfigPath = Join-Path $ScriptRoot "_local\config.json"
$LogPath = Join-Path $ScriptRoot "_local\r14logs"
$LogPathOld = Join-Path $LogPath "old"

$Path_PNSRAD = Join-Path $ScriptRoot "bin\win10\pnsradgameserver.dll"
$Path_DBGCORE = Join-Path $ScriptRoot "bin\win10\dbgcore.dll"

$StartupFolder = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupFolder "EchoVR Server Monitor.lnk"

if (-not (Test-Path $EchoExePath)) {
    [System.Windows.Forms.MessageBox]::Show("Error: 'bin\win10\echovr.exe' not found.`nPlace this program in the root ready-at-dawn-echo-arena folder.", "Fatal Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Exit
}
if (-not (Test-Path $DashboardDir)) { New-Item -ItemType Directory -Path $DashboardDir -Force | Out-Null }
if (-not (Test-Path $LogPathOld)) { New-Item -ItemType Directory -Path $LogPathOld -Force | Out-Null }

# ==============================================================================
# 2. STATE PERSISTENCE & API TOGGLE
# ==============================================================================

Function Save-PortMap {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    
    # Pack Hashtable into a PSObject to bypass PS5.1 JSON serialization bugs
    $exportObj = New-Object PSObject
    foreach ($key in $Global:PortMap.Keys) {
        $exportObj | Add-Member -MemberType NoteProperty -Name $key.ToString() -Value $Global:PortMap[$key]
    }
    
    $exportObj | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $PortsFile -Force
}

Function Import-PortMap {
    if (Test-Path $PortsFile) {
        try {
            $raw = Get-Content $PortsFile -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $saved = $raw | ConvertFrom-Json
                foreach ($prop in $saved.psobject.properties) {
                    $pidInt = [int]$prop.Name
                    $Global:PortMap[$pidInt] = @{
                        GS = $prop.Value.GS
                        API = $prop.Value.API
                        GS_Confirmed = $prop.Value.GS_Confirmed
                        API_Confirmed = $prop.Value.API_Confirmed
                        LogPath = $prop.Value.LogPath
                        ShutdownQueued = $false
                        PlayerCount = 0
                        ModeTitle = "Unknown Mode"
                    }
                }
            }
            Remove-Item $PortsFile -Force
        } catch {}
    }
}

Function Set-ApiAccess ($enable) {
    # 1. Update menu_settings.json
    $r14MenuPath = Join-Path $ScriptRoot "sourcedb\rad15\json\r14\config\uisettings\menu_settings.json"
    if (Test-Path $r14MenuPath) {
        try {
            $json = Get-Content $r14MenuPath -Raw | ConvertFrom-Json
            $needsSave = $false
            
            if ($null -ne $json.pages) {
                foreach ($page in $json.pages) {
                    if ($null -ne $page.rows) {
                        foreach ($row in $page.rows) {
                            if ($row.path -eq "game|EnableAPIAccess" -and $row.value -ne $enable) {
                                $row.value = [bool]$enable
                                $needsSave = $true
                            }
                        }
                    }
                }
            }
            
            if ($needsSave) { 
                $json | ConvertTo-Json -Depth 10 | Set-Content $r14MenuPath 
            }
        } catch { 
            Write-Warning "Could not update menu_settings.json" 
        }
    }
    
    # 2. Update settings_mp_v2.json
    $leConfig = Join-Path $env:LOCALAPPDATA "rad\loneecho\settings_mp_v2.json"
    if (Test-Path $leConfig) {
        try {
            $json2 = Get-Content $leConfig -Raw | ConvertFrom-Json
            
            if ($null -ne $json2.game) {
                if ($json2.game.EnableAPIAccess -ne $enable) {
                    $json2.game.EnableAPIAccess = [bool]$enable
                    $json2 | ConvertTo-Json -Depth 10 | Set-Content $leConfig
                }
            }
        } catch { 
            Write-Warning "Could not update settings_mp_v2.json" 
        }
    }
}

Function Repair-NetConfigFiles {
    $ConfigDir = Join-Path $ScriptRoot "sourcedb\rad15\json\r14\config"
    $TargetFiles = @("netconfig_client.json", "netconfig_dedicatedserver.json", "netconfig_lanserver.json", "netconfig_localserver.json")
    foreach ($file in $TargetFiles) {
        $filePath = Join-Path $ConfigDir $file
        if (Test-Path $filePath) {
            $rawContent = Get-Content $filePath -Raw
            $cleanedContent = $rawContent -replace '(?m),(?=\s*[\}\]])', ''
            try {
                $jsonObj = $cleanedContent | ConvertFrom-Json
                $needsSave = ($rawContent -ne $cleanedContent)
                if ($null -ne $jsonObj.broadcaster_init -and $jsonObj.broadcaster_init.retries -ne 50) {
                    $jsonObj.broadcaster_init.retries = 50
                    $needsSave = $true
                }
                if ($needsSave) { $jsonObj | ConvertTo-Json -Depth 10 | Set-Content $filePath }
            } catch { }
        }
    }
}

Import-PortMap
Repair-NetConfigFiles

# ==============================================================================
# 3. CONFIGURATION MANAGEMENT
# ==============================================================================

Function Get-MonitorConfig {
    $defaultConfig = @{
        amountOfInstances = 1
        basePort = 6792
        delayProcessCheck = 5000
        numTaskThreads = 2
        timeStep = 120
        additionalArgs = "-server -headless -noovr -fixedtimestep -nosymbollookup"
        suppressSetupWarning = $false
        autoUpdate = $true
        updateInterval = "Daily"
        lastUpdateCheckDate = "2000-01-01T00:00:00"
        pauseSpawning = $false
        autoArchive = $true
        autoPurge = $false
        purgeInterval = "Weekly"
        enableApi = $true
        allowMonitorApi = $true
        titlePid = $true; titlePorts = $true; titleLobby = $true; titlePlayers = $true; titleUptime = $true
        trayPid = $true; trayPorts = $true; trayLobby = $false; trayPlayers = $true; trayUptime = $true
    }

    if (-not (Test-Path $MonitorFile)) {
        if (Test-Path $SetupFile) {
            $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
            if ($dashData.numInstances) { $defaultConfig.amountOfInstances = $dashData.numInstances }
            if ($dashData.lowerPort) { $defaultConfig.basePort = $dashData.lowerPort }
        }
        $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content $MonitorFile
        return $defaultConfig
    }
    
    $config = Get-Content $MonitorFile -Raw | ConvertFrom-Json
    $saveNeeded = $false

    foreach ($key in $defaultConfig.Keys) {
        if ($null -eq $config.$key) { 
            $config | Add-Member -MemberType NoteProperty -Name $key -Value $defaultConfig[$key] -Force
            $saveNeeded = $true 
        }
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
        $dashData.upperPort = $Global:BasePort + ([int]$numInstances * 2) 
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
            if (Test-Path $EchoExePath) { $Shortcut.IconLocation = $EchoExePath }
            $Shortcut.Save()
        } catch { }
    } else {
        if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force }
    }
}

$initConfig = Get-MonitorConfig
$Global:BasePort = $initConfig.basePort
Set-ApiAccess $initConfig.enableApi

# ==============================================================================
# 4. LOG MAINTENANCE LOGIC
# ==============================================================================

Function Invoke-LogMaintenance {
    param([switch]$ManualArchive, [switch]$ManualPurge)
    $runningJobs = Get-Job -Name "LogMaintenance_Manual", "LogMaintenance_Auto" -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
    if ($runningJobs) { return }

    $config = Get-MonitorConfig
    $IsManual = $ManualArchive -or $ManualPurge
    $jobArgs = @($config, $LogPath, $LogPathOld, [bool]$ManualArchive, [bool]$ManualPurge, [bool]$IsManual)
    $jobName = if ($IsManual) { "LogMaintenance_Manual" } else { "LogMaintenance_Auto" }

    Start-Job -Name $jobName -ArgumentList $jobArgs -ScriptBlock {
        param($jobConfig, $jobLogPath, $jobLogPathOld, $IsManualArchive, $IsManualPurge, $IsManual)
        $now = Get-Date

        if ($IsManualArchive -or (-not $IsManual -and $jobConfig.autoArchive)) {
            $targetLogs = if ($IsManualArchive) {
                @(Get-ChildItem -Path $jobLogPath, $jobLogPathOld -Filter "*.log" -File -ErrorAction SilentlyContinue)
            } else {
                @(Get-ChildItem -Path $jobLogPath, $jobLogPathOld -Filter "*.log" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $now.AddDays(-1) })
            }
            
            if ($targetLogs) {
                $foldersToCompress = @{} 
                foreach ($log in $targetLogs) {
                    $logDate = $log.LastWriteTime
                    $startOfWeek = $logDate.AddDays(-([int]$logDate.DayOfWeek)).Date
                    $endOfWeek = $startOfWeek.AddDays(6).Date
                    $weekFolder = Join-Path $jobLogPathOld "Week_$($startOfWeek.ToString('MMM_dd'))_to_$($endOfWeek.ToString('MMM_dd_yyyy'))"
                    
                    if (-not (Test-Path -LiteralPath $weekFolder)) { New-Item -ItemType Directory -Path $weekFolder -Force | Out-Null }
                    $foldersToCompress[$weekFolder] = $true
                    $destPath = Join-Path $weekFolder $log.Name
                    if ($log.Directory.FullName -ne $weekFolder) { try { Move-Item -LiteralPath $log.FullName -Destination $destPath -Force -ErrorAction Stop } catch {} }
                }
                foreach ($folder in $foldersToCompress.Keys) {
                    Start-Process -FilePath "compact.exe" -ArgumentList "/c /i /q `"$folder`"" -WindowStyle Hidden -Wait
                    Start-Process -FilePath "compact.exe" -ArgumentList "/c /i /q `"$folder\*`"" -WindowStyle Hidden -Wait
                }
            }
        }

        if ($IsManualPurge -or (-not $IsManual -and $jobConfig.autoPurge)) {
            $daysToKeep = switch ($jobConfig.purgeInterval) { "Daily" {1} "Weekly" {7} "Monthly" {30} default {7} }
            $cutoffDate = $now.AddDays(-$daysToKeep)
            
            Get-ChildItem -LiteralPath $jobLogPathOld -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoffDate } | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $jobLogPathOld -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName -Descending | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } | Out-Null
}

# ==============================================================================
# 5. GUI: CONFIGURATION WINDOW
# ==============================================================================

Function Show-ConfigWindow {
    $monitorData = Get-MonitorConfig
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Server Monitor Configuration"
    $form.Size = New-Object System.Drawing.Size(460, 600)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(10, 10)
    $tabControl.Size = New-Object System.Drawing.Size(425, 460)
    $form.Controls.Add($tabControl)

    # --- TAB 1: SERVER SETTINGS ---
    $tabServer = New-Object System.Windows.Forms.TabPage
    $tabServer.Text = "Server Settings"
    $tabControl.TabPages.Add($tabServer)

    $lblInst = New-Object System.Windows.Forms.Label
    $lblInst.Text = "Number of Instances:"
    $lblInst.Location = New-Object System.Drawing.Point(20, 25)
    $lblInst.AutoSize = $true
    $tabServer.Controls.Add($lblInst)

    $txtInst = New-Object System.Windows.Forms.TextBox
    $txtInst.Location = New-Object System.Drawing.Point(250, 22)
    $txtInst.Size = New-Object System.Drawing.Size(120, 20)
    $txtInst.Text = "$($monitorData.amountOfInstances)"
    $tabServer.Controls.Add($txtInst)

    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text = "Base Port:"
    $lblPort.Location = New-Object System.Drawing.Point(20, 60)
    $lblPort.AutoSize = $true
    $tabServer.Controls.Add($lblPort)

    $txtPort = New-Object System.Windows.Forms.TextBox
    $txtPort.Location = New-Object System.Drawing.Point(250, 57)
    $txtPort.Size = New-Object System.Drawing.Size(120, 20)
    $txtPort.Text = "$($monitorData.basePort)"
    $tabServer.Controls.Add($txtPort)

    $lblThreads = New-Object System.Windows.Forms.Label
    $lblThreads.Text = "Threads per Instance:"
    $lblThreads.Location = New-Object System.Drawing.Point(20, 95)
    $lblThreads.AutoSize = $true
    $tabServer.Controls.Add($lblThreads)

    $txtThreads = New-Object System.Windows.Forms.TextBox
    $txtThreads.Location = New-Object System.Drawing.Point(250, 92)
    $txtThreads.Size = New-Object System.Drawing.Size(120, 20)
    $txtThreads.Text = "$($monitorData.numTaskThreads)"
    $tabServer.Controls.Add($txtThreads)

    $lblTime = New-Object System.Windows.Forms.Label
    $lblTime.Text = "Server Timestep:"
    $lblTime.Location = New-Object System.Drawing.Point(20, 130)
    $lblTime.AutoSize = $true
    $tabServer.Controls.Add($lblTime)

    $rbStd = New-Object System.Windows.Forms.RadioButton
    $rbStd.Text = "Standard (120)"
    $rbStd.Location = New-Object System.Drawing.Point(150, 128)
    $rbStd.AutoSize = $true
    $tabServer.Controls.Add($rbStd)

    $rbComp = New-Object System.Windows.Forms.RadioButton
    $rbComp.Text = "Competitive (180)"
    $rbComp.Location = New-Object System.Drawing.Point(260, 128)
    $rbComp.AutoSize = $true
    $tabServer.Controls.Add($rbComp)

    if ($monitorData.timeStep -eq 180) { $rbComp.Checked = $true } else { $rbStd.Checked = $true }

    $lblArgs = New-Object System.Windows.Forms.Label
    $lblArgs.Text = "Additional Args:"
    $lblArgs.Location = New-Object System.Drawing.Point(20, 165)
    $lblArgs.AutoSize = $true
    $tabServer.Controls.Add($lblArgs)

    $txtArgs = New-Object System.Windows.Forms.TextBox
    $txtArgs.Location = New-Object System.Drawing.Point(20, 185)
    $txtArgs.Size = New-Object System.Drawing.Size(380, 20)
    $txtArgs.Text = "$($monitorData.additionalArgs)"
    $tabServer.Controls.Add($txtArgs)

    $chkApi = New-Object System.Windows.Forms.CheckBox
    $chkApi.Text = "Enable EchoVR API"
    $chkApi.Location = New-Object System.Drawing.Point(20, 220)
    $chkApi.AutoSize = $true
    $chkApi.Checked = $monitorData.enableApi
    $tabServer.Controls.Add($chkApi)

    # --- TAB 2: MONITOR SETTINGS ---
    $tabMonitor = New-Object System.Windows.Forms.TabPage
    $tabMonitor.Text = "Monitor Settings"
    $tabControl.TabPages.Add($tabMonitor)

    $lblCheck = New-Object System.Windows.Forms.Label
    $lblCheck.Text = "Monitor Update Frequency (sec):"
    $lblCheck.Location = New-Object System.Drawing.Point(20, 15)
    $lblCheck.AutoSize = $true
    $tabMonitor.Controls.Add($lblCheck)

    $txtCheck = New-Object System.Windows.Forms.TextBox
    $txtCheck.Location = New-Object System.Drawing.Point(250, 12)
    $txtCheck.Size = New-Object System.Drawing.Size(120, 20)
    $txtCheck.Text = "$($monitorData.delayProcessCheck / 1000)"
    $tabMonitor.Controls.Add($txtCheck)

    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = "Start with Windows"
    $chkStartup.Location = New-Object System.Drawing.Point(20, 45)
    $chkStartup.AutoSize = $true
    $chkStartup.Checked = (Test-Path $ShortcutPath)
    $tabMonitor.Controls.Add($chkStartup)

    $chkArchive = New-Object System.Windows.Forms.CheckBox
    $chkArchive.Text = "Auto-Archive Logs"
    $chkArchive.Location = New-Object System.Drawing.Point(20, 75)
    $chkArchive.AutoSize = $true
    $chkArchive.Checked = $monitorData.autoArchive
    $tabMonitor.Controls.Add($chkArchive)

    $chkPurge = New-Object System.Windows.Forms.CheckBox
    $chkPurge.Text = "Purge Old Logs:"
    $chkPurge.Location = New-Object System.Drawing.Point(20, 105)
    $chkPurge.AutoSize = $true
    $chkPurge.Checked = $monitorData.autoPurge
    $tabMonitor.Controls.Add($chkPurge)

    $cmbPurge = New-Object System.Windows.Forms.ComboBox
    $cmbPurge.Location = New-Object System.Drawing.Point(135, 103)
    $cmbPurge.Size = New-Object System.Drawing.Size(80, 20)
    $cmbPurge.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Daily", "Weekly", "Monthly") | ForEach-Object { $cmbPurge.Items.Add($_) | Out-Null }
    $cmbPurge.SelectedItem = $monitorData.purgeInterval
    $cmbPurge.Enabled = $chkPurge.Checked
    $tabMonitor.Controls.Add($cmbPurge)
    $chkPurge.Add_CheckedChanged({ $cmbPurge.Enabled = $chkPurge.Checked })

    $chkAutoUpdate = New-Object System.Windows.Forms.CheckBox
    $chkAutoUpdate.Text = "Check Updates:"
    $chkAutoUpdate.Location = New-Object System.Drawing.Point(20, 135)
    $chkAutoUpdate.AutoSize = $true
    $chkAutoUpdate.Checked = $monitorData.autoUpdate
    $tabMonitor.Controls.Add($chkAutoUpdate)

    $cmbUpdate = New-Object System.Windows.Forms.ComboBox
    $cmbUpdate.Location = New-Object System.Drawing.Point(135, 133)
    $cmbUpdate.Size = New-Object System.Drawing.Size(80, 20)
    $cmbUpdate.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Daily", "Weekly", "Monthly") | ForEach-Object { $cmbUpdate.Items.Add($_) | Out-Null }
    $cmbUpdate.SelectedItem = $monitorData.updateInterval
    $cmbUpdate.Enabled = $chkAutoUpdate.Checked
    $tabMonitor.Controls.Add($cmbUpdate)
    $chkAutoUpdate.Add_CheckedChanged({ $cmbUpdate.Enabled = $chkAutoUpdate.Checked })

    # -- Monitor API Toggle --
    $chkAllowMonitorApi = New-Object System.Windows.Forms.CheckBox
    $chkAllowMonitorApi.Text = "Allow Monitor API Usage"
    $chkAllowMonitorApi.Location = New-Object System.Drawing.Point(20, 165)
    $chkAllowMonitorApi.AutoSize = $true
    $chkAllowMonitorApi.Checked = $monitorData.allowMonitorApi
    $tabMonitor.Controls.Add($chkAllowMonitorApi)

    # -- Telemetry Settings --
    $lblTelemetry = New-Object System.Windows.Forms.Label
    $lblTelemetry.Text = "Telemetry Visibility:"
    $lblTelemetry.Font = New-Object System.Drawing.Font("Arial", 8, [System.Drawing.FontStyle]::Bold)
    $lblTelemetry.Location = New-Object System.Drawing.Point(20, 195)
    $lblTelemetry.AutoSize = $true
    $tabMonitor.Controls.Add($lblTelemetry)

    $lblTitleCol = New-Object System.Windows.Forms.Label
    $lblTitleCol.Text = "Window Title"
    $lblTitleCol.Location = New-Object System.Drawing.Point(20, 215)
    $lblTitleCol.AutoSize = $true
    $tabMonitor.Controls.Add($lblTitleCol)

    $lblTrayCol = New-Object System.Windows.Forms.Label
    $lblTrayCol.Text = "System Tray"
    $lblTrayCol.Location = New-Object System.Drawing.Point(170, 215)
    $lblTrayCol.AutoSize = $true
    $tabMonitor.Controls.Add($lblTrayCol)

    $chkTitlePid = New-Object System.Windows.Forms.CheckBox; $chkTitlePid.Text = "PID"; $chkTitlePid.Location = New-Object System.Drawing.Point(20, 240); $chkTitlePid.AutoSize = $true; $chkTitlePid.Checked = $monitorData.titlePid; $tabMonitor.Controls.Add($chkTitlePid)
    $chkTrayPid = New-Object System.Windows.Forms.CheckBox; $chkTrayPid.Text = "PID"; $chkTrayPid.Location = New-Object System.Drawing.Point(170, 240); $chkTrayPid.AutoSize = $true; $chkTrayPid.Checked = $monitorData.trayPid; $tabMonitor.Controls.Add($chkTrayPid)

    $chkTitlePorts = New-Object System.Windows.Forms.CheckBox; $chkTitlePorts.Text = "Ports"; $chkTitlePorts.Location = New-Object System.Drawing.Point(20, 265); $chkTitlePorts.AutoSize = $true; $chkTitlePorts.Checked = $monitorData.titlePorts; $tabMonitor.Controls.Add($chkTitlePorts)
    $chkTrayPorts = New-Object System.Windows.Forms.CheckBox; $chkTrayPorts.Text = "Ports"; $chkTrayPorts.Location = New-Object System.Drawing.Point(170, 265); $chkTrayPorts.AutoSize = $true; $chkTrayPorts.Checked = $monitorData.trayPorts; $tabMonitor.Controls.Add($chkTrayPorts)

    $chkTitleLobby = New-Object System.Windows.Forms.CheckBox; $chkTitleLobby.Text = "Lobby Info [API]"; $chkTitleLobby.Location = New-Object System.Drawing.Point(20, 290); $chkTitleLobby.AutoSize = $true; $chkTitleLobby.Checked = $monitorData.titleLobby; $tabMonitor.Controls.Add($chkTitleLobby)
    $chkTrayLobby = New-Object System.Windows.Forms.CheckBox; $chkTrayLobby.Text = "Lobby Info [API]"; $chkTrayLobby.Location = New-Object System.Drawing.Point(170, 290); $chkTrayLobby.AutoSize = $true; $chkTrayLobby.Checked = $monitorData.trayLobby; $tabMonitor.Controls.Add($chkTrayLobby)

    $chkTitlePlayers = New-Object System.Windows.Forms.CheckBox; $chkTitlePlayers.Text = "Player Count [API]"; $chkTitlePlayers.Location = New-Object System.Drawing.Point(20, 315); $chkTitlePlayers.AutoSize = $true; $chkTitlePlayers.Checked = $monitorData.titlePlayers; $tabMonitor.Controls.Add($chkTitlePlayers)
    $chkTrayPlayers = New-Object System.Windows.Forms.CheckBox; $chkTrayPlayers.Text = "Player Count [API]"; $chkTrayPlayers.Location = New-Object System.Drawing.Point(170, 315); $chkTrayPlayers.AutoSize = $true; $chkTrayPlayers.Checked = $monitorData.trayPlayers; $tabMonitor.Controls.Add($chkTrayPlayers)

    $chkTitleUptime = New-Object System.Windows.Forms.CheckBox; $chkTitleUptime.Text = "Uptime"; $chkTitleUptime.Location = New-Object System.Drawing.Point(20, 340); $chkTitleUptime.AutoSize = $true; $chkTitleUptime.Checked = $monitorData.titleUptime; $tabMonitor.Controls.Add($chkTitleUptime)
    $chkTrayUptime = New-Object System.Windows.Forms.CheckBox; $chkTrayUptime.Text = "Uptime"; $chkTrayUptime.Location = New-Object System.Drawing.Point(170, 340); $chkTrayUptime.AutoSize = $true; $chkTrayUptime.Checked = $monitorData.trayUptime; $tabMonitor.Controls.Add($chkTrayUptime)

    # Setup the logic specifically for the new Monitor API Usage checkbox
    $chkAllowMonitorApi.Add_CheckedChanged({
        $enabled = $chkAllowMonitorApi.Checked
        $chkTitleLobby.Enabled = $enabled; $chkTrayLobby.Enabled = $enabled
        $chkTitlePlayers.Enabled = $enabled; $chkTrayPlayers.Enabled = $enabled
    })
    
    # Force initial state on load
    $chkTitleLobby.Enabled = $monitorData.allowMonitorApi; $chkTrayLobby.Enabled = $monitorData.allowMonitorApi
    $chkTitlePlayers.Enabled = $monitorData.allowMonitorApi; $chkTrayPlayers.Enabled = $monitorData.allowMonitorApi

    # --- TAB 3: ABOUT ---
    $tabAbout = New-Object System.Windows.Forms.TabPage
    $tabAbout.Text = "About"
    $tabControl.TabPages.Add($tabAbout)

    $pfcStencil = New-Object System.Drawing.Text.PrivateFontCollection
    $pfcNeuro = New-Object System.Drawing.Text.PrivateFontCollection
    $fontEchoStencilPath = Join-Path $ScriptRoot "content\engine\core\fonts\EchoStencil.ttf"
    $fontNeuropolPath = Join-Path $ScriptRoot "content\engine\core\fonts\Neuropol-X-Rg.otf"

    if (Test-Path -LiteralPath $fontEchoStencilPath) { $pfcStencil.AddFontFile($fontEchoStencilPath) }
    if (Test-Path -LiteralPath $fontNeuropolPath) { $pfcNeuro.AddFontFile($fontNeuropolPath) }

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "EchoVR Server Monitor"
    if ($pfcStencil.Families.Count -gt 0) { $lblTitle.Font = New-Object System.Drawing.Font($pfcStencil.Families[0], 12, [System.Drawing.FontStyle]::Regular) } 
    else { $lblTitle.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold) }
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblTitle.Location = New-Object System.Drawing.Point(10, 40)
    $lblTitle.Size = New-Object System.Drawing.Size(400, 30)
    $tabAbout.Controls.Add($lblTitle)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "v$($Global:Version)"
    if ($pfcNeuro.Families.Count -gt 0) { $lblVersion.Font = New-Object System.Drawing.Font($pfcNeuro.Families[0], 12, [System.Drawing.FontStyle]::Bold) } 
    else { $lblVersion.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold) }
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblVersion.Location = New-Object System.Drawing.Point(10, 65)
    $lblVersion.Size = New-Object System.Drawing.Size(400, 30)
    $tabAbout.Controls.Add($lblVersion)

    $lblPing = New-Object System.Windows.Forms.Label
    $lblPing.Text = "Ping @berg_ on Discord for issues/feedback!"
    $lblPing.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblPing.Location = New-Object System.Drawing.Point(10, 110)
    $lblPing.Size = New-Object System.Drawing.Size(400, 20)
    $tabAbout.Controls.Add($lblPing)

    $btnAboutUpdate = New-Object System.Windows.Forms.Button
    $btnAboutUpdate.Text = "Check for Updates"
    $btnAboutUpdate.Location = New-Object System.Drawing.Point(135, 150)
    $btnAboutUpdate.Size = New-Object System.Drawing.Size(150, 30)
    $btnAboutUpdate.Add_Click({ Test-ForUpdates -ManualCheck $true })
    $tabAbout.Controls.Add($btnAboutUpdate)

    # --- BOTTOM BUTTONS ---
    $btnOpenLocal = New-Object System.Windows.Forms.Button
    $btnOpenLocal.Text = "Open Server Config"
    $btnOpenLocal.Location = New-Object System.Drawing.Point(30, 485)
    $btnOpenLocal.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenLocal.Add_Click({ Invoke-Item $LocalConfigPath })
    $form.Controls.Add($btnOpenLocal)

    $btnOpenEcho = New-Object System.Windows.Forms.Button
    $btnOpenEcho.Text = "Open Echo Folder"
    $btnOpenEcho.Location = New-Object System.Drawing.Point(235, 485)
    $btnOpenEcho.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenEcho.Add_Click({ Invoke-Item $ScriptRoot })
    $form.Controls.Add($btnOpenEcho)
    
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(85, 520)
    $btnSave.Size = New-Object System.Drawing.Size(80, 25)
    $btnSave.Add_Click({
        try {
            if ([int]$txtInst.Text -lt 1) { throw "Invalid Instances" }
            if ([int]$txtPort.Text -lt 1 -or [int]$txtPort.Text -gt 65535) { throw "Invalid Port" }
            $null = [double]$txtCheck.Text
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Please enter valid numbers for the required fields.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($btnSave)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Defaults"
    $btnRestore.Location = New-Object System.Drawing.Point(180, 520)
    $btnRestore.Size = New-Object System.Drawing.Size(80, 25)
    $btnRestore.Add_Click({
        $txtInst.Text = "1"; $txtPort.Text = "6792"; $txtThreads.Text = "2"; $rbStd.Checked = $true
        $txtArgs.Text = "-server -headless -noovr -fixedtimestep -nosymbollookup"
        $txtCheck.Text = "5"; $chkStartup.Checked = $true; $chkArchive.Checked = $true
        $chkPurge.Checked = $false; $cmbPurge.SelectedItem = "Weekly"
        $chkAutoUpdate.Checked = $true; $cmbUpdate.SelectedItem = "Daily"
        $chkApi.Checked = $true
        $chkAllowMonitorApi.Checked = $true
        $chkTitlePid.Checked = $true; $chkTitlePorts.Checked = $true; $chkTitleLobby.Checked = $true; $chkTitlePlayers.Checked = $true; $chkTitleUptime.Checked = $true
        $chkTrayPid.Checked = $true; $chkTrayPorts.Checked = $true; $chkTrayLobby.Checked = $false; $chkTrayPlayers.Checked = $true; $chkTrayUptime.Checked = $true
    })
    $form.Controls.Add($btnRestore)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Discard"
    $btnCancel.Location = New-Object System.Drawing.Point(275, 520)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 25)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $numInst = [int]$txtInst.Text
        $tStep = if ($rbComp.Checked) { 180 } else { 120 }
        
        # Check if any Server Settings were actually changed
        $serverSettingsChanged = $false
        if ($monitorData.amountOfInstances -ne $numInst) { $serverSettingsChanged = $true }
        if ($monitorData.basePort -ne [int]$txtPort.Text) { $serverSettingsChanged = $true }
        if ($monitorData.numTaskThreads -ne [int]$txtThreads.Text) { $serverSettingsChanged = $true }
        if ($monitorData.timeStep -ne $tStep) { $serverSettingsChanged = $true }
        if ($monitorData.additionalArgs -ne $txtArgs.Text) { $serverSettingsChanged = $true }
        if ($monitorData.enableApi -ne $chkApi.Checked) { $serverSettingsChanged = $true }

        $monitorData.amountOfInstances = $numInst
        $monitorData.basePort = [int]$txtPort.Text
        $monitorData.delayProcessCheck = [int]([double]$txtCheck.Text * 1000)
        $monitorData.numTaskThreads = [int]$txtThreads.Text
        $monitorData.timeStep = $tStep
        $monitorData.additionalArgs = $txtArgs.Text
        $monitorData.autoUpdate = $chkAutoUpdate.Checked
        $monitorData.updateInterval = $cmbUpdate.SelectedItem
        $monitorData.autoArchive = $chkArchive.Checked
        $monitorData.autoPurge = $chkPurge.Checked
        $monitorData.purgeInterval = $cmbPurge.SelectedItem
        $monitorData.enableApi = $chkApi.Checked
        $monitorData.allowMonitorApi = $chkAllowMonitorApi.Checked
        $monitorData.titlePid = $chkTitlePid.Checked; $monitorData.titlePorts = $chkTitlePorts.Checked; $monitorData.titleLobby = $chkTitleLobby.Checked; $monitorData.titlePlayers = $chkTitlePlayers.Checked; $monitorData.titleUptime = $chkTitleUptime.Checked
        $monitorData.trayPid = $chkTrayPid.Checked; $monitorData.trayPorts = $chkTrayPorts.Checked; $monitorData.trayLobby = $chkTrayLobby.Checked; $monitorData.trayPlayers = $chkTrayPlayers.Checked; $monitorData.trayUptime = $chkTrayUptime.Checked

        $Global:BasePort = $monitorData.basePort

        Switch-StartupShortcut $chkStartup.Checked
        Set-ApiAccess $monitorData.enableApi
        Save-MonitorConfig $monitorData
        Update-ExternalConfigs $numInst

        # Only perform a soft shutdown if server settings were altered
        if ($serverSettingsChanged) {
            if ($monitorData.enableApi -and $monitorData.allowMonitorApi) {
                foreach ($k in $Global:PortMap.Keys) { $Global:PortMap[$k].ShutdownQueued = $true }
                [System.Windows.Forms.MessageBox]::Show("Configuration Saved. Server settings were modified; a soft shutdown has been queued for active instances to apply changes.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            } else {
                [System.Windows.Forms.MessageBox]::Show("Configuration Saved. Server settings were modified, but soft shutdowns are disabled (requires API). Please restart instances manually.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Configuration Saved.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    }
}

# ==============================================================================
# 6. PORT MANAGEMENT
# ==============================================================================

Function Get-AvailablePortPair {
    for ($i = 0; $i -lt 100; $i++) {
        $gsPort = $Global:BasePort + ($i * 2)
        $apiPort = $gsPort + 1
        $inUse = $false
        foreach ($pidKey in $Global:PortMap.Keys) {
            $entry = $Global:PortMap[$pidKey]
            if ($entry.GS -eq $gsPort -or $entry.API -eq $apiPort) { $inUse = $true; break }
        }
        if (-not $inUse) { return @{ GS=$gsPort; API=$apiPort } }
    }
    return $null
}

# ==============================================================================
# 7. SYSTEM TRAY & MENU
# ==============================================================================

$ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip

$MenuItemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemStatus.Text = "Status: Initializing..."
$MenuItemStatus.Enabled = $false
$ContextMenuStrip.Items.Add($MenuItemStatus) | Out-Null

$MenuItemSeparator1 = New-Object System.Windows.Forms.ToolStripSeparator
$ContextMenuStrip.Items.Add($MenuItemSeparator1) | Out-Null

$MenuItemConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemConfig.Text = "Configure Settings"
$MenuItemConfig.Add_Click({ $MonitorTimer.Stop(); Show-ConfigWindow; $MonitorTimer.Start() })
$ContextMenuStrip.Items.Add($MenuItemConfig) | Out-Null

$MenuItemPortal = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemPortal.Text = "Open EchoVRCE Portal"
$MenuItemPortal.Add_Click({ Start-Process "https://echovrce.com/" })
$ContextMenuStrip.Items.Add($MenuItemPortal) | Out-Null

$ContextMenuStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$MenuItemPause = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemPause.Text = "Pause Server Spawning"
$MenuItemPause.CheckOnClick = $true
$initialConfig = Get-MonitorConfig
$MenuItemPause.Checked = $initialConfig.pauseSpawning
$MenuItemPause.Add_Click({
    $conf = Get-MonitorConfig
    $conf.pauseSpawning = $MenuItemPause.Checked
    Save-MonitorConfig $conf
    if (-not $conf.pauseSpawning) { $Global:LinkCodeActive = $false }
})
$ContextMenuStrip.Items.Add($MenuItemPause) | Out-Null

$MenuItemExit = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemExit.Text = "Exit"
$MenuItemExit.Add_Click({
    $MonitorTimer.Stop()
    $NotifyIcon.Visible = $false
    Save-PortMap
    [System.Windows.Forms.Application]::Exit()
})
$ContextMenuStrip.Items.Add($MenuItemExit) | Out-Null

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($EchoExePath)
$NotifyIcon.Text = "EchoVR Server Monitor"
$NotifyIcon.ContextMenuStrip = $ContextMenuStrip
$NotifyIcon.Visible = $true

# ==============================================================================
# 8. NATIVE API POLLING
# ==============================================================================

# Ultra-fast TCP port check to prevent UI freezing if server is down
Function Test-PortOpen ($port, $timeoutMs=100) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $res = $tcp.BeginConnect("127.0.0.1", $port, $null, $null)
        $success = $res.AsyncWaitHandle.WaitOne($timeoutMs, $false)
        if ($success) { $tcp.EndConnect($res); $tcp.Close(); return $true }
        $tcp.Close()
    } catch {}
    return $false
}

Function Get-EchoApiData ($apiPort) {
    $res = @{ success=$false; is500=$false; is404=$false; sessionStr=""; bonesStr="" }
    try {
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$apiPort/session")
        $req.Timeout = 800
        $req.Method = "GET"
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $res.sessionStr = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        $res.success = $true
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $resp = [System.Net.HttpWebResponse]$_.Exception.Response
            if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::InternalServerError) {
                $res.is500 = $true
                $resp.Close()
                try {
                    $req2 = [System.Net.WebRequest]::Create("http://127.0.0.1:$apiPort/player_bones")
                    $req2.Timeout = 800
                    $resp2 = $req2.GetResponse()
                    $stream2 = $resp2.GetResponseStream()
                    $reader2 = New-Object System.IO.StreamReader($stream2)
                    $res.bonesStr = $reader2.ReadToEnd()
                    $reader2.Close(); $resp2.Close()
                    $res.success = $true
                } catch {}
            } elseif ($resp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                $res.is404 = $true
                $res.success = $true
                $resp.Close()
            } else {
                $resp.Close()
            }
        }
    } catch {}
    return $res
}

# ==============================================================================
# 9. MONITORING LOGIC
# ==============================================================================

$MonitorTimer = New-Object System.Windows.Forms.Timer
$MonitorTimer.Interval = 3000

$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck
    $Global:BasePort = $config.basePort

    $now = Get-Date
    $currentDay = $now.DayOfYear
    if ($Global:LastLogMaintenanceDay -ne $currentDay) {
        Invoke-LogMaintenance
        if ($config.autoUpdate) {
            $daysToWait = switch ($config.updateInterval) { "Daily" {1} "Weekly" {7} "Monthly" {30} default {7} }
            $lastCheck = [datetime]$config.lastUpdateCheckDate
            if (($now - $lastCheck).TotalDays -ge $daysToWait) {
                Test-ForUpdates -ManualCheck $false
                $config.lastUpdateCheckDate = $now.ToString("o")
                Save-MonitorConfig $config
            }
        }
        $Global:LastLogMaintenanceDay = $currentDay
    }

    if ($MenuItemPause.Checked -ne $config.pauseSpawning) { $MenuItemPause.Checked = $config.pauseSpawning }

    $processes = @(Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue)
    $runningCount = $processes.Count
    $runningIds = $processes.Id

    $trackedPids = @($Global:PortMap.Keys)
    foreach ($pidKey in $trackedPids) {
        if ($runningIds -notcontains $pidKey) { $Global:PortMap.Remove($pidKey) }
    }

    $canSoftShutdown = ($config.enableApi -and $config.allowMonitorApi)

    # --- UNIFIED LOG READING & API POLLING ---
    if ($processes) {
        foreach ($proc in $processes) {
            $pData = $Global:PortMap[$proc.Id]
            if ($null -eq $pData) { continue }

            # 1. Soft Shutdown Evaluation
            if ($pData.ShutdownQueued) {
                if ($pData.ModeTitle -eq "Idle") {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    $Global:PortMap.Remove($proc.Id)
                    continue
                }
            }

            # 2. Log Parsing (Kept specifically for pulling Link Codes on initial start)
            if ($null -eq $pData.LogPath -or -not (Test-Path -LiteralPath $pData.LogPath)) {
                $logFile = Get-ChildItem -Path $LogPath -Filter "*_$($proc.Id).log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($logFile) { $pData.LogPath = $logFile.FullName }
            }

            if ($pData.LogPath) {
                $lines = Get-Content -LiteralPath $pData.LogPath -Tail 15 -ErrorAction SilentlyContinue
                if ($lines) {
                    $content = $lines -join "`n"
                    if (-not $Global:LinkCodeActive -and -not $Global:NotifiedPids.ContainsKey($proc.Id)) {
                        if ($content -match ">>>\s*(?<code>[A-Z0-9]+)\s*<<<") {
                            $code = $Matches['code'].Trim()
                            if (-not [string]::IsNullOrWhiteSpace($code)) {
                                $Global:NotifiedPids[$proc.Id] = $true; $Global:LinkCodeActive = $true
                                $conf = Get-MonitorConfig; $conf.pauseSpawning = $true; Save-MonitorConfig $conf
                                $msgBody = "Your link code is: $code`n`nClick OK to open command central.`nClick Link EchoVRCE and enter your code.`n`nUnpause server spawning in the system tray after linking."
                                $msgTitle = "Link Code Detected"
                                $discordUrl = "discord://https://discord.com/channels/779349159852769310/1227795372244729926/1355176306484056084"
                                $cmd = "Add-Type -AssemblyName System.Windows.Forms; `$res = [System.Windows.Forms.MessageBox]::Show('$msgBody', '$msgTitle', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information); if (`$res -eq [System.Windows.Forms.DialogResult]::OK) { Start-Process '$discordUrl' }"
                                $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
                                $encodedCommand = [Convert]::ToBase64String($bytes)
                                Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-EncodedCommand $encodedCommand" -WindowStyle Hidden
                            }
                        }
                    }
                }
            }

            # 3. Synchronous Native API Polling
            if ($config.allowMonitorApi -and (Test-PortOpen $pData.API 100)) {
                $jobRes = Get-EchoApiData $pData.API
                
                if ($jobRes.success) {
                    $modeStrTitle = "Unknown Mode"; $modeStrTray = "Unknown"
                    $maxPid = -1; $specs = 0
                    
                    if ($jobRes.is404) {
                        $modeStrTitle = "Idle"; $modeStrTray = "Idle"
                    } elseif ($jobRes.is500) {
                        $modeStrTitle = "Social Lobby"; $modeStrTray = "Social Lobby"
                        if ($jobRes.bonesStr) {
                            $playerMatches = [regex]::Matches($jobRes.bonesStr, '(?i)"playerid"\s*:\s*(\d+)')
                            foreach ($m in $playerMatches) {
                                $val = [int]$m.Groups[1].Value
                                if ($val -gt $maxPid) { $maxPid = $val }
                            }
                        }
                    } else {
                        try {
                            $sessionObj = $jobRes.sessionStr | ConvertFrom-Json
                            
                            $mType = $sessionObj.match_type
                            if ($mType -eq "Echo_Combat") { $modeStrTray="Combat, Public"; $modeStrTitle="Public Combat Match" }
                            elseif ($mType -eq "Echo_Combat_Private") { $modeStrTray="Combat, Private"; $modeStrTitle="Private Combat Match" }
                            elseif ($mType -eq "Echo_Combat_Tournament") { $modeStrTray="Combat, Tournament"; $modeStrTitle="Tournament Combat Match" }
                            elseif ($mType -eq "Echo_Arena") { $modeStrTray="Arena, Public"; $modeStrTitle="Public Arena Match" }
                            elseif ($mType -eq "Echo_Arena_Private") { $modeStrTray="Arena, Private"; $modeStrTitle="Private Arena Match" }
                            elseif ($mType -eq "Echo_Arena_Tournament") { $modeStrTray="Arena, Tournament"; $modeStrTitle="Tournament Arena Match" }
                            
                            $mMap = $sessionObj.map_name
                            $mapName = ""
                            if ($mMap -eq "mpl_combat_fission") { $mapName = " (Fission)" }
                            elseif ($mMap -eq "mpl_combat_combustion") { $mapName = " (Combustion)" }
                            elseif ($mMap -eq "mpl_combat_dyson") { $mapName = " (Dyson)" }
                            elseif ($mMap -eq "mpl_combat_gauss") { $mapName = " (Surge)" }
                            elseif ($mMap -eq "mpl_arena_a") { $mapName = "" }
                            
                            if ($mapName) { $modeStrTray += " ($mapName)"; $modeStrTitle += "$mapName" }
                            
                            if ($sessionObj.teams) {
                                $playerMatches = [regex]::Matches($jobRes.sessionStr, '(?i)"playerid"\s*:\s*(\d+)')
                                foreach ($m in $playerMatches) {
                                    $val = [int]$m.Groups[1].Value
                                    if ($val -gt $maxPid) { $maxPid = $val }
                                }
                                foreach ($team in $sessionObj.teams) {
                                    if ($team.team -eq "SPECTATORS" -and $null -ne $team.players) {
                                        $specs = @($team.players).Count
                                    }
                                }
                            }
                        } catch {}
                    }
                    
                    if ($jobRes.is404) {
                        $pStrTitle = "0 Players Connected"; $pStrTray = "0 Players"
                        $totalConnected = 0
                    } else {
                        $totalConnected = $maxPid + 1
                        $activePlayers = $totalConnected - $specs
                        
                        if ($totalConnected -eq 0) {
                            $pStrTitle = "0 Players Connected"; $pStrTray = "0 Players"
                        } else {
                            if ($specs -gt 0) {
                                $pStrTitle = "$activePlayers Players Connected ($specs Spectating)"
                                $pStrTray = "$activePlayers Players ($specs Spec.)"
                            } else {
                                $pStrTitle = "$activePlayers Players Connected"
                                $pStrTray = "$activePlayers Players"
                            }
                        }
                    }
                    
                    $pData.ModeTitle = $modeStrTitle; $pData.ModeTray = $modeStrTray
                    $pData.PlayersTitle = $pStrTitle; $pData.PlayersTray = $pStrTray
                    $pData.PlayerCount = $totalConnected
                }
            }
        }
    }
    
    if ($canSoftShutdown) {
        $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances) (Click Instance to Queue Shutdown)"
    } else {
        $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances)"
    }

    $sepIndex = $ContextMenuStrip.Items.IndexOf($MenuItemSeparator1)
    for ($i = $sepIndex - 1; $i -gt 0; $i--) { $ContextMenuStrip.Items.RemoveAt($i) }

    if ($processes) {
        $pIndex = 1
        $sortedProcs = $processes | Sort-Object StartTime
        
        foreach ($proc in $sortedProcs) {
            try {
                $uptime = New-TimeSpan -Start $proc.StartTime -End $now
                $pData = $Global:PortMap[$proc.Id]
                
                # --- Format Window Title ---
                $titleParts = @("EchoVR Server $pIndex")
                if ($config.titlePid) { $titleParts += "PID: $($proc.Id)" }
                if ($config.titlePorts -and $pData) { $titleParts += "Session/API Ports: $($pData.GS), $($pData.API)" }
                if ($config.titleLobby -and $pData.ModeTitle) { $titleParts += "Mode: $($pData.ModeTitle)" }
                if ($config.titlePlayers -and $pData.PlayersTitle) { $titleParts += "$($pData.PlayersTitle)" }
                if ($config.titleUptime) { $titleParts += "Uptime: $($uptime.Hours)h $($uptime.Minutes)m" }
                
                if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                    $newTitle = $titleParts -join " - "
                    [Win32Window]::SetWindowText($proc.MainWindowHandle, $newTitle) | Out-Null
                }
                
                # --- Format Tray Item ---
                $trayParts = @("Server $pIndex")
                if ($config.trayPid) { $trayParts += "PID $($proc.Id)" }
                $trayStr = $trayParts -join " "
                
                $traySuffix = @()
                if ($config.trayPorts -and $pData) { $traySuffix += "GS:$($pData.GS) API:$($pData.API)" }
                if ($config.trayLobby -and $pData.ModeTray) { $traySuffix += "$($pData.ModeTray)" }
                if ($config.trayPlayers -and $pData.PlayersTray) { $traySuffix += "$($pData.PlayersTray)" }
                if ($config.trayUptime) { $traySuffix += "$($uptime.Hours)h $($uptime.Minutes)m" }
                if ($traySuffix.Count -gt 0) { $trayStr += " - " + ($traySuffix -join " - ") }

                $item = New-Object System.Windows.Forms.ToolStripMenuItem
                $item.Text = $trayStr
                
                if ($canSoftShutdown) {
                    $item.CheckOnClick = $true
                    $item.Checked = [bool]$pData.ShutdownQueued
                    $item.Tag = $proc.Id 
                    $item.Add_Click({
                        $clickedPid = $this.Tag
                        if ($Global:PortMap[$clickedPid]) {
                            $Global:PortMap[$clickedPid].ShutdownQueued = $this.Checked
                        }
                    })
                } else {
                    $item.CheckOnClick = $false
                }
                
                $ContextMenuStrip.Items.Insert($pIndex, $item)
                $pIndex++
            } catch { }
        }
    }

    if (-not $config.pauseSpawning) {
        $needed = $config.amountOfInstances - $runningCount
        if ($needed -gt 0) {
            $freshConfig = Get-MonitorConfig
            if (-not $freshConfig.pauseSpawning -and -not $Global:LinkCodeActive) {
                $portPair = Get-AvailablePortPair
                if ($null -ne $portPair) {
                    $launchArgs = "-numtaskthreads $($config.numTaskThreads) -timestep $($config.timeStep) $($config.additionalArgs) -port $($portPair.GS) -httpport $($portPair.API) -exitonerror"
                    $newProc = Start-Process -FilePath $EchoExePath -ArgumentList $launchArgs -WindowStyle Minimized -PassThru
                    
                    if ($newProc) {
                        $Global:PortMap[$newProc.Id] = @{
                            GS = $portPair.GS; API = $portPair.API
                            GS_Confirmed = $null; API_Confirmed = $null; LogPath = $null
                            ShutdownQueued = $false; PlayerCount = 0; ModeTitle = "Unknown Mode"
                        }
                    }
                }
            }
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 10. UPDATE LOGIC (Monitor + DLLs)
# ==============================================================================

Function Test-FileHash ($path, $targetHash) {
    if (-not (Test-Path $path)) { return $false }
    $hash = Get-FileHash -Path $path -Algorithm MD5
    return ($hash.Hash -eq $targetHash)
}

Function Update-DLLs ($Silent = $false) {
    $rawBaseUrl = "https://raw.githubusercontent.com/$Global:GithubOwner/$Global:GithubRepo/main/dll"
    $urlPNSRAD = "$rawBaseUrl/pnsradgameserver.dll"
    $urlDBG    = "$rawBaseUrl/dbgcore.dll"

    $running = Get-Process -Name $Script:EchoProcessName -ErrorAction SilentlyContinue
    if ($running) {
        if ($Silent) { return $false } # Abort silent update if servers are running
        
        $conf = Get-MonitorConfig
        $conf.pauseSpawning = $true
        Save-MonitorConfig $conf
        
        $msg = "Cannot update DLLs while instances are running.`n`nSpawning has been PAUSED.`nPlease manually close all EchoVR instances now, then click OK to proceed."
        $res = [System.Windows.Forms.MessageBox]::Show($msg, "Action Required", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
        
        if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        
        $running = Get-Process -Name $Script:EchoProcessName -ErrorAction SilentlyContinue
        if ($running) {
             [System.Windows.Forms.MessageBox]::Show("Instances are still running. Update aborted.", "Aborted", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
             return $false
        }
    }

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $urlPNSRAD -OutFile $Script:Path_PNSRAD
        Invoke-WebRequest -Uri $urlDBG -OutFile $Script:Path_DBGCORE
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show("DLLs updated successfully.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
        return $true
    } catch {
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show("Failed to download DLLs. Check internet or repo path.`nError: $_", "Download Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }
        return $false
    }
}

Function Test-ForUpdates ($ManualCheck = $false) {
    $apiUrl = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    $TargetFileName = if ($Global:IsBinary) { "EchoVR-Server-Monitor.exe" } else { "EchoVR-Server-Monitor.ps1" }
    
    $monitorUpdateAvailable = $false; $monitorAssetUrl = $null; $dllUpdateAvailable = $false

    try {
        if ($ManualCheck) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor }

        try {
            $headers = @{ "Cache-Control" = "no-cache"; "Pragma" = "no-cache" }
            $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -ErrorAction Stop
            $monitorAsset = $response.assets | Where-Object { $_.name -eq $TargetFileName } | Select-Object -First 1
            
            if ($monitorAsset) {
                $latestTag = $response.tag_name -replace "^v", ""
                $currentVer = $Global:Version -replace "^v", ""
                if ([System.Version]$latestTag -gt [System.Version]$currentVer) {
                    $monitorUpdateAvailable = $true; $monitorAssetUrl = $monitorAsset.browser_download_url
                }
            }
        } catch { if ($ManualCheck) { Write-Warning "Could not connect to GitHub API." } }

        $pnsradValid = Test-FileHash $Script:Path_PNSRAD $Global:Hash_PNSRAD
        $dbgValid = Test-FileHash $Script:Path_DBGCORE $Global:Hash_DBGCORE
        
        if (-not $pnsradValid -or -not $dbgValid) { $dllUpdateAvailable = $true }

        if ($monitorUpdateAvailable -and $dllUpdateAvailable) {
            if ($ManualCheck) {
                $msg = "Updates Available:`n`n1. New Monitor Version ($($response.tag_name))`n2. New Server DLLs (Hash Mismatch)`n`nUpdate all components now?"
                $res = [System.Windows.Forms.MessageBox]::Show($msg, "Critical Updates Found", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Exclamation)
                if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { if (Update-DLLs) { Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl } }
            } else {
                if (Update-DLLs -Silent $true) { Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl }
            }
            return
        }

        if ($monitorUpdateAvailable) {
            if ($ManualCheck) {
                $msg = "New Monitor Version Available: $($response.tag_name)`n`nUpdate now?"
                $res = [System.Windows.Forms.MessageBox]::Show($msg, "Monitor Update", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl }
            } else {
                Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl
            }
            return
        }

        if ($dllUpdateAvailable) {
            if ($ManualCheck) {
                $msg = "Your local server DLLs do not match the required versions.`n`nUpdate pnsradgameserver.dll and dbgcore.dll now?"
                $res = [System.Windows.Forms.MessageBox]::Show($msg, "DLL Integrity Check", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { Update-DLLs }
            } else {
                Update-DLLs -Silent $true
            }
            return
        }

        if ($ManualCheck) { [System.Windows.Forms.MessageBox]::Show("Everything is up to date.`n`nMonitor: v$($Global:Version)`nDLLs: Verified", "Up to Date", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }

    } catch {
        if ($ManualCheck) { [System.Windows.Forms.MessageBox]::Show("Update check failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }
    } finally {
        if ($ManualCheck) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    }
}

Function Invoke-MonitorUpdate ($downloadUrl) {
    try {
        Save-PortMap
        $currentFile = $Global:ExecutionPath
        $currentDir = [System.IO.Path]::GetDirectoryName($currentFile)
        $newFileName = if ($Global:IsBinary) { "EchoMonitor_New.exe" } else { "EchoMonitor_New.ps1" }
        $newFilePath = Join-Path $currentDir $newFileName
        $dashboardDir = Join-Path $currentDir "dashboard"
        $batchPath = Join-Path $dashboardDir "updater.bat"

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $newFilePath

        $exePath = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
        $startCommand = if ($Global:IsBinary) { "start `"`" `"$currentFile`"" } else { "start `"`" $exePath -WindowStyle Hidden -File `"$currentFile`"" }
        
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
        $NotifyIcon.ShowBalloonTip(4000, "Monitor Update", "New version downloaded! Restarting to apply updates...", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 3

        Start-Process -FilePath $batchPath -WindowStyle Hidden
        $NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
        Stop-Process -Id $PID -Force
    } catch { [System.Windows.Forms.MessageBox]::Show("Update failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }
}

# ==============================================================================
# 11. EXECUTION
# ==============================================================================

$initConf = Get-MonitorConfig
$daysToWaitInit = switch ($initConf.updateInterval) { "Daily" {1} "Weekly" {7} "Monthly" {30} default {7} }
if ($initConf.autoUpdate -and ((Get-Date) - [datetime]$initConf.lastUpdateCheckDate).TotalDays -ge $daysToWaitInit) {
    Test-ForUpdates -ManualCheck $false
    $initConf.lastUpdateCheckDate = (Get-Date).ToString("o")
    Save-MonitorConfig $initConf
}

$MonitorTimer.Start()
[System.Windows.Forms.Application]::Run()