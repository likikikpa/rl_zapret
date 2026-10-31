import tkinter as tk
from tkinter import messagebox
import subprocess
import threading
import shutil
import winreg
import json
import os
import time
import ctypes

CREATE_NO_WINDOW = 0x08000000
HKLM = winreg.HKEY_LOCAL_MACHINE

DISCORD_SETTINGS = os.path.join(os.environ.get('APPDATA', ''), 'discord', 'settings.json')
DISCORD_CACHE    = os.path.join(os.environ.get('APPDATA', ''), 'discord', 'Cache', 'Cache_Data')

POWER_HIGH     = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
POWER_BALANCED = "381b4222-f694-41f0-9685-ff5bb260df2e"

PRIO_HIGH         = "128"
PRIO_ABOVE_NORMAL = "32768"
PRIO_BELOW_NORMAL = "16384"

BG     = "#0f0f1a"
PANEL  = "#1a1a2e"
BORDER = "#2a2a4a"
FG     = "#d0d0e8"
GREEN  = "#4ade80"
RED    = "#f87171"
YELLOW = "#facc15"
BLUE   = "#5c9cf5"
ORANGE = "#fb923c"
PURPLE = "#a78bfa"
TEAL   = "#2dd4bf"
GRAY   = "#6b7280"


# ── helpers ─────────────────────────────────────────────────────────────────

def _is_admin():
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True,
                          creationflags=CREATE_NO_WINDOW, errors="ignore")


def _ps(script):
    return subprocess.run(
        ["powershell", "-NoProfile", "-Command", script],
        capture_output=True, text=True,
        creationflags=CREATE_NO_WINDOW, errors="ignore"
    )


def _is_running(exe):
    r = _run(["tasklist", "/FI", f"IMAGENAME eq {exe}"])
    return exe.lower() in r.stdout.lower()


def _cache_mb(path):
    try:
        return sum(
            os.path.getsize(os.path.join(dp, f))
            for dp, _, files in os.walk(path) for f in files
        ) / (1024 * 1024)
    except Exception:
        return 0.0


def _set_priority(exe_name, prio):
    exe = exe_name.strip()
    if not exe.lower().endswith(".exe"):
        exe += ".exe"
    if not _is_running(exe):
        return False, f"{exe} не запущен."
    r = _run(["wmic", "process", "where", f"name='{exe}'",
              "call", "setpriority", prio])
    return (r.returncode == 0), exe


# ── registry tweaks ──────────────────────────────────────────────────────────

def _reg_set(hive, path, name, value, reg_type=winreg.REG_DWORD):
    key = winreg.CreateKeyEx(hive, path, 0, winreg.KEY_SET_VALUE)
    try:
        winreg.SetValueEx(key, name, 0, reg_type, value)
    finally:
        winreg.CloseKey(key)


def _reg_get(hive, path, name, default=None):
    try:
        key = winreg.OpenKey(hive, path, 0, winreg.KEY_READ)
        try:
            val, _ = winreg.QueryValueEx(key, name)
            return val
        finally:
            winreg.CloseKey(key)
    except Exception:
        return default


def _reg_del(hive, path, name):
    try:
        key = winreg.OpenKey(hive, path, 0, winreg.KEY_SET_VALUE)
        try:
            winreg.DeleteValue(key, name)
        finally:
            winreg.CloseKey(key)
    except Exception:
        pass


# ── tweak: Delivery Optimization ────────────────────────────────────────────
_DO_PATH = r"SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"

def tweak_do_status():
    return _reg_get(HKLM, _DO_PATH, "DODownloadMode", -1) == 0

def tweak_do_apply():
    _reg_set(HKLM, _DO_PATH, "DODownloadMode", 0)

def tweak_do_revert():
    _reg_del(HKLM, _DO_PATH, "DODownloadMode")


# ── tweak: NetworkThrottlingIndex ────────────────────────────────────────────
_NTI_PATH = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"

def tweak_nti_status():
    return _reg_get(HKLM, _NTI_PATH, "NetworkThrottlingIndex", -1) == 0xffffffff

def tweak_nti_apply():
    _reg_set(HKLM, _NTI_PATH, "NetworkThrottlingIndex", 0xffffffff)

def tweak_nti_revert():
    _reg_set(HKLM, _NTI_PATH, "NetworkThrottlingIndex", 10)


# ── tweak: Nagle Algorithm ───────────────────────────────────────────────────
_IFACES = r"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"

def _nagle_each(fn):
    try:
        root = winreg.OpenKey(HKLM, _IFACES, 0, winreg.KEY_READ)
        i = 0
        while True:
            try:
                sub = winreg.EnumKey(root, i)
                fn(sub)
                i += 1
            except OSError:
                break
        winreg.CloseKey(root)
    except Exception:
        pass

def tweak_nagle_status():
    found = [False]
    def check(sub):
        v = _reg_get(HKLM, f"{_IFACES}\\{sub}", "TCPNoDelay", 0)
        if v == 1:
            found[0] = True
    _nagle_each(check)
    return found[0]

def tweak_nagle_apply():
    def apply(sub):
        path = f"{_IFACES}\\{sub}"
        _reg_set(HKLM, path, "TcpAckFrequency", 1)
        _reg_set(HKLM, path, "TCPNoDelay", 1)
    _nagle_each(apply)

def tweak_nagle_revert():
    def revert(sub):
        path = f"{_IFACES}\\{sub}"
        _reg_del(HKLM, path, "TcpAckFrequency")
        _reg_del(HKLM, path, "TCPNoDelay")
    _nagle_each(revert)


# ── tweak: Interrupt Moderation + LSO ───────────────────────────────────────

def tweak_nic_status():
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "(Get-NetAdapterAdvancedProperty -DisplayName 'Interrupt Moderation' "
             "-EA SilentlyContinue | Where-Object DisplayValue -eq 'Disabled').Count -gt 0"],
            capture_output=True, text=True,
            creationflags=CREATE_NO_WINDOW, errors="ignore",
            timeout=4
        )
        return r.stdout.strip().lower() == "true"
    except Exception:
        return False

def tweak_nic_apply():
    _ps(
        "Get-NetAdapter | %{"
        "  Set-NetAdapterAdvancedProperty -Name $_.Name "
        "    -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -EA SilentlyContinue;"
        "  Disable-NetAdapterLso -Name $_.Name -EA SilentlyContinue"
        "}"
    )

def tweak_nic_revert():
    _ps(
        "Get-NetAdapter | %{"
        "  Set-NetAdapterAdvancedProperty -Name $_.Name "
        "    -DisplayName 'Interrupt Moderation' -DisplayValue 'Enabled' -EA SilentlyContinue;"
        "  Enable-NetAdapterLso -Name $_.Name -EA SilentlyContinue"
        "}"
    )


# ── tweak registry ────────────────────────────────────────────────────────────

TWEAKS = [
    {
        "label":   "Delivery Optimization",
        "hint":    "Windows P2P раздача обновлений через твой канал — OFF",
        "status":  tweak_do_status,
        "apply":   tweak_do_apply,
        "revert":  tweak_do_revert,
    },
    {
        "label":   "NetworkThrottlingIndex",
        "hint":    "Снять лимит 20% пропускной способности для не-мультимедиа",
        "status":  tweak_nti_status,
        "apply":   tweak_nti_apply,
        "revert":  tweak_nti_revert,
    },
    {
        "label":   "Nagle Algorithm — OFF",
        "hint":    "Запрет группировки TCP пакетов (-20-200ms на TCP соединениях)",
        "status":  tweak_nagle_status,
        "apply":   tweak_nagle_apply,
        "revert":  tweak_nagle_revert,
    },
    {
        "label":   "Interrupt Moderation + LSO",
        "hint":    "NIC перестаёт группировать прерывания (-2-5ms стабильный)",
        "status":  tweak_nic_status,
        "apply":   tweak_nic_apply,
        "revert":  tweak_nic_revert,
    },
]


# ── App ──────────────────────────────────────────────────────────────────────

class App:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("PC Optimizer")
        self.root.resizable(False, False)
        self.root.configure(bg=BG)
        self.root.geometry("430x760")
        self._alive = True
        self._tweak_status_labels = []
        self._build()
        threading.Thread(target=self._monitor, daemon=True).start()

    def _build(self):
        # title
        tk.Label(self.root, text="PC Optimizer",
                 bg=BG, fg=BLUE, font=("Segoe UI", 16, "bold")).pack(pady=(12, 0))
        tk.Label(self.root, text="Discord  ·  Internet  ·  Priority  ·  Tweaks",
                 bg=BG, fg=BORDER, font=("Segoe UI", 8)).pack(pady=(0, 4))

        # admin warning
        if not _is_admin():
            tk.Label(self.root,
                     text="  Запущено без прав администратора — некоторые функции не сработают  ",
                     bg="#7f1d1d", fg=RED, font=("Segoe UI", 8)).pack(
                         fill="x", padx=14, pady=(0, 4))

        # ── ПРИОРИТЕТ ПРОЦЕССА ──
        pf = self._section("ПРИОРИТЕТ ПРОЦЕССА", ORANGE)

        pr = tk.Frame(pf, bg=PANEL)
        pr.grid(row=1, column=0, columnspan=2, sticky="ew", padx=10, pady=(6, 2))
        pr.columnconfigure((0, 1, 2), weight=1)
        for col, (lbl, exe) in enumerate([
            ("Rocket League", "RocketLeague.exe"),
            ("CS2",           "cs2.exe"),
            ("Discord",       "Discord.exe"),
        ]):
            tk.Button(pr, text=lbl, bg=BORDER, fg=FG,
                      activebackground=PANEL, font=("Segoe UI", 8),
                      relief="flat", padx=4, pady=3, cursor="hand2",
                      command=lambda e=exe: self._exe_var.set(e)
                      ).grid(row=0, column=col, padx=2, sticky="ew")

        ef = tk.Frame(pf, bg=PANEL)
        ef.grid(row=2, column=0, columnspan=2, sticky="ew", padx=10, pady=2)
        ef.columnconfigure(0, weight=1)
        self._exe_var = tk.StringVar(value="RocketLeague.exe")
        self._exe_cached = "RocketLeague.exe"
        self._exe_var.trace_add("write", lambda *_: self._sync_exe_cache())
        tk.Entry(ef, textvariable=self._exe_var,
                 bg=BORDER, fg=FG, insertbackground=FG,
                 font=("Segoe UI", 9), relief="flat"
                 ).grid(row=0, column=0, sticky="ew", ipady=4)
        self._proc_status = tk.Label(ef, text="", bg=PANEL, fg=GRAY,
                                      font=("Segoe UI", 8))
        self._proc_status.grid(row=1, column=0, sticky="w", pady=(1, 0))

        pb = tk.Frame(pf, bg=PANEL)
        pb.grid(row=3, column=0, columnspan=2, sticky="ew", padx=10, pady=(2, 8))
        pb.columnconfigure((0, 1, 2), weight=1)
        for col, (lbl, bg, prio) in enumerate([
            ("High Priority",  GREEN,  PRIO_HIGH),
            ("Above Normal",   TEAL,   PRIO_ABOVE_NORMAL),
            ("Below Normal",   PURPLE, PRIO_BELOW_NORMAL),
        ]):
            tk.Button(pb, text=lbl, bg=bg, fg="white",
                      activebackground=bg, font=("Segoe UI", 8, "bold"),
                      relief="flat", padx=2, pady=5, cursor="hand2",
                      command=lambda p=prio, l=lbl: self._apply_prio(p, l)
                      ).grid(row=0, column=col, padx=2, sticky="ew")

        # ── СЕТЕВЫЕ ТВИКИ ──
        tf = self._section("СЕТЕВЫЕ ТВИКИ  (требуется перезагрузка)", RED)

        tk.Button(tf, text="Применить все", bg=RED, fg="white",
                  activebackground="#7f1d1d", font=("Segoe UI", 8, "bold"),
                  relief="flat", padx=8, pady=3, cursor="hand2",
                  command=self._apply_all_tweaks
                  ).grid(row=1, column=0, sticky="w", padx=10, pady=(6, 2))
        tk.Button(tf, text="Откатить все", bg=BORDER, fg=FG,
                  activebackground=PANEL, font=("Segoe UI", 8),
                  relief="flat", padx=8, pady=3, cursor="hand2",
                  command=self._revert_all_tweaks
                  ).grid(row=1, column=1, sticky="e", padx=10, pady=(6, 2))

        self._tweak_status_labels = []
        for i, tweak in enumerate(TWEAKS):
            row = i + 2
            dot = tk.Label(tf, text="○", bg=PANEL, fg=GRAY,
                           font=("Segoe UI", 10, "bold"))
            dot.grid(row=row, column=0, padx=(10, 4), pady=3, sticky="w")
            tk.Label(tf, text=tweak["label"], bg=PANEL, fg=FG,
                     font=("Segoe UI", 8, "bold"), anchor="w"
                     ).grid(row=row, column=0, padx=(24, 0), sticky="w")

            btnf = tk.Frame(tf, bg=PANEL)
            btnf.grid(row=row, column=1, padx=10, pady=3, sticky="e")
            tk.Button(btnf, text="Вкл", bg=GREEN, fg="white",
                      activebackground=GREEN, font=("Segoe UI", 8, "bold"),
                      relief="flat", padx=8, pady=2, cursor="hand2",
                      command=lambda t=tweak: self._tweak_run(t["apply"], t["label"], "Применён")
                      ).pack(side="left", padx=(0, 2))
            tk.Button(btnf, text="Выкл", bg=BORDER, fg=FG,
                      activebackground=PANEL, font=("Segoe UI", 8),
                      relief="flat", padx=8, pady=2, cursor="hand2",
                      command=lambda t=tweak: self._tweak_run(t["revert"], t["label"], "Откатан")
                      ).pack(side="left")

            self._tweak_status_labels.append(dot)

        tk.Label(tf, text="", bg=PANEL).grid(row=20, column=0, pady=(0, 4))

        # ── DISCORD ──
        df = self._section("DISCORD", PURPLE)
        self._discord_lbl = self._row(df, "Discord", "...", 1)
        self._cache_lbl   = self._row(df, "Кеш",     "...", 2)
        bf = tk.Frame(df, bg=PANEL)
        bf.grid(row=3, column=0, columnspan=2, sticky="ew", padx=10, pady=(4, 8))
        bf.columnconfigure((0, 1, 2), weight=1)
        for col, (lbl, bg, cmd) in enumerate([
            ("Below Normal",  PURPLE, self._discord_priority),
            ("Без HW Accel",  ORANGE, self._discord_hw_accel),
            ("Очистить кеш",  RED,    self._discord_cache),
        ]):
            tk.Button(bf, text=lbl, bg=bg, fg="white",
                      activebackground=bg, font=("Segoe UI", 8, "bold"),
                      relief="flat", padx=2, pady=5, cursor="hand2",
                      command=cmd).grid(row=0, column=col, padx=2, sticky="ew")

        # ── ИНТЕРНЕТ / СЕТЬ ──
        nf = self._section("ИНТЕРНЕТ / СЕТЬ", TEAL)
        nb = tk.Frame(nf, bg=PANEL)
        nb.grid(row=1, column=0, columnspan=2, sticky="ew", padx=10, pady=(6, 8))
        nb.columnconfigure((0, 1, 2), weight=1)
        for col, (lbl, bg, cmd) in enumerate([
            ("DNS → 1.1.1.1",      TEAL,  self._set_dns),
            ("Flush DNS",           BLUE,  self._flush_dns),
            ("Power Save адаптера", GREEN, self._adapter_powersave),
        ]):
            tk.Button(nb, text=lbl, bg=bg, fg="white",
                      activebackground=bg, font=("Segoe UI", 8, "bold"),
                      relief="flat", padx=2, pady=5, cursor="hand2",
                      command=cmd).grid(row=0, column=col, padx=2, sticky="ew")

        # ── СИСТЕМА ──
        sf = self._section("СИСТЕМА", YELLOW)
        self._power_lbl = self._row(sf, "Power plan", "...", 1)
        pw = tk.Frame(sf, bg=PANEL)
        pw.grid(row=2, column=0, columnspan=2, sticky="ew", padx=10, pady=(4, 8))
        pw.columnconfigure((0, 1), weight=1)
        tk.Button(pw, text="High Performance", bg=GREEN, fg="white",
                  activebackground=GREEN, font=("Segoe UI", 8, "bold"),
                  relief="flat", pady=5, cursor="hand2",
                  command=self._power_high
                  ).grid(row=0, column=0, sticky="ew", padx=(0, 2))
        tk.Button(pw, text="Balanced", bg=YELLOW, fg="black",
                  activebackground=YELLOW, font=("Segoe UI", 8, "bold"),
                  relief="flat", pady=5, cursor="hand2",
                  command=self._power_balanced
                  ).grid(row=0, column=1, sticky="ew", padx=(2, 0))

    def _section(self, title, color):
        f = tk.Frame(self.root, bg=PANEL,
                     highlightbackground=color, highlightthickness=1)
        f.pack(fill="x", padx=14, pady=3)
        f.columnconfigure((0, 1), weight=1)
        tk.Label(f, text=f"  {title}", bg=PANEL, fg=color,
                 font=("Segoe UI", 7, "bold")).grid(
                     row=0, column=0, columnspan=2, sticky="w", pady=(4, 0))
        return f

    def _row(self, parent, label, value, row):
        tk.Label(parent, text=label, bg=PANEL, fg=FG,
                 font=("Segoe UI", 9), anchor="w").grid(
                     row=row, column=0, padx=(10, 4), pady=2, sticky="w")
        lbl = tk.Label(parent, text=value, bg=PANEL, fg=YELLOW,
                       font=("Segoe UI", 9, "bold"), anchor="e")
        lbl.grid(row=row, column=1, padx=(0, 10), pady=2, sticky="e")
        return lbl

    # ── monitor ──────────────────────────────────────────────────────────────

    def _sync_exe_cache(self):
        self._exe_cached = self._exe_var.get()

    def _monitor(self):
        while self._alive:
            discord_ok = _is_running("Discord.exe")
            cache_mb   = _cache_mb(DISCORD_CACHE)
            plan       = self._get_plan()
            exe        = self._exe_cached.strip()
            if not exe.lower().endswith(".exe"):
                exe += ".exe"
            proc_ok    = _is_running(exe)
            statuses   = [t["status"]() for t in TWEAKS]
            self.root.after(0, self._refresh,
                            discord_ok, cache_mb, plan, exe, proc_ok, statuses)
            time.sleep(5)

    def _refresh(self, discord_ok, cache_mb, plan, exe, proc_ok, statuses):
        self._discord_lbl.config(
            text="Запущен" if discord_ok else "Не запущен",
            fg=GREEN if discord_ok else RED)
        c = RED if cache_mb > 500 else (YELLOW if cache_mb > 100 else GREEN)
        self._cache_lbl.config(text=f"{cache_mb:.0f} MB", fg=c)
        self._power_lbl.config(
            text=plan, fg=GREEN if plan == "High Performance" else YELLOW)
        self._proc_status.config(
            text=f"{exe}: {'запущен ✓' if proc_ok else 'не запущен'}",
            fg=GREEN if proc_ok else GRAY)
        for lbl, ok in zip(self._tweak_status_labels, statuses):
            lbl.config(text="●" if ok else "○", fg=GREEN if ok else GRAY)

    def _get_plan(self):
        r = _run(["powercfg", "/getactivescheme"])
        if POWER_HIGH in r.stdout.lower():
            return "High Performance"
        if POWER_BALANCED in r.stdout.lower():
            return "Balanced"
        return "Other"

    # ── priority ─────────────────────────────────────────────────────────────

    def _apply_prio(self, prio, label):
        ok, msg = _set_priority(self._exe_var.get(), prio)
        if ok:
            messagebox.showinfo("PC Optimizer", f"{msg} → {label} ✓")
        else:
            messagebox.showwarning("PC Optimizer", msg)

    # ── tweaks ───────────────────────────────────────────────────────────────

    def _tweak_run(self, fn, name, action):
        def worker():
            try:
                fn()
                self.root.after(0, messagebox.showinfo, "PC Optimizer",
                                f"{name}: {action} ✓\nДля полного эффекта — перезагрузи ПК.")
            except Exception as e:
                self.root.after(0, messagebox.showerror, "Ошибка", str(e))
        threading.Thread(target=worker, daemon=True).start()

    def _apply_all_tweaks(self):
        if not messagebox.askyesno("PC Optimizer",
                                    "Применить все 4 сетевых твика?\n"
                                    "После — потребуется перезагрузка."):
            return
        def worker():
            for t in TWEAKS:
                try:
                    t["apply"]()
                except Exception:
                    pass
            self.root.after(0, messagebox.showinfo, "PC Optimizer",
                            "Все твики применены ✓\nПерезагрузи ПК для полного эффекта.")
        threading.Thread(target=worker, daemon=True).start()

    def _revert_all_tweaks(self):
        if not messagebox.askyesno("PC Optimizer",
                                    "Откатить все сетевые твики к дефолту?"):
            return
        def worker():
            for t in TWEAKS:
                try:
                    t["revert"]()
                except Exception:
                    pass
            self.root.after(0, messagebox.showinfo, "PC Optimizer",
                            "Все твики сброшены ✓\nПерезагрузи ПК.")
        threading.Thread(target=worker, daemon=True).start()

    # ── discord ──────────────────────────────────────────────────────────────

    def _discord_priority(self):
        ok, msg = _set_priority("Discord.exe", PRIO_BELOW_NORMAL)
        if ok:
            messagebox.showinfo("PC Optimizer",
                                "Discord → Below Normal ✓\nCPU отдаётся игре.")
        else:
            messagebox.showwarning("PC Optimizer", msg)

    def _discord_hw_accel(self):
        try:
            cfg = {}
            if os.path.exists(DISCORD_SETTINGS):
                with open(DISCORD_SETTINGS, encoding="utf-8") as f:
                    cfg = json.load(f)
            if not cfg.get("enableHardwareAcceleration", True):
                messagebox.showinfo("PC Optimizer", "HW Acceleration уже выключена.")
                return
            cfg["enableHardwareAcceleration"] = False
            with open(DISCORD_SETTINGS, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=2)
            messagebox.showinfo("PC Optimizer",
                                "Hardware Acceleration выключена ✓\nПерезапусти Discord.")
        except Exception as e:
            messagebox.showerror("Ошибка", str(e))

    def _discord_cache(self):
        if _is_running("Discord.exe"):
            if not messagebox.askyesno("PC Optimizer",
                                        "Discord запущен. Закрыть и очистить?"):
                return
            threading.Thread(target=self._do_clear_discord_cache,
                             daemon=True).start()
        else:
            self._clear_cache_now()

    def _do_clear_discord_cache(self):
        _run(["taskkill", "/F", "/IM", "Discord.exe"])
        time.sleep(1.2)
        self.root.after(0, self._clear_cache_now)

    def _clear_cache_now(self):
        if not os.path.exists(DISCORD_CACHE):
            messagebox.showinfo("PC Optimizer", "Кеш не найден.")
            return
        mb = _cache_mb(DISCORD_CACHE)
        shutil.rmtree(DISCORD_CACHE, ignore_errors=True)
        messagebox.showinfo("PC Optimizer", f"Освобождено {mb:.0f} MB ✓")

    # ── network ──────────────────────────────────────────────────────────────

    def _set_dns(self):
        r = _ps(
            "foreach ($a in (Get-NetAdapter | Where-Object {$_.Status -eq 'Up'})) {"
            "  Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex "
            "    -ServerAddresses '1.1.1.1','8.8.8.8' -EA SilentlyContinue"
            "}; Write-Output 'OK'"
        )
        if "OK" in r.stdout:
            messagebox.showinfo("PC Optimizer", "DNS → 1.1.1.1 / 8.8.8.8 ✓")
        else:
            messagebox.showerror("Ошибка", "Нужны права администратора.")

    def _flush_dns(self):
        _run(["ipconfig", "/flushdns"])
        messagebox.showinfo("PC Optimizer", "DNS кеш очищен ✓")

    def _adapter_powersave(self):
        r = _ps(
            "$n=0;Get-NetAdapter|%{try{"
            "Disable-NetAdapterPowerManagement -Name $_.Name -EA Stop;$n++}catch{}};"
            "Write-Output \"OK:$n\""
        )
        if "OK:" in r.stdout:
            n = r.stdout.strip().split(":")[-1].strip()
            messagebox.showinfo("PC Optimizer",
                                f"Power Save отключён ({n} адаптеров) ✓")
        else:
            messagebox.showerror("Ошибка", "Нужны права администратора.")

    # ── power ─────────────────────────────────────────────────────────────────

    def _power_high(self):
        if _run(["powercfg", "/setactive", POWER_HIGH]).returncode == 0:
            messagebox.showinfo("PC Optimizer", "High Performance ✓")
        else:
            messagebox.showerror("Ошибка", "Не удалось сменить план.")

    def _power_balanced(self):
        if _run(["powercfg", "/setactive", POWER_BALANCED]).returncode == 0:
            messagebox.showinfo("PC Optimizer", "Balanced восстановлен ✓")
        else:
            messagebox.showerror("Ошибка", "Не удалось сменить план.")

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._close)
        self.root.mainloop()

    def _close(self):
        self._alive = False
        self.root.destroy()


if __name__ == "__main__":
    App().run()
