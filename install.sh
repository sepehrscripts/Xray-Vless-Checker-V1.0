#!/bin/bash
# ═══════════════════════════════════════════════════════
#   VLESS Monitor v3
#   bash <(curl -Ls https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh)
# ═══════════════════════════════════════════════════════

INSTALL_DIR="/opt/vless-monitor"
SERVICE="vless-monitor"
XRAY_SERVICE="vless-monitor-xray"
PORT=5000
XRAY_SOCKS_PORT=10808
XRAY_DIR="$INSTALL_DIR/xray"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step() { echo -e "  ${GREEN}[+]${NC} $1"; }
info() { echo -e "  ${YELLOW}[~]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $1"; }
die()  { echo -e "  ${RED}[✗]${NC} $1"; exit 1; }
banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║        ▣  VLESS Monitor v3               ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${NC}"
}

[ "$EUID" -ne 0 ] && die "Run as root or with sudo."

# ══════════════════════════════════════════════════════
#  CLI MENU  (when called with argument)
# ══════════════════════════════════════════════════════
if [ "$1" = "menu" ]; then
  while true; do
    banner
    echo -e "  ${BOLD}Management Menu${NC}\n"
    echo "   1) Status"
    echo "   2) Start"
    echo "   3) Stop"
    echo "   4) Restart"
    echo "   5) Live Logs"
    echo "   6) Update (re-run installer)"
    echo "   7) Uninstall"
    echo "   8) Exit"
    echo ""
    read -rp "  Choose [1-8]: " choice
    case $choice in
      1)
        echo ""
        systemctl status $SERVICE --no-pager
        [ -f /etc/systemd/system/${XRAY_SERVICE}.service ] && systemctl status $XRAY_SERVICE --no-pager
        read -rp "  Press Enter..." ;;
      2)
        systemctl start $SERVICE
        [ -f /etc/systemd/system/${XRAY_SERVICE}.service ] && systemctl start $XRAY_SERVICE
        echo -e "  ${GREEN}Started.${NC}"; sleep 1 ;;
      3)
        systemctl stop $SERVICE
        [ -f /etc/systemd/system/${XRAY_SERVICE}.service ] && systemctl stop $XRAY_SERVICE
        echo -e "  ${YELLOW}Stopped.${NC}"; sleep 1 ;;
      4)
        systemctl restart $SERVICE
        [ -f /etc/systemd/system/${XRAY_SERVICE}.service ] && systemctl restart $XRAY_SERVICE
        echo -e "  ${GREEN}Restarted.${NC}"; sleep 1 ;;
      5)
        echo -e "  ${YELLOW}Press Ctrl+C to exit logs${NC}"
        journalctl -u $SERVICE -f ;;
      6)
        echo -e "  ${CYAN}Re-running installer...${NC}"
        bash <(curl -Ls https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh)
        exit 0 ;;
      7)
        echo ""
        read -rp "  Are you sure you want to uninstall? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          systemctl stop $SERVICE 2>/dev/null || true
          systemctl disable $SERVICE 2>/dev/null || true
          systemctl stop $XRAY_SERVICE 2>/dev/null || true
          systemctl disable $XRAY_SERVICE 2>/dev/null || true
          rm -f /etc/systemd/system/${SERVICE}.service
          rm -f /etc/systemd/system/${XRAY_SERVICE}.service
          systemctl daemon-reload
          rm -rf "$INSTALL_DIR"
          rm -f /usr/local/bin/vless-monitor
          echo -e "  ${GREEN}Uninstalled successfully.${NC}"
          exit 0
        fi ;;
      8) exit 0 ;;
      *) warn "Invalid choice." ; sleep 1 ;;
    esac
  done
fi

# ══════════════════════════════════════════════════════
#  INSTALLER
# ══════════════════════════════════════════════════════
banner
echo -e "  Installing VLESS Monitor v3...\n"

# ── Remove old installation ───────────────────────────
if systemctl is-active --quiet $SERVICE 2>/dev/null; then
  info "Stopping existing service..."
  systemctl stop $SERVICE 2>/dev/null || true
  systemctl disable $SERVICE 2>/dev/null || true
  systemctl stop $XRAY_SERVICE 2>/dev/null || true
  systemctl disable $XRAY_SERVICE 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE}.service
  rm -f /etc/systemd/system/${XRAY_SERVICE}.service
  systemctl daemon-reload
fi

# ── System deps ───────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq python3 python3-flask python3-requests iputils-ping curl unzip
step "Packages installed"

# ── Directories ───────────────────────────────────────
mkdir -p "$INSTALL_DIR/templates" "$XRAY_DIR"
step "Directories ready"

# ── Download Xray-core ────────────────────────────────
info "Downloading Xray-core..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  XRAY_ARCH="64" ;;
  aarch64) XRAY_ARCH="arm64-v8a" ;;
  armv7l)  XRAY_ARCH="arm32-v7a" ;;
  *)       XRAY_ARCH="64" ;;
esac

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
if curl -sL --max-time 30 "$XRAY_URL" -o /tmp/xray.zip 2>/dev/null; then
  unzip -qo /tmp/xray.zip -d "$XRAY_DIR" xray
  chmod +x "$XRAY_DIR/xray"
  rm /tmp/xray.zip
  step "Xray-core downloaded"
else
  warn "Could not download Xray-core. VLESS proxy feature will be unavailable."
  warn "You can still use SOCKS5/HTTP proxy for Telegram."
fi

# ── monitor.py ────────────────────────────────────────
info "Writing monitor.py..."
cat > "$INSTALL_DIR/monitor.py" << 'PYEOF'
#!/usr/bin/env python3
import json, socket, time, threading, urllib.parse, subprocess, os
from datetime import datetime
from pathlib import Path
import requests
from flask import Flask, jsonify, render_template, request

BASE_DIR    = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "config.json"
LOG_FILE    = BASE_DIR / "events.json"
XRAY_BIN    = BASE_DIR / "xray" / "xray"
XRAY_CFG    = BASE_DIR / "xray" / "config.json"
SOCKS_PORT  = 10808

DEFAULT_CONFIG = {
    "telegram_token": "", "telegram_chat_id": "",
    "proxy_mode":    "none",   # none | socks5 | http | vless
    "proxy_host":    "", "proxy_port": "",
    "proxy_user":    "", "proxy_pass": "",
    "vless_link":    "",
    "interval": 300, "timeout": 10, "links": []
}

state_lock   = threading.Lock()
server_state = {}
event_log    = []
xray_proc    = None

# ── Config ────────────────────────────────────────────
def load_config():
    if CONFIG_FILE.exists():
        try:
            cfg = DEFAULT_CONFIG.copy()
            cfg.update(json.loads(CONFIG_FILE.read_text()))
            return cfg
        except: pass
    return DEFAULT_CONFIG.copy()

def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))

def load_events():
    global event_log
    if LOG_FILE.exists():
        try: event_log = json.loads(LOG_FILE.read_text())[-500:]
        except: event_log = []

def save_events():
    LOG_FILE.write_text(json.dumps(event_log[-500:], ensure_ascii=False, indent=2))

def log_event(kind, message, server=""):
    entry = {"ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
             "kind": kind, "server": server, "message": message}
    with state_lock: event_log.append(entry)
    save_events()

# ── Xray / VLESS proxy ───────────────────────────────
def parse_vless_link(link):
    try:
        p = urllib.parse.urlparse(link)
        if p.scheme != "vless": return None
        qs = urllib.parse.parse_qs(p.query)
        return {
            "id":       p.username,
            "address":  p.hostname,
            "port":     p.port or 443,
            "network":  qs.get("type",["tcp"])[0],
            "security": qs.get("security",["none"])[0],
            "sni":      qs.get("sni",[p.hostname])[0],
            "path":     qs.get("path",["/"])[0],
            "host":     qs.get("host",[p.hostname])[0],
        }
    except: return None

def build_xray_config(vless):
    return {
        "inbounds": [{
            "port": SOCKS_PORT, "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True}
        }],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{
                "address": vless["address"], "port": vless["port"],
                "users": [{"id": vless["id"], "encryption": "none"}]
            }]},
            "streamSettings": {
                "network":  vless["network"],
                "security": vless["security"],
                "tlsSettings": {"serverName": vless["sni"]} if vless["security"] in ("tls","reality") else {},
                "wsSettings": {"path": vless["path"], "headers": {"Host": vless["host"]}}
                               if vless["network"] == "ws" else {}
            }
        }]
    }

def start_xray(vless_link):
    global xray_proc
    stop_xray()
    if not XRAY_BIN.exists():
        log_event("error", "Xray binary not found"); return False
    v = parse_vless_link(vless_link)
    if not v:
        log_event("error", "Invalid VLESS link for proxy"); return False
    XRAY_CFG.write_text(json.dumps(build_xray_config(v), indent=2))
    try:
        xray_proc = subprocess.Popen(
            [str(XRAY_BIN), "run", "-c", str(XRAY_CFG)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        time.sleep(1.5)
        if xray_proc.poll() is None:
            log_event("system", f"Xray started — SOCKS5 on 127.0.0.1:{SOCKS_PORT}")
            return True
        log_event("error", "Xray process exited immediately")
    except Exception as e:
        log_event("error", f"Xray start failed: {e}")
    return False

def stop_xray():
    global xray_proc
    if xray_proc and xray_proc.poll() is None:
        xray_proc.terminate()
        try: xray_proc.wait(timeout=3)
        except: xray_proc.kill()
    xray_proc = None

def build_proxies(cfg):
    mode = cfg.get("proxy_mode", "none")
    if mode == "none": return None
    if mode == "vless":
        url = f"socks5://127.0.0.1:{SOCKS_PORT}"
        return {"http": url, "https": url}
    host = cfg.get("proxy_host","")
    port = cfg.get("proxy_port","")
    if not host or not port: return None
    user = cfg.get("proxy_user",""); pw = cfg.get("proxy_pass","")
    auth = f"{user}:{pw}@" if user else ""
    url  = f"{mode}://{auth}{host}:{port}"
    return {"http": url, "https": url}

# ── Checks ────────────────────────────────────────────
def check_tcp(host, port, timeout):
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, round((time.perf_counter()-t0)*1000, 1)
    except:
        return False, round((time.perf_counter()-t0)*1000, 1)

def check_icmp(host):
    try:
        r = subprocess.run(["ping","-c","1","-W","3",host],
                           capture_output=True, timeout=5)
        if r.returncode == 0:
            for part in r.stdout.decode().split():
                if "time=" in part:
                    return True, round(float(part.replace("time=","")),1)
            return True, 0.0
        return False, 0.0
    except: return False, 0.0

def check_http(timeout):
    t0 = time.perf_counter()
    try:
        r = requests.get("http://www.gstatic.com/generate_204",
                         timeout=timeout, allow_redirects=False)
        return r.status_code==204, round((time.perf_counter()-t0)*1000,1)
    except: return False, round((time.perf_counter()-t0)*1000,1)

def get_location(host):
    try:
        r = requests.get(
            f"http://ip-api.com/json/{host}?fields=status,country,countryCode,city,isp,query",
            timeout=5)
        d = r.json()
        if d.get("status")=="success":
            return {"ip":d.get("query",""),"country":d.get("country",""),
                    "cc":d.get("countryCode",""),"city":d.get("city",""),"isp":d.get("isp","")}
    except: pass
    return {}

def send_telegram(token, chat_id, text, proxies=None):
    if not token or not chat_id: return
    try:
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
            json={"chat_id":chat_id,"text":text,"parse_mode":"HTML"},
            timeout=15, proxies=proxies)
    except Exception as e:
        log_event("telegram_error", str(e))

# ── Main check ────────────────────────────────────────
def parse_server_vless(link):
    try:
        p = urllib.parse.urlparse(link)
        if p.scheme != "vless": return None
        name = urllib.parse.unquote(p.fragment) or f"{p.hostname}:{p.port}"
        return {"name": name, "host": p.hostname, "port": p.port or 443}
    except: return None

def run_checks():
    cfg     = load_config()
    timeout = cfg.get("timeout", 10)
    proxies = build_proxies(cfg)
    failed  = []

    for link in cfg.get("links", []):
        srv = parse_server_vless(link)
        if not srv: continue
        host, port = srv["host"], srv["port"]

        tcp_ok,  tcp_ms  = check_tcp(host, port, timeout)
        icmp_ok, icmp_ms = check_icmp(host)
        http_ok, http_ms = check_http(timeout)

        loc = get_location(host) if tcp_ok else {}

        result = {
            "name": srv["name"], "host": host, "port": port,
            "ok":   tcp_ok,
            "tcp":    {"ok": tcp_ok,  "ms": tcp_ms},
            "icmp":   {"ok": icmp_ok, "ms": icmp_ms},
            "http204":{"ok": http_ok, "ms": http_ms},
            "location": loc,
            "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        }

        with state_lock:
            prev = server_state.get(srv["name"], {})
            server_state[srv["name"]] = result

        was_ok = prev.get("ok", True)
        if not tcp_ok and was_ok:
            log_event("down", f"DOWN — TCP:{tcp_ms}ms ICMP:{'OK' if icmp_ok else 'FAIL'}", srv["name"])
            failed.append(result)
        elif tcp_ok and not was_ok:
            log_event("up", f"UP — TCP:{tcp_ms}ms", srv["name"])

    if failed:
        lines = ["🚨 <b>Server(s) Unreachable</b>\n"]
        for s in failed:
            loc = s["location"]
            lines += [
                f"• <b>{s['name']}</b>",
                f"  <code>{s['host']}:{s['port']}</code>",
                f"  TCP: {'✅' if s['tcp']['ok'] else '❌'} {s['tcp']['ms']}ms | "
                f"ICMP: {'✅' if s['icmp']['ok'] else '❌'} {s['icmp']['ms']}ms | "
                f"HTTP: {'✅' if s['http204']['ok'] else '❌'} {s['http204']['ms']}ms",
                f"  📍 {loc.get('city','')}, {loc.get('country','Unknown')} — {loc.get('isp','')}\n",
            ]
        lines.append(f"🕐 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        send_telegram(cfg["telegram_token"], cfg["telegram_chat_id"], "\n".join(lines), proxies)

def monitor_loop():
    load_events()
    log_event("system", "Monitor v3 started")
    cfg = load_config()
    if cfg.get("proxy_mode") == "vless" and cfg.get("vless_link"):
        start_xray(cfg["vless_link"])
    while True:
        try: run_checks()
        except Exception as e: log_event("error", str(e))
        time.sleep(load_config().get("interval", 300))

# ── Flask ─────────────────────────────────────────────
app = Flask(__name__)

@app.route("/")
def index(): return render_template("index.html")

@app.route("/api/status")
def api_status():
    with state_lock: servers = list(server_state.values())
    total = len(servers); up = sum(1 for s in servers if s["ok"])
    return jsonify({"servers":servers,"summary":{"total":total,"up":up,"down":total-up}})

@app.route("/api/events")
def api_events():
    limit = int(request.args.get("limit",100))
    with state_lock: evts = event_log[-limit:][::-1]
    return jsonify(evts)

@app.route("/api/config", methods=["GET"])
def api_config_get():
    cfg = load_config(); m = cfg.copy()
    t = m.get("telegram_token","")
    if t: m["telegram_token"] = t[:6]+"***"+t[-4:] if len(t)>10 else "***"
    return jsonify(m)

@app.route("/api/config", methods=["POST"])
def api_config_post():
    data = request.json or {}; cfg = load_config()
    if "telegram_token" in data and "***" not in str(data["telegram_token"]):
        cfg["telegram_token"] = data["telegram_token"]
    for k in ["telegram_chat_id","proxy_mode","proxy_host","proxy_port",
              "proxy_user","proxy_pass","vless_link"]:
        if k in data: cfg[k] = data[k]
    if "interval" in data: cfg["interval"] = max(30, int(data["interval"]))
    if "timeout"  in data: cfg["timeout"]  = max(3,  int(data["timeout"]))
    if "links"    in data: cfg["links"]    = [l.strip() for l in data["links"] if l.strip()]
    save_config(cfg)

    # restart xray if vless mode
    if cfg.get("proxy_mode") == "vless" and cfg.get("vless_link"):
        threading.Thread(target=lambda: start_xray(cfg["vless_link"]), daemon=True).start()
    elif cfg.get("proxy_mode") != "vless":
        stop_xray()

    return jsonify({"ok": True})

@app.route("/api/check_now", methods=["POST"])
def api_check_now():
    threading.Thread(target=run_checks, daemon=True).start()
    return jsonify({"ok": True})

@app.route("/api/test_telegram", methods=["POST"])
def api_test_telegram():
    cfg = load_config(); proxies = build_proxies(cfg)
    send_telegram(cfg.get("telegram_token",""), cfg.get("telegram_chat_id",""),
                  "✅ <b>Test successful!</b>\nVLESS Monitor v3 is working correctly.", proxies)
    return jsonify({"ok": True})

@app.route("/api/xray_status")
def api_xray_status():
    running = xray_proc is not None and xray_proc.poll() is None
    return jsonify({"running": running, "port": SOCKS_PORT})

if __name__ == "__main__":
    threading.Thread(target=monitor_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5000, debug=False)
PYEOF
step "monitor.py written"

# ── index.html ────────────────────────────────────────
info "Writing web panel..."
cat > "$INSTALL_DIR/templates/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VLESS Monitor</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Inter:wght@300;400;600;700&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root[data-theme="dark"]{--bg:#0a0c0f;--bg2:#111318;--bg3:#181c23;--bg4:#1e2330;--border:#1e2330;--border2:#252b3a;--green:#00e5a0;--green-dim:#00e5a018;--red:#ff3b5c;--red-dim:#ff3b5c18;--yellow:#ffc043;--yellow-dim:#ffc04318;--blue:#3b82f6;--blue-dim:#3b82f618;--text:#e2e8f0;--text2:#8892a4;--text3:#4a5568;--shadow:0 4px 24px #0006}
:root[data-theme="light"]{--bg:#f0f2f5;--bg2:#ffffff;--bg3:#f8f9fb;--bg4:#eef0f4;--border:#e2e6ed;--border2:#d0d5de;--green:#00a572;--green-dim:#00a57215;--red:#d9264a;--red-dim:#d9264a15;--yellow:#c4880a;--yellow-dim:#c4880a15;--blue:#2563eb;--blue-dim:#2563eb15;--text:#1a202c;--text2:#4a5568;--text3:#a0aec0;--shadow:0 4px 24px #0001}
:root{--mono:'JetBrains Mono',monospace;--sans:'Inter',sans-serif}
html{font-size:14px}body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;transition:background .2s,color .2s}
.layout{display:grid;grid-template-columns:240px 1fr;min-height:100vh}
.sidebar{background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:24px 0;position:sticky;top:0;height:100vh;overflow-y:auto}
.logo{padding:0 24px 24px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.logo-mark{font-family:var(--mono);font-size:1.2rem;font-weight:700;color:var(--green)}
.logo-sub{font-size:.65rem;color:var(--text3);margin-top:3px;letter-spacing:2px;text-transform:uppercase}
.theme-btn{background:var(--bg3);border:1px solid var(--border2);border-radius:8px;width:34px;height:34px;cursor:pointer;display:flex;align-items:center;justify-content:center;color:var(--text2);transition:all .15s;flex-shrink:0}
.theme-btn:hover{color:var(--yellow);border-color:var(--yellow)}
nav{padding:16px 12px;flex:1}
.nav-item{display:flex;align-items:center;gap:10px;padding:10px 14px;border-radius:8px;cursor:pointer;color:var(--text2);font-size:.85rem;font-weight:600;transition:all .15s;margin-bottom:3px;border:none;background:none;width:100%;text-align:left}
.nav-item:hover{background:var(--bg3);color:var(--text)}.nav-item.active{background:var(--green-dim);color:var(--green)}
.nav-icon{width:16px;height:16px;flex-shrink:0}
.sidebar-footer{padding:16px 24px;border-top:1px solid var(--border)}
.last-check{font-size:.68rem;color:var(--text3);font-family:var(--mono)}
main{padding:28px 32px;overflow-y:auto}
.page{display:none}.page.active{display:block}
h2{font-size:1.05rem;font-weight:700;margin-bottom:22px;display:flex;align-items:center;gap:10px}
.badge{font-size:.65rem;font-family:var(--mono);background:var(--bg3);border:1px solid var(--border2);padding:2px 8px;border-radius:20px;color:var(--text3)}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-bottom:28px}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:18px 22px;position:relative;overflow:hidden;box-shadow:var(--shadow)}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px}
.card.green::before{background:var(--green)}.card.red::before{background:var(--red)}.card.blue::before{background:var(--blue)}
.card-label{font-size:.66rem;color:var(--text3);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:8px}
.card-value{font-size:2rem;font-weight:700;font-family:var(--mono);line-height:1}
.card.green .card-value{color:var(--green)}.card.red .card-value{color:var(--red)}.card.blue .card-value{color:var(--blue)}
.server-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
.server-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:18px 20px;transition:transform .15s,border-color .2s;position:relative;overflow:hidden;box-shadow:var(--shadow)}
.server-card:hover{transform:translateY(-2px)}
.server-card.up{border-color:color-mix(in srgb,var(--green) 25%,transparent)}
.server-card.down{border-color:color-mix(in srgb,var(--red) 25%,transparent)}
.server-card.down::after{content:'';position:absolute;inset:0;background:var(--red-dim);pointer-events:none}
.sc-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px;gap:8px}
.sc-name{font-weight:700;font-size:.9rem;word-break:break-all}
.sc-badge{display:flex;align-items:center;gap:5px;font-size:.7rem;font-weight:700;padding:3px 10px;border-radius:20px;white-space:nowrap;flex-shrink:0}
.sc-badge.up{background:var(--green-dim);color:var(--green)}.sc-badge.down{background:var(--red-dim);color:var(--red)}
.pulse{width:6px;height:6px;border-radius:50%}
.pulse.up{background:var(--green);animation:ping 1.5s infinite}.pulse.down{background:var(--red)}
@keyframes ping{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--green) 60%,transparent)}70%{box-shadow:0 0 0 6px transparent}100%{box-shadow:0 0 0 0 transparent}}
.check-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px;margin:10px 0}
.check-item{background:var(--bg3);border:1px solid var(--border);border-radius:7px;padding:7px 10px}
.check-label{font-size:.6rem;color:var(--text3);text-transform:uppercase;letter-spacing:1px;margin-bottom:3px}
.check-val{font-family:var(--mono);font-size:.78rem;font-weight:600}
.check-val.ok{color:var(--green)}.check-val.fail{color:var(--red)}
.loc-row{display:flex;align-items:center;gap:6px;margin-top:8px;font-size:.75rem;color:var(--text2);flex-wrap:wrap}
.sc-ts{font-size:.66rem;color:var(--text3);margin-top:8px}
.event-list{display:flex;flex-direction:column;gap:6px}
.event-item{display:grid;grid-template-columns:148px 70px 1fr;gap:10px;align-items:center;background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:9px 14px;font-size:.8rem}
.ev-ts{font-family:var(--mono);color:var(--text3);font-size:.7rem}
.ev-kind{font-size:.68rem;font-weight:700;padding:2px 7px;border-radius:4px;text-align:center;text-transform:uppercase;letter-spacing:.5px}
.ev-kind.up{background:var(--green-dim);color:var(--green)}.ev-kind.down{background:var(--red-dim);color:var(--red)}
.ev-kind.system{background:var(--blue-dim);color:var(--blue)}.ev-kind.error,.ev-kind.telegram_error{background:var(--yellow-dim);color:var(--yellow)}
.ev-msg{color:var(--text2)}.ev-server{color:var(--text);font-weight:600}
.settings-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}
.s-box{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:22px;box-shadow:var(--shadow)}
.s-box.full{grid-column:1/-1}
.s-title{font-size:.7rem;font-weight:700;color:var(--text3);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:18px;padding-bottom:10px;border-bottom:1px solid var(--border)}
.field{margin-bottom:14px}.field label{display:block;font-size:.77rem;color:var(--text2);margin-bottom:5px;font-weight:600}
.field input,.field textarea,.field select{width:100%;background:var(--bg3);border:1px solid var(--border2);border-radius:8px;padding:9px 13px;color:var(--text);font-family:var(--mono);font-size:.83rem;outline:none;transition:border-color .15s;resize:vertical}
.field input:focus,.field textarea:focus,.field select:focus{border-color:var(--green);box-shadow:0 0 0 3px var(--green-dim)}
.field-hint{font-size:.68rem;color:var(--text3);margin-top:4px}
.interval-row{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-bottom:10px}
.int-btn{background:var(--bg3);border:1px solid var(--border2);border-radius:7px;padding:7px 4px;font-size:.78rem;font-family:var(--mono);font-weight:600;cursor:pointer;color:var(--text2);transition:all .15s;text-align:center}
.int-btn:hover,.int-btn.active{background:var(--green-dim);border-color:var(--green);color:var(--green)}

/* Proxy mode tabs */
.mode-tabs{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
.mode-tab{padding:6px 14px;border-radius:7px;border:1px solid var(--border2);background:var(--bg3);color:var(--text2);font-size:.78rem;font-weight:600;cursor:pointer;transition:all .15s}
.mode-tab:hover{color:var(--text);border-color:var(--text3)}
.mode-tab.active{background:var(--green-dim);border-color:var(--green);color:var(--green)}
.proxy-panel{display:none}.proxy-panel.show{display:block}

/* Xray status pill */
.xray-status{display:inline-flex;align-items:center;gap:6px;font-size:.75rem;font-weight:600;padding:4px 12px;border-radius:20px;margin-bottom:14px}
.xray-status.on{background:var(--green-dim);color:var(--green)}.xray-status.off{background:var(--red-dim);color:var(--red)}

.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;border-radius:8px;border:none;font-family:var(--sans);font-size:.82rem;font-weight:600;cursor:pointer;transition:all .15s}
.btn-primary{background:var(--green);color:#0a0c0f}.btn-primary:hover{filter:brightness(1.1);transform:translateY(-1px)}
.btn-secondary{background:var(--bg3);color:var(--text2);border:1px solid var(--border2)}.btn-secondary:hover{color:var(--text);border-color:var(--text3)}
.btn-row{display:flex;gap:8px;flex-wrap:wrap;margin-top:18px}
.header-actions{display:flex;align-items:center;justify-content:space-between;margin-bottom:22px}
.action-btn{background:var(--bg3);border:1px solid var(--border2);border-radius:8px;color:var(--text2);padding:7px 13px;font-size:.79rem;font-family:var(--sans);font-weight:600;cursor:pointer;display:flex;align-items:center;gap:6px;transition:all .15s}
.action-btn:hover{color:var(--green);border-color:var(--green)}
.spin{animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}
.empty{text-align:center;padding:50px 20px;color:var(--text3)}
.empty-icon{font-size:2.2rem;margin-bottom:10px}.empty-text{font-size:.85rem}
.toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(80px);background:var(--bg2);border:1px solid var(--border2);border-radius:10px;padding:11px 20px;font-size:.83rem;color:var(--text);z-index:999;transition:transform .3s cubic-bezier(.175,.885,.32,1.275);box-shadow:var(--shadow)}
.toast.show{transform:translateX(-50%) translateY(0)}.toast.ok{border-color:var(--green);color:var(--green)}.toast.err{border-color:var(--red);color:var(--red)}
@media(max-width:900px){.layout{grid-template-columns:1fr}.sidebar{display:none}.cards{grid-template-columns:1fr 1fr}.settings-grid{grid-template-columns:1fr}.event-item{grid-template-columns:100px 55px 1fr}}
</style>
</head>
<body>
<div class="layout">
  <aside class="sidebar">
    <div class="logo">
      <div><div class="logo-mark">▣ VLESS</div><div class="logo-sub">Monitor v3</div></div>
      <button class="theme-btn" onclick="toggleTheme()" title="Toggle theme">
        <svg id="themeIcon" width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"/></svg>
      </button>
    </div>
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
    <div class="sidebar-footer"><div class="last-check" id="lastCheck">Last check: —</div></div>
  </aside>

  <main>
    <!-- Dashboard -->
    <div class="page active" id="page-dashboard">
      <div class="header-actions">
        <h2>Server Status</h2>
        <button class="action-btn" id="checkBtn" onclick="checkNow()">
          <svg id="checkIcon" width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24"><polyline stroke-width="2.5" points="23 4 23 10 17 10"/><path stroke-width="2.5" d="M20.49 15a9 9 0 11-2.12-9.36L23 10"/></svg>Check Now
        </button>
      </div>
      <div class="cards">
        <div class="card blue"><div class="card-label">Total</div><div class="card-value" id="cTotal">—</div></div>
        <div class="card green"><div class="card-label">Online</div><div class="card-value" id="cUp">—</div></div>
        <div class="card red"><div class="card-label">Offline</div><div class="card-value" id="cDown">—</div></div>
      </div>
      <div class="server-grid" id="serverGrid">
        <div class="empty"><div class="empty-icon">📡</div><div class="empty-text">No servers yet. Add VLESS links in Settings.</div></div>
      </div>
    </div>

    <!-- Events -->
    <div class="page" id="page-events">
      <div class="header-actions"><h2>Events <span class="badge" id="evCount">0</span></h2></div>
      <div class="event-list" id="eventList">
        <div class="empty"><div class="empty-icon">📋</div><div class="empty-text">No events yet.</div></div>
      </div>
    </div>

    <!-- Settings -->
    <div class="page" id="page-settings">
      <h2>Settings</h2>
      <div class="settings-grid">

        <div class="s-box">
          <div class="s-title">Telegram</div>
          <div class="field"><label>Bot Token</label><input type="text" id="tgToken" placeholder="1234567890:AAH..."><div class="field-hint">From @BotFather</div></div>
          <div class="field"><label>Chat ID</label><input type="text" id="tgChatId" placeholder="-100... or @username"><div class="field-hint">From @userinfobot</div></div>
          <button class="btn btn-secondary" onclick="testTg()">📨 Send Test</button>
        </div>

        <div class="s-box">
          <div class="s-title">Check Interval</div>
          <div class="interval-row">
            <button class="int-btn" onclick="setInt(60)">1 min</button>
            <button class="int-btn" onclick="setInt(300)">5 min</button>
            <button class="int-btn" onclick="setInt(900)">15 min</button>
            <button class="int-btn" onclick="setInt(1800)">30 min</button>
          </div>
          <div class="field"><label>Custom (seconds)</label><input type="number" id="cfgInterval" value="300" min="30" oninput="syncBtns()"></div>
          <div class="field"><label>Connection Timeout (seconds)</label><input type="number" id="cfgTimeout" value="10" min="3"></div>
        </div>

        <!-- Proxy -->
        <div class="s-box full">
          <div class="s-title">Telegram Proxy</div>
          <div class="mode-tabs">
            <button class="mode-tab active" onclick="setMode('none',this)">No Proxy</button>
            <button class="mode-tab" onclick="setMode('socks5',this)">SOCKS5</button>
            <button class="mode-tab" onclick="setMode('http',this)">HTTP</button>
            <button class="mode-tab" onclick="setMode('vless',this)">VLESS Link</button>
          </div>

          <!-- SOCKS5 / HTTP -->
          <div class="proxy-panel" id="panel-socks5">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
              <div class="field"><label>Host</label><input type="text" id="proxyHost" placeholder="127.0.0.1"></div>
              <div class="field"><label>Port</label><input type="number" id="proxyPort" placeholder="1080"></div>
              <div class="field"><label>Username <small style="font-weight:400;color:var(--text3)">(optional)</small></label><input type="text" id="proxyUser" placeholder="user"></div>
              <div class="field"><label>Password <small style="font-weight:400;color:var(--text3)">(optional)</small></label><input type="password" id="proxyPass" placeholder="pass"></div>
            </div>
          </div>
          <div class="proxy-panel" id="panel-http" style="display:none">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
              <div class="field"><label>Host</label><input type="text" id="proxyHostH" placeholder="proxy.example.com"></div>
              <div class="field"><label>Port</label><input type="number" id="proxyPortH" placeholder="8080"></div>
            </div>
          </div>

          <!-- VLESS -->
          <div class="proxy-panel" id="panel-vless" style="display:none">
            <div id="xrayPill" class="xray-status off">⬤ Xray not running</div>
            <div class="field">
              <label>VLESS Link (used only for sending Telegram messages)</label>
              <input type="text" id="vlessLink" placeholder="vless://uuid@host:443?type=ws&security=tls#MyProxy">
              <div class="field-hint">Xray-core will create a local SOCKS5 on port 10808 using this link.</div>
            </div>
          </div>

          <input type="hidden" id="proxyMode" value="none">
        </div>

        <!-- VLESS Links -->
        <div class="s-box full">
          <div class="s-title">VLESS Links to Monitor — one per line</div>
          <div class="field"><textarea id="cfgLinks" rows="8" placeholder="vless://uuid@host:443?type=ws&security=tls#Server1&#10;vless://uuid@host2:443?type=ws&security=tls#Server2"></textarea></div>
          <div class="btn-row">
            <button class="btn btn-primary" onclick="saveCfg()">💾 Save Settings</button>
          </div>
        </div>

      </div>
    </div>
  </main>
</div>
<div class="toast" id="toast"></div>
<script>
const MOON=`<path stroke-width="2" d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"/>`;
const SUN=`<circle cx="12" cy="12" r="5" stroke-width="2"/><g stroke-width="2" stroke-linecap="round"><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></g>`;
function applyTheme(t){document.documentElement.setAttribute('data-theme',t);document.getElementById('themeIcon').innerHTML=t==='dark'?MOON:SUN;localStorage.setItem('vt',t)}
function toggleTheme(){applyTheme(document.documentElement.getAttribute('data-theme')==='dark'?'light':'dark')}
applyTheme(localStorage.getItem('vt')||'dark');

function showPage(n,btn){document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.querySelectorAll('.nav-item').forEach(b=>b.classList.remove('active'));document.getElementById('page-'+n).classList.add('active');btn.classList.add('active');if(n==='events')loadEvents();if(n==='settings'){loadCfg();loadXrayStatus()}}
function toast(msg,type='ok'){const t=document.getElementById('toast');t.textContent=msg;t.className=`toast ${type} show`;setTimeout(()=>t.classList.remove('show'),3000)}
function esc(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function flagEmoji(cc){if(!cc||cc.length!==2)return'🌐';return String.fromCodePoint(...[...cc.toUpperCase()].map(c=>c.charCodeAt(0)+127397))}

// Proxy mode
function setMode(mode, btn){
  document.getElementById('proxyMode').value=mode;
  document.querySelectorAll('.mode-tab').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('.proxy-panel').forEach(p=>p.style.display='none');
  if(mode==='socks5') document.getElementById('panel-socks5').style.display='block';
  if(mode==='http')   document.getElementById('panel-http').style.display='block';
  if(mode==='vless')  {document.getElementById('panel-vless').style.display='block';loadXrayStatus();}
}

async function loadXrayStatus(){
  try{
    const d=await fetch('/api/xray_status').then(r=>r.json());
    const pill=document.getElementById('xrayPill');
    if(!pill)return;
    if(d.running){pill.className='xray-status on';pill.textContent=`⬤ Xray running — SOCKS5 :${d.port}`}
    else{pill.className='xray-status off';pill.textContent='⬤ Xray not running'}
  }catch(e){}
}

// Interval
function setInt(v){document.getElementById('cfgInterval').value=v;syncBtns()}
function syncBtns(){const v=parseInt(document.getElementById('cfgInterval').value)||0;const map={60:0,300:1,900:2,1800:3};document.querySelectorAll('.int-btn').forEach((b,i)=>b.classList.toggle('active',map[v]===i))}

// Dashboard
async function loadStatus(){
  try{
    const {servers,summary}=await fetch('/api/status').then(r=>r.json());
    document.getElementById('cTotal').textContent=summary.total;
    document.getElementById('cUp').textContent=summary.up;
    document.getElementById('cDown').textContent=summary.down;
    const grid=document.getElementById('serverGrid');
    if(!servers.length){grid.innerHTML='<div class="empty"><div class="empty-icon">📡</div><div class="empty-text">No servers yet. Add VLESS links in Settings.</div></div>';return}
    grid.innerHTML=servers.map(s=>{
      const st=s.ok?'up':'down';
      const loc=s.location||{};
      const flag=flagEmoji(loc.cc);
      const tcp=s.tcp||{};const icmp=s.icmp||{};const http=s.http204||{};
      return`<div class="server-card ${st}">
        <div class="sc-header"><div class="sc-name">${esc(s.name)}</div><div class="sc-badge ${st}"><span class="pulse ${st}"></span>${s.ok?'Online':'Offline'}</div></div>
        <div style="font-family:var(--mono);font-size:.74rem;color:var(--text3);margin-bottom:8px">${esc(s.host)}:${s.port}</div>
        <div class="check-grid">
          <div class="check-item"><div class="check-label">TCP</div><div class="check-val ${tcp.ok?'ok':'fail'}">${tcp.ok?'✓':'✗'} ${tcp.ms||0}ms</div></div>
          <div class="check-item"><div class="check-label">ICMP</div><div class="check-val ${icmp.ok?'ok':'fail'}">${icmp.ok?'✓':'✗'} ${icmp.ms||0}ms</div></div>
          <div class="check-item"><div class="check-label">HTTP 204</div><div class="check-val ${http.ok?'ok':'fail'}">${http.ok?'✓':'✗'} ${http.ms||0}ms</div></div>
        </div>
        <div class="loc-row"><span>${flag}</span><span>${esc(loc.city?loc.city+', ':'')}${esc(loc.country||'—')}</span>${loc.isp?`<span style="color:var(--text3)">· ${esc(loc.isp)}</span>`:''}
        </div>
        <div class="sc-ts">${s.ts||'—'}</div>
      </div>`}).join('');
    document.getElementById('lastCheck').textContent='Last check: '+new Date().toLocaleTimeString();
  }catch(e){console.error(e)}
}

async function checkNow(){
  const btn=document.getElementById('checkBtn');const ico=document.getElementById('checkIcon');
  btn.disabled=true;ico.classList.add('spin');
  try{await fetch('/api/check_now',{method:'POST'});toast('Check started…');setTimeout(loadStatus,2500)}
  finally{btn.disabled=false;ico.classList.remove('spin')}
}

// Events
async function loadEvents(){
  try{
    const evts=await fetch('/api/events?limit=150').then(r=>r.json());
    document.getElementById('evCount').textContent=evts.length;
    const list=document.getElementById('eventList');
    if(!evts.length){list.innerHTML='<div class="empty"><div class="empty-icon">📋</div><div class="empty-text">No events yet.</div></div>';return}
    const kl={up:'UP',down:'DOWN',system:'SYS',error:'ERR',telegram_error:'TG'};
    list.innerHTML=evts.map(e=>`<div class="event-item"><span class="ev-ts">${e.ts}</span><span class="ev-kind ${e.kind}">${kl[e.kind]||e.kind}</span><span class="ev-msg">${e.server?`<span class="ev-server">${esc(e.server)}</span> — `:''}${esc(e.message)}</span></div>`).join('');
  }catch(e){console.error(e)}
}

// Config
async function loadCfg(){
  try{
    const cfg=await fetch('/api/config').then(r=>r.json());
    document.getElementById('tgToken').value=cfg.telegram_token||'';
    document.getElementById('tgChatId').value=cfg.telegram_chat_id||'';
    document.getElementById('cfgInterval').value=cfg.interval||300;
    document.getElementById('cfgTimeout').value=cfg.timeout||10;
    document.getElementById('cfgLinks').value=(cfg.links||[]).join('\n');
    document.getElementById('vlessLink').value=cfg.vless_link||'';
    document.getElementById('proxyHost').value=cfg.proxy_host||'';
    document.getElementById('proxyPort').value=cfg.proxy_port||'';
    document.getElementById('proxyUser').value=cfg.proxy_user||'';
    document.getElementById('proxyPass').value=cfg.proxy_pass||'';
    document.getElementById('proxyHostH').value=cfg.proxy_host||'';
    document.getElementById('proxyPortH').value=cfg.proxy_port||'';
    // activate correct mode tab
    const mode=cfg.proxy_mode||'none';
    document.getElementById('proxyMode').value=mode;
    document.querySelectorAll('.mode-tab').forEach(b=>{
      const m=['none','socks5','http','vless'][['No Proxy','SOCKS5','HTTP','VLESS Link'].indexOf(b.textContent)];
      b.classList.toggle('active',m===mode);
    });
    document.querySelectorAll('.proxy-panel').forEach(p=>p.style.display='none');
    if(mode==='socks5')document.getElementById('panel-socks5').style.display='block';
    if(mode==='http')  document.getElementById('panel-http').style.display='block';
    if(mode==='vless') document.getElementById('panel-vless').style.display='block';
    syncBtns();
  }catch(e){console.error(e)}
}

async function saveCfg(){
  const mode=document.getElementById('proxyMode').value;
  let host='',port='',user='',pass='';
  if(mode==='socks5'){host=document.getElementById('proxyHost').value.trim();port=document.getElementById('proxyPort').value.trim();user=document.getElementById('proxyUser').value.trim();pass=document.getElementById('proxyPass').value}
  if(mode==='http'){host=document.getElementById('proxyHostH').value.trim();port=document.getElementById('proxyPortH').value.trim()}
  const body={
    telegram_token:  document.getElementById('tgToken').value.trim(),
    telegram_chat_id:document.getElementById('tgChatId').value.trim(),
    interval:parseInt(document.getElementById('cfgInterval').value)||300,
    timeout: parseInt(document.getElementById('cfgTimeout').value)||10,
    proxy_mode:mode, proxy_host:host, proxy_port:port,
    proxy_user:user, proxy_pass:pass,
    vless_link:document.getElementById('vlessLink').value.trim(),
    links:document.getElementById('cfgLinks').value.trim().split('\n').filter(Boolean),
  };
  try{
    await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    toast('Settings saved ✓');
    setTimeout(loadXrayStatus,2000);
  }catch(e){toast('Save failed','err')}
}

async function testTg(){await saveCfg();try{await fetch('/api/test_telegram',{method:'POST'});toast('Test message sent!')}catch(e){toast('Failed','err')}}

loadStatus();
setInterval(loadStatus,15000);
setInterval(()=>{if(document.getElementById('page-settings').classList.contains('active'))loadXrayStatus()},5000);
</script>
</body>
</html>
HTMLEOF
step "Web panel written"

# ── Default config ────────────────────────────────────
if [ ! -f "$INSTALL_DIR/config.json" ]; then
  cat > "$INSTALL_DIR/config.json" << 'EOF'
{"telegram_token":"","telegram_chat_id":"","proxy_mode":"none","proxy_host":"","proxy_port":"","proxy_user":"","proxy_pass":"","vless_link":"","interval":300,"timeout":10,"links":[]}
EOF
fi

# ── Verify Python packages ───────────────────────────
info "Verifying Python packages..."
python3 -c "import flask, requests" 2>/dev/null || die "Flask or Requests not found."
step "Python packages verified"

# ── Systemd — monitor ─────────────────────────────────
info "Installing systemd service..."
cat > /etc/systemd/system/${SERVICE}.service << EOF
[Unit]
Description=VLESS Monitor v3 Web Panel
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
step "Service started"

# ── Firewall ──────────────────────────────────────────
if command -v ufw &>/dev/null; then
  ufw allow "$PORT/tcp" comment "VLESS Monitor" > /dev/null 2>&1 || true
fi

# ── CLI shortcut ──────────────────────────────────────
cat > /usr/local/bin/vless-monitor << 'EOF'
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh) menu
EOF
chmod +x /usr/local/bin/vless-monitor
step "CLI command 'vless-monitor' installed"

# ── Done ──────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║    VLESS Monitor v3 — Installed! ✓    ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Web Panel:  ${CYAN}http://$IP:$PORT${NC}"
echo ""
echo -e "  CLI Menu:   ${CYAN}vless-monitor${NC}"
echo ""
echo -e "  ${YELLOW}Go to Settings → add Telegram token & VLESS links.${NC}"
echo ""
