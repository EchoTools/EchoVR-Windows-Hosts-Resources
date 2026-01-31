# Echo-VR-Server-Error-Monitoring

This script is made for checking of errors running on Echo VR Server Instances.
It will automatically handle crashes/errors and auto-restart when necessary.

Before you do anything, open the file and change the info as necessary in the `THINGS YOU HAVE TO SET UP` section.

> [!TIP]
> Before starting, allow script execution by running `Set-ExecutionPolicy Bypass` in an admin terminal.
> 
> The script will install Powershell 7 for you. Just right click > Run With Powershell to get started.

### Usage
You can quickly run the script by creating a batch file with the following line: `pwsh Echo-VR-Server-Error-Monitoring.ps1`

If you'd like to hide the terminal window, put this in your batch file isntead: `start /min pwsh -windowstyle hidden -file Echo-VR-Server-Error-Monitoring.ps1`

> [!NOTE]
> Unless you input the entire filepath in your batch file, it will need to be in the same directory as the .ps1 script.
>
> You should probably make a shortcut to the batch file and put it in the startup folder as well.

Right-click the system tray icon to open the menu.

<img width="453" height="272" alt="image" src="https://github.com/user-attachments/assets/afb38d84-77fd-497a-9af5-45ce336aa82d" />
