import tkinter as tk
from tkinter import messagebox
import subprocess
import threading
import os
import ctypes
import time
import re

ZAPRET_DIR = os.path.dirname(os.path.abspath(__file__))
BAT_FILE = os.path.join(ZAPRET_DIR, "general (ALT9-CS2).bat")
WINWS_EXE = os.path.join(ZAPRET_DIR, "bin", "winws.exe")
GAME_PROCESS = "cs2.exe"
GAME_TITLE = "Counter-Strike 2"

CREATE_NO_WINDOW = 0x08000000

PING_TARGETS = {
    "Google (инет)":   "8.8.8.8",
    "Cloudflare":      "1.1.1.1",
    "Steam (RU)":      "steamcommunity.com",
}

BG     = "#0f0f1a"
PANEL  = "#1a1a2e"
BORDER = "#2a2a4a"
FG     = "#d0d0e8"
ACCENT = "#f59e0b"
GREEN  = "#4ade80"
RED    = "#f87171"
YELLOW = "#facc15"
PURPLE = "#a78bfa"


def _ping_ms(host):
    try:
        r = subprocess.run(
            ["ping", "-n", "1", "-w", "2000", host],
            capture_output=True, text=True, timeout=5,
            encoding="cp866", errors="ignore",
            creationflags=CREATE_NO_WINDOW
        )
        m = re.search(r"(?:время|time)[<=](\d+)", r.stdout, re.IGNORECASE)
        if m:
            return int(m.group(1))
        m = re.search(r"(?:Average|Среднее)\s*=\s*(\d+)", r.stdout, re.IGNORECASE)
        if m:
            return int(m.group(1))
    except Exception:
        pass
    return None


def _is_running(exe_name):
    r = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {exe_name}"],
        capture_output=True, text=True,
        creationflags=CREATE_NO_WINDOW
    )
    return exe_name.lower() in r.stdout.lower()


class App:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("CS2 Optimizer")
        self.root.resizable(False, False)
        self.root.configure(bg=BG)
        self.root.geometry("370x430")

        self._monitoring = True
        self._ping_enabled = tk.BooleanVar(value=True)
        self._ping_labels = {}

        self._build()
        threading.Thread(target=self._monitor_loop, daemon=True).start()

    def _build(self):
        tk.Label(self.root, text="CS2 Optimizer",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 17, "bold")).pack(pady=(16, 4))
        tk.Label(self.root, text=f"{GAME_TITLE} · Zapret manager",
                 bg=BG, fg=BORDER, font=("Segoe UI", 8)).pack(pady=(0, 10))

        sf = self._panel(self.root)
        sf.pack(fill="x", padx=18, pady=4)

        self._zapret_lbl = self._status_row(sf, "Zapret (winws)", 0)
        self._game_lbl   = self._status_row(sf, GAME_TITLE, 1)

        pf = self._panel(self.root)
        pf.pack(fill="x", padx=18, pady=4)

        tk.Label(pf, text="Пинг", bg=PANEL, fg=FG,
                 font=("Segoe UI", 9, "bold")).grid(row=0, column=0, columnspan=3,
                                                     padx=12, pady=(8, 2), sticky="w")
        for i, (name, host) in enumerate(PING_TARGETS.items()):
            tk.Label(pf, text=name, bg=PANEL, fg=FG,
                     font=("Segoe UI", 9), width=16, anchor="w").grid(
                         row=i+1, column=0, padx=(12, 4), pady=3, sticky="w")
            tk.Label(pf, text=host, bg=PANEL, fg=BORDER,
                     font=("Segoe UI", 8)).grid(row=i+1, column=1, padx=4, sticky="w")
            lbl = tk.Label(pf, text="—", bg=PANEL, fg=ACCENT,
                           font=("Segoe UI", 9, "bold"), width=9, anchor="e")
            lbl.grid(row=i+1, column=2, padx=(4, 12), sticky="e")
            self._ping_labels[name] = lbl

        tk.Checkbutton(
            pf, text="Мониторинг пинга", variable=self._ping_enabled,
            bg=PANEL, fg=FG, selectcolor=BORDER, activebackground=PANEL,
            font=("Segoe UI", 8), command=self._on_ping_toggle
        ).grid(row=len(PING_TARGETS)+1, column=0, columnspan=3,
               padx=12, pady=(2, 8), sticky="w")

        bf = tk.Frame(self.root, bg=BG)
        bf.pack(fill="x", padx=18, pady=6)

        self._btn(bf, "Запустить Zapret (CS2-режим)",
                  GREEN, "#166534", self._start_zapret).pack(fill="x", pady=3)
        self._btn(bf, "Остановить Zapret",
                  RED, "#7f1d1d", self._stop_zapret).pack(fill="x", pady=3)
        self._btn(bf, f"High Priority для {GAME_PROCESS}",
                  PURPLE, "#3b0764", self._set_priority).pack(fill="x", pady=3)

        tk.Label(self.root,
                 text="Bat: general (ALT9-CS2).bat",
                 bg=BG, fg=BORDER, font=("Segoe UI", 7)).pack(pady=(2, 0))

    def _panel(self, parent):
        return tk.Frame(parent, bg=PANEL, highlightbackground=BORDER,
                        highlightthickness=1)

    def _status_row(self, parent, label, row):
        tk.Label(parent, text=label, bg=PANEL, fg=FG,
                 font=("Segoe UI", 9), width=18, anchor="w").grid(
                     row=row, column=0, padx=(12, 4), pady=6, sticky="w")
        lbl = tk.Label(parent, text="...", bg=PANEL, fg=YELLOW,
                       font=("Segoe UI", 9, "bold"))
        lbl.grid(row=row, column=1, padx=(0, 12), sticky="w")
        return lbl

    def _btn(self, parent, text, bg, activebg, cmd):
        return tk.Button(
            parent, text=text, bg=bg, fg="white", activebackground=activebg,
            activeforeground="white", font=("Segoe UI", 9, "bold"),
            relief="flat", padx=10, pady=7, cursor="hand2", command=cmd
        )

    def _monitor_loop(self):
        while self._monitoring:
            zapret_ok = _is_running("winws.exe")
            game_ok   = _is_running(GAME_PROCESS)
            self.root.after(0, self._update_status, zapret_ok, game_ok)

            if self._ping_enabled.get():
                results = {}
                for name, host in PING_TARGETS.items():
                    results[name] = _ping_ms(host)
                self.root.after(0, self._update_pings, results)

            time.sleep(4)

    def _update_status(self, zapret_ok, game_ok):
        self._zapret_lbl.config(
            text="Работает" if zapret_ok else "Не запущен",
            fg=GREEN if zapret_ok else RED
        )
        self._game_lbl.config(
            text="Запущена" if game_ok else "Не запущена",
            fg=GREEN if game_ok else RED
        )

    def _update_pings(self, results):
        for name, ms in results.items():
            lbl = self._ping_labels[name]
            if ms is None:
                lbl.config(text="timeout", fg=RED)
            elif ms < 50:
                lbl.config(text=f"{ms} ms", fg=GREEN)
            elif ms < 100:
                lbl.config(text=f"{ms} ms", fg=YELLOW)
            else:
                lbl.config(text=f"{ms} ms", fg=RED)

    def _on_ping_toggle(self):
        if not self._ping_enabled.get():
            for lbl in self._ping_labels.values():
                lbl.config(text="—", fg=ACCENT)

    def _start_zapret(self):
        if not os.path.exists(BAT_FILE):
            messagebox.showerror("Ошибка", f"Файл не найден:\n{BAT_FILE}")
            return
        if _is_running("winws.exe"):
            if not messagebox.askyesno("CS2 Optimizer",
                                        "Zapret уже запущен. Перезапустить?"):
                return
            threading.Thread(target=self._restart_zapret, daemon=True).start()
        else:
            self._launch_zapret()

    def _restart_zapret(self):
        self._stop_zapret()
        time.sleep(1)
        self.root.after(0, self._launch_zapret)

    def _launch_zapret(self):
        ctypes.windll.shell32.ShellExecuteW(
            None, "runas", "cmd.exe",
            f'/c "{BAT_FILE}"',
            ZAPRET_DIR, 0
        )

    def _stop_zapret(self):
        subprocess.run(["taskkill", "/F", "/IM", "winws.exe"],
                       capture_output=True,
                       creationflags=CREATE_NO_WINDOW)

    def _set_priority(self):
        if not _is_running(GAME_PROCESS):
            messagebox.showinfo("CS2 Optimizer",
                                f"{GAME_TITLE} не запущена.\nСначала зайдите в игру.")
            return
        r = subprocess.run(
            ["wmic", "process", "where", f"name='{GAME_PROCESS}'",
             "call", "setpriority", "128"],
            capture_output=True, text=True,
            creationflags=CREATE_NO_WINDOW
        )
        if r.returncode == 0:
            messagebox.showinfo("CS2 Optimizer",
                                f"High Priority установлен для {GAME_PROCESS}")
        else:
            messagebox.showerror("Ошибка",
                                 f"Не удалось установить приоритет:\n{r.stderr}")

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        self._monitoring = False
        self.root.destroy()


if __name__ == "__main__":
    App().run()
