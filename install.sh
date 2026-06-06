#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#   VLESS Monitor v3.0.1 — Installer
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

INSTALL_DIR="/opt/vless-monitor"
SERVICE="vless-monitor"
PORT=5000

RED='\033[0;31m';GRN='\033[0;32m';YLW='\033[1;33m'
CYN='\033[0;36m';BLD='\033[1m';NC='\033[0m'
_step(){ echo -e "  ${GRN}[+]${NC} $1"; }
_info(){ echo -e "  ${YLW}[~]${NC} $1"; }
_warn(){ echo -e "  ${YLW}[!]${NC} $1"; }
_die() { echo -e "  ${RED}[✗]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && _die "Run as root or with sudo."
[ "${1:-}" = "menu" ] && exec python3 "$INSTALL_DIR/cli.py"

clear; echo -e "${CYN}${BLD}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║   ▣  VLESS Monitor v3.0.1 — Setup            ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}\n  Ubuntu 24.04 LTS\n"

# Stop old service
systemctl stop "$SERVICE" 2>/dev/null||true
systemctl disable "$SERVICE" 2>/dev/null||true
systemctl daemon-reload

# ── 1. System packages ────────────────────────────────────────────────────────
_info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
  python3 curl unzip iputils-ping sqlite3 \
  python3-fastapi python3-uvicorn python3-aiohttp \
  python3-aiosqlite python3-jinja2 python3-multipart
python3 -c "import fastapi,uvicorn,aiohttp,aiosqlite,jinja2" 2>/dev/null || \
  _die "Python packages missing."
_step "System packages ready"

# ── 2. Directories ────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"/data
mkdir -p "$INSTALL_DIR"/xray
mkdir -p "$INSTALL_DIR"/src/api/templates
mkdir -p "$INSTALL_DIR"/src/db
mkdir -p "$INSTALL_DIR"/src/core
mkdir -p "$INSTALL_DIR"/src/bot
touch "$INSTALL_DIR/src/db/__init__.py"
touch "$INSTALL_DIR/src/core/__init__.py"
touch "$INSTALL_DIR/src/bot/__init__.py"
touch "$INSTALL_DIR/src/api/__init__.py"
_step "Directories ready"

# ── 3. Copy source files from this package ────────────────────────────────────
_info "Copying source files..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/src/main.py"                        "$INSTALL_DIR/src/"
cp "$SCRIPT_DIR/src/db/models.py"                   "$INSTALL_DIR/src/db/"
cp "$SCRIPT_DIR/src/core/checker.py"                "$INSTALL_DIR/src/core/"
cp "$SCRIPT_DIR/src/core/xray.py"                   "$INSTALL_DIR/src/core/"
cp "$SCRIPT_DIR/src/core/scheduler.py"              "$INSTALL_DIR/src/core/"
cp "$SCRIPT_DIR/src/bot/telegram.py"                "$INSTALL_DIR/src/bot/"
cp "$SCRIPT_DIR/src/api/auth.py"                    "$INSTALL_DIR/src/api/"
cp "$SCRIPT_DIR/src/api/app.py"                     "$INSTALL_DIR/src/api/"
cp "$SCRIPT_DIR/src/api/templates/login.html"       "$INSTALL_DIR/src/api/templates/"
cp "$SCRIPT_DIR/src/api/templates/index.html"       "$INSTALL_DIR/src/api/templates/"
cp "$SCRIPT_DIR/cli.py"                             "$INSTALL_DIR/"
_step "Source files copied"

# ── 4. Xray-core ──────────────────────────────────────────────────────────────
_info "Downloading Xray-core..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  XA="64" ;;
  aarch64) XA="arm64-v8a" ;;
  armv7l)  XA="arm32-v7a" ;;
  *)       XA="64" ;;
esac
XURL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XA}.zip"
if curl -sL --max-time 60 --retry 2 "$XURL" -o /tmp/xray.zip 2>/dev/null; then
  unzip -qo /tmp/xray.zip -d "$INSTALL_DIR/xray" xray 2>/dev/null||true
  chmod +x "$INSTALL_DIR/xray/xray" 2>/dev/null||true
  rm -f /tmp/xray.zip
  _step "Xray-core installed ($(${INSTALL_DIR}/xray/xray version 2>/dev/null | head -1 || echo 'ok'))"
else
  _warn "Xray download failed — VLESS proxy will be unavailable"
fi

# ── 5. Find Python3 uvicorn path ─────────────────────────────────────────────
UVICORN_CMD=""
if command -v uvicorn &>/dev/null; then
  UVICORN_CMD="$(command -v uvicorn)"
else
  # FIX v3.0.1: fallback to python3 -m uvicorn (apt install doesn't create binary)
  UVICORN_CMD="/usr/bin/python3 -m uvicorn"
fi
_step "Uvicorn: $UVICORN_CMD"

# ── 6. Systemd service ────────────────────────────────────────────────────────
_info "Installing systemd service..."
cat > "/etc/systemd/system/${SERVICE}.service" << SVCEOF
[Unit]
Description=VLESS Monitor v3.0.1 SaaS
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/src
ExecStart=${UVICORN_CMD} main:app --host 0.0.0.0 --port ${PORT} --log-level info
Restart=on-failure
RestartSec=10
Environment=PYTHONPATH=${INSTALL_DIR}/src

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "$SERVICE" --quiet
systemctl restart "$SERVICE"
_step "Service started"

# ── 7. CLI shortcut ───────────────────────────────────────────────────────────
cat > /usr/local/bin/vless-monitor << CEOF
#!/bin/bash
python3 ${INSTALL_DIR}/cli.py "\$@"
CEOF
chmod +x /usr/local/bin/vless-monitor
_step "CLI installed — run: vless-monitor"

# ── 8. Firewall ───────────────────────────────────────────────────────────────
command -v ufw &>/dev/null && ufw allow "${PORT}/tcp" comment "VLESS Monitor" >/dev/null 2>&1 || true

# ── Done ──────────────────────────────────────────────────────────────────────
sleep 2
IP=$(hostname -I | awk '{print $1}')
echo ""; echo -e "${GRN}${BLD}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║     VLESS Monitor v3.0.1 — Ready! ✓          ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  🌐 Web Panel:  ${CYN}http://${IP}:${PORT}${NC}"
echo -e "  🔑 Login:      ${BLD}admin${NC} / ${BLD}admin${NC}"
echo -e "  🖥  CLI Menu:   ${CYN}vless-monitor${NC}"
echo ""
echo "  Useful commands:"
echo "    systemctl status vless-monitor"
echo "    journalctl -u vless-monitor -f"
echo ""
echo -e "  ${YLW}⚠️  Change the default password after first login!${NC}"
echo ""
