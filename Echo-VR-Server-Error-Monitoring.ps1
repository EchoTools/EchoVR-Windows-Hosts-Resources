###################################################################
#Code by marshmallow_mia (and berg_)
#Checks for errors and restarts the server. Also checks for the right amount of servers running.
#Monitor now lives in the system tray! --berg
#Please contact either of us if you found bugs or for feature requests
#Sorry for weird german variable names at some points
#Echo <3
###################################################################

param (
    [Parameter(Mandatory=$false)]
    [int]$Instances
)

####### THINGS YOU HAVE TO SET UP #######
$amountOfInstances = 2 # number of game servers you want to run
$global:filepath = "C:\Program Files\Oculus\Software\Software\ready-at-dawn-echo-arena" # path to the main echo directory, without the \ at the end

####### ADDITIONAL SETTINGS #######
# If you don't know what's going on here, just leave it as-is.
$global:errors = "Unable to find MiniDumpWriteDump", "[NETGAME] Service status request failed: 400 Bad Request", "[NETGAME] Service status request failed: 404 Not Found", "[TCP CLIENT] [R14NETCLIENT] connection to ws:///login", "[TCP CLIENT] [R14NETCLIENT] connection to failed", `
 "[TCP CLIENT] [R14NETCLIENT] connection to established", "[TCP CLIENT] [R14NETCLIENT] connection to restored", "[TCP CLIENT] [R14NETCLIENT] connection to closed", "[TCP CLIENT] [R14NETCLIENT] Lost connection (okay) to peer", "[NETGAME] Service status request failed: 502 Bad Gateway", `
 "[NETGAME] Service status request failed: 0 Unknown"
$global:delay_for_exiting = 30 
$global:delay_for_process_checking = 3 
$flags =  "-numtaskthreads 2 -server -headless -noovr -server -fixedtimestep -nosymbollookup -timestep 120" 
$processName = "echovr"
$global:delayForKillingIfStuck = 10




#############################################################
# DON'T TOUCH ANYTHING BELOW OR WE'LL VISIT YOU AT NIGHT
#############################################################

# PS7 Check
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Old PowerShell version detected ($($PSVersionTable.PSVersion.Major)). Checking for PowerShell 7..." -ForegroundColor Yellow
    
    if (!(Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Host "PowerShell 7 not found. Attempting installation via winget..." -ForegroundColor Cyan
        if (!(Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Error "winget not found. Please install PowerShell 7 manually from https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.5"
            pause
            exit
        }
        winget install --id Microsoft.PowerShell --source winget --silent --accept-source-agreements --accept-package-agreements
    }

    Write-Host "Relaunching script in PowerShell 7..." -ForegroundColor Green
    & pwsh -File $PSCommandPath $args
    exit
}

if ($Instances) { $amountOfInstances = $Instances }

# Global State
$global:startedTime = ((get-date) - (gcim Win32_OperatingSystem).LastBootUpTime | Select TotalSeconds).TotalSeconds
$global:path = "$filepath\bin\win10\$processName.exe" 
$global:logpath = "$filepath\_local\r14logs"
$global:checkRunningBool = $false 
$global:checkStuckBool = $false 

function check_for_amount_instances($amount, $path, $processName, $flags){
    $echovrProcesses = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($echovrProcesses.Count -lt $amountOfInstances) {
        while ($echovrProcesses.Count -lt $amountOfInstances) {
            New-Item -Path $logpath"\old" -ItemType Directory -Force *> $null
            Move-Item -Path $logpath"\*.log" -Destination $logpath"\old\" -ErrorAction SilentlyContinue *> $null
            Start-Process -FilePath $path $flags -PassThru *> $null
            $echovrProcesses = Get-Process -Name $processName -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }
    else {
        if ($checkRunningBool -eq $false) {
            $global:checkRunningBool = $true
            check_for_errors
        }
        if ($delayForKillingIfStuck -ne 0 -and $checkStuckBool -eq $false) {
            $global:checkStuckBool = $true
            vibWantsMeToForceARestartEveryXMinutes
        }
    }
}

function check_for_errors(){
    Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
        $job = Get-Job -Name $_.ID -ErrorAction SilentlyContinue 
        if ($null -eq $job) {
            $pfad_logs = $logpath+"\*_" + $_.ID + ".log"
            if (Test-Path $pfad_logs) {
                $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
                $line_clean = $lastLineFromFile.Substring(25) -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
                if ($errors -contains $line_clean) {
                    Start-Job -ScriptBlock $Function:check_for_error_consistency -Name $_.ID -ArgumentList $line_clean, $_.ID, $errors, $delay_for_exiting, $logpath 
                }
            }
        }
    }
    $global:checkRunningBool = $false
}

function check_for_error_consistency($line_clean, $ID, $errors, $delay_for_exiting, $logpath){
    Start-Sleep -Seconds $delay_for_exiting
    $pfad_logs = $logpath+"\*_" + $ID + ".log"
    $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
    $line_clean_now = $lastLineFromFile.Substring(25) -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
    if ($errors -contains $line_clean_now) {
        Stop-Process -Id $ID -Force
    }
}

function check_every_output_of_jobs(){
    Get-Job -State Completed | ForEach-Object {
        Receive-Job -Job $_ -Wait -AutoRemoveJob *> $null
    }
}

function vibWantsMeToForceARestartEveryXMinutes(){
    Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
        $job = Get-Job -Name ($_.ID.ToString() + "_stuck") -ErrorAction SilentlyContinue 
        if ($null -eq $job) {
            $pfad_logs = $logpath+"\*_" + $_.ID + ".log"
            if (Test-Path $pfad_logs) {
                $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
                Start-Job -ScriptBlock $Function:checkForStuckServer -Name ($_.ID.ToString() + "_stuck") -ArgumentList $lastLineFromFile, $_.ID, $delayForKillingIfStuck, $logpath 
            }
        }
    }
    $global:checkStuckBool = $false
}

function checkForStuckServer($lineToCheck, $ID, $delayForKillingIfStuck, $logpath){
    $startTimeOfJob = (Get-Uptime).TotalSeconds
    $pfad_logs = $logpath+"\*_" + $ID + ".log"
    while($true){
        if (((Get-Uptime).TotalSeconds) -gt ($startTimeOfJob + ($delayForKillingIfStuck * 60))){
            Stop-Process -Id $ID -Force
            break
        }
        $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
        if ($lineToCheck -ne $lastLineFromFile) { break }
        Start-Sleep -Seconds 5
    }
}

#############################################################
# TRAY UI SETUP, DON'T TOUCH THIS
#############################################################

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Write-Host "Server monitor is running; see system tray for details."

# Automatically hide the starting console
$showWindowAsync = Add-Type -MemberDefinition @"
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
"@ -Name "Win32ShowWindowAsync" -Namespace Win32Functions -PassThru
$showWindowAsync::ShowWindowAsync((Get-Process -Id $PID).MainWindowHandle, 0) | Out-Null

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
# Attempt to use the Echo icon, fallback to a system icon if path is invalid
try { $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($global:path) }
catch { $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application }

$notifyIcon.Text = "Echo VR Monitor"
$notifyIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$notifyIcon.ContextMenuStrip = $contextMenu

function Update-TrayMenu {
    $contextMenu.Items.Clear()
    $header = $contextMenu.Items.Add("Echo VR Status ($amountOfInstances instances)")
    $header.Enabled = $false
    [void]$contextMenu.Items.Add("-")

    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($processes) {
        foreach ($proc in $processes) {
            $uptime = (Get-Date) - $proc.StartTime
            $uptimeStr = "{0:d2}h {1:d2}m {2:d2}s" -f [int]$uptime.TotalHours, $uptime.Minutes, $uptime.Seconds
            [void]$contextMenu.Items.Add("PID: $($proc.Id) | Up: $uptimeStr")
        }
    } else {
        [void]$contextMenu.Items.Add("Checking servers...")
    }

    [void]$contextMenu.Items.Add("-")
    
    # NEW: Open Logs Folder
    $logItem = $contextMenu.Items.Add("Open Logs Folder")
    $logItem.Add_Click({
        explorer.exe $global:logpath
    })

    $exitItem = $contextMenu.Items.Add("Exit Monitor")
    $exitItem.Add_Click({
        $notifyIcon.Visible = $false
        Stop-Process -Id $PID
    })
}

# --- Main Runtime ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = ($global:delay_for_process_checking * 1000)
$timer.Add_Tick({
    check_for_amount_instances $amountOfInstances $path $processName $flags
    check_every_output_of_jobs
    Update-TrayMenu
})

$timer.Start() | Out-Null

$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = "Minimized"
[System.Windows.Forms.Application]::Run($form) | Out-Null

#21.11.2023 added:
#[TCP CLIENT] [R14NETCLIENT] connection to ws:///login?auth failed
#[TCP CLIENT] [R14NETCLIENT] connection to ws:///login?auth established
#[NETGAME] Service status request failed: 404 Not Found
#22.11.2023 
#the $flags variable is now in "THINGS YOU CAN BUT DONT NEED SET UP!!!"
#added an $region vaiable in THINGS YOU HAVE TO SET UP!!!
#the $flags variable now has the $region variable in it
#27.11.2023
#changed some thing on the while loop and tasks to get the script to be a lot less performance hungry
#01.12.2023
#changed to Powershell 7 to be able to use the -Tail Command on Get-Content. Should better the performance
#Powershell 7 will now be installed automatically
#If this script runs in Powershell 5, it will rerun itself in Powershell 7
#06.12.2023
#Added a function to disable the Edit Mode for the CLI that can be activated or deactivated by $true or $false
#15.12.2023
#Fixed a bug where processes couldnt be killed.
#Cleaned up a lot of the code and removed some "now" unnecessary functions as i improved parts of the code.
#The Script will now also check errors on echovr processes that were started before the script was started
#Old logfiles will now be moved into $logpath\old
#28.12.2023
#changed some parts of the RegEx Checks.
#07.04.2024
#Recreated the install_winget as Microsoft broke it!
#Implemented new errors
#added the possibility to add the amount of needed server instances behind the script like "pswhEcho-VR-Server-Error-Monitoring.ps1 5"
#08.04.2024
#added a function to check for stuck servers
#26.01.2026
#moved all user-facing outputs to the system tray menu (berg)
#30.01.2026
#removed $region stuff as it wasn't being used anywhere
