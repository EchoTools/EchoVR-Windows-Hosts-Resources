###################################################################
#Code by marshmallow_mia
#Checks for errors and restarts the server. Also checks for the right amount of servers running.
#Do what you want with it, but I dont take any responsibility
#Please contact me if you found bugs or for feature requests
#Sorry for weird german variable names at some points
#Echo <3
###################################################################
#CHANGELOG IS NOW AT THE END OF THE FILE



#######THINGS YOU HAVE TO SET UP!!!#######
$processName = "echovr" #without .exe, this is the name of the echovr.exe (in most cases its just echovr)

$amountOfInstances = 2 #number of instances you want to run (If you give this script an Input behind it, this will be overwritten! So like "Echo-VR-Server-Error-Monitoring.ps1 5" )

$global:filepath = "C:\Users\Administrator\Desktop\ready-at-dawn-echo-arena" #the path to your echo-folder (No \ at the end!!!)

$region = "euw";

#Please use one of the following region codes after in $region
#  "uscn", // US Central North (Chicago)
#  "us-central-2", // US Central South (Texas)
#  "us-central-3", // US Central South (Texas)
#  "use", // US East (Virgina)
#  "usw", // US West (California)
#  "euw", // EU West 
#  "jp", // Japan (idk)
#  "sin", // Singapore oce region

#SET THIS TO 0 TO DISABLE THE AUTO RESTART OF THE SERVER AFTER X MINUTES. ITS NEEDED AS SERVER CAN GET STUCK SOMETIMES
$global:delayForKillingIfStuck = 20 #minutes after a server that doesnt change its state will be killed as it could be stuck



if ( $args[0] )
{
    $amountOfInstances = $args[0]
}



#######THINGS YOU CAN BUT DONT NEED SET UP!!!#######
#This are all known errors. If you add one, you might need to change the "check_for_errors" function
$global:errors = "Unable to find MiniDumpWriteDump", "[NETGAME] Service status request failed: 400 Bad Request", "[NETGAME] Service status request failed: 404 Not Found", "[TCP CLIENT] [R14NETCLIENT] connection to ws:///login", "[TCP CLIENT] [R14NETCLIENT] connection to failed", `
 "[TCP CLIENT] [R14NETCLIENT] connection to established", "[TCP CLIENT] [R14NETCLIENT] connection to restored", "[TCP CLIENT] [R14NETCLIENT] connection to closed", "[TCP CLIENT] [R14NETCLIENT] Lost connection (okay) to peer", "[NETGAME] Service status request failed: 502 Bad Gateway", `
 "[NETGAME] Service status request failed: 0 Unknown"
$global:delay_for_exiting = 30 #seconds, this timer sets the time for the second error check.
$global:delay_for_process_checking = 3 #seconds Delay between each process check
$global:verbose = $false # If set to true, the Jobs/Tasks Output will be visible
$global:showPids = $false# If set to true, the PIDs will be shown
$flags =  "-numtaskthreads 2 -server -headless -noovr -fixedtimestep -nosymbollookup -timestep 120" # Flags/Parameters
$disableEditMode = $true #if true the edit mode inside the CLI will be deactivated, if $false it will be activated again (As the script will pause if you press on it when the EditMode is activated, you should use $true here)



#DONT CHANGE OR I WILL VISIT YOU AT NIGHT!!!!
$global:startedTime = ((get-date) - (gcim Win32_OperatingSystem).LastBootUpTime | Select TotalSeconds).TotalSeconds
$global:path = "$filepath\bin\win10\$processName.exe" #Path of your echovr.exe
$global:logpath = "$filepath\_local\r14logs"
$global:checkRunningBool = $false # is set to true if the check_for_errors function is running
$global:checkStuckBool = $false # is set to true if the vibWantsMeToForceARestartEveryXMinutes function is running
$global:loop = $true# will stay on false if Powershell 7 isnt standard or not installed at all
$global:PSversion = $PSVersionTable.PSVersion.Major




#############################################################
#This functions checks if enough instances are running. If not it will open enough and starts the error check for the processes
function check_for_amount_instances($amount, $path, $processName, $flags){
    $echovrProcesses = Get-Process -Name $processName 
    # If there are less than $amount echovr.exe processes running, start a new one
    #if not enough start, else check for errors
    if ($echovrProcesses.Count -lt $amountOfInstances) {
        while ($echovrProcesses.Count -lt $amountOfInstances) {
            # create the \old folder
            New-Item -Path $logpath"\old" -ItemType Directory *> $null
            #move old logfiles
            Move-Item -Path $logpath"\*.log" -Destination $logpath"\old\" *> $null
            #start the processes
            Start-Process -FilePath  $path  $flags -PassThru *> $null
            $echovrProcesses = Get-Process -Name $processName
            
        }
        #make sure the logs have been created
        sleep 3
    }
    else
    {
            #if enough instances are running, check for error
            if ($checkRunningBool -eq $false)
            {
                $global:checkRunningBool = $true
                check_for_errors
            }

            if ( $delayForKillingIfStuck -ne 0){
                if ($checkStuckBool -eq $false)
                {
                    $global:checkStuckBool = $true
                    vibWantsMeToForceARestartEveryXMinutes
                }  
            }
    }
}



#This function checks the logs for errors specified in the $errors array
function check_for_errors(){
    #loop through every running echo PID
    Get-Process -Name $processName | ForEach-Object {
        #check if the PID already is in check by a running job
        $job = Get-Job -Name $_.ID -ErrorAction SilentlyContinue 
        if ( $job -eq $null ) {
            $pfad_logs = $logpath+"\*_" + $_.ID + ".log" #the path of the specified logfile
            $lastLineFromFile =  Get-Content -Path $pfad_logs -Tail 1
                # delete the first X charachters (the datetime) and delete IP:Port, will probably need to remove more for new found errors
                $line_clean = $lastLineFromFile.Substring(25) -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
                #if one of the errors in our "error" array contains the content of the last logged line   
                if ( $errors -contains $line_clean ){
                    #echo $error" = "$line_clean
                    #start a new task for the check if the error will stay. That way the loop doesnt need to interrupt like with sleep
                    Start-Job -ScriptBlock $Function:check_for_error_consistency -Name $_.ID -ArgumentList $line_clean, $_.ID, $errors, $delay_for_exiting, $logpath 
                }
                
  
        }
    }
    $global:checkRunningBool = $false
}




#function to check if the specified error is still present after $errorDelayCheckTime
function check_for_error_consistency($line_clean, $ID, $errors, $delay_for_exiting, $logpath){
    $errorindex = -1 #probably not needed to set here, but to get sure i set out outside the for below
    Start-Sleep -Seconds $delay_for_exiting
    #get the index of the specified error, to check if we got the same error and not just an random error from the array
    $check = $true
    for ($a = 0; $check -eq $true; $a++){
        # if the index content is the previous error, save the indexno and stop the for loop
        if ($errors[$a] -contains $line_clean){
            $errorindex = $a
            $check = $false
        }
        #if this happens, i am stupid D: (Okay, I am also if it doesnt...)
        if ( $a -gt $errors.count ){
            Write-Host "Unknown Problem in check_for_error_consistency. Contact marcel_One_"
            break;
        }
    
    }
    $pfad_logs = $logpath+"\*_" + $ID + ".log" #the path of the specified logfile
    $lastLineFromFile =  Get-Content -Path $pfad_logs -Tail 1
    #delete the first X charachters (the datetime) and delete IP:Port, will probably need to remove more for new found errors
    $line_clean = $lastLineFromFile.Substring(25) -replace "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*", "" -replace "ws://.* ", "" -replace " ws://.*api_key=.*",""  -replace "\?auth=.*", ""
    #if one of the errors in out error array contains the content of the last logged line kill the process, else add the PID back as an output
    if ( $errors[$errorindex] -contains $line_clean ){
        taskkill /F /PID $ID
    }
    else{
        Write-Output "addPID.$ID"
    }
        
}


#function to check the output, echo the output and react on the dependent output if needed
function check_every_output_of_jobs(){
    $IDofJobs = Get-Job -State Completed | Where-Object -Property HasMoreData -eq $true | Select Id
    foreach ($job in $IDofJobs){     
        $result = Receive-Job -Id $job.Id -Wait -AutoRemoveJob
        #If verbose is active output everything from the jobs
        if ($verbose -eq $true){
            echo $result 
        }
    }
}



#This function starts a job to check if the server is stuck with the same notification for X Minutes
function vibWantsMeToForceARestartEveryXMinutes(){
    #loop through every running echo PID
    #Start the Job for each running process, if no is running already
    Get-Process -Name $processName | ForEach-Object {
        #check if the PID already is in check by a running job
        $job = Get-Job -Name ($_.ID.ToString() + "_stuck") -ErrorAction SilentlyContinue 
        if ( $job -eq $null ) {
            $pfad_logs = $logpath+"\*_" + $_.ID + ".log" #the path of the specified logfile
            
            $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
            #start a new task for the check for X min if there is no change and the server got stuck. It kills the process, if it is ruck
            Start-Job -ScriptBlock $Function:checkForStuckServer -Name ($_.ID.ToString() + "_stuck") -ArgumentList $lastLineFromFile, $_.ID, $delayForKillingIfStuck, $logpath 
        }
    }
    $global:checkStuckBool = $false
}



#This function checks if the server is stuck with the same notification for X Minutes
function checkForStuckServer($lineToCheck, $ID, $delayForKillingIfStuck, $logpath){
    $startTimeOfJob = (Get-Uptime).TotalSeconds

    $pfad_logs = $logpath+"\*_" + $ID + ".log" #the path of the specified logfile
    $stillChecking = $true
    
    while($stillChecking -eq $true){
        if( $((Get-Uptime).TotalSeconds) -gt $($startTimeOfJob+($delayForKillingIfStuck*60))){
            taskkill /F /PID $ID
            $stillChecking = $false
        }
      
        $lastLineFromFile = Get-Content -Path $pfad_logs -Tail 1
        echo $lineToCheck
        echo $lastLineFromFile
        if ( $lineToCheck -ne $lastLineFromFile ){
            $stillChecking = $false
        }
        Start-Sleep -Seconds 2
    }


}




function install_winget(){
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main" -Name "DisableFirstRunCustomize" -Value 2
    $Uri = 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/'
    $Results = Invoke-WebRequest -Method Get -Uri $Uri -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing
    Invoke-WebRequest -Uri $Results.Headers.Location -OutFile ~\Microsoft.UI.Xaml.zip -UseBasicParsing
    Expand-Archive -Path  ~\Microsoft.UI.Xaml.zip -DestinationPath '~\microsoft.ui.xaml' -Force
    Add-AppxPackage -Path "~\microsoft.ui.xaml\tools\AppX\x64\Release\Microsoft.UI.Xaml*.appx"
    Invoke-WebRequest -Uri "https://download.microsoft.com/download/4/7/c/47c6134b-d61f-4024-83bd-b9c9ea951c25/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile ~\Microsoft.VCLibs.140.00.appx -UseBasicParsing
    Add-AppxPackage ~\Microsoft.VCLibs.140.00.appx


    # get latest download url
    $URL = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    $URL = (Invoke-WebRequest -Uri $URL -UseBasicParsing ).Content | ConvertFrom-Json |
            Select-Object -ExpandProperty "assets" |
            Where-Object "browser_download_url" -Match '.msixbundle' |
            Select-Object -ExpandProperty "browser_download_url"

    # download
    Invoke-WebRequest -Uri $URL -OutFile "Setup.msix" -UseBasicParsing
    Invoke-WebRequest -Uri https://github.com/microsoft/winget-cli/releases/download/v1.7.3172-preview/34f5f38e82aa4e7ab15e617c6974e40e_License1.xml -Outfile .\34f5f38e82aa4e7ab15e617c6974e40e_License1.xml -UseBasicParsing

    # install
    Add-AppxPackage -Path "Setup.msix"
    Add-AppxProvisionedPackage -Online -PackagePath Setup.msix -LicensePath .\34f5f38e82aa4e7ab15e617c6974e40e_License1.xml -Verbose

    # delete file
    Remove-Item "Setup.msix"

}






function install_powershell7(){
    echo "Powershell 7 is not installed. We will install it and its dependencys in 5 seconds."
    echo  "Please make sure to run this script with Administartor right, if it closes without installing"
    sleep 5
    install_winget
    winget install --id Microsoft.Powershell --source winget 
    echo "done"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") 
}

pwsh --version
function check_ps7_install_state(){
    $Error.Clear()
    try {$null = pwsh --version}
    catch {
        install_powershell7
    }
}


function check_ps_version(){
    if ($host.Version.Major -ne 7)
    {
        start pwsh $PSCommandPath  
        exit       
    }
}

#If activated this function disables the Edit Mode, so the Script will not be interrupted with an left mouseclick (It is stupid, thats it is activated at all.) If you want to pause for some reason, press the pause button
function deactivateEditMode() {
    $Value
   if ($disableEditMode -eq $true){
        $Value = '0'
   }
   else{
        $Value = '1'
   }
   
        # Set variables to indicate value and key to set
        $RegistryPath = 'HKCU:\Console\C:_Program Files_PowerShell_7_pwsh.exe'
        $Name         = 'QuickEdit'
        # Create the key if it does not exist
        if ( get-itempropertyvalue -path $RegistryPath -name $Name *> $null ){
            Set-ItemProperty -Path $RegistryPath -Type DWord -Name $Name -Value $Value
        }else{
            New-Item $RegistryPath -Force | New-ItemProperty -Type DWord -Name $Name -Value $Value -Force | Out-Null *> $null
        }
}


deactivateEditMode
check_ps7_install_state
check_ps_version
echo $flags
while ($loop -eq $true) {
        check_for_amount_instances $amountOfInstances $path $processName $flags
        check_every_output_of_jobs
        if ($showPids -eq $true){        
            echo $PIDS
        }
sleep $delay_for_process_checking
    
} 


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


