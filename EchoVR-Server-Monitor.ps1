###################################################################
# Code by marshmallow_mia and now berg_
# Server monitor lives in the system tray :)
# Echo <3
###################################################################

# Changes 
# v4.0.0 - Revamped config, unified log/update scheduling.
# v3.2.1 - Fixed log archiving, added 'Clean up logs now' tray button.
# v3.2.0 - Added Base Port config, Auto-Archive, and Auto-Purge scheduling for logs.
# v3.1.0 - Added Open Echo Folder, Delay fields in seconds, EchoVRCE Portal button.

# ==============================================================================
# GLOBAL SETTINGS
# ==============================================================================
$Global:Version = "4.0.0"
$Global:GithubOwner = "EchoTools"
$Global:GithubRepo  = "EchoVR-Windows-Hosts-Resources"

# Port Management & Tracking
# Structure: @{ PID = @{ GS=1234; API=1235; LogPath="..."; LastLogLine="..."; LastLogTime=[datetime] } }
$Global:PortMap = @{}
$Global:PendingKills = @{}

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
$LogPathOld = Join-Path $LogPath "old"

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
if (-not (Test-Path $LogPathOld)) { New-Item -ItemType Directory -Path $LogPathOld -Force | Out-Null }

# ==============================================================================
# 3. CONFIGURATION MANAGEMENT
# ==============================================================================

Function Get-MonitorConfig {
    if (-not (Test-Path $MonitorFile)) {
        $defaultConfig = @{
            amountOfInstances = 1
            basePort = 6792
            delayExiting = 2000
            delayProcessCheck = 5000
            delayKillStuck = 20000
            numTaskThreads = 2
            timeStep = 120
            additionalArgs = "-server -headless -noovr -fixedtimestep -nosymbollookup -exitnoerror"
            suppressSetupWarning = $false
            autoUpdate = $true
            updateInterval = "Daily"
            lastUpdateCheckDate = "2000-01-01T00:00:00"
            pauseSpawning = $false
            autoArchive = $true
            autoPurge = $false
            purgeInterval = "Weekly"
        }
        if (Test-Path $SetupFile) {
            $dashData = Get-Content $SetupFile -Raw | ConvertFrom-Json
            if ($dashData.numInstances) { $defaultConfig.amountOfInstances = $dashData.numInstances }
            if ($dashData.lowerPort) { $defaultConfig.basePort = $dashData.lowerPort }
        }
        $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content $MonitorFile
        return $defaultConfig
    }
    
    # Ensure properties exist for older configs
    $config = Get-Content $MonitorFile -Raw | ConvertFrom-Json
    $saveNeeded = $false

    if ($null -eq $config.basePort) { $config | Add-Member -MemberType NoteProperty -Name "basePort" -Value 6792 -Force; $saveNeeded = $true }
    if ($null -eq $config.autoUpdate) { $config | Add-Member -MemberType NoteProperty -Name "autoUpdate" -Value $true -Force; $saveNeeded = $true }
    if ($null -eq $config.updateInterval) { $config | Add-Member -MemberType NoteProperty -Name "updateInterval" -Value "Daily" -Force; $saveNeeded = $true }
    if ($null -eq $config.lastUpdateCheckDate) { $config | Add-Member -MemberType NoteProperty -Name "lastUpdateCheckDate" -Value "2000-01-01T00:00:00" -Force; $saveNeeded = $true }
    if ($null -eq $config.pauseSpawning) { $config | Add-Member -MemberType NoteProperty -Name "pauseSpawning" -Value $false -Force; $saveNeeded = $true }
    if ($null -eq $config.autoArchive) { $config | Add-Member -MemberType NoteProperty -Name "autoArchive" -Value $true -Force; $saveNeeded = $true }
    if ($null -eq $config.autoPurge) { $config | Add-Member -MemberType NoteProperty -Name "autoPurge" -Value $false -Force; $saveNeeded = $true }
    if ($null -eq $config.purgeInterval) { $config | Add-Member -MemberType NoteProperty -Name "purgeInterval" -Value "Weekly" -Force; $saveNeeded = $true }

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

$initConfig = Get-MonitorConfig
$Global:BasePort = $initConfig.basePort

# ==============================================================================
# 4. LOG MAINTENANCE LOGIC (Auto-Archive & Purge)
# ==============================================================================

Function Invoke-LogMaintenance {
    param([switch]$ManualArchive, [switch]$ManualPurge)
    
    $runningJobs = Get-Job -Name "LogMaintenance_Manual", "LogMaintenance_Auto" -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
    
    if ($runningJobs) {
        if ($ManualArchive -or $ManualPurge) {
            [System.Windows.Forms.MessageBox]::Show("Log maintenance is already running. Please wait.", "In Progress", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        return
    }

    $config = Get-MonitorConfig
    $IsManual = $ManualArchive -or $ManualPurge
    $jobArgs = @($config, $LogPath, $LogPathOld, [bool]$ManualArchive, [bool]$ManualPurge, [bool]$IsManual)
    
    $jobName = if ($IsManual) { "LogMaintenance_Manual" } else { "LogMaintenance_Auto" }

    Start-Job -Name $jobName -ArgumentList $jobArgs -ScriptBlock {
        param($jobConfig, $jobLogPath, $jobLogPathOld, $IsManualArchive, $IsManualPurge, $IsManual)

        $now = Get-Date

        $doArchive = $IsManualArchive -or (-not $IsManual -and $jobConfig.autoArchive)
        if ($doArchive) {
            if ($IsManualArchive) {
                $targetLogs = @(Get-ChildItem -Path $jobLogPath -Filter "*.log" -File -ErrorAction SilentlyContinue)
                $targetLogs += @(Get-ChildItem -Path $jobLogPathOld -Filter "*.log" -File -ErrorAction SilentlyContinue)
            } else {
                $targetLogs = @(Get-ChildItem -Path $jobLogPath -Filter "*.log" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $now.AddDays(-1) })
                $targetLogs += @(Get-ChildItem -Path $jobLogPathOld -Filter "*.log" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $now.AddDays(-1) })
            }
            
            if ($targetLogs) {
                $foldersToCompress = @{} 
                
                foreach ($log in $targetLogs) {
                    $logDate = $log.LastWriteTime
                    $offset = [int]$logDate.DayOfWeek
                    $startOfWeek = $logDate.AddDays(-$offset).Date
                    $endOfWeek = $startOfWeek.AddDays(6).Date
                    
                    $folderName = "Week_$($startOfWeek.ToString('MMM_dd'))_to_$($endOfWeek.ToString('MMM_dd_yyyy'))"
                    $weekFolder = Join-Path $jobLogPathOld $folderName
                    
                    if (-not (Test-Path -LiteralPath $weekFolder)) {
                        New-Item -ItemType Directory -Path $weekFolder -Force | Out-Null
                    }
                    
                    $foldersToCompress[$weekFolder] = $true
                    $destPath = Join-Path $weekFolder $log.Name
                    
                    if ($log.Directory.FullName -ne $weekFolder) {
                        try {
                            Move-Item -LiteralPath $log.FullName -Destination $destPath -Force -ErrorAction Stop
                        } catch {}
                    }
                }
                
                foreach ($folder in $foldersToCompress.Keys) {
                    Start-Process -FilePath "compact.exe" -ArgumentList "/c /i /q `"$folder`"" -WindowStyle Hidden -Wait
                    Start-Process -FilePath "compact.exe" -ArgumentList "/c /i /q `"$folder\*`"" -WindowStyle Hidden -Wait
                }
            }
        }

        $doPurge = $IsManualPurge -or (-not $IsManual -and $jobConfig.autoPurge)
        if ($doPurge) {
            $daysToKeep = 7
            switch ($jobConfig.purgeInterval) {
                "Daily"   { $daysToKeep = 1 }
                "Weekly"  { $daysToKeep = 7 }
                "Monthly" { $daysToKeep = 30 }
            }

            $cutoffDate = $now.AddDays(-$daysToKeep)
            
            $oldFiles = Get-ChildItem -LiteralPath $jobLogPathOld -File -Recurse -ErrorAction SilentlyContinue | 
                        Where-Object { $_.LastWriteTime -lt $cutoffDate }
            
            foreach ($file in $oldFiles) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }

            $allDirs = Get-ChildItem -LiteralPath $jobLogPathOld -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName -Descending
            foreach ($dir in $allDirs) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
            }
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
    $form.Size = New-Object System.Drawing.Size(460, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # TAB CONTROL
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(10, 10)
    $tabControl.Size = New-Object System.Drawing.Size(425, 360)
    $form.Controls.Add($tabControl)

    # ==========================
    # TAB 1: SERVER SETTINGS
    # ==========================
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

    # ==========================
    # TAB 2: MONITOR SETTINGS
    # ==========================
    $tabMonitor = New-Object System.Windows.Forms.TabPage
    $tabMonitor.Text = "Monitor Settings"
    $tabControl.TabPages.Add($tabMonitor)

    $lblExit = New-Object System.Windows.Forms.Label
    $lblExit.Text = "Exit Delay (sec):"
    $lblExit.Location = New-Object System.Drawing.Point(20, 25)
    $lblExit.AutoSize = $true
    $tabMonitor.Controls.Add($lblExit)

    $txtExit = New-Object System.Windows.Forms.TextBox
    $txtExit.Location = New-Object System.Drawing.Point(250, 22)
    $txtExit.Size = New-Object System.Drawing.Size(120, 20)
    $txtExit.Text = "$($monitorData.delayExiting / 1000)"
    $tabMonitor.Controls.Add($txtExit)

    $lblCheck = New-Object System.Windows.Forms.Label
    $lblCheck.Text = "Monitor Update Frequency (sec):"
    $lblCheck.Location = New-Object System.Drawing.Point(20, 60)
    $lblCheck.AutoSize = $true
    $tabMonitor.Controls.Add($lblCheck)

    $txtCheck = New-Object System.Windows.Forms.TextBox
    $txtCheck.Location = New-Object System.Drawing.Point(250, 57)
    $txtCheck.Size = New-Object System.Drawing.Size(120, 20)
    $txtCheck.Text = "$($monitorData.delayProcessCheck / 1000)"
    $tabMonitor.Controls.Add($txtCheck)

    $lblKill = New-Object System.Windows.Forms.Label
    $lblKill.Text = "Stuck Process Kill Delay (sec):"
    $lblKill.Location = New-Object System.Drawing.Point(20, 95)
    $lblKill.AutoSize = $true
    $tabMonitor.Controls.Add($lblKill)

    $txtKill = New-Object System.Windows.Forms.TextBox
    $txtKill.Location = New-Object System.Drawing.Point(250, 92)
    $txtKill.Size = New-Object System.Drawing.Size(120, 20)
    $txtKill.Text = "$($monitorData.delayKillStuck / 1000)"
    $tabMonitor.Controls.Add($txtKill)

    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = "Start with Windows"
    $chkStartup.Location = New-Object System.Drawing.Point(20, 135)
    $chkStartup.AutoSize = $true
    $chkStartup.Checked = (Test-Path $ShortcutPath)
    $tabMonitor.Controls.Add($chkStartup)

    # Archive Config
    $chkArchive = New-Object System.Windows.Forms.CheckBox
    $chkArchive.Text = "Auto-Archive Logs"
    $chkArchive.Location = New-Object System.Drawing.Point(20, 165)
    $chkArchive.AutoSize = $true
    $chkArchive.Checked = $monitorData.autoArchive
    $tabMonitor.Controls.Add($chkArchive)

    $btnArchiveLogs = New-Object System.Windows.Forms.Button
    $btnArchiveLogs.Text = "Archive Now"
    $btnArchiveLogs.Location = New-Object System.Drawing.Point(250, 162)
    $btnArchiveLogs.Size = New-Object System.Drawing.Size(140, 24)
    $btnArchiveLogs.Add_Click({ Invoke-LogMaintenance -ManualArchive })
    $tabMonitor.Controls.Add($btnArchiveLogs)

    # Purge Config
    $chkPurge = New-Object System.Windows.Forms.CheckBox
    $chkPurge.Text = "Purge Old Logs:"
    $chkPurge.Location = New-Object System.Drawing.Point(20, 195)
    $chkPurge.AutoSize = $true
    $chkPurge.Checked = $monitorData.autoPurge
    $tabMonitor.Controls.Add($chkPurge)

    $cmbPurge = New-Object System.Windows.Forms.ComboBox
    $cmbPurge.Location = New-Object System.Drawing.Point(155, 193)
    $cmbPurge.Size = New-Object System.Drawing.Size(80, 20)
    $cmbPurge.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Daily", "Weekly", "Monthly") | ForEach-Object { $cmbPurge.Items.Add($_) | Out-Null }
    $cmbPurge.SelectedItem = $monitorData.purgeInterval
    $cmbPurge.Enabled = $chkPurge.Checked
    $tabMonitor.Controls.Add($cmbPurge)

    $chkPurge.Add_CheckedChanged({ $cmbPurge.Enabled = $chkPurge.Checked })

    $btnCleanLogs = New-Object System.Windows.Forms.Button
    $btnCleanLogs.Text = "Purge Now"
    $btnCleanLogs.Location = New-Object System.Drawing.Point(250, 192)
    $btnCleanLogs.Size = New-Object System.Drawing.Size(140, 24)
    $btnCleanLogs.Add_Click({ Invoke-LogMaintenance -ManualPurge })
    $tabMonitor.Controls.Add($btnCleanLogs)

    # Auto-Update Config
    $chkAutoUpdate = New-Object System.Windows.Forms.CheckBox
    $chkAutoUpdate.Text = "Check for Updates:"
    $chkAutoUpdate.Location = New-Object System.Drawing.Point(20, 225)
    $chkAutoUpdate.AutoSize = $true
    $chkAutoUpdate.Checked = $monitorData.autoUpdate
    $tabMonitor.Controls.Add($chkAutoUpdate)

    $cmbUpdate = New-Object System.Windows.Forms.ComboBox
    $cmbUpdate.Location = New-Object System.Drawing.Point(155, 223)
    $cmbUpdate.Size = New-Object System.Drawing.Size(80, 20)
    $cmbUpdate.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Daily", "Weekly", "Monthly") | ForEach-Object { $cmbUpdate.Items.Add($_) | Out-Null }
    $cmbUpdate.SelectedItem = $monitorData.updateInterval
    $cmbUpdate.Enabled = $chkAutoUpdate.Checked
    $tabMonitor.Controls.Add($cmbUpdate)

    $chkAutoUpdate.Add_CheckedChanged({ $cmbUpdate.Enabled = $chkAutoUpdate.Checked })

    $btnCheckUpdates = New-Object System.Windows.Forms.Button
    $btnCheckUpdates.Text = "Check Now"
    $btnCheckUpdates.Location = New-Object System.Drawing.Point(250, 222)
    $btnCheckUpdates.Size = New-Object System.Drawing.Size(140, 24)
    $btnCheckUpdates.Add_Click({ Test-ForUpdates -ManualCheck $true })
    $tabMonitor.Controls.Add($btnCheckUpdates)

    # ==========================
    # TAB 3: ABOUT
    # ==========================
    $tabAbout = New-Object System.Windows.Forms.TabPage
    $tabAbout.Text = "About"
    $tabControl.TabPages.Add($tabAbout)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "EchoVR Server Monitor v$($Global:Version)"
    $lblVersion.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 12, [System.Drawing.FontStyle]::Bold)
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblVersion.Location = New-Object System.Drawing.Point(10, 40)
    $lblVersion.Size = New-Object System.Drawing.Size(400, 30)
    $tabAbout.Controls.Add($lblVersion)

    $lblPing = New-Object System.Windows.Forms.Label
    $lblPing.Text = "Ping @berg_ on Discord for issues/feedback!"
    $lblPing.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblPing.Location = New-Object System.Drawing.Point(10, 80)
    $lblPing.Size = New-Object System.Drawing.Size(400, 20)
    $tabAbout.Controls.Add($lblPing)

    $btnAboutUpdate = New-Object System.Windows.Forms.Button
    $btnAboutUpdate.Text = "Check for Updates"
    $btnAboutUpdate.Location = New-Object System.Drawing.Point(135, 120)
    $btnAboutUpdate.Size = New-Object System.Drawing.Size(150, 30)
    $btnAboutUpdate.Add_Click({ Test-ForUpdates -ManualCheck $true })
    $tabAbout.Controls.Add($btnAboutUpdate)

    # ==========================
    # BOTTOM BUTTONS (Always Visible)
    # ==========================
    $btnOpenLocal = New-Object System.Windows.Forms.Button
    $btnOpenLocal.Text = "Open Server Config"
    $btnOpenLocal.Location = New-Object System.Drawing.Point(30, 385)
    $btnOpenLocal.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenLocal.Add_Click({ Invoke-Item $LocalConfigPath })
    $form.Controls.Add($btnOpenLocal)

    $btnOpenEcho = New-Object System.Windows.Forms.Button
    $btnOpenEcho.Text = "Open Echo Folder"
    $btnOpenEcho.Location = New-Object System.Drawing.Point(235, 385)
    $btnOpenEcho.Size = New-Object System.Drawing.Size(180, 25)
    $btnOpenEcho.Add_Click({ Invoke-Item $ScriptRoot })
    $form.Controls.Add($btnOpenEcho)
    
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(85, 420)
    $btnSave.Size = New-Object System.Drawing.Size(80, 25)
    $btnSave.Add_Click({
        try {
            if ([int]$txtInst.Text -lt 1) { throw "Invalid Instances" }
            if ([int]$txtPort.Text -lt 1 -or [int]$txtPort.Text -gt 65535) { throw "Invalid Port" }
            
            $null = [double]$txtExit.Text
            $null = [double]$txtCheck.Text
            $null = [double]$txtKill.Text

            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Please enter valid numbers for the required fields.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($btnSave)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Defaults"
    $btnRestore.Location = New-Object System.Drawing.Point(180, 420)
    $btnRestore.Size = New-Object System.Drawing.Size(80, 25)
    $btnRestore.Add_Click({
        $txtInst.Text = "1"
        $txtPort.Text = "6792"
        $txtThreads.Text = "2"
        $rbStd.Checked = $true
        $txtArgs.Text = "-server -headless -noovr -fixedtimestep -nosymbollookup"
        
        $txtExit.Text = "2"
        $txtCheck.Text = "5"
        $txtKill.Text = "20"
        
        $chkStartup.Checked = $true
        $chkArchive.Checked = $true
        
        $chkPurge.Checked = $false
        $cmbPurge.SelectedItem = "Weekly"
        
        $chkAutoUpdate.Checked = $true
        $cmbUpdate.SelectedItem = "Daily"
    })
    $form.Controls.Add($btnRestore)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Discard"
    $btnCancel.Location = New-Object System.Drawing.Point(275, 420)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 25)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $numInst = [int]$txtInst.Text
        $tStep = if ($rbComp.Checked) { 180 } else { 120 }
        
        $monitorData.amountOfInstances = $numInst
        $monitorData.basePort = [int]$txtPort.Text
        $monitorData.delayExiting = [int]([double]$txtExit.Text * 1000)
        $monitorData.delayProcessCheck = [int]([double]$txtCheck.Text * 1000)
        $monitorData.delayKillStuck = [int]([double]$txtKill.Text * 1000)
        $monitorData.numTaskThreads = [int]$txtThreads.Text
        $monitorData.timeStep = $tStep
        $monitorData.additionalArgs = $txtArgs.Text
        $monitorData.autoUpdate = $chkAutoUpdate.Checked
        $monitorData.updateInterval = $cmbUpdate.SelectedItem
        $monitorData.autoArchive = $chkArchive.Checked
        $monitorData.autoPurge = $chkPurge.Checked
        $monitorData.purgeInterval = $cmbPurge.SelectedItem

        $Global:BasePort = $monitorData.basePort

        Switch-StartupShortcut $chkStartup.Checked
        Save-MonitorConfig $monitorData
        Update-ExternalConfigs $numInst
        
        [System.Windows.Forms.MessageBox]::Show("Configuration Saved.", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# ==============================================================================
# 6. PORT MANAGEMENT
# ==============================================================================

Function Get-AvailablePortPair {
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
# 7. SYSTEM TRAY & MENU
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
$MenuItemConfig.Text = "Configure Settings"
$MenuItemConfig.Add_Click({ 
    $MonitorTimer.Stop()
    Show-ConfigWindow 
    $MonitorTimer.Start()
})
$ContextMenuStrip.Items.Add($MenuItemConfig) | Out-Null

# 4. OPEN ECHOVRCE PORTAL
$MenuItemPortal = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuItemPortal.Text = "Open EchoVRCE Portal"
$MenuItemPortal.Add_Click({
    Start-Process "https://echovrce.com/"
})
$ContextMenuStrip.Items.Add($MenuItemPortal) | Out-Null

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
# 8. MONITORING LOGIC
# ==============================================================================

$MonitorTimer = New-Object System.Windows.Forms.Timer
$MonitorTimer.Interval = 3000

Function Clear-Jobs {
    $completedJobs = Get-Job -State Completed -ErrorAction SilentlyContinue
    $showNotification = $false
    
    foreach ($job in $completedJobs) {
        if ($job.Name -eq "LogMaintenance_Manual") {
            $showNotification = $true
        }
        Remove-Job -Job $job -Force
    }
    
    if ($showNotification) {
        $NotifyIcon.ShowBalloonTip(3000, "Log Maintenance", "Log housekeeping has completed.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

$MonitorAction = {
    $config = Get-MonitorConfig
    $MonitorTimer.Interval = $config.delayProcessCheck
    $Global:BasePort = $config.basePort

    $now = Get-Date

    # --- AUTO-MAINTENANCE TASKS (Run once every midnight) ---
    $currentDay = $now.DayOfYear
    if ($Global:LastLogMaintenanceDay -ne $currentDay) {
        Invoke-LogMaintenance
        
        # Purge and Update Checks occur together
        if ($config.autoUpdate) {
            $daysToWait = 7
            switch ($config.updateInterval) {
                "Daily"   { $daysToWait = 1 }
                "Weekly"  { $daysToWait = 7 }
                "Monthly" { $daysToWait = 30 }
            }
            $lastCheck = [datetime]$config.lastUpdateCheckDate
            if (($now - $lastCheck).TotalDays -ge $daysToWait) {
                Test-ForUpdates
                $config.lastUpdateCheckDate = $now.ToString("o")
                Save-MonitorConfig $config
            }
        }
        $Global:LastLogMaintenanceDay = $currentDay
    }

    if ($MenuItemPause.Checked -ne $config.pauseSpawning) {
        $MenuItemPause.Checked = $config.pauseSpawning
    }

    # Only poll the job engine if we expect active maintenance jobs
    $activeMaintenanceJobs = Get-Job -Name "LogMaintenance_Manual", "LogMaintenance_Auto" -ErrorAction SilentlyContinue
    if ($activeMaintenanceJobs) {
        Clear-Jobs
    }

    $processes = @(Get-Process -Name $EchoProcessName -ErrorAction SilentlyContinue)
    $runningCount = $processes.Count
    $runningIds = $processes.Id

    # --- PENDING PROCESS KILLS ---
    $killKeys = @($Global:PendingKills.Keys)
    foreach ($k in $killKeys) {
        if ($now -ge $Global:PendingKills[$k]) {
            Stop-Process -Id $k -Force -ErrorAction SilentlyContinue
            $Global:PendingKills.Remove($k)
        }
    }

    $trackedPids = @($Global:PortMap.Keys)
    foreach ($pidKey in $trackedPids) {
        if ($runningIds -notcontains $pidKey) {
            $Global:PortMap.Remove($pidKey)
            $Global:PendingKills.Remove($pidKey)
        }
    }

    # --- UNIFIED LOG READING & WATCHDOG ---
    if ($processes) {
        foreach ($proc in $processes) {
            $pData = $Global:PortMap[$proc.Id]
            if ($null -eq $pData) { continue }

            # Locate and cache log path to save disk I/O
            if ($null -eq $pData.LogPath -or -not (Test-Path -LiteralPath $pData.LogPath)) {
                $logFile = Get-ChildItem -Path $LogPath -Filter "*_$($proc.Id).log" -ErrorAction SilentlyContinue | 
                           Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($logFile) { $pData.LogPath = $logFile.FullName }
            }

            if ($pData.LogPath) {
                $lines = Get-Content -LiteralPath $pData.LogPath -Tail 15 -ErrorAction SilentlyContinue
                if ($lines) {
                    $lastLine = $lines[-1]

                    # Watchdog: Check if log is frozen
                    if ($pData.LastLogLine -ne $lastLine) {
                        $pData.LastLogLine = $lastLine
                        $pData.LastLogTime = $now
                    } elseif (($now - $pData.LastLogTime).TotalMilliseconds -gt $config.delayKillStuck) {
                        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                        continue # Skip remaining checks, process is dead
                    }

                    $content = $lines -join "`n"

                    # Port Verification
                    if ($null -eq $pData.GS_Confirmed -and $content -match "Dedicated: broadcaster initialized at \[[0-9\.]+:(\d+)\]") {
                        $pData.GS_Confirmed = [int]$Matches[1]
                    }
                    if ($null -eq $pData.API_Confirmed -and $content -match "\[NETGAME\] Bound HTTP listener to [0-9\.]+:(\d+)") {
                        $pData.API_Confirmed = [int]$Matches[1]
                    }

                    # Link Code Check
                    if (-not $Global:LinkCodeActive -and -not $Global:NotifiedPids.ContainsKey($proc.Id)) {
                        if ($content -match ">>>\s*(?<code>[A-Z0-9]+)\s*<<<") {
                            $code = $Matches['code'].Trim()
                            if (-not [string]::IsNullOrWhiteSpace($code)) {
                                $Global:NotifiedPids[$proc.Id] = $true
                                $Global:LinkCodeActive = $true
                                
                                $conf = Get-MonitorConfig
                                $conf.pauseSpawning = $true
                                Save-MonitorConfig $conf
                                
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
        }
    }
    
    $MenuItemStatus.Text = "Active: $runningCount / $($config.amountOfInstances)                 v$($Global:Version)"

    $sepIndex = $ContextMenuStrip.Items.IndexOf($MenuItemSeparator1)
    
    for ($i = $sepIndex - 1; $i -gt 0; $i--) {
        $ContextMenuStrip.Items.RemoveAt($i)
    }

    if ($processes) {
        $pIndex = 1
        $sortedProcs = $processes | Sort-Object StartTime
        
        foreach ($proc in $sortedProcs) {
            try {
                $uptime = New-TimeSpan -Start $proc.StartTime -End $now
                $pData = $Global:PortMap[$proc.Id]
                $portStr = if ($pData) { " [GS:$($pData.GS) API:$($pData.API)]" } else { "" }
                
                if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                    $newTitle = "EchoVR Server $pIndex - PID: $($proc.Id)$portStr"
                    [Win32Window]::SetWindowText($proc.MainWindowHandle, $newTitle) | Out-Null
                }
                
                $txt = "{0}. PID {1}{2} | {3}h {4}m" -f $pIndex, $proc.Id, $portStr, $uptime.Hours, $uptime.Minutes
                $item = New-Object System.Windows.Forms.ToolStripMenuItem
                $item.Text = $txt
                $item.Enabled = $false 
                
                $ContextMenuStrip.Items.Insert($pIndex, $item)
                $pIndex++
            } catch { }
        }
    }

    if (-not $config.pauseSpawning) {
        $needed = $config.amountOfInstances - $runningCount

        if ($needed -gt 0) {
            for ($i = 0; $i -lt $needed; $i++) {
                $freshConfig = Get-MonitorConfig
                if ($freshConfig.pauseSpawning -or $Global:LinkCodeActive) { break }

                $portPair = Get-AvailablePortPair
                if ($null -eq $portPair) { break }

                $launchArgs = "-numtaskthreads $($config.numTaskThreads) -timestep $($config.timeStep) $($config.additionalArgs) -port $($portPair.GS) -httpport $($portPair.API)"
                
                $newProc = Start-Process -FilePath $EchoExePath -ArgumentList $launchArgs -WindowStyle Minimized -PassThru
                
                if ($newProc) {
                    $Global:PortMap[$newProc.Id] = @{
                        GS = $portPair.GS
                        API = $portPair.API
                        GS_Confirmed = $null
                        API_Confirmed = $null
                        LogPath = $null
                        LastLogLine = ""
                        LastLogTime = Get-Date
                    }
                }

                Start-Sleep -Milliseconds 3000
            }
        }
    }
}

$MonitorTimer.Add_Tick($MonitorAction)

# ==============================================================================
# 9. UPDATE LOGIC (Monitor + DLLs)
# ==============================================================================

Function Test-FileHash ($path, $targetHash) {
    if (-not (Test-Path $path)) { return $false }
    $hash = Get-FileHash -Path $path -Algorithm MD5
    return ($hash.Hash -eq $targetHash)
}

Function Update-DLLs {
    $rawBaseUrl = "https://raw.githubusercontent.com/$Global:GithubOwner/$Global:GithubRepo/main/dll"
    $urlPNSRAD = "$rawBaseUrl/pnsradgameserver.dll"
    $urlDBG    = "$rawBaseUrl/dbgcore.dll"

    $running = Get-Process -Name $Script:EchoProcessName -ErrorAction SilentlyContinue
    if ($running) {
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
        
        [System.Windows.Forms.MessageBox]::Show("DLLs updated successfully.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to download DLLs. Check internet or repo path.`nError: $_", "Download Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

Function Test-ForUpdates ($ManualCheck = $false) {
    $apiUrl = "https://api.github.com/repos/$($Global:GithubOwner)/$($Global:GithubRepo)/releases/latest"
    $TargetFileName = if ($Global:IsBinary) { "EchoVR-Server-Monitor.exe" } else { "EchoVR-Server-Monitor.ps1" }
    
    $monitorUpdateAvailable = $false
    $monitorAssetUrl = $null
    $dllUpdateAvailable = $false

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
                    $monitorUpdateAvailable = $true
                    $monitorAssetUrl = $monitorAsset.browser_download_url
                }
            }
        } catch {
            if ($ManualCheck) { Write-Warning "Could not connect to GitHub API." }
        }

        $pnsradValid = Test-FileHash $Script:Path_PNSRAD $Global:Hash_PNSRAD
        $dbgValid = Test-FileHash $Script:Path_DBGCORE $Global:Hash_DBGCORE
        
        if (-not $pnsradValid -or -not $dbgValid) {
            $dllUpdateAvailable = $true
        }

        if ($monitorUpdateAvailable -and $dllUpdateAvailable) {
            $msg = "Updates Available:`n`n1. New Monitor Version ($($response.tag_name))`n2. New Server DLLs (Hash Mismatch)`n`nUpdate all components now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Critical Updates Found", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Exclamation)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                if (Update-DLLs) {
                    Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl
                }
            }
            return
        }

        if ($monitorUpdateAvailable) {
            $msg = "New Monitor Version Available: $($response.tag_name)`n`nUpdate now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Monitor Update", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                Invoke-MonitorUpdate -downloadUrl $monitorAssetUrl
            }
            return
        }

        if ($dllUpdateAvailable) {
            $msg = "Your local server DLLs do not match the required versions.`n`nUpdate pnsradgameserver.dll and dbgcore.dll now?"
            $res = [System.Windows.Forms.MessageBox]::Show($msg, "DLL Integrity Check", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            
            if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                Update-DLLs
            }
            return
        }

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

        $NotifyIcon.ShowBalloonTip(4000, "Monitor Update", "New version downloaded! Restarting to apply updates...", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 3

        Start-Process -FilePath $batchPath -WindowStyle Hidden
        $NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
        Stop-Process -Id $PID -Force
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Update failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# ==============================================================================
# 10. EXECUTION
# ==============================================================================

# Force a manual check on script launch if the interval allows it
$initConf = Get-MonitorConfig
$daysToWaitInit = 7
switch ($initConf.updateInterval) {
    "Daily"   { $daysToWaitInit = 1 }
    "Weekly"  { $daysToWaitInit = 7 }
    "Monthly" { $daysToWaitInit = 30 }
}
if ($initConf.autoUpdate -and ((Get-Date) - [datetime]$initConf.lastUpdateCheckDate).TotalDays -ge $daysToWaitInit) {
    Test-ForUpdates -ManualCheck $false
    $initConf.lastUpdateCheckDate = (Get-Date).ToString("o")
    Save-MonitorConfig $initConf
}

$MonitorTimer.Start()
[System.Windows.Forms.Application]::Run()