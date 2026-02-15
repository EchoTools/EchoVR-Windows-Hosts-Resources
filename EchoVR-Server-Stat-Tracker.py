# Made with <3 by berg_
# Can be used on its own, but will also integrate with the server monitor!

import customtkinter as ctk
import os
import sys
import glob
import re
import csv
import json
import threading
import requests
import subprocess
from datetime import datetime, timedelta
from matplotlib.figure import Figure
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
import tkinter.messagebox as msgbox
import matplotlib.gridspec as gridspec

# --- Configuration & Constants ---
CURRENT_VERSION = "2.1.1"
CTK_THEME = "dark-blue"
REPO_OWNER = "EchoTools"
REPO_NAME = "EchoVR-Windows-Hosts-Resources"
ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme(CTK_THEME)

# --- Path Handling for PyInstaller ---
# This block detects if we are running as a compiled exe or a script
IS_FROZEN = getattr(sys, 'frozen', False)

if IS_FROZEN:
    # If compiled, use the directory of the executable
    BASE_DIR = os.path.dirname(sys.executable)
    APP_FILE = sys.executable
    APP_EXT = ".exe"
else:
    # If running as a script, use the directory of the script file
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))
    APP_FILE = os.path.abspath(__file__)
    APP_EXT = ".py"

# Directory Paths
LOG_DIR = os.path.join(BASE_DIR, "_local", "r14logs")
LOG_DIR_OLD = os.path.join(LOG_DIR, "old")
STATS_DIR = os.path.join(BASE_DIR, "dashboard", "stats")
TEMP_DIR = os.path.join(BASE_DIR, "dashboard", "temp")
ECHO_EXE = os.path.join(BASE_DIR, "bin", "win10", "echovr.exe")

# File Paths
LEVELS_TXT = os.path.join(STATS_DIR, "levels.txt")
PLAYERS_TXT = os.path.join(STATS_DIR, "players.txt")
ERRORS_TXT = os.path.join(STATS_DIR, "errors.txt")
PROCESSED_LOGS_JSON = os.path.join(STATS_DIR, "processed_logs.json")

# Hex Mappings
LEVEL_MAP = {
    "0xD09AFD15B1C75C04": "Lobby",
    "0x576ED3F8428EBC4B": "Arena",
    "0xDF5CA7B7DFA383D4": "Fission",
    "0x43E2DA7A0C623A19": "Surge",
    "0x43E2DA7914642604": "Dyson",
    "0x42670F2BED45703C": "Combustion"
}

GAMETYPE_MAP = {
    "0x042D9CF9CFDDCF76": ("Public", "Lobby"),
    "0x305D6E37C1589C45": ("Private", "Lobby"),
    "0xCB60A4DE7E1CAF73": ("Public", "Arena"),
    "0x09990965F4DB8C03": ("Private", "Arena"),
    "0x3D5C3976578A321A": ("Public", "Combat"),
    "0x33BBF6842DF97A3F": ("Private", "Combat")
}

# Error Signatures
KNOWN_ERRORS = [
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
]

# Error Legend Aliases
ERROR_ALIASES = {
    "Unable to find MiniDumpWriteDump": "Unable to find MiniDumpWriteDump",
    "[NETGAME] Service status request failed: 400 Bad Request": "400 Bad Request [NETGAME]",
    "[NETGAME] Service status request failed: 404 Not Found": "404 Not Found [NETGAME]",
    "[TCP CLIENT] [R14NETCLIENT] connection to ws:///login": "R14 Login Connection Error [TCP]",
    "[TCP CLIENT] [R14NETCLIENT] connection to failed": "R14 Connection Failed [TCP]",
    "[TCP CLIENT] [R14NETCLIENT] connection to established": "R14 Connection Established [TCP]",
    "[TCP CLIENT] [R14NETCLIENT] connection to restored": "R14 Connection Restored [TCP]",
    "[TCP CLIENT] [R14NETCLIENT] connection to closed": "R14 Connection Closed [TCP]",
    "[TCP CLIENT] [R14NETCLIENT] Lost connection (okay) to peer": "R14 Lost Peer Connection [TCP]",
    "[NETGAME] Service status request failed: 502 Bad Gateway": "502 Bad Gateway [NETGAME]",
    "[NETGAME] Service status request failed: 0 Unknown": "0 Unknown [NETGAME]"
}

class StatTrackerApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        # --- Startup Checks ---
        if not os.path.exists(ECHO_EXE):
            # Detailed error message to help debug path issues
            msgbox.showerror(
                "Error", 
                f"Echo VR Executable not found.\n\nLooking in:\n{ECHO_EXE}\n\nPlease place this program in the root 'ready-at-dawn-echo-arena' folder."
            )
            sys.exit()

        if not os.path.exists(STATS_DIR):
            os.makedirs(STATS_DIR)
        
        # Ensure Temp dir exists for updates
        if not os.path.exists(TEMP_DIR):
            os.makedirs(TEMP_DIR)

        if not os.path.exists(PROCESSED_LOGS_JSON):
            with open(PROCESSED_LOGS_JSON, 'w') as f:
                json.dump([], f)

        # --- Window Setup ---
        self.title(f"EchoVR Server Stat Tracker v{CURRENT_VERSION}")
        self.geometry("1200x700")
        self.minsize(1200, 700)
        
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(0, weight=1)

        # --- Left Panel (Controls) ---
        self.sidebar_frame = ctk.CTkFrame(self, width=200, corner_radius=0)
        self.sidebar_frame.grid(row=0, column=0, sticky="nsew")
        self.sidebar_frame.grid_rowconfigure(8, weight=1) # Spacer row

        self.logo_label = ctk.CTkLabel(self.sidebar_frame, text="Server Stat Tracker", font=ctk.CTkFont(size=20, weight="bold"))
        self.logo_label.grid(row=0, column=0, padx=20, pady=(20, 10))

        # Button Label Logic (Initial)
        btn_text = "Import Log Data"
        if self.check_data_exists():
            btn_text = "Refresh Log Data"

        self.import_btn = ctk.CTkButton(self.sidebar_frame, text=btn_text, command=self.start_import_thread)
        self.import_btn.grid(row=1, column=0, padx=20, pady=10)

        self.export_btn = ctk.CTkButton(self.sidebar_frame, text="Export to .csv", command=self.export_csv)
        self.export_btn.grid(row=2, column=0, padx=20, pady=10)

        # Update Button
        self.update_btn = ctk.CTkButton(self.sidebar_frame, text="Check for Updates", command=self.start_update_check_thread, fg_color="#2B719E", hover_color="#1F5374")
        self.update_btn.grid(row=3, column=0, padx=20, pady=10)

        self.filter_label = ctk.CTkLabel(self.sidebar_frame, text="Range:", anchor="w")
        self.filter_label.grid(row=4, column=0, padx=20, pady=(20, 0))
        self.time_filter = ctk.CTkOptionMenu(self.sidebar_frame, values=["Last Hour", "Last 24h", "Last 30d", "All Time"], command=self.refresh_charts)
        self.time_filter.set("All Time")
        self.time_filter.grid(row=5, column=0, padx=20, pady=10)

        self.display_mode = ctk.CTkSwitch(self.sidebar_frame, text="Show Percentages", command=self.refresh_charts)
        self.display_mode.grid(row=6, column=0, padx=20, pady=10)

        # Status Area
        self.status_label = ctk.CTkLabel(self.sidebar_frame, text="Checking data...", font=ctk.CTkFont(size=12), text_color="gray")
        self.status_label.grid(row=7, column=0, padx=10, pady=(10, 0))

        # Bottom Section (Progress)
        self.progress_label = ctk.CTkLabel(self.sidebar_frame, text="", font=ctk.CTkFont(size=12))
        self.progress_label.grid(row=9, column=0, padx=20, pady=(0, 0))
        
        self.progress_bar = ctk.CTkProgressBar(self.sidebar_frame)
        self.progress_bar.grid(row=10, column=0, padx=20, pady=(5, 20))
        self.progress_bar.set(0)

        # --- Right Panel (Charts) ---
        self.charts_frame = ctk.CTkFrame(self)
        self.charts_frame.grid(row=0, column=1, padx=20, pady=20, sticky="nsew")
        self.charts_frame.grid_rowconfigure(1, weight=1)
        self.charts_frame.grid_columnconfigure(0, weight=1)
        
        # Top Stats Header
        self.stats_header = ctk.CTkFrame(self.charts_frame, fg_color="transparent")
        self.stats_header.grid(row=0, column=0, sticky="ew", pady=10)
        self.stats_header.grid_columnconfigure((0, 1, 2), weight=1)

        self.player_count_label = ctk.CTkLabel(self.stats_header, text="Players Served: 0", font=ctk.CTkFont(size=18, weight="bold"))
        self.player_count_label.grid(row=0, column=0)

        self.game_count_label = ctk.CTkLabel(self.stats_header, text="Games Hosted: 0", font=ctk.CTkFont(size=18, weight="bold"))
        self.game_count_label.grid(row=0, column=1)

        self.error_count_label = ctk.CTkLabel(self.stats_header, text="Errors Encountered: 0", font=ctk.CTkFont(size=18, weight="bold"), text_color="#ff5555")
        self.error_count_label.grid(row=0, column=2)

        # Chart Container
        self.fig = Figure(dpi=100)
        self.fig.patch.set_facecolor('#2b2b2b')
        
        self.canvas = FigureCanvasTkAgg(self.fig, master=self.charts_frame)
        self.canvas.get_tk_widget().grid(row=1, column=0, sticky="nsew", padx=10, pady=10)

        # Initial Load
        self.refresh_charts()

    # --- Utilities ---
    def check_data_exists(self):
        try:
            with open(PROCESSED_LOGS_JSON, 'r') as f:
                data = json.load(f)
                return len(data) > 0
        except:
            return False

    # --- Logic: Import ---
    def start_import_thread(self):
        self.import_btn.configure(state="disabled")
        threading.Thread(target=self.import_logs, daemon=True).start()

    def import_logs(self):
        files = glob.glob(os.path.join(LOG_DIR, "*.log")) + glob.glob(os.path.join(LOG_DIR_OLD, "*.log"))
        
        if not os.path.exists(PROCESSED_LOGS_JSON):
            processed_files = []
        else:
            with open(PROCESSED_LOGS_JSON, 'r') as f:
                processed_files = json.load(f)

        new_files = [f for f in files if os.path.basename(f) not in processed_files]
        total_files = len(new_files)

        if total_files == 0:
            self.update_progress(1.0)
            self.after(0, lambda: self.import_btn.configure(state="normal"))
            return

        count = 0
        for filepath in new_files:
            filename = os.path.basename(filepath)
            
            try:
                match = re.search(r'\[(\d{2}-\d{2}-\d{4})\]', filename)
                if match:
                    date_str = match.group(1)
                    file_date = datetime.strptime(date_str, "%m-%d-%Y")
                else:
                    file_date = datetime.fromtimestamp(os.path.getmtime(filepath))
            except Exception:
                 file_date = datetime.now()

            date_prefix = file_date.strftime("%Y-%m-%d")

            try:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
            except Exception:
                processed_files.append(filename) # Skip unreadable but mark as done
                continue

            # Track seen player entries for this file to prevent duplicates
            seen_joins = set()

            for line in lines:
                line = line.strip()
                if not line: continue

                if "[NETLOBBY] Starting session" in line:
                    gt_match = re.search(r'gametype (0x[0-9A-F]+)', line)
                    lvl_match = re.search(r'level (0x[0-9A-F]+)', line)
                    if gt_match and lvl_match:
                        self.append_to_file(LEVELS_TXT, f"{date_prefix} | {line}")

                # OLD LOGIC: "Accepted 1 players..."
                # NEW LOGIC: Look for username using standard EchoVR join syntax
                # Typical syntax: [NETGAME] Player <NAME> joined
                player_match = re.search(r"\[NETGAME\] User '(.*?)' participating", line)
                if player_match:
                     # Check if we've already seen this exact log line in this file
                     if line in seen_joins:
                         continue
                     seen_joins.add(line)
                     self.append_to_file(PLAYERS_TXT, f"{date_prefix} | {line}")

                for error in KNOWN_ERRORS:
                    if error in line:
                         self.append_to_file(ERRORS_TXT, f"{date_prefix} | {line}")
                         break

            processed_files.append(filename)
            count += 1
            self.update_progress(count / total_files)

        with open(PROCESSED_LOGS_JSON, 'w') as f:
            json.dump(processed_files, f)

        # Update button text on main thread
        self.after(0, lambda: self.import_btn.configure(state="normal", text="Refresh Log Data"))
        self.after(0, self.refresh_charts)

    def append_to_file(self, filepath, text):
        with open(filepath, 'a', encoding='utf-8') as f:
            f.write(text + "\n")

    def update_progress(self, val):
        self.progress_bar.set(val)
        if val <= 0.0 or val >= 1.0:
            self.progress_label.configure(text="")
        else:
            self.progress_label.configure(text=f"{int(val * 100)}%")

    # --- Logic: Update Checker ---
    def start_update_check_thread(self):
        self.update_btn.configure(state="disabled", text="Checking...")
        threading.Thread(target=self.check_for_updates, daemon=True).start()

    def check_for_updates(self):
        try:
            url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/releases/latest"
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            latest_version = data.get("tag_name", "").strip().lstrip("v")
            if not latest_version:
                raise ValueError("Could not retrieve version tag.")

            # Simple string comparison (assuming Semantic Versioning)
            if latest_version != CURRENT_VERSION:
                # New version available
                assets = data.get("assets", [])
                download_url = None
                
                # Determine which file to download based on how we are running
                target_extension = ".exe" if IS_FROZEN else ".py"
                
                for asset in assets:
                    if asset["name"].endswith(target_extension):
                        download_url = asset["browser_download_url"]
                        break
                
                if download_url:
                    self.after(0, lambda: self.prompt_update(latest_version, download_url))
                else:
                    self.after(0, lambda: msgbox.showwarning("Update Found", f"Version {latest_version} is available, but no matching {target_extension} file was found in the release assets."))
            else:
                self.after(0, lambda: msgbox.showinfo("Up to Date", f"You are running the latest version ({CURRENT_VERSION})."))
        
        except Exception as e:
            self.after(0, lambda: msgbox.showerror("Update Error", f"Failed to check for updates:\n{str(e)}"))
        
        finally:
            self.after(0, lambda: self.update_btn.configure(state="normal", text="Check for Updates"))

    def prompt_update(self, version, url):
        response = msgbox.askyesno("Update Available", f"New version {version} is available.\nWould you like to download and update now?")
        if response:
            self.update_btn.configure(state="disabled", text="Updating...")
            threading.Thread(target=self.perform_update, args=(url,), daemon=True).start()

    def perform_update(self, url):
        try:
            # 1. Download the new file
            new_filename = f"StatTracker-New{APP_EXT}"
            new_filepath = os.path.join(BASE_DIR, new_filename)
            
            r = requests.get(url, stream=True)
            r.raise_for_status()
            
            with open(new_filepath, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
            
            # 2. Create the batch script in dashboard/temp
            batch_path = os.path.join(TEMP_DIR, "update_tracker.bat")
            
            # Handle spaces in paths by ensuring quotes are used in the batch file
            current_exe = APP_FILE
            
            # The batch script waits, moves the new file over the old one, and restarts
            batch_content = f"""@echo off
timeout /t 2 /nobreak > NUL
move /Y "{new_filepath}" "{current_exe}"
start "" "{current_exe}"
del "%~f0"
"""
            with open(batch_path, 'w') as f:
                f.write(batch_content)
            
            # 3. Execute batch and exit
            subprocess.Popen([batch_path], shell=True)
            self.after(0, self.destroy) # Close the app
            
        except Exception as e:
            self.after(0, lambda: msgbox.showerror("Update Failed", f"An error occurred during update:\n{str(e)}"))
            self.after(0, lambda: self.update_btn.configure(state="normal", text="Check for Updates"))

    # --- Logic: Export ---
    def export_csv(self):
        try:
            self.process_levels_csv()
            self.process_players_csv()
            self.process_errors_csv()
            msgbox.showinfo("Success", f"Data exported to {STATS_DIR}")
        except Exception as e:
            msgbox.showerror("Error", str(e))

    def process_levels_csv(self):
        data = self.parse_levels(filter_range="All Time")
        csv_path = os.path.join(STATS_DIR, "levels.csv")
        with open(csv_path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(["Date", "Time", "Gametype", "Gamemode", "Level"])
            for item in data:
                writer.writerow([item['date'], item['time'], item['type'], item['mode'], item['level']])

    def process_players_csv(self):
        if not os.path.exists(PLAYERS_TXT): return
        csv_path = os.path.join(STATS_DIR, "players.csv")
        with open(PLAYERS_TXT, 'r') as f: lines = f.readlines()
        
        seen_entries = set() # Filter for CSV export to skip duplicates
        
        with open(csv_path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(["Date", "Time", "Player Log"])
            for line in lines:
                parts = line.split('|', 1)
                if len(parts) < 2: continue
                date_part = parts[0].strip()
                log_part = parts[1].strip()
                
                # Check duplicate before writing
                # We check the full log line content including the timestamp
                if log_part in seen_entries:
                    continue
                seen_entries.add(log_part)

                time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                time_str = time_match.group(1) if time_match else "00:00:00"
                # Export the raw log part so user can see which player joined
                writer.writerow([date_part, time_str, log_part])

    def process_errors_csv(self):
        if not os.path.exists(ERRORS_TXT): return
        csv_path = os.path.join(STATS_DIR, "errors.csv")
        with open(ERRORS_TXT, 'r') as f: lines = f.readlines()
        with open(csv_path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(["Date", "Time", "Error"])
            for line in lines:
                parts = line.split('|', 1)
                if len(parts) < 2: continue
                date_part = parts[0].strip()
                log_part = parts[1].strip()
                time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                time_str = time_match.group(1) if time_match else "00:00:00"
                writer.writerow([date_part, time_str, log_part])

    # --- Logic: Data Parsing ---
    def get_filter_delta(self):
        selection = self.time_filter.get()
        if selection == "Last Hour": return timedelta(hours=1)
        if selection == "Last 24h": return timedelta(hours=24)
        if selection == "Last 30d": return timedelta(days=30)
        return None

    def is_within_time(self, date_str, time_str, delta):
        if delta is None: return True
        try:
            full_dt = datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M:%S")
            return datetime.now() - full_dt <= delta
        except:
            return False

    def get_oldest_data_date(self):
        """Find the oldest date/time across all data files."""
        oldest_dt = None
        
        # Check all three data files
        for filepath in [LEVELS_TXT, PLAYERS_TXT, ERRORS_TXT]:
            if not os.path.exists(filepath):
                continue
            try:
                with open(filepath, 'r') as f:
                    for line in f:
                        parts = line.split('|', 1)
                        if len(parts) < 2: continue
                        
                        date_str = parts[0].strip()
                        log_part = parts[1].strip()
                        
                        time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                        time_str = time_match.group(1) if time_match else "00:00:00"
                        
                        try:
                            full_dt = datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M:%S")
                            if oldest_dt is None or full_dt < oldest_dt:
                                oldest_dt = full_dt
                        except:
                            continue
            except:
                continue
        
        return oldest_dt

    def parse_levels(self, filter_range):
        data = []
        if not os.path.exists(LEVELS_TXT): return data
        delta = self.get_filter_delta() if filter_range != "All Time" else None
        with open(LEVELS_TXT, 'r') as f:
            for line in f:
                parts = line.split('|', 1)
                if len(parts) < 2: continue
                date_part = parts[0].strip()
                log_part = parts[1].strip()
                time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                time_str = time_match.group(1) if time_match else "00:00:00"

                if not self.is_within_time(date_part, time_str, delta): continue

                gt_match = re.search(r'gametype (0x[0-9A-F]+)', log_part)
                lvl_match = re.search(r'level (0x[0-9A-F]+)', log_part)

                if gt_match and lvl_match:
                    gt_hex = gt_match.group(1)
                    lvl_hex = lvl_match.group(1)
                    lvl_name = LEVEL_MAP.get(lvl_hex, "Unknown")
                    type_name, mode_name = GAMETYPE_MAP.get(gt_hex, ("Unknown", "Unknown"))
                    data.append({"date": date_part, "time": time_str, "type": type_name, "mode": mode_name, "level": lvl_name})
        return data

    def count_players(self):
        unique_players = set()
        if not os.path.exists(PLAYERS_TXT): return 0
        delta = self.get_filter_delta()
        
        with open(PLAYERS_TXT, 'r') as f:
            for line in f:
                parts = line.split('|', 1)
                if len(parts) < 2: continue
                date_part = parts[0].strip()
                log_part = parts[1].strip()
                
                time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                time_str = time_match.group(1) if time_match else "00:00:00"
                
                if self.is_within_time(date_part, time_str, delta):
                    # Extract username from single quotes
                    player_match = re.search(r"\[NETGAME\] User '(.*?)' participating", log_part)
                    if player_match:
                        username = player_match.group(1)
                        unique_players.add(username)
                        
        return len(unique_players)

    def parse_errors(self):
        counts = {k: 0 for k in KNOWN_ERRORS}
        if not os.path.exists(ERRORS_TXT): return counts
        delta = self.get_filter_delta()
        with open(ERRORS_TXT, 'r') as f:
            for line in f:
                parts = line.split('|', 1)
                if len(parts) < 2: continue
                date_part = parts[0].strip()
                log_part = parts[1].strip()
                time_match = re.search(r'\[(\d{2}:\d{2}:\d{2})\]', log_part)
                time_str = time_match.group(1) if time_match else "00:00:00"
                if not self.is_within_time(date_part, time_str, delta): continue
                for err in KNOWN_ERRORS:
                    if err in log_part:
                        counts[err] += 1
                        break
        return counts

    # --- Logic: Visualization ---
    def refresh_charts(self, _=None):
        self.fig.clear()
        
        # Determine Data Presence & Status Text
        if not self.check_data_exists():
            self.status_label.configure(text="Please import log data.", text_color="#ff5555")
        else:
            oldest_date = self.get_oldest_data_date()
            if oldest_date is None:
                self.status_label.configure(text="Since: Unknown", text_color="white")
            else:
                delta = self.get_filter_delta()
                if delta:
                    cutoff_time = datetime.now() - delta
                    if cutoff_time < oldest_date:
                        display_time = oldest_date
                    else:
                        display_time = cutoff_time
                else:
                    display_time = oldest_date

                self.status_label.configure(text=f"Since: {display_time.strftime('%Y-%m-%d at %H:%M')}", text_color="white")

        level_data = self.parse_levels(self.time_filter.get())
        player_count = self.count_players()
        error_counts = self.parse_errors()
        
        # Calculate Stats
        total_games = len(level_data)
        total_errors = sum(error_counts.values())

        # Update Top Labels
        self.player_count_label.configure(text=f"Players Served: {player_count}")
        self.game_count_label.configure(text=f"Games Hosted: {total_games}")
        self.error_count_label.configure(text=f"Errors Encountered: {total_errors}")
        
        # Update Error Label Color
        if total_errors == 0:
            self.error_count_label.configure(text_color="#2cc985") # Green
        else:
            self.error_count_label.configure(text_color="#ff5555") # Red

        show_pct = (self.display_mode.get() == 1)

        # Layout Adjustment: Fixed sizing for 1200x700 window
        self.fig.subplots_adjust(left=0.05, right=0.75, top=0.90, bottom=0.08, wspace=0.4, hspace=0.25)

        # Create separated GridSpecs
        gs_top = gridspec.GridSpec(1, 4, figure=self.fig, 
                                   width_ratios=[1, 0.5, 1, 0.5], 
                                   bottom=0.55, top=0.90, left=0.05, right=0.75, wspace=0.4)
        
        gs_bottom = gridspec.GridSpec(1, 1, figure=self.fig, 
                                      top=0.45, bottom=0.08, left=0.05, right=0.95)

        ax_levels = self.fig.add_subplot(gs_top[0, 0])  # Top Left Chart
        ax_errors = self.fig.add_subplot(gs_top[0, 2])  # Top Right Chart
        ax_bar = self.fig.add_subplot(gs_bottom[0, 0])  # Bottom Chart (Wide)

        # --- Helper for Labels ---
        def get_label(val, total):
            if total == 0: return ""
            return f"{val}" if not show_pct else f"{val/total:.1%}"

        # --- Chart 1: Levels (Pie with Legend) ---
        level_counts = {}
        for x in level_data:
            level_counts[x['level']] = level_counts.get(x['level'], 0) + 1
        
        if level_counts:
            sorted_levels = sorted(level_counts.items(), key=lambda item: item[1], reverse=True)
            labels = [k for k, v in sorted_levels]
            values = [v for k, v in sorted_levels]
            total = sum(values)
            
            legend_labels = [f"{l} - {get_label(v, total)}" for l, v in zip(labels, values)]
            wedges, _ = ax_levels.pie(values, startangle=90)
            
            ax_levels.legend(legend_labels, title="Levels", loc="center left", bbox_to_anchor=(1.05, 0.5), borderaxespad=0, fontsize=8)
            ax_levels.set_title("Hosted Levels", color="white")
        else:
            ax_levels.text(0.5, 0.5, "No Level Data", ha='center', color="white")
            ax_levels.axis('off')

        # --- Chart 2: Errors (Pie with Legend) ---
        active_errors = {k: v for k, v in error_counts.items() if v > 0}
        if active_errors:
            sorted_errors = sorted(active_errors.items(), key=lambda item: item[1], reverse=True)
            labels_raw = [k for k, v in sorted_errors]
            labels = [ERROR_ALIASES.get(lbl, lbl) for lbl in labels_raw]
            values = [v for k, v in sorted_errors]
            total = sum(values)

            legend_labels = [f"{l} - {get_label(v, total)}" for l, v in zip(labels, values)]
            wedges, _ = ax_errors.pie(values, startangle=90)

            ax_errors.legend(legend_labels, title="Errors", loc="center left", bbox_to_anchor=(1.05, 0.5), borderaxespad=0, fontsize=8)
            ax_errors.set_title("Errors", color="white")
        else:
            ax_errors.text(0.5, 0.5, "No Errors", ha='center', color="white")
            ax_errors.axis('off')

        # --- Chart 3: Gametypes (Single Stacked Bar) ---
        type_counts = {"Public": 0, "Private": 0}
        for x in level_data:
            if x['type'] in type_counts:
                type_counts[x['type']] += 1
        
        total_gt = sum(type_counts.values())
        if total_gt > 0:
            pub_val = type_counts["Public"]
            priv_val = type_counts["Private"]
            
            ax_bar.barh([0], [pub_val], color='#1f77b4', height=0.6, label='Public')
            ax_bar.barh([0], [priv_val], left=[pub_val], color='#ff7f0e', height=0.6, label='Private')
            
            if pub_val > 0:
                ax_bar.text(pub_val/2, 0, f"Public: {get_label(pub_val, total_gt)}", 
                            ha='center', va='center', color='white', fontweight='bold')
            if priv_val > 0:
                ax_bar.text(pub_val + priv_val/2, 0, f"Private: {get_label(priv_val, total_gt)}", 
                            ha='center', va='center', color='white', fontweight='bold')

            ax_bar.set_xlim(0, total_gt)
            ax_bar.margins(x=0)
            ax_bar.axis('off')
            ax_bar.set_title("Gametypes (Public / Private)", color="white")
        else:
            ax_bar.text(0.5, 0.5, "No Gametype Data", ha='center', color="white")
            ax_bar.axis('off')

        self.canvas.draw()

if __name__ == "__main__":
    app = StatTrackerApp()
    app.mainloop()