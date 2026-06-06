"""
Xray-core process manager
Parses VLESS links → generates Xray config → runs local SOCKS5
"""
import asyncio, json, urllib.parse, logging
from pathlib import Path

log = logging.getLogger("xray")

XRAY_BIN  = Path("/opt/vless-monitor/xray/xray")
XRAY_CFG  = Path("/opt/vless-monitor/xray/config.json")
SOCKS_HOST = "127.0.0.1"
SOCKS_PORT = 10808

_proc: asyncio.subprocess.Process | None = None

# ─── VLESS parser ────────────────────────────────────────────────────────────
def parse_vless(link: str) -> dict | None:
    try:
        p = urllib.parse.urlparse(link)
        if p.scheme != "vless":
            return None
        qs = urllib.parse.parse_qs(p.query)
        return {
            "id":       p.username or "",
            "address":  p.hostname or "",
            "port":     p.port or 443,
            "network":  qs.get("type",  ["tcp"])[0],
            "security": qs.get("security", ["none"])[0],
            "sni":      qs.get("sni",   [p.hostname or ""])[0],
            "path":     qs.get("path",  ["/"])[0],
            "host":     qs.get("host",  [p.hostname or ""])[0],
            "flow":     qs.get("flow",  [""])[0],
            "fp":       qs.get("fp",    [""])[0],
            "pbk":      qs.get("pbk",   [""])[0],
            "sid":      qs.get("sid",   [""])[0],
        }
    except Exception as e:
        log.error("VLESS parse error: %s", e)
        return None

def _build_stream(v: dict) -> dict:
    net = v["network"]
    sec = v["security"]

    stream: dict = {"network": net}

    if sec == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {"serverName": v["sni"], "allowInsecure": False}
    elif sec == "reality":
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "serverName": v["sni"],
            "fingerprint": v["fp"] or "chrome",
            "publicKey":   v["pbk"],
            "shortId":     v["sid"],
        }
    else:
        stream["security"] = "none"

    if net == "ws":
        stream["wsSettings"] = {
            "path":    v["path"],
            "headers": {"Host": v["host"]},
        }
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": v["path"]}
    elif net == "h2":
        stream["httpSettings"] = {
            "host": [v["host"]],
            "path": v["path"],
        }

    return stream

def build_xray_config(v: dict) -> dict:
    user = {"id": v["id"], "encryption": "none"}
    if v.get("flow"):
        user["flow"] = v["flow"]

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag":      "socks-in",
            "port":     SOCKS_PORT,
            "listen":   SOCKS_HOST,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
        }],
        "outbounds": [
            {
                "tag":      "proxy",
                "protocol": "vless",
                "settings": {"vnext": [{
                    "address": v["address"],
                    "port":    v["port"],
                    "users":   [user],
                }]},
                "streamSettings": _build_stream(v),
            },
            {"tag": "direct",   "protocol": "freedom"},
            {"tag": "blocked",  "protocol": "blackhole"},
        ],
        "routing": {
            "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
            ]
        },
    }

# ─── Process control ─────────────────────────────────────────────────────────
async def start(vless_link: str) -> bool:
    global _proc
    await stop()

    if not XRAY_BIN.exists():
        log.error("Xray binary not found at %s", XRAY_BIN)
        return False

    v = parse_vless(vless_link)
    if not v:
        log.error("Invalid VLESS link")
        return False

    XRAY_CFG.parent.mkdir(parents=True, exist_ok=True)
    XRAY_CFG.write_text(json.dumps(build_xray_config(v), indent=2))

    try:
        _proc = await asyncio.create_subprocess_exec(
            str(XRAY_BIN), "run", "-c", str(XRAY_CFG),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.sleep(1.5)
        if _proc.returncode is None:
            log.info("Xray started (pid=%s) SOCKS5 %s:%s", _proc.pid, SOCKS_HOST, SOCKS_PORT)
            return True
        log.error("Xray exited immediately (rc=%s)", _proc.returncode)
    except Exception as e:
        log.error("Xray start error: %s", e)
    return False

async def stop():
    global _proc
    if _proc and _proc.returncode is None:
        try:
            _proc.terminate()
            await asyncio.wait_for(_proc.wait(), timeout=4)
        except Exception:
            _proc.kill()
    _proc = None

def is_running() -> bool:
    return _proc is not None and _proc.returncode is None

def socks5_url() -> str:
    return f"socks5://{SOCKS_HOST}:{SOCKS_PORT}"

async def watchdog(vless_link: str):
    """Restart Xray if it crashes."""
    while True:
        await asyncio.sleep(15)
        if vless_link and not is_running():
            log.warning("Xray died, restarting...")
            await start(vless_link)

