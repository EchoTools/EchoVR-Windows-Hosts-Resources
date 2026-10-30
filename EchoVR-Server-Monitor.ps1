# THIS CODEBASE IS DEPRECATED AS OF OCTOBER 30 2026!
# Click the Migrate Now button in the About tab to migrate your server.

###################################################################
# Code by marshmallow_mia and now largely berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# Changes
# v5.5.0 - EOL Update - Added server migration flow.
#          Added event logging option. Instance restart timer now queues shutdown only after continuous idle time. 
#          Moved telemetry visibility config to a submenu. Monitor now also checks & updates power/sleep options on startup.

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "5.5.0"

$headsetLinkURL = "discord://-/channels/779349159852769310/1227795372244729926/1355176306484056084"
$portalURL = "https://echovrce.com/"
$migrationGuideURL = "https://github.com/EchoTools/EchoVR-Windows-Hosts-Resources"

# Target Log Errors for Termination
$Global:TargetLogErrors = @(
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
    "[NETGAME] Service status request failed: 0 Unknown",
    "Console close signal received"
)

# Migration State
$Global:MigrationInProgress = $false
$Global:MigrationPopupOpen = $false

# Port Management & Instance Tracking
$Global:PortMap = @{}
$Global:NotifiedPids = @{}
$Global:LinkCodeActive = $false
$Global:LastLogMaintenanceDay = -1

# Setting up system tray menu and GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Window {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool SetWindowText(IntPtr hWnd, string text);
    
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, [MarshalAs(UnmanagedType.LPWStr)] string lParam);
}
"@ -ErrorAction SilentlyContinue

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
    [System.Windows.Forms.MessageBox]::Show("The Server Monitor is already running. Check the system tray.", "Monitor Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
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
$MigrationFile = Join-Path $DashboardDir "migration.json"
$LocalConfigPath = Join-Path $ScriptRoot "_local\config.json"
$LogPath = Join-Path $ScriptRoot "_local\r14logs"
$LogPathOld = Join-Path $LogPath "old"

$StartupFolder = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupFolder "EchoVR Server Monitor.lnk"

if (-not (Test-Path $EchoExePath)) {
    [System.Windows.Forms.MessageBox]::Show("Error: 'bin\win10\echovr.exe' not found.`nPlace this program in the root ready-at-dawn-echo-arena folder.", "Fatal Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Exit
}
if (-not (Test-Path $DashboardDir)) { New-Item -ItemType Directory -Path $DashboardDir -Force | Out-Null }
if (-not (Test-Path $LogPathOld)) { New-Item -ItemType Directory -Path $LogPathOld -Force | Out-Null }

# ==============================================================================
# 2. LOGGING FRAMEWORK
# ==============================================================================

$Global:CurrentLogFile = $null

Function Initialize-MonitorLog {
    $conf = Get-MonitorConfig
    if ($conf.enableMonitorLogging) {
        # Explicitly use $Script: scope so WinForms events don't lose the variable
        $logsDir = Join-Path $Script:DashboardDir "logs"
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        
        # Ensure it creates if null OR if the file was deleted while running
        if ($null -eq $Global:CurrentLogFile -or -not (Test-Path $Global:CurrentLogFile)) {
            $ts = Get-Date -Format "MM-dd-yyyy HH-mm-ss"
            $Global:CurrentLogFile = Join-Path $logsDir "servermonitor-$($Global:Version) $ts.log"
            Write-MonitorLog "Logging started"
        }
    } else {
        $Global:CurrentLogFile = $null
    }
}

Function Write-MonitorLog {
    param([string]$Message, [int]$ProcId = 0, $pData = $null)
    if (-not [string]::IsNullOrEmpty($Global:CurrentLogFile)) {
        $ts = (Get-Date).ToString("MM-dd-yyyy HH:mm:ss")
        $logLine = "[$ts]: $Message"
        
        if ($ProcId -gt 0 -and $null -ne $pData) {
            $uptimeStr = "Unknown"
            try {
                $proc = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
                if ($proc) {
                    $uptime = New-TimeSpan -Start $proc.StartTime -End (Get-Date)
                    $uptimeStr = "$($uptime.Hours)h $($uptime.Minutes)m $($uptime.Seconds)s"
                }
            } catch {}
            $logLine += " | PID: $ProcId, Ports: $($pData.GS)/$($pData.API), Mode: $($pData.ModeTitle), Players: $($pData.PlayerCount), Uptime: $uptimeStr"
        }
        try { Add-Content -Path $Global:CurrentLogFile -Value $logLine -Force } catch {}
    }
}

# ==============================================================================
# 3. STATE PERSISTENCE & API TOGGLE
# ==============================================================================

Function Save-PortMap {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    
    $exportObj = New-Object PSObject
    $portsStr = @()
    foreach ($key in $Global:PortMap.Keys) {
        $exportObj | Add-Member -MemberType NoteProperty -Name $key.ToString() -Value $Global:PortMap[$key]
        $portsStr += "[$key, $($Global:PortMap[$key].GS), $($Global:PortMap[$key].API)]"
    }
    
    $exportObj | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $PortsFile -Force
    Write-MonitorLog "Portmap exported. Data: $($portsStr -join ', ')"
}

Function Import-PortMap {
    if (Test-Path $PortsFile) {
        try {
            $raw = Get-Content $PortsFile -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $saved = $raw | ConvertFrom-Json
                $portsStr = @()
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
                        PreviousMode = "Unknown Mode"
                        LastIdleStart = $null
                    }
                    $portsStr += "[$pidInt, $($prop.Value.GS), $($prop.Value.API)]"
                }
                Write-MonitorLog "Portmap imported. Data: $($portsStr -join ', ')"
            }
            Remove-Item $PortsFile -Force
        } catch {}
    }
}

Function Set-ApiAccess ($enable) {
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
            if ($needsSave) { $json | ConvertTo-Json -Depth 10 | Set-Content $r14MenuPath }
        } catch { Write-Warning "Could not update menu_settings.json" }
    }
    
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
        } catch { Write-Warning "Could not update settings_mp_v2.json" }
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

Function Update-PowerSettingsToNever {
    # Combine output arrays into single strings so -match properly populates $Matches
    $sleepQ = (powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) -join "`n"
    $videoQ = (powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE) -join "`n"
    
    $needsChange = $false
    
    # Check AC (Plugged in) and DC (Battery) for both Sleep and Display
    if ($sleepQ -match "Current AC Power Setting Index: (0x[0-9A-Fa-f]+)" -and [int]$Matches[1] -ne 0) { $needsChange = $true }
    if ($sleepQ -match "Current DC Power Setting Index: (0x[0-9A-Fa-f]+)" -and [int]$Matches[1] -ne 0) { $needsChange = $true }
    if ($videoQ -match "Current AC Power Setting Index: (0x[0-9A-Fa-f]+)" -and [int]$Matches[1] -ne 0) { $needsChange = $true }
    if ($videoQ -match "Current DC Power Setting Index: (0x[0-9A-Fa-f]+)" -and [int]$Matches[1] -ne 0) { $needsChange = $true }
    
    if ($needsChange) {
        powercfg -change -standby-timeout-ac 0
        powercfg -change -standby-timeout-dc 0
        powercfg -change -monitor-timeout-ac 0
        powercfg -change -monitor-timeout-dc 0
        Write-MonitorLog "Power settings updated: Sleep and Display timeouts set to Never"
    }
}

Function Get-Guilds {
    if (Test-Path $LocalConfigPath) {
        try {
            $c = Get-Content $LocalConfigPath -Raw | ConvertFrom-Json
            if ($c.serverdb_host -match "&guilds=([0-9,]+)") { return $Matches[1] }
        } catch {}
    }
    return ""
}

Function Set-Guilds ($guildsStr) {
    if (Test-Path $LocalConfigPath) {
        try {
            $c = Get-Content $LocalConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $c.serverdb_host) {
                $hostStr = $c.serverdb_host
                if ($hostStr -match "&guilds=[0-9,]+") {
                    if ([string]::IsNullOrWhiteSpace($guildsStr)) { $hostStr = $hostStr -replace "&guilds=[0-9,]+", "" } 
                    else { $hostStr = $hostStr -replace "&guilds=[0-9,]+", "&guilds=$guildsStr" }
                } else {
                    if (-not [string]::IsNullOrWhiteSpace($guildsStr)) { $hostStr += "&guilds=$guildsStr" }
                }
                $c.serverdb_host = $hostStr
                $c | ConvertTo-Json -Depth 10 | Set-Content $LocalConfigPath
            }
        } catch {}
    }
}

# ==============================================================================
# 4. CONFIGURATION MANAGEMENT
# ==============================================================================

Function Get-MonitorConfig {
    $defaultConfig = @{
        amountOfInstances = 1
        basePort = 6792
        portMappingMode = "Automatic"
        manualPortArray = @()
        delayProcessCheck = 5000
        numTaskThreads = 2
        timeStep = 120
        additionalArgs = "-server -headless -noovr -nosymbollookup"
        killCondition = "ExitOnError"
        startupGracePeriod = 30
        suppressSetupWarning = $false
        pauseSpawning = $false
        autoArchive = $true
        autoPurge = $false
        purgeInterval = "Weekly"
        enableApi = $true
        allowMonitorApi = $true
        autoRestartIdle = $false
        autoRestartTimeout = 15
        enableMonitorLogging = $false
        titlePid = $true; titlePorts = $true; titleLobby = $true; titlePlayers = $true; titleUptime = $true
        trayPid = $true; trayPorts = $true; trayLobby = $false; trayPlayers = $true; trayUptime = $true
        touchFriendly = $false
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

    if ($null -ne $config.exitOnError -and $null -eq $config.killCondition) {
        $migratedMode = if ($config.exitOnError) { "ExitOnError" } else { "CheckLogs" }
        $config | Add-Member -MemberType NoteProperty -Name "killCondition" -Value $migratedMode -Force
        $saveNeeded = $true
    }

    if ($null -ne $config.additionalArgs -and $config.additionalArgs -match "(?i)-fixedtimestep") {
        $config.additionalArgs = ($config.additionalArgs -ireplace "-fixedtimestep", "") -replace "\s+", " "
        $config.additionalArgs = $config.additionalArgs.Trim()
        $saveNeeded = $true
    }

    # Updater settings no longer exist; drop them from older monitor.json files
    foreach ($legacyKey in @("autoUpdate", "updateInterval", "lastUpdateCheckDate")) {
        if ($null -ne $config.psobject.Properties[$legacyKey]) {
            $config.psobject.Properties.Remove($legacyKey)
            $saveNeeded = $true
        }
    }

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

# Initialization block (Order-sensitive)
$initConfig = Get-MonitorConfig
$Global:BasePort = $initConfig.basePort
Set-ApiAccess $initConfig.enableApi
Initialize-MonitorLog
Update-PowerSettingsToNever
Import-PortMap
Repair-NetConfigFiles

# ==============================================================================
# 5. LOG MAINTENANCE LOGIC
# ==============================================================================

Function Invoke-LogMaintenance {
    param([switch]$ManualArchive, [switch]$ManualPurge)
    Get-Job -State Completed | Remove-Job -ErrorAction SilentlyContinue
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
# 6. GUI: CONFIGURATION WINDOWS
# ==============================================================================

$ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip

Function Set-TrayStyle {
    $conf = Get-MonitorConfig
    if ($conf.touchFriendly) {
        $ContextMenuStrip.Font = New-Object System.Drawing.Font("Segoe UI", 14)
    } else {
        $ContextMenuStrip.Font = [System.Windows.Forms.Control]::DefaultFont
    }
}
Set-TrayStyle

Function Show-TelemetryConfigWindow {
    param($currentData, $allowApi)

    $tf = $Global:ConfigForm.Font.Name -eq "Segoe UI"
    $xScale = if ($tf) { 1.25 } else { 1 }
    $yScale = if ($tf) { 1.5 } else { 1 }
    
    Function P2($x, $y) { return New-Object System.Drawing.Point([int]($x * $xScale), [int]($y * $yScale)) }
    Function S2($w, $h) { return New-Object System.Drawing.Size([int]($w * $xScale), [int]($h * $yScale)) }

    $telForm = New-Object System.Windows.Forms.Form
    $telForm.Text = "Configure Telemetry"
    $telForm.Size = S2 300 240
    $telForm.StartPosition = "CenterParent"
    $telForm.FormBorderStyle = "FixedDialog"
    $telForm.MaximizeBox = $false
    if ($tf) { $telForm.Font = New-Object System.Drawing.Font("Segoe UI", 11) }

    $lblTitleCol = New-Object System.Windows.Forms.Label; $lblTitleCol.Text = "Window Title"; $lblTitleCol.Location = P2 20 20; $lblTitleCol.AutoSize = $true; $telForm.Controls.Add($lblTitleCol)
    $lblTrayCol = New-Object System.Windows.Forms.Label; $lblTrayCol.Text = "System Tray"; $lblTrayCol.Location = P2 150 20; $lblTrayCol.AutoSize = $true; $telForm.Controls.Add($lblTrayCol)

    $chkTitlePid = New-Object System.Windows.Forms.CheckBox; $chkTitlePid.Text = "PID"; $chkTitlePid.Location = P2 20 45; $chkTitlePid.AutoSize = $true; $chkTitlePid.Checked = $currentData.titlePid; $telForm.Controls.Add($chkTitlePid)
    $chkTrayPid = New-Object System.Windows.Forms.CheckBox; $chkTrayPid.Text = "PID"; $chkTrayPid.Location = P2 150 45; $chkTrayPid.AutoSize = $true; $chkTrayPid.Checked = $currentData.trayPid; $telForm.Controls.Add($chkTrayPid)

    $chkTitlePorts = New-Object System.Windows.Forms.CheckBox; $chkTitlePorts.Text = "Ports"; $chkTitlePorts.Location = P2 20 70; $chkTitlePorts.AutoSize = $true; $chkTitlePorts.Checked = $currentData.titlePorts; $telForm.Controls.Add($chkTitlePorts)
    $chkTrayPorts = New-Object System.Windows.Forms.CheckBox; $chkTrayPorts.Text = "Ports"; $chkTrayPorts.Location = P2 150 70; $chkTrayPorts.AutoSize = $true; $chkTrayPorts.Checked = $currentData.trayPorts; $telForm.Controls.Add($chkTrayPorts)

    $chkTitleLobby = New-Object System.Windows.Forms.CheckBox; $chkTitleLobby.Text = "Lobby Info"; $chkTitleLobby.Location = P2 20 95; $chkTitleLobby.AutoSize = $true; $chkTitleLobby.Checked = $currentData.titleLobby; $telForm.Controls.Add($chkTitleLobby)
    $chkTrayLobby = New-Object System.Windows.Forms.CheckBox; $chkTrayLobby.Text = "Lobby Info"; $chkTrayLobby.Location = P2 150 95; $chkTrayLobby.AutoSize = $true; $chkTrayLobby.Checked = $currentData.trayLobby; $telForm.Controls.Add($chkTrayLobby)

    $chkTitlePlayers = New-Object System.Windows.Forms.CheckBox; $chkTitlePlayers.Text = "Player Count"; $chkTitlePlayers.Location = P2 20 120; $chkTitlePlayers.AutoSize = $true; $chkTitlePlayers.Checked = $currentData.titlePlayers; $telForm.Controls.Add($chkTitlePlayers)
    $chkTrayPlayers = New-Object System.Windows.Forms.CheckBox; $chkTrayPlayers.Text = "Player Count"; $chkTrayPlayers.Location = P2 150 120; $chkTrayPlayers.AutoSize = $true; $chkTrayPlayers.Checked = $currentData.trayPlayers; $telForm.Controls.Add($chkTrayPlayers)

    $chkTitleUptime = New-Object System.Windows.Forms.CheckBox; $chkTitleUptime.Text = "Uptime"; $chkTitleUptime.Location = P2 20 145; $chkTitleUptime.AutoSize = $true; $chkTitleUptime.Checked = $currentData.titleUptime; $telForm.Controls.Add($chkTitleUptime)
    $chkTrayUptime = New-Object System.Windows.Forms.CheckBox; $chkTrayUptime.Text = "Uptime"; $chkTrayUptime.Location = P2 150 145; $chkTrayUptime.AutoSize = $true; $chkTrayUptime.Checked = $currentData.trayUptime; $telForm.Controls.Add($chkTrayUptime)

    if (-not $allowApi) {
        $chkTitleLobby.Enabled = $false; $chkTrayLobby.Enabled = $false
        $chkTitlePlayers.Enabled = $false; $chkTrayPlayers.Enabled = $false
    }

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Save"; $btnSave.Location = P2 50 170; $btnSave.Size = S2 80 25; $telForm.Controls.Add($btnSave)
    $btnSave.Add_Click({
        $telForm.Tag = @{
            titlePid = $chkTitlePid.Checked; titlePorts = $chkTitlePorts.Checked; titleLobby = $chkTitleLobby.Checked; titlePlayers = $chkTitlePlayers.Checked; titleUptime = $chkTitleUptime.Checked
            trayPid = $chkTrayPid.Checked; trayPorts = $chkTrayPorts.Checked; trayLobby = $chkTrayLobby.Checked; trayPlayers = $chkTrayPlayers.Checked; trayUptime = $chkTrayUptime.Checked
        }
        $telForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $telForm.Close()
    })

    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Location = P2 150 170; $btnCancel.Size = S2 80 25; $telForm.Controls.Add($btnCancel)
    $btnCancel.Add_Click({
        $telForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $telForm.Close()
    })

    $res = $telForm.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return $telForm.Tag }
    return $null
}

Function Show-PortConfigWindow {
    param([int]$numInstances, [array]$currentPorts)
    $tf = $Global:ConfigForm.Font.Name -eq "Segoe UI"
    $xScale = if ($tf) { 1.25 } else { 1 }
    $yScale = if ($tf) { 1.5 } else { 1 }
    
    Function P2($x, $y) { return New-Object System.Drawing.Point([int]($x * $xScale), [int]($y * $yScale)) }
    Function S2($w, $h) { return New-Object System.Drawing.Size([int]($w * $xScale), [int]($h * $yScale)) }

    $portForm = New-Object System.Windows.Forms.Form
    $portForm.Text = "Configure Manual Ports"
    $portForm.Size = S2 380 400
    $portForm.StartPosition = "CenterParent"
    $portForm.FormBorderStyle = "FixedDialog"
    $portForm.MaximizeBox = $false
    if ($tf) { $portForm.Font = New-Object System.Drawing.Font("Segoe UI", 11) }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = P2 10 10; $panel.Size = S2 340 300; $panel.AutoScroll = $true
    $portForm.Controls.Add($panel)

    $ctrlPairs = @(); $yOffset = 0

    for ($i = 0; $i -lt $numInstances; $i++) {
        $lblInst = New-Object System.Windows.Forms.Label; $lblInst.Text = "Instance $($i + 1):"; $lblInst.Font = New-Object System.Drawing.Font($portForm.Font, [System.Drawing.FontStyle]::Bold); $lblInst.Location = P2 10 $yOffset; $lblInst.AutoSize = $true; $panel.Controls.Add($lblInst)
        $lblMap = New-Object System.Windows.Forms.Label; $lblMap.Text = "Port mapping:"; $lblMap.Location = P2 160 $yOffset; $lblMap.AutoSize = $true; $panel.Controls.Add($lblMap)
        
        $yOffset += 25
        $lblGS = New-Object System.Windows.Forms.Label; $lblGS.Text = "GameServer  ->"; $lblGS.Location = P2 20 $yOffset; $lblGS.AutoSize = $true; $panel.Controls.Add($lblGS)
        $txtGS = New-Object System.Windows.Forms.TextBox; $txtGS.Location = P2 160 $yOffset; $txtGS.Size = S2 80 20; 
        
        $yOffset += 25
        $lblAPI = New-Object System.Windows.Forms.Label; $lblAPI.Text = "API              ->"; $lblAPI.Location = P2 20 $yOffset; $lblAPI.AutoSize = $true; $panel.Controls.Add($lblAPI)
        $txtAPI = New-Object System.Windows.Forms.TextBox; $txtAPI.Location = P2 160 $yOffset; $txtAPI.Size = S2 80 20; 
        
        if ($i -lt $currentPorts.Count) {
            $txtGS.Text = "$($currentPorts[$i].GS)"
            $txtAPI.Text = "$($currentPorts[$i].API)"
        }

        $panel.Controls.Add($txtGS); $panel.Controls.Add($txtAPI)
        $ctrlPairs += @{ GS = $txtGS; API = $txtAPI }
        $yOffset += 40
    }

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Save"; $btnSave.Location = P2 90 320; $btnSave.Size = S2 80 25; $portForm.Controls.Add($btnSave)
    $btnSave.Add_Click({
        $err = $false; $seen = @{}; $newPorts = @()

        foreach ($p in $ctrlPairs) {
            $gsStr = $p.GS.Text; $apiStr = $p.API.Text
            if ([string]::IsNullOrWhiteSpace($gsStr) -or [string]::IsNullOrWhiteSpace($apiStr)) { $err = $true; break }
            try { $gsInt = [int]$gsStr; $apiInt = [int]$apiStr } catch { $err = $true; break }
            if ($gsInt -lt 1 -or $gsInt -gt 65535 -or $apiInt -lt 1 -or $apiInt -gt 65535) { $err = $true; break }
            if ($gsInt -eq $apiInt) { $err = $true; break }
            if ($seen[$gsInt] -or $seen[$apiInt]) { $err = $true; break }
            $seen[$gsInt] = $true; $seen[$apiInt] = $true
            $newPorts += @{ GS = $gsInt; API = $apiInt }
        }

        if ($err) { [System.Windows.Forms.MessageBox]::Show("Please ensure all ports are valid numbers (1-65535), not empty, and completely unique.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) } 
        else { $portForm.Tag = $newPorts; $portForm.DialogResult = [System.Windows.Forms.DialogResult]::OK; $portForm.Close() }
    })

    $btnDiscard = New-Object System.Windows.Forms.Button; $btnDiscard.Text = "Discard"; $btnDiscard.Location = P2 190 320; $btnDiscard.Size = S2 80 25; $portForm.Controls.Add($btnDiscard)
    $btnDiscard.Add_Click({ $portForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $portForm.Close() })

    $res = $portForm.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return $portForm.Tag }
    return $null
}

Function Show-ConfigWindow {
    if ($null -ne $Global:ConfigForm -and -not $Global:ConfigForm.IsDisposed) {
        if ($Global:ConfigForm.WindowState -eq 'Minimized') { $Global:ConfigForm.WindowState = 'Normal' }
        $Global:ConfigForm.Activate()
        return
    }
    
    $monitorData = Get-MonitorConfig
    $oldConfigStr = $monitorData | ConvertTo-Json -Compress
    
    $tf = $monitorData.touchFriendly
    $xScale = if ($tf) { 1.25 } else { 1 }
    $yScale = if ($tf) { 1.5 } else { 1 }
    $hScale = if ($tf) { 1.5 } else { 1 }

    Function P($x, $y) { return New-Object System.Drawing.Point([int]($x * $xScale), [int]($y * $yScale)) }
    Function S($w, $h) { return New-Object System.Drawing.Size([int]($w * $xScale), [int]($h * $hScale)) }

    $form = New-Object System.Windows.Forms.Form
    $Global:ConfigForm = $form
    $form.Text = "Server Monitor Configuration"
    $form.Size = New-Object System.Drawing.Size([int](460 * $xScale), [int](600 * $yScale))
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    if ($tf) { $form.Font = New-Object System.Drawing.Font("Segoe UI", 11) }

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = P 10 10; $tabControl.Size = New-Object System.Drawing.Size([int](425 * $xScale), [int](460 * $yScale))
    $form.Controls.Add($tabControl)

    # --- TAB 1: SERVER SETTINGS ---
    $tabServer = New-Object System.Windows.Forms.TabPage; $tabServer.Text = "Server Settings"; $tabControl.TabPages.Add($tabServer)

    $lblInst = New-Object System.Windows.Forms.Label; $lblInst.Text = "Number of Instances:"; $lblInst.Location = P 20 25; $lblInst.AutoSize = $true; $tabServer.Controls.Add($lblInst)
    $txtInst = New-Object System.Windows.Forms.TextBox; $txtInst.Location = P 250 22; $txtInst.Size = S 120 20; $txtInst.Text = "$($monitorData.amountOfInstances)"; $tabServer.Controls.Add($txtInst)

    $lblThreads = New-Object System.Windows.Forms.Label; $lblThreads.Text = "Max Threads per Instance:"; $lblThreads.Location = P 20 60; $lblThreads.AutoSize = $true; $tabServer.Controls.Add($lblThreads)
    $txtThreads = New-Object System.Windows.Forms.TextBox; $txtThreads.Location = P 250 57; $txtThreads.Size = S 120 20; $txtThreads.Text = "$($monitorData.numTaskThreads)"; $tabServer.Controls.Add($txtThreads)

    $lblTime = New-Object System.Windows.Forms.Label; $lblTime.Text = "Timestep:"; $lblTime.Location = P 20 95; $lblTime.AutoSize = $true; $tabServer.Controls.Add($lblTime)

    $rbStd = New-Object System.Windows.Forms.RadioButton; $rbStd.Text = "Standard (120)"; $rbStd.Location = P 95 93; $rbStd.AutoSize = $true; $tabServer.Controls.Add($rbStd)
    $rbComp = New-Object System.Windows.Forms.RadioButton; $rbComp.Text = "Competitive (180)"; $rbComp.Location = P 205 93; $rbComp.AutoSize = $true; $tabServer.Controls.Add($rbComp)
    $rbDyn = New-Object System.Windows.Forms.RadioButton; $rbDyn.Text = "Dynamic"; $rbDyn.Location = P 330 93; $rbDyn.AutoSize = $true; $tabServer.Controls.Add($rbDyn)
    if ($monitorData.timeStep -eq 180) { $rbComp.Checked = $true } elseif ($monitorData.timeStep -eq 120) { $rbStd.Checked = $true } else {$rbDyn.Checked = $true}

    $lblArgs = New-Object System.Windows.Forms.Label; $lblArgs.Text = "Additional Args:"; $lblArgs.Location = P 20 130; $lblArgs.AutoSize = $true; $tabServer.Controls.Add($lblArgs)
    $txtArgs = New-Object System.Windows.Forms.TextBox; $txtArgs.Location = P 20 150; $txtArgs.Size = S 380 20; $txtArgs.Text = "$($monitorData.additionalArgs)"; $tabServer.Controls.Add($txtArgs)

    $chkApi = New-Object System.Windows.Forms.CheckBox; $chkApi.Text = "Enable EchoVR API"; $chkApi.Location = P 20 185; $chkApi.AutoSize = $true; $chkApi.Checked = $monitorData.enableApi; $tabServer.Controls.Add($chkApi)

    $pnlKillMode = New-Object System.Windows.Forms.Panel; $pnlKillMode.Location = P 15 208; $pnlKillMode.Size = S 400 30; $tabServer.Controls.Add($pnlKillMode)
    $rbKillExit = New-Object System.Windows.Forms.RadioButton; $rbKillExit.Text = "Wait for crash (-exitonerror)"; $rbKillExit.Location = P 5 3; $rbKillExit.AutoSize = $true; $pnlKillMode.Controls.Add($rbKillExit)
    $rbKillLog = New-Object System.Windows.Forms.RadioButton; $rbKillLog.Text = "Check logs for errors"; $rbKillLog.Location = P 200 3; $rbKillLog.AutoSize = $true; $pnlKillMode.Controls.Add($rbKillLog)
    if ($monitorData.killCondition -eq "CheckLogs") { $rbKillLog.Checked = $true } else { $rbKillExit.Checked = $true }

    $lblPortMap = New-Object System.Windows.Forms.Label; $lblPortMap.Text = "Port Mapping:"; $lblPortMap.Location = P 20 240; $lblPortMap.AutoSize = $true; $tabServer.Controls.Add($lblPortMap)
    
    $pnlPortMap = New-Object System.Windows.Forms.Panel; $pnlPortMap.Location = P 100 235; $pnlPortMap.Size = S 150 30; $tabServer.Controls.Add($pnlPortMap)
    $rbAutoMap = New-Object System.Windows.Forms.RadioButton; $rbAutoMap.Text = "Automatic"; $rbAutoMap.Location = P 5 3; $rbAutoMap.AutoSize = $true; $pnlPortMap.Controls.Add($rbAutoMap)
    $rbManMap = New-Object System.Windows.Forms.RadioButton; $rbManMap.Text = "Manual"; $rbManMap.Location = P 85 3; $rbManMap.AutoSize = $true; $pnlPortMap.Controls.Add($rbManMap)
    
    $txtBasePort = New-Object System.Windows.Forms.TextBox; $txtBasePort.Location = P 260 238; $txtBasePort.Size = S 120 20; $txtBasePort.Text = "$($monitorData.basePort)"; $tabServer.Controls.Add($txtBasePort)
    $btnConfigPorts = New-Object System.Windows.Forms.Button; $btnConfigPorts.Text = "Configure Ports"; $btnConfigPorts.Location = P 260 237; $btnConfigPorts.Size = S 120 23; $tabServer.Controls.Add($btnConfigPorts)

    [Win32Window]::SendMessage($txtBasePort.Handle, 0x1501, [IntPtr]1, "Base Port") | Out-Null

    $Global:TempManualPorts = @()
    if ($monitorData.manualPortArray) { $Global:TempManualPorts = @($monitorData.manualPortArray) }
    $btnConfigPorts.Add_Click({
        try { $numInstCount = [int]$txtInst.Text } catch { $numInstCount = 1 }
        $res = Show-PortConfigWindow -numInstances $numInstCount -currentPorts $Global:TempManualPorts
        if ($res) { $Global:TempManualPorts = $res }
    })

    $UpdateMapMode = {
        if ($rbAutoMap.Checked) { $txtBasePort.Visible = $true; $btnConfigPorts.Visible = $false } 
        else { $txtBasePort.Visible = $false; $btnConfigPorts.Visible = $true }
    }
    $rbAutoMap.Add_CheckedChanged($UpdateMapMode); $rbManMap.Add_CheckedChanged($UpdateMapMode)
    if ($monitorData.portMappingMode -eq "Manual") { $rbManMap.Checked = $true } else { $rbAutoMap.Checked = $true }
    & $UpdateMapMode

    $lblGuilds = New-Object System.Windows.Forms.Label; $lblGuilds.Text = "Guild Restriction (IDs):"; $lblGuilds.Location = P 20 275; $lblGuilds.AutoSize = $true; $tabServer.Controls.Add($lblGuilds)
    $txtGuilds = New-Object System.Windows.Forms.TextBox; $txtGuilds.Location = P 150 272; $txtGuilds.Size = S 230 20; $txtGuilds.Text = (Get-Guilds); $tabServer.Controls.Add($txtGuilds)

    # --- TAB 2: MONITOR SETTINGS ---
    $tabMonitor = New-Object System.Windows.Forms.TabPage; $tabMonitor.Text = "Monitor Settings"; $tabControl.TabPages.Add($tabMonitor)

    $lblCheck = New-Object System.Windows.Forms.Label; $lblCheck.Text = "Monitor Update Frequency (sec):"; $lblCheck.Location = P 20 15; $lblCheck.AutoSize = $true; $tabMonitor.Controls.Add($lblCheck)
    $txtCheck = New-Object System.Windows.Forms.TextBox; $txtCheck.Location = P 250 12; $txtCheck.Size = S 120 20; $txtCheck.Text = "$($monitorData.delayProcessCheck / 1000)"; $tabMonitor.Controls.Add($txtCheck)

    $chkStartup = New-Object System.Windows.Forms.CheckBox; $chkStartup.Text = "Start with Windows"; $chkStartup.Location = P 20 45; $chkStartup.AutoSize = $true; $chkStartup.Checked = (Test-Path $ShortcutPath); $tabMonitor.Controls.Add($chkStartup)

    $chkArchive = New-Object System.Windows.Forms.CheckBox; $chkArchive.Text = "Auto-Archive Logs"; $chkArchive.Location = P 20 75; $chkArchive.AutoSize = $true; $chkArchive.Checked = $monitorData.autoArchive; $tabMonitor.Controls.Add($chkArchive)
    $btnArchiveNow = New-Object System.Windows.Forms.Button; $btnArchiveNow.Text = "Archive Now"; $btnArchiveNow.Location = P 250 73; $btnArchiveNow.Size = S 120 23; $tabMonitor.Controls.Add($btnArchiveNow)
    $btnArchiveNow.Add_Click({ Invoke-LogMaintenance -ManualArchive })

    $chkPurge = New-Object System.Windows.Forms.CheckBox; $chkPurge.Text = "Purge Old Logs:"; $chkPurge.Location = P 20 105; $chkPurge.AutoSize = $true; $chkPurge.Checked = $monitorData.autoPurge; $tabMonitor.Controls.Add($chkPurge)

    $cmbPurge = New-Object System.Windows.Forms.ComboBox; $cmbPurge.Location = P 135 103; $cmbPurge.Size = S 80 20; $cmbPurge.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Daily", "Weekly", "Monthly") | ForEach-Object { $cmbPurge.Items.Add($_) | Out-Null }
    $cmbPurge.SelectedItem = $monitorData.purgeInterval; $cmbPurge.Enabled = $chkPurge.Checked; $tabMonitor.Controls.Add($cmbPurge)
    $chkPurge.Add_CheckedChanged({ $cmbPurge.Enabled = $chkPurge.Checked })

    $btnPurgeNow = New-Object System.Windows.Forms.Button; $btnPurgeNow.Text = "Purge Now"; $btnPurgeNow.Location = P 250 102; $btnPurgeNow.Size = S 120 23; $tabMonitor.Controls.Add($btnPurgeNow)
    $btnPurgeNow.Add_Click({ Invoke-LogMaintenance -ManualPurge })

    $chkAllowMonitorApi = New-Object System.Windows.Forms.CheckBox; $chkAllowMonitorApi.Text = "Allow Monitor to use EchoVR API"; $chkAllowMonitorApi.Location = P 20 135; $chkAllowMonitorApi.AutoSize = $true; $chkAllowMonitorApi.Checked = $monitorData.allowMonitorApi; $tabMonitor.Controls.Add($chkAllowMonitorApi)

    $chkAutoRestart = New-Object System.Windows.Forms.CheckBox; $chkAutoRestart.Text = "Idle Time until Auto-Restart (min):"; $chkAutoRestart.Location = P 20 165; $chkAutoRestart.AutoSize = $true; $chkAutoRestart.Checked = $monitorData.autoRestartIdle; $tabMonitor.Controls.Add($chkAutoRestart)
    $txtAutoRestart = New-Object System.Windows.Forms.TextBox; $txtAutoRestart.Location = P 250 162; $txtAutoRestart.Size = S 120 20; $txtAutoRestart.Text = "$($monitorData.autoRestartTimeout)"; $txtAutoRestart.Enabled = $monitorData.autoRestartIdle; $tabMonitor.Controls.Add($txtAutoRestart)
    $chkAutoRestart.Add_CheckedChanged({ $txtAutoRestart.Enabled = $chkAutoRestart.Checked })

    $chkLogging = New-Object System.Windows.Forms.CheckBox; $chkLogging.Text = "Monitor Event Logging"; $chkLogging.Location = P 20 195; $chkLogging.AutoSize = $true; $chkLogging.Checked = $monitorData.enableMonitorLogging; $tabMonitor.Controls.Add($chkLogging)

    $telSize = if ($tf) { 10 } else { 8 }
    $lblTelemetry = New-Object System.Windows.Forms.Label; $lblTelemetry.Text = "Telemetry Visibility:"; $lblTelemetry.Font = New-Object System.Drawing.Font("Arial", $telSize, [System.Drawing.FontStyle]::Bold); $lblTelemetry.Location = P 20 225; $lblTelemetry.AutoSize = $true; $tabMonitor.Controls.Add($lblTelemetry)

    $Global:TempTelemetry = @{
        titlePid = $monitorData.titlePid; titlePorts = $monitorData.titlePorts; titleLobby = $monitorData.titleLobby; titlePlayers = $monitorData.titlePlayers; titleUptime = $monitorData.titleUptime
        trayPid = $monitorData.trayPid; trayPorts = $monitorData.trayPorts; trayLobby = $monitorData.trayLobby; trayPlayers = $monitorData.trayPlayers; trayUptime = $monitorData.trayUptime
    }
    
    $btnConfigTelemetry = New-Object System.Windows.Forms.Button; $btnConfigTelemetry.Text = "Configure"; $btnConfigTelemetry.Location = P 170 223; $btnConfigTelemetry.Size = S 80 23; $tabMonitor.Controls.Add($btnConfigTelemetry)
    $btnConfigTelemetry.Add_Click({
        $res = Show-TelemetryConfigWindow -currentData $Global:TempTelemetry -allowApi $chkAllowMonitorApi.Checked
        if ($res) { $Global:TempTelemetry = $res }
    })

    $chkTouch = New-Object System.Windows.Forms.CheckBox; $chkTouch.Text = "Enable Touch-Friendly Interface"; $chkTouch.Location = P 20 255; $chkTouch.AutoSize = $true; $chkTouch.Checked = $monitorData.touchFriendly; $tabMonitor.Controls.Add($chkTouch)

    # --- TAB 3: ABOUT ---
    $tabAbout = New-Object System.Windows.Forms.TabPage; $tabAbout.Text = "About"; $tabControl.TabPages.Add($tabAbout)

    $pfcStencil = New-Object System.Drawing.Text.PrivateFontCollection
    $pfcNeuro = New-Object System.Drawing.Text.PrivateFontCollection
    $fontEchoStencilPath = Join-Path $ScriptRoot "content\engine\core\fonts\EchoStencil.ttf"
    $fontNeuropolPath = Join-Path $ScriptRoot "content\engine\core\fonts\Neuropol-X-Rg.otf"

    if (Test-Path -LiteralPath $fontEchoStencilPath) { $pfcStencil.AddFontFile($fontEchoStencilPath) }
    if (Test-Path -LiteralPath $fontNeuropolPath) { $pfcNeuro.AddFontFile($fontNeuropolPath) }

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "EchoVR Server Monitor"
    
    $titleStencilSize = if ($tf) { 16 } else { 12 }; $titleArialSize = if ($tf) { 18 } else { 14 }
    
    if ($pfcStencil.Families.Count -gt 0) { $lblTitle.Font = New-Object System.Drawing.Font($pfcStencil.Families[0], $titleStencilSize, [System.Drawing.FontStyle]::Regular) } 
    else { $lblTitle.Font = New-Object System.Drawing.Font("Arial", $titleArialSize, [System.Drawing.FontStyle]::Bold) }
    
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter; $lblTitle.Location = P 10 40; $lblTitle.Size = S 400 30
    $tabAbout.Controls.Add($lblTitle)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "v$($Global:Version)"
    $versionSize = if ($tf) { 16 } else { 12 }
    
    if ($pfcNeuro.Families.Count -gt 0) { $lblVersion.Font = New-Object System.Drawing.Font($pfcNeuro.Families[0], $versionSize, [System.Drawing.FontStyle]::Bold) } 
    else { $lblVersion.Font = New-Object System.Drawing.Font("Arial", $versionSize, [System.Drawing.FontStyle]::Bold) }
    
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter; $lblVersion.Location = P 10 65; $lblVersion.Size = S 400 30
    $tabAbout.Controls.Add($lblVersion)

    $lblPing = New-Object System.Windows.Forms.Label
    $lblPing.Text = "The PowerShell Monitor has reached EOL. Thank you for your feedback!"
    $lblPing.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter; $lblPing.Location = P 10 110; $lblPing.Size = S 400 20
    $tabAbout.Controls.Add($lblPing)

    $btnMigrate = New-Object System.Windows.Forms.Button
    $btnMigrate.Text = "Migrate Server"; $btnMigrate.Location = P 135 150; $btnMigrate.Size = S 150 30
    $btnMigrate.Add_Click({
        $choice = Invoke-MigrationPrompt -Owner $form
        if ($choice -eq "Migrate") {
            # Migration has started and the monitor will exit on its own; close this window without saving
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        }
    })
    $tabAbout.Controls.Add($btnMigrate)

    # --- BOTTOM BUTTONS ---
    $btnOpenLocal = New-Object System.Windows.Forms.Button; $btnOpenLocal.Text = "Open Server Config"; $btnOpenLocal.Location = P 30 485; $btnOpenLocal.Size = S 180 25; $btnOpenLocal.Add_Click({ Invoke-Item $LocalConfigPath }); $form.Controls.Add($btnOpenLocal)
    $btnOpenEcho = New-Object System.Windows.Forms.Button; $btnOpenEcho.Text = "Open Echo Folder"; $btnOpenEcho.Location = P 235 485; $btnOpenEcho.Size = S 180 25; $btnOpenEcho.Add_Click({ Invoke-Item $ScriptRoot }); $form.Controls.Add($btnOpenEcho)
    
    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Save"; $btnSave.Location = P 85 520; $btnSave.Size = S 80 25; $form.Controls.Add($btnSave)
    $btnSave.Add_Click({
        try {
            if ([int]$txtInst.Text -lt 1) { throw "Invalid Instances" }
            if ($rbAutoMap.Checked) {
                if ([string]::IsNullOrWhiteSpace($txtBasePort.Text) -or $txtBasePort.Text -eq "Base Port") { throw "Invalid Port" }
                if ([int]$txtBasePort.Text -lt 1 -or [int]$txtBasePort.Text -gt 65535) { throw "Invalid Port" }
            }
            $null = [double]$txtCheck.Text
            if ($chkAutoRestart.Checked -and [int]$txtAutoRestart.Text -lt 1) { throw "Invalid Timeout" }
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch { [System.Windows.Forms.MessageBox]::Show("Please enter valid numbers for the required fields.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }
    })

    $btnRestore = New-Object System.Windows.Forms.Button; $btnRestore.Text = "Defaults"; $btnRestore.Location = P 180 520; $btnRestore.Size = S 80 25; $form.Controls.Add($btnRestore)
    $btnRestore.Add_Click({
        $txtInst.Text = "1"; $txtThreads.Text = "2"; $rbStd.Checked = $true
        $rbAutoMap.Checked = $true; $txtBasePort.Text = "6792"
        $txtGuilds.Text = ""; $Global:TempManualPorts = @()
        $txtArgs.Text = "-server -headless -noovr -nosymbollookup"
        $rbKillExit.Checked = $true
        $txtCheck.Text = "5"; $chkStartup.Checked = $true; $chkArchive.Checked = $true
        $chkPurge.Checked = $false; $cmbPurge.SelectedItem = "Weekly"
        $chkApi.Checked = $true; $chkAllowMonitorApi.Checked = $true
        $chkAutoRestart.Checked = $false; $txtAutoRestart.Text = "15"
        $chkLogging.Checked = $false
        $Global:TempTelemetry = @{ titlePid=$true; titlePorts=$true; titleLobby=$true; titlePlayers=$true; titleUptime=$true; trayPid=$true; trayPorts=$true; trayLobby=$false; trayPlayers=$true; trayUptime=$true }
        $chkTouch.Checked = $false
    })

    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Discard"; $btnCancel.Location = P 275 520; $btnCancel.Size = S 80 25; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($btnCancel)

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $numInst = [int]$txtInst.Text
        $tStep = if ($rbComp.Checked) { 180 } elseif ($rbStd.Checked) { 120 } else { 0 }
        
        $serverSettingsChanged = $false
        if ($monitorData.amountOfInstances -ne $numInst) { $serverSettingsChanged = $true }
        if ($rbAutoMap.Checked) {
            if ($monitorData.portMappingMode -ne "Automatic") { $serverSettingsChanged = $true }
            if ($monitorData.basePort -ne [int]$txtBasePort.Text) { $serverSettingsChanged = $true }
            $monitorData.portMappingMode = "Automatic"; $monitorData.basePort = [int]$txtBasePort.Text
        } else {
            $serverSettingsChanged = $true 
            $monitorData.portMappingMode = "Manual"; $monitorData.manualPortArray = $Global:TempManualPorts
        }

        $newKillCondition = if ($rbKillExit.Checked) { "ExitOnError" } else { "CheckLogs" }
        if ($monitorData.killCondition -ne $newKillCondition) { $serverSettingsChanged = $true }
        if ($monitorData.numTaskThreads -ne [int]$txtThreads.Text) { $serverSettingsChanged = $true }
        if ($monitorData.timeStep -ne $tStep) { $serverSettingsChanged = $true }
        if ($monitorData.additionalArgs -ne $txtArgs.Text) { $serverSettingsChanged = $true }
        if ($monitorData.enableApi -ne $chkApi.Checked) { $serverSettingsChanged = $true }

        $oldGuilds = Get-Guilds
        if ($oldGuilds -ne $txtGuilds.Text) { Set-Guilds $txtGuilds.Text; $serverSettingsChanged = $true }

        $monitorData.amountOfInstances = $numInst
        $monitorData.delayProcessCheck = [int]([double]$txtCheck.Text * 1000)
        $monitorData.numTaskThreads = [int]$txtThreads.Text
        $monitorData.timeStep = $tStep
        $monitorData.additionalArgs = $txtArgs.Text
        $monitorData.killCondition = $newKillCondition
        $monitorData.autoArchive = $chkArchive.Checked
        $monitorData.autoPurge = $chkPurge.Checked
        $monitorData.purgeInterval = $cmbPurge.SelectedItem
        $monitorData.enableApi = $chkApi.Checked
        $monitorData.allowMonitorApi = $chkAllowMonitorApi.Checked
        $monitorData.autoRestartIdle = $chkAutoRestart.Checked
        $monitorData.autoRestartTimeout = [int]$txtAutoRestart.Text
        $monitorData.enableMonitorLogging = $chkLogging.Checked
        
        $monitorData.titlePid = $Global:TempTelemetry.titlePid; $monitorData.titlePorts = $Global:TempTelemetry.titlePorts; $monitorData.titleLobby = $Global:TempTelemetry.titleLobby; $monitorData.titlePlayers = $Global:TempTelemetry.titlePlayers; $monitorData.titleUptime = $Global:TempTelemetry.titleUptime
        $monitorData.trayPid = $Global:TempTelemetry.trayPid; $monitorData.trayPorts = $Global:TempTelemetry.trayPorts; $monitorData.trayLobby = $Global:TempTelemetry.trayLobby; $monitorData.trayPlayers = $Global:TempTelemetry.trayPlayers; $monitorData.trayUptime = $Global:TempTelemetry.trayUptime
        $monitorData.touchFriendly = $chkTouch.Checked

        # Perform explicit JSON comparison for accurate diff logging
        $newConfigStr = $monitorData | ConvertTo-Json -Compress
        if ($oldConfigStr -ne $newConfigStr) {
            $diffs = @()
            $oldObj = $oldConfigStr | ConvertFrom-Json
            foreach ($key in $monitorData.psobject.properties.Name) {
                if ($oldObj.$key -ne $monitorData.$key) {
                    if ($key -eq "manualPortArray") { $diffs += "$key updated" }
                    else { $diffs += "$($key): $($oldObj.$key) -> $($monitorData.$key)" }
                }
            }
            
            # Initialize log first so the file exists before writing the settings diff
            if ($monitorData.enableMonitorLogging -ne $oldObj.enableMonitorLogging) { Initialize-MonitorLog }
            if ($diffs.Count -gt 0) { Write-MonitorLog "Settings changed: $($diffs -join ' | ')" }
        }

        if ($rbAutoMap.Checked) { $Global:BasePort = $monitorData.basePort }

        Switch-StartupShortcut $chkStartup.Checked
        Set-ApiAccess $monitorData.enableApi
        Save-MonitorConfig $monitorData
        Update-ExternalConfigs $numInst
        Set-TrayStyle

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
    $form.Dispose()
}

# ==============================================================================
# 7. PORT MANAGEMENT
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

Function Get-ManualPortPair {
    $conf = Get-MonitorConfig
    $manualPorts = $conf.manualPortArray
    if ($null -eq $manualPorts) { return $null }
    for ($i = 0; $i -lt $manualPorts.Count; $i++) {
        $gsPort = [int]$manualPorts[$i].GS
        $apiPort = [int]$manualPorts[$i].API
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
# 8. SYSTEM TRAY & MENU
# ==============================================================================

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
$MenuItemPortal.Add_Click({ Start-Process $portalURL })
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
    
    $statusStr = if ($MenuItemPause.Checked) { "paused" } else { "unpaused" }
    Write-MonitorLog "Spawning $statusStr by user"
    
    if (-not $conf.pauseSpawning) { $Global:LinkCodeActive = $false }
})

$ContextMenuStrip.Items.Add($MenuItemPause) | Out-Null

$MenuItemExit = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemExit.Text = "Exit"
$MenuItemExit.Add_Click({
    Write-MonitorLog "Monitor exited by user"
    $MonitorTimer.Stop()
    if ($MigrationTimer) { $MigrationTimer.Stop() }
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

$NotifyIcon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try {
            $mi = [System.Windows.Forms.NotifyIcon].GetMethod("ShowContextMenu", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
            $mi.Invoke($NotifyIcon, $null)
        } catch { }
    }
})

$NotifyIcon.Add_DoubleClick({
    if ($Global:MigrationInProgress) { return }
    $MonitorTimer.Stop()
    Show-ConfigWindow
    $MonitorTimer.Start()
})

# ==============================================================================
# 9. NATIVE API POLLING
# ==============================================================================

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
# 10. MONITORING LOGIC
# ==============================================================================

$MonitorTimer = New-Object System.Windows.Forms.Timer
$MonitorTimer.Interval = 3000

$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck
    
    if ($config.portMappingMode -eq "Automatic") { $Global:BasePort = $config.basePort }

    $now = Get-Date
    $currentDay = $now.DayOfYear
    if ($Global:LastLogMaintenanceDay -ne $currentDay) {
        Invoke-LogMaintenance
        $Global:LastLogMaintenanceDay = $currentDay
    }

    if ($MenuItemPause.Checked -ne $config.pauseSpawning) { $MenuItemPause.Checked = $config.pauseSpawning }

    $processes = @(Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue)
    $runningCount = $processes.Count
    $runningIds = $processes.Id

    $trackedPids = @($Global:PortMap.Keys)
    foreach ($pidKey in $trackedPids) {
        if ($runningIds -notcontains $pidKey) { 
            Write-MonitorLog "Instance exited or killed automatically (process terminated)" -ProcId $pidKey -pData $Global:PortMap[$pidKey]
            $Global:PortMap.Remove($pidKey) 
            $Global:NotifiedPids.Remove($pidKey)
        }
    }

    # Migration: once every instance has shut down, the monitor exits on its own
    if ($Global:MigrationInProgress -and $runningCount -eq 0) {
        Complete-Migration
        return
    }

    $canSoftShutdown = ($config.enableApi -and $config.allowMonitorApi)

    # --- UNIFIED LOG READING & API POLLING ---
    if ($processes) {
        foreach ($proc in $processes) {
            $pData = $Global:PortMap[$proc.Id]
            if ($null -eq $pData) { continue }

            # 1. Log Parsing
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
                                $cmd = "Add-Type -AssemblyName System.Windows.Forms; `$res = [System.Windows.Forms.MessageBox]::Show('$msgBody', '$msgTitle', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information); if (`$res -eq [System.Windows.Forms.DialogResult]::OK) { Start-Process '$headsetLinkURL' }"
                                $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
                                $encodedCommand = [Convert]::ToBase64String($bytes)
                                Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-EncodedCommand $encodedCommand" -WindowStyle Hidden
                            }
                        }
                    }

                    if ($config.killCondition -eq "CheckLogs") {
                        try { $uptimeSeconds = ($now - $proc.StartTime).TotalSeconds } catch { $uptimeSeconds = 999 }
                        if ($uptimeSeconds -gt $config.startupGracePeriod) {
                            foreach ($line in $lines) {
                                if ($line.Length -ge 25) {
                                    $line_clean = $line.Substring(25) -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
                                    if ($Global:TargetLogErrors -contains $line_clean) {
                                        Write-MonitorLog "Instance exited or killed automatically (log error matched: $line_clean)" -ProcId $proc.Id -pData $pData
                                        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                                        $Global:PortMap.Remove($proc.Id)
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            # 2. Synchronous Native API Polling
            if ($config.allowMonitorApi -and (Test-PortOpen $pData.API 100)) {
                $jobRes = Get-EchoApiData $pData.API
                if ($jobRes.success) {
                    $modeStrTitle = "Unknown Mode"; $modeStrTray = "Unknown"
                    $totalConnected = 0; $specs = 0

                    if ($jobRes.is404) {
                        $modeStrTitle = "Idle"; $modeStrTray = "Idle"
                    } elseif ($jobRes.is500) {
                        $modeStrTitle = "Social Lobby"; $modeStrTray = "Social Lobby"
                        if ($jobRes.bonesStr) {
                            $playerMatches = [regex]::Matches($jobRes.bonesStr, '(?i)"playerid"\s*:\s*(\d+)')
                            $totalConnected = $playerMatches.Count
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
                                $totalConnected = $playerMatches.Count
                                if ($sessionObj.teams.Count -ge 3 -and $null -ne $sessionObj.teams[2].players) {
                                    $specs = @($sessionObj.teams[2].players).Count
                                }
                            }
                        } catch {}
                    }

                    $activePlayers = $totalConnected - $specs
                    if ($totalConnected -eq 0) { $pStrTitle = "0 Active Players"; $pStrTray = "0 Players" } 
                    else {
                        if ($specs -gt 0) { $pStrTitle = "$activePlayers Active Players ($specs Spectating)"; $pStrTray = "$activePlayers Players ($specs Spec.)" } 
                        else { $pStrTitle = "$activePlayers Active Players"; $pStrTray = "$activePlayers Players" }
                    }
                    
                    $pData.ModeTitle = $modeStrTitle; $pData.ModeTray = $modeStrTray
                    $pData.PlayersTitle = $pStrTitle; $pData.PlayersTray = $pStrTray
                    $pData.PlayerCount = $totalConnected
                }
            }

            # 3. Soft Shutdown Evaluation & Idle Auto-Restart
            if ($Global:MigrationInProgress -and -not $pData.ShutdownQueued) { $pData.ShutdownQueued = $true }
            if ($pData.ModeTitle -eq "Idle") {
                if ($pData.PreviousMode -ne "Idle") {
                    $pData.LastIdleStart = $now
                } elseif ($config.autoRestartIdle -and $null -ne $pData.LastIdleStart) {
                    $idleTime = New-TimeSpan -Start $pData.LastIdleStart -End $now
                    if ($idleTime.TotalMinutes -ge $config.autoRestartTimeout -and -not $pData.ShutdownQueued) {
                        $pData.ShutdownQueued = $true
                        Write-MonitorLog "Instance queued for shutdown automatically (Idle timeout)" -ProcId $proc.Id -pData $pData
                    }
                }
            } else {
                $pData.LastIdleStart = $null
            }
            $pData.PreviousMode = $pData.ModeTitle

            # Process Shutdown Execution
            if ($pData.ShutdownQueued) {
                if ($pData.ModeTitle -eq "Idle") {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    $Global:PortMap.Remove($proc.Id)
                    continue
                }
            }
        }
    }
    
    if ($Global:MigrationInProgress) {
        $migNote = if ($canSoftShutdown) { "" } else { " - soft shutdown unavailable, close them manually" }
        $MenuItemStatus.Text = "Migrating: waiting for $runningCount instance(s) to shut down$migNote"
    } elseif ($canSoftShutdown) { $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances) (Click Instance to Queue Shutdown)" }
    else { $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances) (Allow API Usage for Soft Shutdowns)" }

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
                            $newState = $this.Checked
                            $Global:PortMap[$clickedPid].ShutdownQueued = $newState
                            if ($newState) { Write-MonitorLog "Instance queued for shutdown by user" -ProcId $clickedPid -pData $Global:PortMap[$clickedPid] }
                        }
                    })
                } else {
                    $item.CheckOnClick = $false
                    $item.Enabled = $false
                }
                
                if ($Global:MigrationInProgress) { $item.Enabled = $false }
                $ContextMenuStrip.Items.Insert($pIndex, $item)
                $pIndex++
            } catch { }
        }
    }

    if (-not $config.pauseSpawning -and -not $Global:MigrationInProgress) {
        $needed = $config.amountOfInstances - $runningCount
        if ($needed -gt 0) {
            $freshConfig = Get-MonitorConfig
            if (-not $freshConfig.pauseSpawning -and -not $Global:LinkCodeActive) {
                
                $portPair = $null
                if ($freshConfig.portMappingMode -eq "Manual") { $portPair = Get-ManualPortPair } 
                else { $portPair = Get-AvailablePortPair }

                if ($null -ne $portPair) {
                    $exitArg = if ($config.killCondition -eq "ExitOnError") { " -exitonerror" } else { "" }
                    $timeStepArg = if ($config.timeStep -ne 0) { "-fixedtimestep -timestep $($config.timeStep) " } else { "" }
                    $launchArgs = "-numtaskthreads $($config.numTaskThreads) $timeStepArg$($config.additionalArgs) -port $($portPair.GS) -httpport $($portPair.API)$exitArg"
                    
                    $consoleSubKey = $EchoExePath -replace '\\', '_'
                    $appRegPath = "HKCU:\Console\$consoleSubKey"
                    
                    if (-not (Test-Path $appRegPath)) { New-Item -Path $appRegPath -Force | Out-Null }
                    Set-ItemProperty -Path $appRegPath -Name "QuickEdit" -Value 0 -Force
                    
                    $newProc = Start-Process -FilePath $EchoExePath -ArgumentList $launchArgs -WindowStyle Minimized -PassThru
                    
                    if ($newProc) {
                        $Global:PortMap[$newProc.Id] = @{
                            GS = $portPair.GS; API = $portPair.API
                            GS_Confirmed = $null; API_Confirmed = $null; LogPath = $null
                            ShutdownQueued = $false; PlayerCount = 0; ModeTitle = "Unknown Mode"; PreviousMode = "Unknown Mode"; LastIdleStart = $null
                        }
                        Write-MonitorLog "Instance spawned" -ProcId $newProc.Id -pData $Global:PortMap[$newProc.Id]
                    }
                }
            }
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 11. MIGRATION TO THE COMMUNITY LAUNCHER
# ==============================================================================

# Helper script template. When migration starts it is written to %TEMP% under a random name.
# One file serves both stages (each stage runs as its own separate process):
#   -Stage Dialog  : shows the "Instances are preparing for shutdown" dialog, then launches the cleanup stage
#   -Stage Cleanup : runs in its own terminal window, waits for echovr + the monitor to exit, deletes files,
#                    and deletes this script file itself (so nothing is left behind)
$Script:MigrationHelperTemplate = @'
param([string]$Stage = 'Dialog', [switch]$DeleteAll)

$ErrorActionPreference = 'SilentlyContinue'
$root       = '__ROOT__'
$monitorPid = __MONPID__
$guideUrl   = '__URL__'
Set-Location -LiteralPath $env:TEMP

# ------------------------------------------------------------ Stage 1: dialog
if ($Stage -eq 'Dialog') {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EchoVR Server Monitor - Migration'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Instances are preparing for shutdown. Click OK to open the community launcher setup guide.'
    $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $lbl.Size = New-Object System.Drawing.Size(380, 40)
    $form.Controls.Add($lbl)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Delete my ready-at-dawn-echo-arena folder'
    $chk.Location = New-Object System.Drawing.Point(20, 70)
    $chk.Size = New-Object System.Drawing.Size(380, 24)
    $chk.Checked = $false
    $form.Controls.Add($chk)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Location = New-Object System.Drawing.Point(310, 105)
    $ok.Size = New-Object System.Drawing.Size(90, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    [void]$form.ShowDialog()
    $wipe = $chk.Checked
    $form.Dispose()

    Start-Process $guideUrl

    # Hand off to a separate process in a new terminal window
    $cleanupArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stage Cleanup"
    if ($wipe) { $cleanupArgs += ' -DeleteAll' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cleanupArgs -WorkingDirectory $env:TEMP -WindowStyle Normal
    exit
}

# ------------------------------------------------------------ Stage 2: cleanup
# PowerShell has already read this file completely, so it is safe to remove it right away
Remove-Item -LiteralPath $PSCommandPath -Force

$Host.UI.RawUI.WindowTitle = 'EchoVR Server Monitor - Migration Cleanup'
$wipe = $DeleteAll.IsPresent
# Never wipe a drive root, fall back to the targeted cleanup instead
if ($wipe -and $root.TrimEnd('\').Length -le 3) { $wipe = $false }

$monitorName = (Get-Process -Id $monitorPid).ProcessName
function Test-MonitorAlive {
    if (-not $monitorName) { return $false }
    $p = Get-Process -Id $monitorPid
    return ($null -ne $p -and $p.ProcessName -eq $monitorName)
}

function Show-Status([string]$text) { Clear-Host; Write-Host $text }

Show-Status 'Waiting for servers to shut down... (Press ENTER to kill processes now)'
while ((Get-Process -Name echovr) -or (Test-MonitorAlive)) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') {
            Get-Process -Name echovr | Stop-Process -Force
            if (Test-MonitorAlive) { Stop-Process -Id $monitorPid -Force }
            break
        }
    }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2   # let file handles release

Show-Status 'Cleaning up...'
if ($wipe) {
    $targets = @($root)
} else {
    $targets = @((Join-Path $root 'Launch-Monitor.bat'), (Join-Path $root 'dashboard'), (Join-Path $root 'combatGunPatchFiles'))
}

$remaining = @()
for ($attempt = 1; $attempt -le 5; $attempt++) {
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
    }
    $remaining = @($targets | Where-Object { Test-Path -LiteralPath $_ })
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 2
}

if ($remaining.Count -eq 0) {
    Show-Status 'Finished! Exiting in 5 seconds...'
    Start-Sleep -Seconds 5
} else {
    Show-Status ("Some files could not be deleted (they may be in use). Please delete them manually:`n" + ($remaining -join "`n") + "`n`nExiting in 10 seconds...")
    Start-Sleep -Seconds 10
}
exit
'@

# --- Persistent prompt state (own file, so the settings window can never overwrite it with stale data) ---
Function Get-MigrationState {
    $state = @{ dismissed = $false; remindAt = $null }
    if (Test-Path -LiteralPath $Script:MigrationFile) {
        try {
            $raw = Get-Content -LiteralPath $Script:MigrationFile -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                if ($null -ne $obj.dismissed) { $state.dismissed = [bool]$obj.dismissed }
                if ($null -ne $obj.remindAt) { $state.remindAt = [datetime]$obj.remindAt }
            }
        } catch { }
    }
    return $state
}

Function Set-MigrationState ([bool]$dismissed, $remindAt) {
    try {
        if (-not (Test-Path -LiteralPath $Script:DashboardDir)) { New-Item -ItemType Directory -Path $Script:DashboardDir -Force | Out-Null }
        $remindStr = $null
        if ($null -ne $remindAt) { $remindStr = ([datetime]$remindAt).ToString("o") }
        @{ dismissed = $dismissed; remindAt = $remindStr } | ConvertTo-Json | Set-Content -LiteralPath $Script:MigrationFile -Force
    } catch { }
}

Function Test-MigrationPromptDue {
    $state = Get-MigrationState
    if ($state.dismissed) { return $false }
    if ($null -eq $state.remindAt) { return $true }
    return ((Get-Date) -ge $state.remindAt)
}

# --- The three-button migration popup. Returns "Migrate", "Later", "Never" (or "Busy" if one is already open) ---
Function Show-MigrationPopup {
    param($Owner = $null)

    if ($Global:MigrationPopupOpen) { return "Busy" }
    $Global:MigrationPopupOpen = $true
    $dlg = $null
    try {
        $conf = Get-MonitorConfig
        $tf = $conf.touchFriendly
        $k = if ($tf) { 1.25 } else { 1 }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "EchoVR Server Monitor - Deprecated"
        $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.TopMost = $true
        if ($null -ne $Owner) { $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent }
        else { $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($tf) { $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 11) }
        $dlg.ClientSize = New-Object System.Drawing.Size([int](460 * $k), [int](180 * $k))

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "The PowerShell monitor has been deprecated as of October 30, 2026 in favor of the new community launcher. Would you like to migrate now?`n`nYou can also begin migration at any time from the About tab."
        $lbl.Location = New-Object System.Drawing.Point([int](20 * $k), [int](20 * $k))
        $lbl.Size = New-Object System.Drawing.Size([int](420 * $k), [int](100 * $k))
        $dlg.Controls.Add($lbl)

        $btnMigrate = New-Object System.Windows.Forms.Button
        $btnMigrate.Text = "Migrate Now"
        $btnMigrate.Location = New-Object System.Drawing.Point([int](20 * $k), [int](135 * $k))
        $btnMigrate.Size = New-Object System.Drawing.Size([int](130 * $k), [int](30 * $k))
        $btnMigrate.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $dlg.Controls.Add($btnMigrate)

        $btnLater = New-Object System.Windows.Forms.Button
        $btnLater.Text = "Remind Me Later"
        $btnLater.Location = New-Object System.Drawing.Point([int](165 * $k), [int](135 * $k))
        $btnLater.Size = New-Object System.Drawing.Size([int](130 * $k), [int](30 * $k))
        $btnLater.DialogResult = [System.Windows.Forms.DialogResult]::Retry
        $dlg.Controls.Add($btnLater)

        $btnNever = New-Object System.Windows.Forms.Button
        $btnNever.Text = "Don't Ask Again"
        $btnNever.Location = New-Object System.Drawing.Point([int](310 * $k), [int](135 * $k))
        $btnNever.Size = New-Object System.Drawing.Size([int](130 * $k), [int](30 * $k))
        $btnNever.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
        $dlg.Controls.Add($btnNever)

        # Enter / Esc / the X button all mean "Remind Me Later" so nothing destructive can happen by accident
        $dlg.AcceptButton = $btnLater
        $dlg.CancelButton = $btnLater

        if ($null -ne $Owner) { $res = $dlg.ShowDialog($Owner) } else { $res = $dlg.ShowDialog() }

        if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { return "Migrate" }
        if ($res -eq [System.Windows.Forms.DialogResult]::Ignore) { return "Never" }
        return "Later"
    } finally {
        $Global:MigrationPopupOpen = $false
        if ($null -ne $dlg) { $dlg.Dispose() }
    }
}

# Shows the popup and acts on the answer. Returns the choice.
Function Invoke-MigrationPrompt {
    param($Owner = $null)

    $choice = Show-MigrationPopup -Owner $Owner
    if ($choice -eq "Migrate") {
        Write-MonitorLog "Migration prompt: Migrate Now selected"
        $null = Start-Migration
    } elseif ($choice -eq "Never") {
        Set-MigrationState $true $null
        Write-MonitorLog "Migration prompt: Don't Ask Again selected"
    } elseif ($choice -eq "Later") {
        $remindAt = (Get-Date).AddHours(24)
        Set-MigrationState $false $remindAt
        Write-MonitorLog "Migration prompt: Remind Me Later selected (next prompt after $($remindAt.ToString('MM-dd-yyyy HH:mm:ss')))"
    }
    return $choice
}

# Launches the migration helper (stage 1: dialog) as a separate, hidden process
Function Start-MigrationDialogProcess {
    $tempDir = [System.IO.Path]::GetTempPath()
    $rootEsc = $Script:ScriptRoot.Replace("'", "''")
    $urlEsc = $Script:MigrationGuideURL.Replace("'", "''")
    $helperText = $Script:MigrationHelperTemplate.Replace('__ROOT__', $rootEsc).Replace('__MONPID__', [string]$PID).Replace('__URL__', $urlEsc)

    $helperPath = Join-Path $tempDir ("evr-migrate-" + [guid]::NewGuid().ToString("N") + ".ps1")
    # UTF-8 with BOM so Windows PowerShell 5.1 reads non-ASCII folder names correctly
    [System.IO.File]::WriteAllText($helperPath, $helperText, (New-Object System.Text.UTF8Encoding($true)))

    # WorkingDirectory must NOT be the echo folder, or the helper would block that folder from being deleted
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helperPath`" -Stage Dialog" -WindowStyle Hidden -WorkingDirectory $tempDir
}

# Migrate Now: pause spawning, queue every instance for shutdown, remove the startup shortcut, open the helper dialog
Function Start-Migration {
    if ($Global:MigrationInProgress) { return }
    $Global:MigrationInProgress = $true
    Write-MonitorLog "Migration started"

    # 1. Pause server spawning (also enforced by the monitor loop while migration is in progress)
    try { $conf = Get-MonitorConfig; $conf.pauseSpawning = $true; Save-MonitorConfig $conf } catch { }
    $MenuItemPause.Checked = $true
    $MenuItemPause.Enabled = $false
    $MenuItemConfig.Enabled = $false

    # 2. Queue all instances for shutdown (soft shutdown: each one closes once it is idle)
    foreach ($procId in @($Global:PortMap.Keys)) {
        $Global:PortMap[$procId].ShutdownQueued = $true
        Write-MonitorLog "Instance queued for shutdown (migration)" -ProcId $procId -pData $Global:PortMap[$procId]
    }

    # 3. Remove the startup shortcut
    try {
        if (Test-Path -LiteralPath $Script:ShortcutPath) { Remove-Item -LiteralPath $Script:ShortcutPath -Force -ErrorAction Stop }
    } catch { Write-MonitorLog "Failed to remove startup shortcut: $_" }

    # 4. Open the migration dialog in a new process (it outlives this monitor)
    try {
        Start-MigrationDialogProcess
    } catch {
        Write-MonitorLog "Failed to launch migration dialog: $_"
        [System.Windows.Forms.MessageBox]::Show("Could not open the migration helper ($_).`n`nInstances are still being shut down. Click OK to open the community launcher setup guide.", "Migration", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Start-Process $Script:MigrationGuideURL
    }
}

# Called from the monitor loop once every instance has shut down
Function Complete-Migration {
    Write-MonitorLog "Migration: all instances shut down, monitor exiting"
    $MonitorTimer.Stop()
    $MigrationTimer.Stop()
    $NotifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

# Launch popup + 24h reminders. First check runs shortly after launch, then once a minute.
$MigrationTimer = New-Object System.Windows.Forms.Timer
$MigrationTimer.Interval = 1500

$MigrationTimerAction = {
    $MigrationTimer.Stop()
    try {
        $configOpen = ($null -ne $Global:ConfigForm -and -not $Global:ConfigForm.IsDisposed)
        if (-not $Global:MigrationInProgress -and -not $Global:MigrationPopupOpen -and -not $configOpen) {
            if (Test-MigrationPromptDue) { $null = Invoke-MigrationPrompt }
        }
    } catch { }
    finally {
        if (-not $Global:MigrationInProgress) { $MigrationTimer.Interval = 60000; $MigrationTimer.Start() }
    }
}
$MigrationTimer.Add_Tick($MigrationTimerAction)

# ==============================================================================
# 12. EXECUTION
# ==============================================================================

try {
    $MonitorTimer.Start()
    $MigrationTimer.Start()
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}