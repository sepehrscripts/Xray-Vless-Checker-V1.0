#!/bin/bash
# ═══════════════════════════════════════════════════════
#   VLESS Monitor — One-Line Installer
#   Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh)
# ═══════════════════════════════════════════════════════
set -e

INSTALL_DIR="/opt/vless-monitor"
SERVICE="vless-monitor"
PORT=5000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${CYAN}"
  echo "  ▣  VLESS Monitor Installer"
  echo "  ──────────────────────────"
  echo -e "${NC}"
}

step() { echo -e "  ${GREEN}[+]${NC} $1"; }
info() { echo -e "  ${YELLOW}[~]${NC} $1"; }
die()  { echo -e "  ${RED}[!]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && die "Please run with sudo:  sudo bash <(curl -Ls URL)"

banner

# ── 1. System deps ──────────────────────────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
  python3 \
  python3-flask \
  python3-requests
step "Python + Flask + Requests installed via apt"

# ── 2. Create directory ──────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR/templates"
step "Directory $INSTALL_DIR created"

# ── 3. Write monitor.py ──────────────────────────────────────────────────────
info "Writing monitor.py ..."
cat > "$INSTALL_DIR/monitor.py" << 'PYEOF'
#!/usr/bin/env python3
import json, socket, time, threading, urllib.parse
from datetime import datetime
from pathlib import Path
import requests
from flask import Flask, jsonify, render_template, request

BASE_DIR    = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "config.json"
LOG_FILE    = BASE_DIR / "events.json"

DEFAULT_CONFIG = {
    "telegram_token": "", "telegram_chat_id": "",
    "interval": 300, "timeout": 10, "links": []
}

state_lock   = threading.Lock()
server_state = {}
event_log    = []

def load_config():
    if CONFIG_FILE.exists():
        try: return json.loads(CONFIG_FILE.read_text())
        except: pass
    return DEFAULT_CONFIG.copy()

def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))

def load_events():
    global event_log
    if LOG_FILE.exists():
        try: event_log = json.loads(LOG_FILE.read_text())[-200:]
        except: event_log = []

def save_events():
    LOG_FILE.write_text(json.dumps(event_log[-200:], ensure_ascii=False, indent=2))

def parse_vless(link):
    try:
        p = urllib.parse.urlparse(link)
        if p.scheme != "vless": return None
        name = urllib.parse.unquote(p.fragment) or f"{p.hostname}:{p.port}"
        return {"name": name, "host": p.hostname, "port": p.port or 443, "raw": link}
    except: return None

def tcp_ping(host, port, timeout):
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, round((time.perf_counter()-t0)*1000, 1)
    except:
        return False, round((time.perf_counter()-t0)*1000, 1)

def send_telegram(token, chat_id, text):
    if not token or not chat_id: return
    try:
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
            json={"chat_id": chat_id, "text": text, "parse_mode": "HTML"}, timeout=15)
    except: pass

def log_event(kind, message, server=""):
    entry = {"ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
             "kind": kind, "server": server, "message": message}
    with state_lock: event_log.append(entry)
    save_events()

def run_checks():
    cfg = load_config()
    failed = []
    for link in cfg.get("links", []):
        info = parse_vless(link)
        if not info: continue
        ok, latency = tcp_ping(info["host"], info["port"], cfg.get("timeout", 10))
        result = {**info, "ok": ok, "latency": latency,
                  "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        with state_lock:
            prev = server_state.get(info["name"], {})
            server_state[info["name"]] = result
        was_ok = prev.get("ok", True)
        if not ok and was_ok:
            log_event("down", f"Server went DOWN — {latency}ms", info["name"])
            failed.append(result)
        elif ok and not was_ok:
            log_event("up", f"Server is back UP — {latency}ms", info["name"])
    if failed:
        lines = ["🚨 <b>The following server(s) are unreachable</b>\n"]
        for s in failed:
            lines += [f"• <b>{s['name']}</b>  <code>{s['host']}:{s['port']}</code>",
                      f"  Latency: {s['latency']}ms"]
        lines.append(f"\n🕐 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        send_telegram(cfg.get("telegram_token",""), cfg.get("telegram_chat_id",""), "\n".join(lines))

def monitor_loop():
    load_events()
    log_event("system", "Monitor started")
    while True:
        try: run_checks()
        except Exception as e: log_event("error", str(e))
        time.sleep(load_config().get("interval", 300))

app = Flask(__name__)

@app.route("/")
def index(): return render_template("index.html")

@app.route("/api/status")
def api_status():
    with state_lock: servers = list(server_state.values())
    total = len(servers); up = sum(1 for s in servers if s["ok"])
    return jsonify({"servers": servers, "summary": {"total": total, "up": up, "down": total-up}})

@app.route("/api/events")
def api_events():
    limit = int(request.args.get("limit", 50))
    with state_lock: evts = event_log[-limit:][::-1]
    return jsonify(evts)

@app.route("/api/config", methods=["GET"])
def api_config_get():
    cfg = load_config(); masked = cfg.copy()
    t = masked.get("telegram_token","")
    if t: masked["telegram_token"] = t[:6]+"***"+t[-4:] if len(t)>10 else "***"
    return jsonify(masked)

@app.route("/api/config", methods=["POST"])
def api_config_post():
    data = request.json or {}; cfg = load_config()
    if "telegram_token" in data and "***" not in data["telegram_token"]:
        cfg["telegram_token"] = data["telegram_token"]
    if "telegram_chat_id" in data: cfg["telegram_chat_id"] = data["telegram_chat_id"]
    if "interval" in data: cfg["interval"] = max(30, int(data["interval"]))
    if "timeout"  in data: cfg["timeout"]  = max(3,  int(data["timeout"]))
    if "links"    in data: cfg["links"]    = [l.strip() for l in data["links"] if l.strip()]
    save_config(cfg); return jsonify({"ok": True})

@app.route("/api/check_now", methods=["POST"])
def api_check_now():
    threading.Thread(target=run_checks, daemon=True).start()
    return jsonify({"ok": True})

@app.route("/api/test_telegram", methods=["POST"])
def api_test_telegram():
    cfg = load_config()
    send_telegram(cfg.get("telegram_token",""), cfg.get("telegram_chat_id",""),
                  "✅ <b>Test successful!</b>\nVLESS Monitor is configured correctly.")
    return jsonify({"ok": True})

if __name__ == "__main__":
    threading.Thread(target=monitor_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5000, debug=False)
PYEOF
step "monitor.py written"

# ── 4. Write index.html ──────────────────────────────────────────────────────
info "Writing web panel..."
cat > "$INSTALL_DIR/templates/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VLESS Monitor</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Inter:wght@300;400;600;700&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0a0c0f;--bg2:#111318;--bg3:#181c23;--border:#1e2330;--border2:#252b3a;--green:#00e5a0;--green-dim:#00e5a022;--red:#ff3b5c;--red-dim:#ff3b5c22;--yellow:#ffc043;--yellow-dim:#ffc04322;--blue:#3b82f6;--text:#e2e8f0;--text2:#8892a4;--text3:#4a5568;--mono:'JetBrains Mono',monospace;--sans:'Inter',sans-serif}
html{font-size:14px}
body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;overflow-x:hidden}
.layout{display:grid;grid-template-columns:240px 1fr;min-height:100vh}
.sidebar{background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:24px 0;position:sticky;top:0;height:100vh;overflow-y:auto}
.logo{padding:0 24px 28px;border-bottom:1px solid var(--border)}
.logo-mark{font-family:var(--mono);font-size:1.3rem;font-weight:700;color:var(--green);letter-spacing:-.5px}
.logo-sub{font-size:.7rem;color:var(--text3);margin-top:4px;letter-spacing:2px;text-transform:uppercase}
nav{padding:16px 12px;flex:1}
.nav-item{display:flex;align-items:center;gap:10px;padding:10px 14px;border-radius:8px;cursor:pointer;color:var(--text2);font-size:.85rem;font-weight:600;transition:all .15s;margin-bottom:4px;border:none;background:none;width:100%;text-align:left}
.nav-item:hover{background:var(--bg3);color:var(--text)}
.nav-item.active{background:var(--green-dim);color:var(--green)}
.nav-icon{width:16px;height:16px;flex-shrink:0}
.sidebar-footer{padding:16px 24px;border-top:1px solid var(--border)}
.last-check{font-size:.7rem;color:var(--text3);font-family:var(--mono)}
main{padding:32px;overflow-y:auto}
.page{display:none}.page.active{display:block}
h2{font-size:1.1rem;font-weight:700;margin-bottom:24px;color:var(--text);display:flex;align-items:center;gap:10px}
h2 .badge{font-size:.68rem;font-family:var(--mono);background:var(--bg3);border:1px solid var(--border2);padding:2px 8px;border-radius:20px;color:var(--text3)}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:32px}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px 24px;position:relative;overflow:hidden}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px}
.card.green::before{background:var(--green)}.card.red::before{background:var(--red)}.card.blue::before{background:var(--blue)}
.card-label{font-size:.68rem;color:var(--text3);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:8px}
.card-value{font-size:2.2rem;font-weight:700;font-family:var(--mono);line-height:1}
.card.green .card-value{color:var(--green)}.card.red .card-value{color:var(--red)}.card.blue .card-value{color:var(--blue)}
.server-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
.server-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:18px 20px;transition:border-color .2s,transform .15s;position:relative;overflow:hidden}
.server-card:hover{transform:translateY(-2px);border-color:var(--border2)}
.server-card.up{border-color:#00e5a030}.server-card.down{border-color:#ff3b5c30}
.server-card.down::after{content:'';position:absolute;inset:0;background:var(--red-dim);pointer-events:none}
.sc-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px}
.sc-name{font-weight:700;font-size:.9rem;word-break:break-all}
.sc-status{display:flex;align-items:center;gap:6px;font-size:.72rem;font-weight:700;padding:3px 10px;border-radius:20px;white-space:nowrap}
.sc-status.up{background:var(--green-dim);color:var(--green)}.sc-status.down{background:var(--red-dim);color:var(--red)}
.pulse{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.pulse.up{background:var(--green);animation:ping 1.5s infinite}.pulse.down{background:var(--red)}
@keyframes ping{0%{box-shadow:0 0 0 0 #00e5a066}70%{box-shadow:0 0 0 6px transparent}100%{box-shadow:0 0 0 0 transparent}}
.sc-meta{font-family:var(--mono);font-size:.76rem;color:var(--text3)}
.sc-latency{display:flex;align-items:center;gap:8px;margin-top:8px}
.latency-bar{flex:1;height:3px;background:var(--bg3);border-radius:2px;overflow:hidden}
.latency-fill{height:100%;border-radius:2px;background:var(--green);transition:width .5s ease}
.latency-val{font-size:.73rem;font-family:var(--mono);color:var(--text2)}
.sc-ts{font-size:.68rem;color:var(--text3);margin-top:8px}
.empty{text-align:center;padding:60px 20px;color:var(--text3)}
.empty-icon{font-size:2.5rem;margin-bottom:12px}.empty-text{font-size:.88rem}
.event-list{display:flex;flex-direction:column;gap:8px}
.event-item{display:grid;grid-template-columns:145px 75px 1fr;gap:12px;align-items:center;background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:10px 16px;font-size:.82rem}
.ev-ts{font-family:var(--mono);color:var(--text3);font-size:.72rem}
.ev-kind{font-size:.7rem;font-weight:700;padding:2px 8px;border-radius:4px;text-align:center;text-transform:uppercase;letter-spacing:.5px}
.ev-kind.up{background:var(--green-dim);color:var(--green)}.ev-kind.down{background:var(--red-dim);color:var(--red)}
.ev-kind.system{background:#3b82f622;color:var(--blue)}.ev-kind.error,.ev-kind.telegram_error{background:var(--yellow-dim);color:var(--yellow)}
.ev-msg{color:var(--text2)}.ev-server{color:var(--text);font-weight:600}
.settings-grid{display:grid;grid-template-columns:1fr 1fr;gap:24px}
.settings-section{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:24px}
.settings-section.full{grid-column:1/-1}
.section-title{font-size:.72rem;font-weight:700;color:var(--text3);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:20px;padding-bottom:12px;border-bottom:1px solid var(--border)}
.field{margin-bottom:16px}.field label{display:block;font-size:.78rem;color:var(--text2);margin-bottom:6px;font-weight:600}
.field input,.field textarea{width:100%;background:var(--bg3);border:1px solid var(--border2);border-radius:8px;padding:10px 14px;color:var(--text);font-family:var(--mono);font-size:.83rem;outline:none;transition:border-color .15s;resize:vertical}
.field input:focus,.field textarea:focus{border-color:var(--green);box-shadow:0 0 0 3px var(--green-dim)}
.field-hint{font-size:.7rem;color:var(--text3);margin-top:5px}
.btn{display:inline-flex;align-items:center;gap:7px;padding:9px 18px;border-radius:8px;border:none;font-family:var(--sans);font-size:.83rem;font-weight:600;cursor:pointer;transition:all .15s}
.btn-primary{background:var(--green);color:#0a0c0f}.btn-primary:hover{background:#00ffb3;transform:translateY(-1px)}
.btn-secondary{background:var(--bg3);color:var(--text2);border:1px solid var(--border2)}.btn-secondary:hover{color:var(--text);border-color:var(--text3)}
.btn-row{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
.toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(80px);background:var(--bg3);border:1px solid var(--border2);border-radius:10px;padding:12px 20px;font-size:.83rem;color:var(--text);z-index:999;transition:transform .3s cubic-bezier(.175,.885,.32,1.275);box-shadow:0 8px 32px #0008}
.toast.show{transform:translateX(-50%) translateY(0)}.toast.success{border-color:var(--green);color:var(--green)}.toast.error{border-color:var(--red);color:var(--red)}
.header-actions{display:flex;align-items:center;gap:12px;margin-bottom:24px;justify-content:space-between}
.refresh-btn{background:var(--bg3);border:1px solid var(--border2);border-radius:8px;color:var(--text2);padding:7px 14px;font-size:.8rem;font-family:var(--sans);font-weight:600;cursor:pointer;display:flex;align-items:center;gap:7px;transition:all .15s}
.refresh-btn:hover{color:var(--green);border-color:var(--green)}
.spinning{animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}
@media(max-width:900px){.layout{grid-template-columns:1fr}.sidebar{display:none}.cards{grid-template-columns:1fr 1fr}.settings-grid{grid-template-columns:1fr}.event-item{grid-template-columns:100px 60px 1fr}}
</style>
</head>
<body>
<div class="layout">
  <aside class="sidebar">
    <div class="logo"><div class="logo-mark">▣ VLESS</div><div class="logo-sub">Monitor Panel</div></div>
    <nav>
      <button class="nav-item active" onclick="showPage('dashboard',this)">
        <svg class="nav-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1" stroke-width="2"/><rect x="14" y="3" width="7" height="7" rx="1" stroke-width="2"/><rect x="3" y="14" width="7" height="7" rx="1" stroke-width="2"/><rect x="14" y="14" width="7" height="7" rx="1" stroke-width="2"/></svg>Dashboard
      </button>
      <button class="nav-item" onclick="showPage('events',this)">
        <svg class="nav-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" stroke-linecap="round" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg>Events
      </button>
      <button class="nav-item" onclick="showPage('settings',this)">
        <svg class="nav-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3" stroke-width="2"/><path stroke-width="2" d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>Settings
      </button>
    </nav>
    <div class="sidebar-footer"><div class="last-check" id="lastCheckTime">Last check: —</div></div>
  </aside>
  <main>
    <!-- Dashboard -->
    <div class="page active" id="page-dashboard">
      <div class="header-actions">
        <h2><svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1" stroke-width="2"/><rect x="14" y="3" width="7" height="7" rx="1" stroke-width="2"/><rect x="3" y="14" width="7" height="7" rx="1" stroke-width="2"/><rect x="14" y="14" width="7" height="7" rx="1" stroke-width="2"/></svg>Server Status</h2>
        <button class="refresh-btn" id="checkNowBtn" onclick="checkNow()"><svg id="checkIcon" width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24"><polyline stroke-width="2.5" points="23 4 23 10 17 10"/><path stroke-width="2.5" d="M20.49 15a9 9 0 11-2.12-9.36L23 10"/></svg>Check Now</button>
      </div>
      <div class="cards">
        <div class="card blue"><div class="card-label">Total Servers</div><div class="card-value" id="totalCount">—</div></div>
        <div class="card green"><div class="card-label">Online</div><div class="card-value" id="upCount">—</div></div>
        <div class="card red"><div class="card-label">Offline</div><div class="card-value" id="downCount">—</div></div>
      </div>
      <div class="server-grid" id="serverGrid"><div class="empty"><div class="empty-icon">📡</div><div class="empty-text">No servers added yet. Go to Settings and add your VLESS links.</div></div></div>
    </div>
    <!-- Events -->
    <div class="page" id="page-events">
      <h2><svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" stroke-linecap="round" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg>Events<span class="badge" id="eventCount">0</span></h2>
      <div class="event-list" id="eventList"><div class="empty"><div class="empty-icon">📋</div><div class="empty-text">No events recorded yet.</div></div></div>
    </div>
    <!-- Settings -->
    <div class="page" id="page-settings">
      <h2><svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3" stroke-width="2"/><path stroke-width="2" d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>Settings</h2>
      <div class="settings-grid">
        <div class="settings-section">
          <div class="section-title">Telegram</div>
          <div class="field"><label>Bot Token</label><input type="text" id="tgToken" placeholder="1234567890:AAH..."><div class="field-hint">Get it from @BotFather</div></div>
          <div class="field"><label>Chat ID</label><input type="text" id="tgChatId" placeholder="-100xxxxxxxxxx or @username"><div class="field-hint">Get it from @userinfobot</div></div>
          <button class="btn btn-secondary" onclick="testTelegram()">📨 Send Test Message</button>
        </div>
        <div class="settings-section">
          <div class="section-title">Timing</div>
          <div class="field"><label>Check Interval (seconds)</label><input type="number" id="cfgInterval" value="300" min="30"><div class="field-hint">Minimum 30 seconds</div></div>
          <div class="field"><label>Connection Timeout (seconds)</label><input type="number" id="cfgTimeout" value="10" min="3"></div>
        </div>
        <div class="settings-section full">
          <div class="section-title">VLESS Links — one per line</div>
          <div class="field"><textarea id="cfgLinks" rows="8" placeholder="vless://uuid@host:443?type=ws&security=tls#Server1&#10;vless://uuid@host2:443?type=ws&security=tls#Server2"></textarea></div>
          <div class="btn-row"><button class="btn btn-primary" onclick="saveConfig()">💾 Save Settings</button></div>
        </div>
      </div>
    </div>
  </main>
</div>
<div class="toast" id="toast"></div>
<script>
function showPage(name,btn){document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.querySelectorAll('.nav-item').forEach(b=>b.classList.remove('active'));document.getElementById('page-'+name).classList.add('active');btn.classList.add('active');if(name==='events')loadEvents();if(name==='settings')loadConfig()}
function toast(msg,type='success'){const t=document.getElementById('toast');t.textContent=msg;t.className=`toast ${type} show`;setTimeout(()=>t.classList.remove('show'),3000)}
async function loadStatus(){try{const r=await fetch('/api/status');const{servers,summary}=await r.json();document.getElementById('totalCount').textContent=summary.total;document.getElementById('upCount').textContent=summary.up;document.getElementById('downCount').textContent=summary.down;const grid=document.getElementById('serverGrid');if(!servers.length){grid.innerHTML='<div class="empty"><div class="empty-icon">📡</div><div class="empty-text">No servers added yet. Go to Settings and add your VLESS links.</div></div>';return}grid.innerHTML=servers.map(s=>{const st=s.ok?'up':'down';const fp=s.ok?Math.max(4,Math.min(100,(s.latency/1000)*100)):0;const lc=s.latency<150?'var(--green)':s.latency<400?'var(--yellow)':'var(--red)';return`<div class="server-card ${st}"><div class="sc-header"><div class="sc-name">${esc(s.name)}</div><div class="sc-status ${st}"><span class="pulse ${st}"></span>${s.ok?'Online':'Offline'}</div></div><div class="sc-meta" style="margin-bottom:4px">${esc(s.host)}:${s.port}</div>${s.ok?`<div class="sc-latency"><div class="latency-bar"><div class="latency-fill" style="width:${fp}%;background:${lc}"></div></div><span class="latency-val">${s.latency}ms</span></div>`:`<div class="sc-meta" style="color:var(--red);margin-top:6px">Connection failed — ${s.latency}ms</div>`}<div class="sc-ts">${s.ts||'—'}</div></div>`}).join('');document.getElementById('lastCheckTime').textContent='Last check: '+new Date().toLocaleTimeString()}catch(e){console.error(e)}}
async function checkNow(){const btn=document.getElementById('checkNowBtn');const icon=document.getElementById('checkIcon');btn.disabled=true;icon.classList.add('spinning');try{await fetch('/api/check_now',{method:'POST'});toast('Check started...');setTimeout(loadStatus,2000)}finally{btn.disabled=false;icon.classList.remove('spinning')}}
async function loadEvents(){try{const r=await fetch('/api/events?limit=100');const events=await r.json();document.getElementById('eventCount').textContent=events.length;const list=document.getElementById('eventList');if(!events.length){list.innerHTML='<div class="empty"><div class="empty-icon">📋</div><div class="empty-text">No events recorded yet.</div></div>';return}const kl={up:'UP',down:'DOWN',system:'SYSTEM',error:'ERROR',telegram_error:'TG ERR'};list.innerHTML=events.map(e=>`<div class="event-item"><span class="ev-ts">${e.ts}</span><span class="ev-kind ${e.kind}">${kl[e.kind]||e.kind}</span><span class="ev-msg">${e.server?`<span class="ev-server">${esc(e.server)}</span> — `:''}${esc(e.message)}</span></div>`).join('')}catch(err){console.error(err)}}
async function loadConfig(){try{const r=await fetch('/api/config');const cfg=await r.json();document.getElementById('tgToken').value=cfg.telegram_token||'';document.getElementById('tgChatId').value=cfg.telegram_chat_id||'';document.getElementById('cfgInterval').value=cfg.interval||300;document.getElementById('cfgTimeout').value=cfg.timeout||10;document.getElementById('cfgLinks').value=(cfg.links||[]).join('\n')}catch(e){console.error(e)}}
async function saveConfig(){const links=document.getElementById('cfgLinks').value.trim().split('\n').filter(Boolean);const body={telegram_token:document.getElementById('tgToken').value.trim(),telegram_chat_id:document.getElementById('tgChatId').value.trim(),interval:parseInt(document.getElementById('cfgInterval').value)||300,timeout:parseInt(document.getElementById('cfgTimeout').value)||10,links};try{await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});toast('Settings saved')}catch(e){toast('Save failed','error')}}
async function testTelegram(){await saveConfig();try{await fetch('/api/test_telegram',{method:'POST'});toast('Test message sent!')}catch(e){toast('Send failed','error')}}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
loadStatus();setInterval(loadStatus,15000);
</script>
</body>
</html>
HTMLEOF
step "Web panel written"

# ── 5. Default config ────────────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/config.json" ]; then
  echo '{"telegram_token":"","telegram_chat_id":"","interval":300,"timeout":10,"links":[]}' \
    > "$INSTALL_DIR/config.json"
fi

# ── 6. Verify packages ───────────────────────────────────────────────────────
info "Verifying Python packages..."
python3 -c "import flask, requests" 2>/dev/null || die "Flask or Requests not found. Check apt mirror."
step "Python packages verified"

# ── 7. Systemd service ────────────────────────────────────────────────────────
info "Installing systemd service..."
cat > /etc/systemd/system/${SERVICE}.service << EOF
[Unit]
Description=VLESS Monitor Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 monitor.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" --quiet
systemctl restart "$SERVICE"
step "Service enabled and started"

# ── 8. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  ufw allow "$PORT/tcp" comment "VLESS Monitor" > /dev/null 2>&1 || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║      Installation complete!              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Web Panel:  ${CYAN}http://$IP:$PORT${NC}"
echo ""
echo "  Useful commands:"
echo "    systemctl status $SERVICE"
echo "    journalctl -u $SERVICE -f"
echo "    systemctl restart $SERVICE"
echo ""
echo -e "  ${YELLOW}Open the panel and configure Telegram & VLESS links in Settings.${NC}"
echo ""
