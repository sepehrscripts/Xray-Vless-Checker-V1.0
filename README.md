<div align="center">

```
▣  VLESS MONITOR
```

**Lightweight VLESS link monitoring with Telegram alerts & Web Panel**

[![License](https://img.shields.io/badge/license-MIT-00e5a0?style=flat-square)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.10+-3b82f6?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![Ubuntu](https://img.shields.io/badge/ubuntu-22.04%20%7C%2024.04-ff3b5c?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Flask](https://img.shields.io/badge/flask-3.x-ffc043?style=flat-square&logo=flask&logoColor=black)](https://flask.palletsprojects.com)

</div>

---

## Overview

**VLESS Monitor** automatically pings your VLESS servers every few minutes and instantly notifies you via **Telegram** if any server goes down. Includes a clean dark web panel for real-time monitoring, event logs, and configuration — no Docker, no complexity.

One command installs everything.

---

## Features

- 🟢 **TCP ping** to all servers at a configurable interval
- 📨 **Instant Telegram alert** when a server goes down
- 🔔 **Recovery notification** when a server comes back online
- 🌐 **Web panel** — live dashboard, event log, and settings UI
- ⚡ **One-line install** — just like 3x-ui
- 🔁 **Runs as a systemd service** — survives reboots automatically

---

## Quick Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/sepehrscripts/Xray-Vless-Checker-V1.0/main/install.sh)
```

> Must be run as `root` or with `sudo`.

After installation, the web panel is available at:

```
http://YOUR-SERVER-IP:5000
```

---

## Initial Setup

Open the panel, go to **Settings**, and fill in:

| Step | Action |
|------|--------|
| 1 | Enter your **Bot Token** — get it from [@BotFather](https://t.me/BotFather) |
| 2 | Enter your **Chat ID** — get it from [@userinfobot](https://t.me/userinfobot) |
| 3 | Paste your **VLESS links**, one per line |
| 4 | Click **Send Test Message** to verify Telegram works |
| 5 | Click **Save Settings** |

---

## Web Panel

| Section | Description |
|---------|-------------|
| **Dashboard** | Live server cards with latency bar and online/offline pulse indicator |
| **Events** | Full log of UP/DOWN/system events with timestamps |
| **Settings** | Manage links, Telegram credentials, check interval and timeout |

---

## Telegram Alert Format

When a server goes down you'll receive:

```
🚨 The following server(s) are unreachable

• Server1  1.2.3.4:443
  Latency: 10043ms

• Server2  5.6.7.8:443
  Latency: 10021ms

🕐 2026-06-06 14:32:11
```

---

## Service Management

```bash
# Status
systemctl status vless-monitor

# Live logs
journalctl -u vless-monitor -f

# Restart
systemctl restart vless-monitor

# Stop
systemctl stop vless-monitor
```

---

## Installed File Structure

```
/opt/vless-monitor/
├── monitor.py          ← Core engine + Flask API
├── templates/
│   └── index.html      ← Web panel
├── config.json         ← Settings (editable from the panel)
├── events.json         ← Event log
└── venv/               ← Python virtual environment
```

---

## Requirements

- Ubuntu 22.04 or 24.04
- Python 3.10+
- Port `5000` open
- Internet access for Telegram notifications

---

## Uninstall

```bash
systemctl stop vless-monitor
systemctl disable vless-monitor
rm /etc/systemd/system/vless-monitor.service
rm -rf /opt/vless-monitor
systemctl daemon-reload
```

---

## License

MIT — free to use, modify, and distribute.

---

<div align="center">
<sub>Built with Python · Flask · ♥</sub>
</div>
