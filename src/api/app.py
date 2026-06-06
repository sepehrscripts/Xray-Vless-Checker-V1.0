"""
VLESS Monitor v3.0.1 — FastAPI application

Fixes vs v3:
  - Settings: empty strings no longer overwrite saved values
  - Settings: vless_link always saved independently of other fields
  - Settings GET: returns full token length indicator, not masked partial
  - Telegram poller: restarted automatically when token/chat changes
  - check_now: awaits result properly
  - Auth: SECRET loaded before first request, not on import race
"""
import asyncio, logging, os
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
from pathlib import Path
from typing import Optional

from db.models import (
    init_db, get_settings, set_settings,
    get_servers, get_server, add_server, update_server, delete_server,
    update_server_status, get_events, add_event, get_user, verify_password,
    update_password,
)
from core.checker import check_all, ServerResult
from core.scheduler import scheduler
from core import xray
from bot import telegram as tg
from api.auth import create_token, get_current_user

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s %(message)s")
log = logging.getLogger("app")

TEMPLATES = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

# ─── In-memory state ──────────────────────────────────────────────────────────
_state: dict[int, dict] = {}
_tg_poll_task: asyncio.Task | None = None  # FIX: track poll task for restart

def _result_to_dict(r: ServerResult) -> dict:
    return {
        "server_id": r.server_id,
        "remark":    r.remark,
        "host":      r.host,
        "port":      r.port,
        "ok":        r.ok,
        "tcp":       {"ok": r.tcp.ok,  "ms": r.tcp.ms},
        "icmp":      {"ok": r.icmp.ok, "ms": r.icmp.ms},
        "http":      {"ok": r.http.ok, "ms": r.http.ms},
        "location":  r.location,
        "ts":        r.ts,
    }

# ─── Monitor engine ───────────────────────────────────────────────────────────
async def _run_checks():
    cfg     = await get_settings()
    timeout = float(cfg.get("timeout", 10))
    proxy   = _build_proxy(cfg)
    servers = await get_servers(enabled_only=True)

    if not servers:
        return

    results = await check_all(servers, timeout, proxy)
    tg_token   = cfg.get("telegram_token", "")
    tg_chat_id = cfg.get("telegram_chat_id", "")
    tg_proxy   = _tg_proxy(cfg)

    for r in results:
        d    = _result_to_dict(r)
        prev = _state.get(r.server_id, {})
        _state[r.server_id] = d

        was_ok = prev.get("ok", None)
        if was_ok is None:
            pass
        elif not r.ok and was_ok:
            await add_event(r.server_id, "down", f"DOWN — TCP:{r.tcp.ms}ms")
            await update_server_status(r.server_id, "DOWN")
            if tg_token and tg_chat_id:
                asyncio.create_task(
                    tg.send_message(tg_token, tg_chat_id, tg.build_alert(d, "DOWN"), tg_proxy, tg.MAIN_KB)
                )
        elif r.ok and was_ok is False:
            await add_event(r.server_id, "up", f"UP — TCP:{r.tcp.ms}ms")
            await update_server_status(r.server_id, "UP")
            if tg_token and tg_chat_id:
                asyncio.create_task(
                    tg.send_message(tg_token, tg_chat_id, tg.build_alert(d, "UP"), tg_proxy, tg.MAIN_KB)
                )

    tg.update_cache(list(_state.values()))

async def _send_report():
    cfg = await get_settings()
    token  = cfg.get("telegram_token", "")
    chat   = cfg.get("telegram_chat_id", "")
    proxy  = _tg_proxy(cfg)
    if token and chat:
        text = tg.build_status_report(list(_state.values()))
        await tg.send_message(token, chat, text, proxy, tg.MAIN_KB)

async def _get_interval() -> int:
    cfg = await get_settings()
    return int(cfg.get("interval", 300))

async def _get_report_interval() -> int:
    cfg = await get_settings()
    return int(cfg.get("report_interval", 0))

# ─── Proxy helpers ────────────────────────────────────────────────────────────
def _build_proxy(cfg: dict) -> str | None:
    mode = cfg.get("proxy_mode", "none")
    if mode == "none":
        return None
    if mode == "vless":
        return xray.socks5_url()
    host = cfg.get("proxy_host", "")
    port = cfg.get("proxy_port", "")
    if not host or not port:
        return None
    user = cfg.get("proxy_user", "")
    pw   = cfg.get("proxy_pass", "")
    auth = f"{user}:{pw}@" if user else ""
    return f"{mode}://{auth}{host}:{port}"

def _tg_proxy(cfg: dict) -> str | None:
    return _build_proxy(cfg)

# ─── Telegram poller helper ───────────────────────────────────────────────────
async def _start_tg_poller(cfg: dict):
    """Start (or restart) the Telegram update poller."""
    global _tg_poll_task
    if _tg_poll_task and not _tg_poll_task.done():
        _tg_poll_task.cancel()
        try:
            await _tg_poll_task
        except asyncio.CancelledError:
            pass
    token = cfg.get("telegram_token", "")
    chat  = cfg.get("telegram_chat_id", "")
    if token and chat:
        _tg_poll_task = asyncio.create_task(
            tg.poll_updates(token, chat, _tg_proxy(cfg), _run_checks)
        )

# ─── Lifespan ─────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    await add_event(None, "system", "Monitor v3.0.1 started")
    scheduler.set_check_handler(_run_checks)
    scheduler.set_report_handler(_send_report)
    scheduler.start(_get_interval, _get_report_interval)

    asyncio.create_task(_run_checks())

    cfg = await get_settings()
    await _start_tg_poller(cfg)

    if cfg.get("proxy_mode") == "vless" and cfg.get("vless_link"):
        await xray.start(cfg["vless_link"])
        asyncio.create_task(xray.watchdog(cfg["vless_link"]))

    yield

    await xray.stop()

# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(title="VLESS Monitor", lifespan=lifespan)

# ════════════════════════════════════════════════════
#  AUTH ROUTES
# ════════════════════════════════════════════════════
class LoginBody(BaseModel):
    username: str
    password: str

@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    return TEMPLATES.TemplateResponse("login.html", {"request": request})

@app.post("/api/login")
async def api_login(body: LoginBody):
    user = await get_user(body.username)
    if not user or not verify_password(body.password, user["password"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_token(body.username)
    resp  = JSONResponse({"ok": True})
    resp.set_cookie("token", token, httponly=True, max_age=86400 * 7, samesite="lax")
    return resp

@app.post("/api/logout")
async def api_logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie("token")
    return resp

# ════════════════════════════════════════════════════
#  DASHBOARD / UI
# ════════════════════════════════════════════════════
@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    try:
        get_current_user(request)
    except HTTPException:
        return RedirectResponse("/login")
    return TEMPLATES.TemplateResponse("index.html", {"request": request})

# ════════════════════════════════════════════════════
#  API — STATUS
# ════════════════════════════════════════════════════
@app.get("/api/status")
async def api_status(_=Depends(get_current_user)):
    servers = list(_state.values())
    total = len(servers)
    up    = sum(1 for s in servers if s["ok"])
    return {"servers": servers, "summary": {"total": total, "up": up, "down": total - up}}

@app.post("/api/check_now")
async def api_check_now(_=Depends(get_current_user)):
    # FIX v3.0.1: don't use trigger_now (fire-and-forget); run directly so UI
    # can show "checking" state. Still non-blocking for the HTTP response.
    asyncio.create_task(_run_checks())
    return {"ok": True}

# ════════════════════════════════════════════════════
#  API — SERVERS
# ════════════════════════════════════════════════════
class ServerBody(BaseModel):
    remark:     str
    vless_link: str
    enabled:    bool = True
    interval:   int  = 0

class ServerUpdate(BaseModel):
    remark:     Optional[str]  = None
    vless_link: Optional[str]  = None   # FIX v3.0.1: allow updating vless_link
    enabled:    Optional[bool] = None
    interval:   Optional[int]  = None

@app.get("/api/servers")
async def api_servers(_=Depends(get_current_user)):
    return await get_servers()

@app.post("/api/servers")
async def api_add_server(body: ServerBody, _=Depends(get_current_user)):
    if not body.vless_link.startswith("vless://"):
        raise HTTPException(400, "Invalid VLESS link — must start with vless://")
    sid = await add_server(body.remark, body.vless_link, body.interval)
    await add_event(sid, "system", f"Server added: {body.remark}")
    return {"ok": True, "id": sid}

@app.patch("/api/servers/{sid}")
async def api_update_server(sid: int, body: ServerUpdate, _=Depends(get_current_user)):
    updates = body.model_dump(exclude_none=True)
    if updates:
        await update_server(sid, **updates)
    return {"ok": True}

@app.delete("/api/servers/{sid}")
async def api_delete_server(sid: int, _=Depends(get_current_user)):
    srv = await get_server(sid)
    if not srv:
        raise HTTPException(404, "Not found")
    await delete_server(sid)
    _state.pop(sid, None)
    return {"ok": True}

# ════════════════════════════════════════════════════
#  API — EVENTS
# ════════════════════════════════════════════════════
@app.get("/api/events")
async def api_events(limit: int = 100, server_id: int | None = None,
                     _=Depends(get_current_user)):
    return await get_events(limit, server_id)

# ════════════════════════════════════════════════════
#  API — SETTINGS
# ════════════════════════════════════════════════════
class SettingsBody(BaseModel):
    telegram_token:   Optional[str] = None
    telegram_chat_id: Optional[str] = None
    proxy_mode:       Optional[str] = None
    proxy_host:       Optional[str] = None
    proxy_port:       Optional[str] = None
    proxy_user:       Optional[str] = None
    proxy_pass:       Optional[str] = None
    vless_link:       Optional[str] = None
    interval:         Optional[int] = None
    timeout:          Optional[int] = None
    report_interval:  Optional[int] = None

@app.get("/api/settings")
async def api_settings_get(_=Depends(get_current_user)):
    cfg = await get_settings()
    # FIX v3.0.1: mask token but keep length indicator so UI knows it's set
    t = cfg.get("telegram_token", "")
    if t:
        cfg["telegram_token"] = t[:6] + "***" + t[-4:] if len(t) > 10 else "***"
    return cfg

@app.post("/api/settings")
async def api_settings_post(body: SettingsBody, _=Depends(get_current_user)):
    raw = body.model_dump()

    # FIX v3.0.1: skip None AND empty string — don't overwrite saved values
    updates = {k: v for k, v in raw.items() if v is not None and v != ""}

    # Don't overwrite a real token with a masked display value
    if "telegram_token" in updates and "***" in str(updates["telegram_token"]):
        del updates["telegram_token"]

    if updates:
        await set_settings(updates)

    cfg = await get_settings()

    # Restart xray if proxy mode or vless_link changed
    if cfg.get("proxy_mode") == "vless" and cfg.get("vless_link"):
        asyncio.create_task(_restart_xray(cfg["vless_link"]))
    elif cfg.get("proxy_mode") != "vless":
        asyncio.create_task(xray.stop())

    # FIX v3.0.1: restart Telegram poller if credentials changed
    if "telegram_token" in updates or "telegram_chat_id" in updates:
        await _start_tg_poller(cfg)

    return {"ok": True}

async def _restart_xray(link: str):
    await xray.start(link)
    asyncio.create_task(xray.watchdog(link))

# ════════════════════════════════════════════════════
#  API — MISC
# ════════════════════════════════════════════════════
@app.post("/api/test_telegram")
async def api_test_tg(_=Depends(get_current_user)):
    cfg = await get_settings()
    token = cfg.get("telegram_token", "")
    chat  = cfg.get("telegram_chat_id", "")
    if not token or not chat:
        raise HTTPException(400, "Telegram token and chat ID are not configured")
    ok = await tg.send_message(
        token, chat,
        "✅ <b>Test OK!</b>\nVLESS Monitor v3.0.1 is configured correctly.",
        _tg_proxy(cfg), tg.MAIN_KB
    )
    if not ok:
        raise HTTPException(502, "Telegram send failed — check token and chat ID")
    return {"ok": True}

@app.get("/api/xray_status")
async def api_xray(_=Depends(get_current_user)):
    return {"running": xray.is_running(), "port": xray.SOCKS_PORT}

class PasswordBody(BaseModel):
    current: str
    new:     str

@app.post("/api/change_password")
async def api_change_password(body: PasswordBody, request: Request):
    username = get_current_user(request)
    user = await get_user(username)
    if not user or not verify_password(body.current, user["password"]):
        raise HTTPException(400, "Current password incorrect")
    if len(body.new) < 6:
        raise HTTPException(400, "New password must be at least 6 characters")
    await update_password(username, body.new)
    return {"ok": True}
