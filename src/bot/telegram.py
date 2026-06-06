"""
Telegram bot — alerts + inline keyboard commands
Uses pure aiohttp (no python-telegram-bot dependency)
"""
import asyncio, logging
import aiohttp

log = logging.getLogger("telegram")

BASE = "https://api.telegram.org/bot{token}/{method}"

# ─── Shared state cache (populated by monitor engine) ────────────────────────
_status_cache: list[dict] = []

def update_cache(results: list[dict]):
    global _status_cache
    _status_cache = results

def get_cache() -> list[dict]:
    return _status_cache

# ─── Low-level send ──────────────────────────────────────────────────────────
async def _api(token: str, method: str, payload: dict, proxy: str | None = None) -> dict | None:
    if not token:
        return None
    url = BASE.format(token=token, method=method)
    try:
        async with aiohttp.ClientSession() as s:
            async with s.post(url, json=payload, proxy=proxy,
                              timeout=aiohttp.ClientTimeout(total=15)) as r:
                return await r.json()
    except Exception as e:
        log.error("Telegram API error: %s", e)
        return None

async def send_message(token: str, chat_id: str, text: str,
                        proxy: str | None = None,
                        reply_markup: dict | None = None) -> bool:
    payload = {
        "chat_id":    chat_id,
        "text":       text,
        "parse_mode": "HTML",
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    r = await _api(token, "sendMessage", payload, proxy)
    return bool(r and r.get("ok"))

async def answer_callback(token: str, callback_id: str, text: str = "",
                           proxy: str | None = None):
    await _api(token, "answerCallbackQuery",
               {"callback_query_id": callback_id, "text": text}, proxy)

# ─── Inline keyboard ─────────────────────────────────────────────────────────
MAIN_KB = {
    "inline_keyboard": [[
        {"text": "📊 Live Status",  "callback_data": "status"},
        {"text": "🔄 Recheck Now",  "callback_data": "recheck"},
        {"text": "📡 Server List",  "callback_data": "servers"},
    ]]
}

# ─── Message builders ────────────────────────────────────────────────────────
def _flag(cc: str) -> str:
    if not cc or len(cc) != 2:
        return "🌐"
    return "".join(chr(ord(c) + 127397) for c in cc.upper())

def build_alert(result: dict, event: str) -> str:
    icon  = "🔴" if event == "DOWN" else "🟢"
    loc   = result.get("location", {})
    flag  = _flag(loc.get("cc", ""))
    lines = [
        f"{icon} <b>Server {event}</b>",
        f"Name: <b>{result['remark']}</b>",
        f"Host: <code>{result['host']}:{result['port']}</code>",
        f"TCP:  {'✅' if result['tcp']['ok'] else '❌'} {result['tcp']['ms']}ms",
        f"ICMP: {'✅' if result['icmp']['ok'] else '❌'} {result['icmp']['ms']}ms",
        f"HTTP: {'✅' if result['http']['ok'] else '❌'} {result['http']['ms']}ms",
    ]
    if loc.get("country"):
        lines.append(f"📍 {flag} {loc.get('city', '')}, {loc.get('country', '')} · {loc.get('isp', '')}")
    return "\n".join(lines)

def build_status_report(results: list[dict]) -> str:
    up   = [r for r in results if r.get("ok")]
    down = [r for r in results if not r.get("ok")]
    lines = [
        f"📊 <b>VLESS Monitor — Status Report</b>",
        f"🟢 Online: {len(up)}   🔴 Offline: {len(down)}   Total: {len(results)}\n",
    ]
    if down:
        lines.append("❌ <b>DOWN:</b>")
        for r in down[:10]:
            lines.append(f"  • {r['remark']} — {r['host']}:{r['port']}")
    if up:
        lines.append("\n✅ <b>UP:</b>")
        for r in up[:10]:
            lines.append(f"  • {r['remark']} ({r['tcp']['ms']}ms)")
        if len(up) > 10:
            lines.append(f"  … and {len(up)-10} more")
    return "\n".join(lines)

def build_server_list(results: list[dict]) -> str:
    lines = ["📡 <b>Server List</b>\n"]
    for r in results[:30]:
        icon = "🟢" if r.get("ok") else "🔴"
        lines.append(f"{icon} <b>{r['remark']}</b>  <code>{r['host']}</code>  {r['tcp']['ms']}ms")
    if len(results) > 30:
        lines.append(f"… and {len(results)-30} more")
    return "\n".join(lines)

# ─── Update poller ────────────────────────────────────────────────────────────
async def poll_updates(token: str, chat_id: str, proxy: str | None,
                        trigger_check_fn):
    """Long-poll Telegram updates and respond to inline keyboard presses."""
    offset = 0
    while True:
        try:
            r = await _api(token, "getUpdates",
                           {"offset": offset, "timeout": 20, "allowed_updates": ["callback_query"]},
                           proxy)
            if not r or not r.get("ok"):
                await asyncio.sleep(5)
                continue
            for upd in r.get("result", []):
                offset = upd["update_id"] + 1
                cb = upd.get("callback_query")
                if not cb:
                    continue
                cid   = cb["id"]
                data  = cb.get("data", "")
                from_id = str(cb["from"]["id"])

                if data == "status":
                    await answer_callback(token, cid, "Fetching status…", proxy)
                    await send_message(token, chat_id,
                                       build_status_report(get_cache()), proxy, MAIN_KB)
                elif data == "recheck":
                    await answer_callback(token, cid, "Checking…", proxy)
                    asyncio.create_task(trigger_check_fn())
                    await send_message(token, chat_id, "🔄 Recheck started…", proxy, MAIN_KB)
                elif data == "servers":
                    await answer_callback(token, cid, proxy=proxy)
                    await send_message(token, chat_id,
                                       build_server_list(get_cache()), proxy, MAIN_KB)
        except asyncio.CancelledError:
            return
        except Exception as e:
            log.error("Poll error: %s", e)
            await asyncio.sleep(5)
