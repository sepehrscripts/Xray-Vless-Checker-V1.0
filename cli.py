#!/usr/bin/env python3
"""
VLESS Monitor CLI — interactive management tool
Usage: vless-monitor
"""
import sys, os, subprocess, time
from pathlib import Path

# ── ANSI colors ───────────────────────────────────────────────────────────────
R  = "\033[0;31m"; G  = "\033[0;32m"; Y  = "\033[1;33m"
C  = "\033[0;36m"; B  = "\033[0;34m"; W  = "\033[1;37m"
DIM= "\033[2m";    NC = "\033[0m";    BOLD="\033[1m"

SERVICE    = "vless-monitor"
INSTALL    = Path("/opt/vless-monitor")
PANEL_URL  = "http://localhost:5000"
UPDATE_URL = "https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh"

def clear(): os.system("clear")

def banner():
    clear()
    print(f"{C}{BOLD}")
    print("  ╔══════════════════════════════════════════════╗")
    print("  ║       ▣  VLESS Monitor  —  CLI Tool         ║")
    print("  ╚══════════════════════════════════════════════╝")
    print(f"{NC}")

def svc(cmd: str, name: str = SERVICE) -> int:
    return subprocess.run(["systemctl", cmd, name],
                          capture_output=True).returncode

def is_running() -> bool:
    return subprocess.run(["systemctl", "is-active", "--quiet", SERVICE]).returncode == 0

def status_line() -> str:
    if is_running():
        return f"{G}● running{NC}"
    return f"{R}● stopped{NC}"

def pause():
    input(f"\n  {DIM}Press Enter to continue…{NC}")

# ── Menus ─────────────────────────────────────────────────────────────────────
def menu_main():
    while True:
        banner()
        print(f"  Service: {status_line()}   Panel: {C}{PANEL_URL}{NC}\n")
        print(f"  {W}Service Management{NC}")
        print(f"   {G}1{NC}) Start            {G}2{NC}) Stop")
        print(f"   {G}3{NC}) Restart          {G}4{NC}) Live Status")
        print(f"   {G}5{NC}) Live Logs        {G}6{NC}) Show Panel URL")
        print(f"\n  {W}Data Management{NC}")
        print(f"   {Y}7{NC}) Add Server       {Y}8{NC}) List Servers")
        print(f"   {Y}9{NC}) Remove Server")
        print(f"\n  {W}System{NC}")
        print(f"   {B}10{NC}) Update           {R}11{NC}) Uninstall")
        print(f"   {DIM}0{NC}) Exit\n")
        ch = input(f"  {BOLD}Choose [{DIM}0-11{NC}{BOLD}]:{NC} ").strip()

        if   ch == "1":  do_start()
        elif ch == "2":  do_stop()
        elif ch == "3":  do_restart()
        elif ch == "4":  do_status()
        elif ch == "5":  do_logs()
        elif ch == "6":  do_url()
        elif ch == "7":  do_add()
        elif ch == "8":  do_list()
        elif ch == "9":  do_remove()
        elif ch == "10": do_update()
        elif ch == "11": do_uninstall()
        elif ch == "0":  print(f"\n  {DIM}Bye.{NC}\n"); sys.exit(0)

def do_start():
    banner(); print(f"  {Y}Starting service…{NC}\n")
    rc = svc("start")
    time.sleep(1)
    if is_running(): print(f"  {G}✓ Service started.{NC}")
    else:            print(f"  {R}✗ Failed to start. Check logs.{NC}")
    pause()

def do_stop():
    banner(); print(f"  {Y}Stopping service…{NC}\n")
    svc("stop"); time.sleep(1)
    print(f"  {Y}✓ Service stopped.{NC}")
    pause()

def do_restart():
    banner(); print(f"  {Y}Restarting…{NC}\n")
    svc("restart"); time.sleep(1.5)
    if is_running(): print(f"  {G}✓ Restarted successfully.{NC}")
    else:            print(f"  {R}✗ Service not running. Check logs.{NC}")
    pause()

def do_status():
    banner()
    subprocess.run(["systemctl", "status", SERVICE, "--no-pager", "-l"])
    pause()

def do_logs():
    banner()
    print(f"  {DIM}Press Ctrl+C to exit logs{NC}\n")
    try:
        subprocess.run(["journalctl", "-u", SERVICE, "-f", "--no-pager"])
    except KeyboardInterrupt:
        pass

def do_url():
    banner()
    try:
        import socket
        ip = socket.gethostbyname(socket.gethostname())
    except Exception:
        ip = "YOUR-SERVER-IP"
    print(f"  {W}Web Panel:{NC}")
    print(f"  {C}http://{ip}:5000{NC}")
    print(f"  {C}http://localhost:5000{NC}")
    print(f"\n  Default login: {W}admin{NC} / {W}admin{NC}")
    pause()

# ── DB helpers ────────────────────────────────────────────────────────────────
def _db():
    import sqlite3
    db_path = INSTALL / "data" / "monitor.db"
    if not db_path.exists():
        print(f"  {R}Database not found. Is the service installed?{NC}")
        return None
    return sqlite3.connect(db_path)

def do_add():
    banner()
    print(f"  {W}Add Server{NC}\n")
    remark = input(f"  Remark (name): ").strip()
    link   = input(f"  VLESS link:    ").strip()
    if not remark or not link:
        print(f"  {R}Both fields required.{NC}"); pause(); return
    db = _db()
    if not db: pause(); return
    db.execute("INSERT INTO servers(remark,vless_link) VALUES(?,?)", (remark, link))
    db.commit(); db.close()
    print(f"  {G}✓ Server '{remark}' added.{NC}")
    svc("restart")
    pause()

def do_list():
    banner()
    print(f"  {W}Server List{NC}\n")
    db = _db()
    if not db: pause(); return
    rows = db.execute("SELECT id,remark,last_status,enabled FROM servers ORDER BY id").fetchall()
    db.close()
    if not rows:
        print(f"  {DIM}No servers.{NC}")
    else:
        print(f"  {'ID':<5} {'Status':<8} {'En':<4} Remark")
        print(f"  {'─'*50}")
        for r in rows:
            st   = f"{G}UP{NC}" if r[2]=="UP" else f"{R}DOWN{NC}" if r[2]=="DOWN" else f"{DIM}?{NC}"
            en   = f"{G}✓{NC}" if r[3] else f"{R}✗{NC}"
            print(f"  {r[0]:<5} {st:<18} {en:<14} {r[1]}")
    pause()

def do_remove():
    banner()
    print(f"  {W}Remove Server{NC}\n")
    db = _db()
    if not db: pause(); return
    rows = db.execute("SELECT id,remark FROM servers ORDER BY id").fetchall()
    if not rows:
        print(f"  {DIM}No servers.{NC}"); db.close(); pause(); return
    for r in rows:
        print(f"  {r[0]}) {r[1]}")
    sid = input(f"\n  Enter server ID to delete (0 to cancel): ").strip()
    if sid == "0": db.close(); return
    try:
        sid = int(sid)
        name = next((r[1] for r in rows if r[0]==sid), None)
        if not name:
            print(f"  {R}Invalid ID.{NC}"); db.close(); pause(); return
        confirm = input(f"  Delete '{name}'? [y/N]: ").strip().lower()
        if confirm == "y":
            db.execute("DELETE FROM servers WHERE id=?", (sid,))
            db.commit()
            print(f"  {G}✓ Deleted.{NC}")
    except ValueError:
        print(f"  {R}Invalid input.{NC}")
    db.close()
    pause()

def do_update():
    banner()
    print(f"  {Y}Updating VLESS Monitor…{NC}\n")
    os.system(f"bash <(curl -Ls {UPDATE_URL})")

def do_uninstall():
    banner()
    print(f"  {R}{BOLD}UNINSTALL VLESS Monitor{NC}\n")
    print(f"  {Y}This will remove all files, service, and data.{NC}\n")
    confirm = input(f"  Type 'yes' to confirm: ").strip()
    if confirm != "yes":
        print(f"  {DIM}Cancelled.{NC}"); pause(); return

    print(f"\n  {Y}Stopping services…{NC}")
    svc("stop"); svc("disable")
    svc("stop",  "vless-monitor-xray"); svc("disable","vless-monitor-xray")

    for f in ["/etc/systemd/system/vless-monitor.service",
              "/etc/systemd/system/vless-monitor-xray.service",
              "/usr/local/bin/vless-monitor"]:
        Path(f).unlink(missing_ok=True)

    subprocess.run(["systemctl", "daemon-reload"], capture_output=True)

    import shutil
    shutil.rmtree(str(INSTALL), ignore_errors=True)

    print(f"  {G}✓ Uninstalled successfully.{NC}\n")
    sys.exit(0)

# ─── Entry ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if os.geteuid() != 0:
        print(f"\n  {R}Run as root or with sudo.{NC}\n")
        sys.exit(1)
    menu_main()
