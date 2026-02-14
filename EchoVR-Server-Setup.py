import tkinter as tk
from tkinter import messagebox, filedialog
import json
import os
import sys
import subprocess
import urllib.request
import zipfile
import shutil
import hashlib
import threading
import re

# Filepaths
ROOT_DIR = os.getcwd() 
DASHBOARD_DIR = os.path.join(ROOT_DIR, "dashboard")
SETUP_JSON = os.path.join(DASHBOARD_DIR, "setup.json")
BIN_DIR = os.path.join(ROOT_DIR, "bin", "win10")
CONFIG_LOCAL = os.path.join(ROOT_DIR, "_local", "config.json")
NETCONFIG_PATH = os.path.join(ROOT_DIR, "sourcedb", "rad15", "json", "r14", "config", "netconfig_dedicatedserver.json")

# URLs
newHostFilesURL = "https://github.com/user-attachments/files/25172342/newhostfiles.zip"
GITHUB_API_LATEST = f"https://api.github.com/repos/EchoTools/EchoVR-Windows-Hosts-Resources/releases/latest"

# Monitor Filenames
MONITOR_EXE = "EchoVR-Server-Monitor.exe"
MONITOR_SCRIPT = "EchoVR-Server-Monitor.ps1"

# MD5 Hashes
HASH_DBGCORE = "fc75604280599d92576c75476a9ae894"
HASH_PNSRAD = "707610f329b239651a994b35b139dc22"

class EchoServerConfig(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("EchoVR Server Setup Tool")
        self.geometry("450x700") 
        
        # State variables
        self.setup_data = {}
        self.is_cgnat = False 
        
        self.patch_thread = None
        self.patch_status_text = "Patch Server"

        # Initialization check
        if not os.path.exists(os.path.join(BIN_DIR, "echovr.exe")):
            messagebox.showerror("Error", "Place this program in the ready-at-dawn-echo-arena folder.")
            self.destroy()
            sys.exit()

        self.ensure_setup_exists()
        self.load_setup()
        
        # Run startup checks
        self.startup_checks()
        
        self.build_main_menu()

    def ensure_setup_exists(self):
        if not os.path.exists(DASHBOARD_DIR):
            os.makedirs(DASHBOARD_DIR)
            
        if not os.path.exists(SETUP_JSON):
            default_data = {
                "filePath": ROOT_DIR, 
                "isPatched": False,   
                "isConfigured": False, 
                "checkCGNAT": "Fail",  
                "numInstances": "",    
                "upperPortRange": 6792,
                "chklst_privateNet": False,
                "chklst_staticIP": False,
                "chklst_portFwd": False,
                "chklst_usedNewConfig": False,
                "chklst_hasMonitorScript": False
            }
            with open(SETUP_JSON, 'w') as f:
                json.dump(default_data, f, indent=4)

    def load_setup(self):
        with open(SETUP_JSON, 'r') as f:
            self.setup_data = json.load(f)

    def save_setup(self):
        with open(SETUP_JSON, 'w') as f:
            json.dump(self.setup_data, f, indent=4)

    def startup_checks(self):
        if self.setup_data["filePath"] != ROOT_DIR:
            self.setup_data["filePath"] = ROOT_DIR
            self.save_setup()

        # Check: Auto-detect Monitor Script OR Exe on Startup
        path_exe = os.path.join(ROOT_DIR, MONITOR_EXE)
        path_ps1 = os.path.join(ROOT_DIR, MONITOR_SCRIPT)
        
        if os.path.exists(path_exe) or os.path.exists(path_ps1):
            if not self.setup_data.get("chklst_hasMonitorScript", False):
                self.setup_data["chklst_hasMonitorScript"] = True
                self.save_setup()

        if not self.setup_data["isPatched"]:
            self.check_patch_status()

        if self.setup_data.get("checkCGNAT") in ["Fail", ""]:
            threading.Thread(target=self.run_cgnat_check, daemon=True).start()
        else:
             self.is_cgnat = (self.setup_data["checkCGNAT"] == "Pass") 

    def run_cgnat_check(self):
        try:
            wan_ip = urllib.request.urlopen('https://api.ipify.org', timeout=3).read().decode('utf8')
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            
            output = subprocess.check_output(f"tracert -d -h 5 {wan_ip}", 
                                             startupinfo=startupinfo, 
                                             shell=True).decode()
            
            hops = re.findall(r'^\s*(\d+)\s+', output, re.MULTILINE)
            
            if hops:
                hop_count = int(hops[-1])
                if hop_count > 1:
                    self.setup_data["checkCGNAT"] = "Fail"
                else:
                    self.setup_data["checkCGNAT"] = "Pass"
            else:
                self.setup_data["checkCGNAT"] = "Fail"

            self.save_setup()
            
        except Exception:
            self.setup_data["checkCGNAT"] = "Fail"
            self.save_setup()

    def check_patch_status(self):
        path_dbg = os.path.join(BIN_DIR, "dbgcore.dll")
        path_pns = os.path.join(BIN_DIR, "pnsradgameserver.dll")
        path_gun = os.path.join(ROOT_DIR, "combatGunPatchFiles")

        is_patched = True
        
        if not os.path.exists(path_gun):
            is_patched = False
        else:
            if not self.verify_hash(path_dbg, HASH_DBGCORE) or \
               not self.verify_hash(path_pns, HASH_PNSRAD):
                is_patched = False
        
        self.setup_data["isPatched"] = is_patched
        self.save_setup()
        return is_patched

    def verify_hash(self, filepath, expected_hash):
        if not os.path.exists(filepath): return False
        with open(filepath, "rb") as f:
            file_hash = hashlib.md5(f.read()).hexdigest()
        return file_hash == expected_hash

    # --- GUI Construction ---

    def clear_window(self):
        for widget in self.winfo_children():
            widget.destroy()

    def build_main_menu(self):
        self.clear_window()
        
        main_frame = tk.Frame(self, padx=20, pady=20)
        main_frame.pack(fill="both", expand=True)

        # Buttons
        self.btn_patch = tk.Button(main_frame, text="Patch Server", command=self.action_patch_server, font=("Arial", 12), width=20)
        self.btn_patch.pack(pady=10)
        self.update_patch_button() 

        config_text = "Config Ready" if self.setup_data["isConfigured"] else "Configure Server"
        config_fg = "green" if self.setup_data["isConfigured"] else "black"
        
        self.btn_config = tk.Button(main_frame, text=config_text, fg=config_fg, command=self.action_configure_server, font=("Arial", 12), width=20)
        self.btn_config.pack(pady=10)

        # Checklist Area
        self.checklist_frame = tk.LabelFrame(main_frame, text="Setup Checklist", padx=10, pady=10)
        self.refresh_checklist() 

        # "Ready to Launch" Message
        checklist_keys = ["chklst_privateNet", "chklst_staticIP", "chklst_portFwd", "chklst_usedNewConfig", "chklst_hasMonitorScript"]
        all_checklist_complete = all(self.setup_data.get(k, False) for k in checklist_keys)

        if self.setup_data["isConfigured"] and self.setup_data["isPatched"] and all_checklist_complete:
            
            lbl_ready = tk.Label(main_frame, text="Ready to Launch", font=("Arial", 16, "bold"), fg="green")
            lbl_ready.pack(pady=(20, 5))
            
            # Launch Button
            btn_launch = tk.Button(main_frame, text="Launch Server Monitor", 
                                   command=self.action_launch_monitor, 
                                   bg="green", fg="white", font=("Arial", 12))
            btn_launch.pack(pady=5)

            lbl_instruct = tk.Label(main_frame, text="This will close the setup tool.", font=("Arial", 8), fg="gray")
            lbl_instruct.pack(pady=0)

    def update_patch_button(self):
        if self.patch_thread and self.patch_thread.is_alive():
            self.btn_patch.config(text=self.patch_status_text, state="disabled")
            return

        if self.setup_data["isPatched"]:
            self.btn_patch.config(text="Server Patched", fg="green", state="normal")
        else:
            self.btn_patch.config(text="Patch Server", fg="black", state="normal")

    def refresh_checklist(self):
        checklist_items = {
            "chklst_privateNet": "1. Set Network Profile to Private",
            "chklst_staticIP": "2. Create a Static LAN IP for This Machine",
            "chklst_portFwd": f"3. Forward Ports 6792-{self.setup_data.get('upperPortRange', 6792)} to This Machine (TCP + UDP)",
            "chklst_usedNewConfig": "4. Log In with New Client Config",
            "chklst_hasMonitorScript": "5. Download Server Monitoring Script"
        }

        all_complete = all(self.setup_data.get(k, False) for k in checklist_items)
        if all_complete:
            self.checklist_frame.pack_forget()
            return

        self.checklist_frame.pack(fill="x", pady=20)
        for widget in self.checklist_frame.winfo_children():
            widget.destroy()

        for key, label_text in checklist_items.items():
            if not self.setup_data.get(key, False):
                row = tk.Frame(self.checklist_frame)
                row.pack(fill="x", pady=2)
                lbl = tk.Label(row, text=label_text, anchor="w")
                lbl.pack(side="left", fill="x", expand=True)
                
                state = "normal"
                
                if key == "chklst_portFwd" and not self.setup_data["isConfigured"]:
                    state = "disabled"
                
                if key == "chklst_usedNewConfig" and not self.setup_data["isConfigured"]:
                    state = "disabled"
                
                # Monitor script: Split Download buttons
                if key == "chklst_hasMonitorScript":
                    btn_dl_frame = tk.Frame(row)
                    btn_dl_frame.pack(side="right")
                    
                    tk.Button(btn_dl_frame, text="Download .exe", 
                             command=lambda: self.download_monitor_file(MONITOR_EXE)).pack(side="left", padx=2)
                    
                    tk.Button(btn_dl_frame, text="Download .ps1", 
                             command=lambda: self.download_monitor_file(MONITOR_SCRIPT)).pack(side="left", padx=2)
                else:
                    btn = tk.Button(row, text="Done", state=state, command=lambda k=key: self.complete_checklist_item(k))
                    btn.pack(side="right")

                # --- Checklist Notes ---
                if key == "chklst_privateNet":
                    note_lbl = tk.Label(self.checklist_frame, text="Settings > Network & Internet > Properties > Private Network",
                                        font=("Arial", 8), fg="gray", anchor="w")
                    note_lbl.pack(fill="x", padx=20)

                if key == "chklst_staticIP":
                    note_lbl = tk.Label(self.checklist_frame, text="e.g., 192.168.1.100. Reconnect before continuing.",
                                        font=("Arial", 8), fg="gray", anchor="w")
                    note_lbl.pack(fill="x", padx=20)
                
                if key == "chklst_portFwd":
                    note_lbl = tk.Label(self.checklist_frame, text="Complete your server configuration first.",
                                        font=("Arial", 8), fg="gray", anchor="w")
                    note_lbl.pack(fill="x", padx=20)

                if key == "chklst_usedNewConfig":
                    note_lbl = tk.Label(self.checklist_frame, text="Do not do this on your server machine.\nGet your new file in Config > Generate Client Config.",
                                        font=("Arial", 8), fg="gray", anchor="w")
                    note_lbl.pack(fill="x", padx=20)
                
                if key == "chklst_hasMonitorScript":
                    note_lbl = tk.Label(self.checklist_frame, text="Downloads the Server Monitor to your echo folder.",
                                        font=("Arial", 8), fg="gray", anchor="w")
                    note_lbl.pack(fill="x", padx=20)

    def complete_checklist_item(self, key):
        self.setup_data[key] = True
        self.save_setup()
        self.refresh_checklist()
        self.build_main_menu() 

    # --- Actions ---
    
    def download_monitor_file(self, filename):
            try:
                target_path = os.path.join(ROOT_DIR, filename)
                
                # 1. Get the latest release info from GitHub API
                print(f"Checking for updates at: {GITHUB_API_LATEST}")
                with urllib.request.urlopen(GITHUB_API_LATEST, timeout=5) as response:
                    data = json.loads(response.read().decode())
                    
                # 2. Find the asset with the correct name
                download_url = None
                for asset in data.get("assets", []):
                    # We look for the asset that matches the requested filename
                    if asset["name"].lower() == filename.lower():
                        download_url = asset["browser_download_url"]
                        break
                
                if not download_url:
                    messagebox.showerror("Error", f"Could not find '{filename}' in the latest GitHub release.")
                    return

                # 3. Download the file
                opener = urllib.request.build_opener()
                opener.addheaders = [('User-agent', 'Mozilla/5.0')]
                urllib.request.install_opener(opener)
                
                urllib.request.urlretrieve(download_url, target_path)
                
                if os.path.exists(target_path):
                    messagebox.showinfo("Success", f"Downloaded {filename} successfully!")
                    self.setup_data["chklst_hasMonitorScript"] = True
                    self.save_setup()
                    self.refresh_checklist()
                    self.build_main_menu()
                else:
                    messagebox.showerror("Error", "Download appeared to finish but file is missing.")
                    
            except urllib.error.HTTPError as e:
                messagebox.showerror("GitHub API Error", f"Failed to check GitHub: {e.code} {e.reason}")
            except Exception as e:
                messagebox.showerror("Download Error", str(e))

    def action_launch_monitor(self):
        path_exe = os.path.join(ROOT_DIR, MONITOR_EXE)
        path_ps1 = os.path.join(ROOT_DIR, MONITOR_SCRIPT)

        # Prioritize EXE if both exist, otherwise check PS1
        if os.path.exists(path_exe):
            try:
                os.startfile(path_exe)
                self.destroy() # Close Setup Tool
            except Exception as e:
                messagebox.showerror("Error", f"Could not launch .exe monitor: {e}")

        elif os.path.exists(path_ps1):
            try:
                # Create the batch file to launch PS1 hidden
                bat_filename = "Launch-Monitor.bat"
                bat_path = os.path.join(ROOT_DIR, bat_filename)
                
                # Use the exact command string requested, referencing the script variable
                # Note: We assume the script name on disk (MONITOR_SCRIPT) is the one we want to run
                cmd_content = f"start /min pwsh -windowstyle hidden -file {MONITOR_SCRIPT}"
                
                with open(bat_path, "w") as f:
                    f.write(cmd_content)
                
                # Run the batch file
                os.startfile(bat_path)
                self.destroy() # Close Setup Tool
            except Exception as e:
                messagebox.showerror("Error", f"Could not launch .ps1 monitor: {e}")
        else:
            messagebox.showerror("Error", "Monitor executable or script not found.")

    def action_patch_server(self):
        # Disable button and start thread
        self.btn_patch.config(state="disabled")
        self.patch_thread = threading.Thread(target=self.run_patch_sequence, daemon=True)
        self.patch_thread.start()

    def run_patch_sequence(self):
        """Replicates patch.bat logic in Python with progress updates."""
        try:
            # Step 1: Download files (simulated in progress)
            self.update_btn_text("Downloading...")
            
            url = newHostFilesURL
            temp_dir = os.path.join(DASHBOARD_DIR, "temp")
            if not os.path.exists(temp_dir): os.makedirs(temp_dir)
            zip_path = os.path.join(temp_dir, "newhostfiles.zip")
            
            urllib.request.urlretrieve(url, zip_path)
            
            self.update_btn_text("Extracting...")
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(temp_dir)
            
            shutil.copy(os.path.join(temp_dir, "dbgcore.dll"), BIN_DIR)
            shutil.copy(os.path.join(temp_dir, "pnsradgameserver.dll"), BIN_DIR)
            
            gunpatch_zip = os.path.join(temp_dir, "gunpatch.zip") 
            if os.path.exists(gunpatch_zip):
                 with zipfile.ZipFile(gunpatch_zip, 'r') as zip_ref:
                    zip_ref.extractall(ROOT_DIR)

            # Step 2: Native Patch Logic (replaces patch.bat)
            self.update_btn_text("Getting Ready...")
            
            # Paths mirroring the bat file
            data_dir = os.path.join(ROOT_DIR, "_data")
            rad_base = os.path.join(data_dir, "5932408047", "rad15")
            path_win10 = os.path.join(rad_base, "win10")
            path_orig = os.path.join(rad_base, "original_files")
            
            if os.path.exists(data_dir):
                # Backup Logic
                if not os.path.exists(path_orig):
                    if os.path.exists(path_win10):
                        os.rename(path_win10, path_orig)
                
                # Cleanup Win10
                self.update_btn_text("Getting Ready...")
                if os.path.exists(path_win10):
                    shutil.rmtree(path_win10)
                
                # Create Dirs
                self.update_btn_text("Getting Ready...")
                os.makedirs(os.path.join(path_win10, "packages"), exist_ok=True)
                os.makedirs(os.path.join(path_win10, "manifests"), exist_ok=True)
                
                # Copy Manifests/Packages
                self.update_btn_text("Copying Files...")
                src_manifest = os.path.join(path_orig, "manifests", "2b47aab238f60515")
                dst_manifest = os.path.join(path_win10, "manifests", "2b47aab238f60515")
                if os.path.exists(src_manifest):
                    if os.path.isdir(src_manifest): shutil.copytree(src_manifest, dst_manifest)
                    else: shutil.copy(src_manifest, dst_manifest)

                src_pkg = os.path.join(path_orig, "packages", "2b47aab238f60515_0")
                dst_pkg = os.path.join(path_win10, "packages", "2b47aab238f60515_0")
                if os.path.exists(src_pkg):
                     if os.path.isdir(src_pkg): shutil.copytree(src_pkg, dst_pkg)
                     else: shutil.copy(src_pkg, dst_pkg)

                # Execute Tool
                self.update_btn_text("Patching...")
                
                tool_path = os.path.join(ROOT_DIR, "evrFileTools.exe")
                # Arguments from bat: -mode replace -packageName ...
                args = [
                    tool_path,
                    "-mode", "replace",
                    "-packageName", "48037dc70b0ecab2",
                    "-dataDir", path_orig + "\\",   # Add trailing slash as per bat usage usually
                    "-inputDir", os.path.join(ROOT_DIR, "combatGunPatchFiles"),
                    "-outputDir", path_win10 + "\\",
                    "-ignoreOutputRestrictions"
                ]
                
                # Run invisible
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                subprocess.call(args, startupinfo=startupinfo)
                
            else:
                messagebox.showerror("Error", "Missing _data folder. Ensure you are in the correct directory.")

            self.update_btn_text("Cleaning Up...")
            
            # Final Check
            self.after(500, self.finish_patching) # Schedule the GUI update on main thread

            # Cleanup temp directory
            temp_dir = os.path.join(DASHBOARD_DIR, "temp")
            if os.path.exists(temp_dir):
                shutil.rmtree(temp_dir)
            
            # Cleanup patch tools
            if os.path.exists(os.path.join(ROOT_DIR, "patch.bat")):
                os.remove(os.path.join(ROOT_DIR, "patch.bat"))
    
            if os.path.exists(os.path.join(ROOT_DIR, "evrFileTools.exe")):
                os.remove(os.path.join(ROOT_DIR, "evrFileTools.exe"))
            
        except Exception as e:
            messagebox.showerror("Error", str(e))
            self.after(0, self.update_patch_button)

    def update_btn_text(self, text):
        self.patch_status_text = text

        def _update():
            if hasattr(self, 'btn_patch') and self.btn_patch.winfo_exists():
                self.btn_patch.config(text=text)
        
        self.after(0, _update)

    def finish_patching(self):
        is_success = self.check_patch_status()
        self.patch_thread = None 
        on_main_menu = hasattr(self, 'btn_patch') and self.btn_patch.winfo_exists()

        if is_success:
            messagebox.showinfo("Success", "Server Patched Successfully!")
            if on_main_menu:
                self.build_main_menu()
        else:
            messagebox.showerror("Failed", "Patch verification failed.")
            if on_main_menu:
                self.update_patch_button()

    def action_configure_server(self):
        self.clear_window()
        
        # Load existing
        existing_conf = {}
        discord_id = ""
        password = ""
        region_val = ""
        cgnat_val = ""
        args_val = ""
        
        if os.path.exists(CONFIG_LOCAL):
            with open(CONFIG_LOCAL, 'r') as f:
                try:
                    existing_conf = json.load(f)
                    serverdb_url = existing_conf.get("serverdb_host", "")
                    if "?" in serverdb_url:
                        _, query = serverdb_url.split("?", 1)
                        params = query.split("&")
                        remaining_params = []
                        for p in params:
                            if p.startswith("discordid="):
                                discord_id = p.split("=", 1)[1]
                            elif p.startswith("password="):
                                password = p.split("=", 1)[1]
                            elif p.startswith("regions="):
                                region_val = p.split("=", 1)[1]
                            elif p.startswith("serveraddr="):
                                cgnat_val = p.split("=", 1)[1]
                            else:
                                remaining_params.append(p)
                        if remaining_params:
                            args_val = "&" + "&".join(remaining_params)
                except: pass

        form_frame = tk.Frame(self, padx=20, pady=20)
        form_frame.pack(fill="both", expand=True)
        
        cgnat_status = self.setup_data.get("checkCGNAT", "Fail")
        if cgnat_status == "Pass":
            lbl_cgnat = tk.Label(form_frame, text="No CGNAT Detected!", fg="green", font=("Arial", 10, "bold"))
        else:
            lbl_cgnat = tk.Label(form_frame, text="CGNAT Detected. Use a tunnel service to host.", fg="red", font=("Arial", 10, "bold"))
        lbl_cgnat.pack(anchor="w", pady=(0, 10))

        tk.Label(form_frame, text="Discord User ID (Required)").pack(anchor="w")
        entry_discord = tk.Entry(form_frame, width=40)
        entry_discord.insert(0, discord_id)
        entry_discord.pack(anchor="w")
        tk.Label(form_frame, text="NOT your username. Get your user ID by right clicking your profile > Copy User ID.", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        tk.Label(form_frame, text="Password (Required)").pack(anchor="w")
        entry_pass = tk.Entry(form_frame, width=40)
        entry_pass.insert(0, password)
        entry_pass.pack(anchor="w")
        tk.Label(form_frame, text="Do not use a password you typically use.", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        tk.Label(form_frame, text="Region ID").pack(anchor="w")
        entry_region = tk.Entry(form_frame, width=40)
        entry_region.insert(0, region_val)
        entry_region.pack(anchor="w")
        tk.Label(form_frame, text="Leave blank unless otherwise instructed. Separate multiple IDs with commas.", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        tk.Label(form_frame, text="Tunnel IP:Port").pack(anchor="w")
        entry_cgnat = tk.Entry(form_frame, width=40)
        entry_cgnat.insert(0, cgnat_val)
        entry_cgnat.pack(anchor="w")
        tk.Label(form_frame, text="Required for hosts behind a CGNAT, optional otherwise.", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        tk.Label(form_frame, text="Additional Arguments").pack(anchor="w")
        entry_args = tk.Entry(form_frame, width=40)
        entry_args.insert(0, args_val)
        entry_args.pack(anchor="w")
        tk.Label(form_frame, text="Leave blank unless you know what you're doing!", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        tk.Label(form_frame, text="Number of Instances (Required)").pack(anchor="w")
        saved_instances = self.setup_data.get("numInstances", 0)
        if saved_instances == "": saved_instances = 0
        var_instances = tk.IntVar(value=int(saved_instances))
        spin_instances = tk.Spinbox(form_frame, from_=0, to=100, textvariable=var_instances)
        spin_instances.pack(anchor="w")
        tk.Label(form_frame, text="Will automatically update your monitoring script and netconfig.", font=("Arial", 8), fg="gray").pack(anchor="w", pady=(0, 5))

        btn_frame = tk.Frame(form_frame)
        btn_frame.pack(pady=20, fill="x")

        tk.Button(btn_frame, text="Open Config", command=lambda: os.startfile(CONFIG_LOCAL) if os.path.exists(CONFIG_LOCAL) else None).pack(fill="x")
        tk.Button(btn_frame, text="Open Netconfig", command=lambda: os.startfile(NETCONFIG_PATH) if os.path.exists(NETCONFIG_PATH) else None).pack(fill="x")
        
        def save_and_return(should_return=True):
            if not entry_discord.get() or not entry_pass.get() or var_instances.get() == 0:
                messagebox.showerror("Error", "Missing required fields.")
                return False

            did = entry_discord.get()
            pwd = entry_pass.get()
            base_serverdb = f"ws://g.echovrce.com:80/serverdb?discordid={did}&password={pwd}"
            if entry_region.get(): base_serverdb += f"&regions={entry_region.get()}"
            if entry_cgnat.get(): base_serverdb += f"&serveraddr={entry_cgnat.get()}"
            if entry_args.get(): base_serverdb += f"{entry_args.get()}"

            new_config = {
                "apiservice_host": "http://g.echovrce.com:80/api",
                "configservice_host": "ws://g.echovrce.com:80/config",
                "loginservice_host": f"ws://g.echovrce.com:80/login?discordid={did}&password={pwd}",
                "matchingservice_host": "ws://g.echovrce.com:80/matching",
                "serverdb_host": base_serverdb,
                "transactionservice_host": "ws://g.echovrce.com:80/transaction",
                "publisher_lock": "echovrce"
            }
            
            if not os.path.exists(os.path.dirname(CONFIG_LOCAL)): os.makedirs(os.path.dirname(CONFIG_LOCAL))
            with open(CONFIG_LOCAL, 'w') as f: json.dump(new_config, f, indent=4)

            if os.path.exists(NETCONFIG_PATH):
                try:
                    with open(NETCONFIG_PATH, 'r') as f: content = f.read()
                    content_fixed = re.sub(r',(\s*?[\]}])', r'\1', content)
                    net_data = json.loads(content_fixed)
                    net_data["broadcaster_init"]["retries"] = var_instances.get() + 1
                    with open(NETCONFIG_PATH, 'w') as f: json.dump(net_data, f, indent=4)
                except Exception as e:
                    messagebox.showerror("Netconfig Error", f"Could not update netconfig file: {e}")
                    return False

            # Check 1: Port Forward Reset Logic
            current_instances = self.setup_data.get("numInstances", 0)
            if current_instances == "": current_instances = 0
            current_instances = int(current_instances)

            if current_instances != var_instances.get():
                self.setup_data["chklst_portFwd"] = False 

            self.setup_data["numInstances"] = var_instances.get()
            self.setup_data["upperPortRange"] = 6792 + var_instances.get()
            self.setup_data["isConfigured"] = True
            self.save_setup()

            if should_return: self.build_main_menu()
            return True

        def generate_client():
            if not save_and_return(should_return=False): return
            desktop = os.path.join(os.path.join(os.environ['USERPROFILE']), 'Desktop')
            target = os.path.join(desktop, "config.json")
            with open(CONFIG_LOCAL, 'r') as f: data = json.load(f)
            did = entry_discord.get()
            pwd = entry_pass.get()
            data["serverdb_host"] = f"ws://g.echovrce.com:80/serverdb?discordid={did}&password={pwd}"
            with open(target, 'w') as f: json.dump(data, f, indent=4)
            messagebox.showinfo("Done", "Changes saved. New client config generated on Desktop.")
            self.build_main_menu()

        tk.Button(btn_frame, text="Generate Client Config", command=generate_client).pack(fill="x", pady=5)
        tk.Button(btn_frame, text="Save & Return", bg="green", fg="white", command=save_and_return).pack(side="left", expand=True, fill="x")
        tk.Button(btn_frame, text="Discard & Return", command=self.build_main_menu).pack(side="right", expand=True, fill="x")

if __name__ == "__main__":
    app = EchoServerConfig()
    app.mainloop()