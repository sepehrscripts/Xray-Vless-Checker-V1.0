"""
Async monitoring engine — TCP / ICMP / HTTP checks
"""
import asyncio, socket, subprocess, time, urllib.parse
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
import aiohttp

# ─── Result types ────────────────────────────────────────────────────────────
@dataclass
class CheckResult:
    ok:      bool
    ms:      float

@dataclass
class ServerResult:
    server_id:  int
    remark:     str
    host:       str
    port:       int
    ok:         bool
    tcp:        CheckResult = field(default_factory=lambda: CheckResult(False, 0))
    icmp:       CheckResult = field(default_factory=lambda: CheckResult(False, 0))
    http:       CheckResult = field(default_factory=lambda: CheckResult(False, 0))
    location:   dict = field(default_factory=dict)
    ts:         str  = field(default_factory=lambda: datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

# ─── Parsers ──────────────────────────────────────────────────────────────────
def parse_vless(link: str) -> Optional[dict]:
    try:
        p = urllib.parse.urlparse(link)
        if p.scheme != "vless":
            return None
        return {
            "host": p.hostname,
            "port": p.port or 443,
        }
    except Exception:
        return None

# ─── TCP check ────────────────────────────────────────────────────────────────
async def check_tcp(host: str, port: int, timeout: float) -> CheckResult:
    t0 = time.perf_counter()
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=timeout
        )
        writer.close()
        await writer.wait_closed()
        return CheckResult(True, round((time.perf_counter() - t0) * 1000, 1))
    except Exception:
        return CheckResult(False, round((time.perf_counter() - t0) * 1000, 1))

# ─── ICMP check (subprocess ping, safe fallback) ──────────────────────────────
async def check_icmp(host: str) -> CheckResult:
    try:
        proc = await asyncio.create_subprocess_exec(
            "ping", "-c", "1", "-W", "3", host,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=6)
        if proc.returncode == 0:
            for part in stdout.decode().split():
                if "time=" in part:
                    try:
                        ms = float(part.replace("time=", ""))
                        return CheckResult(True, round(ms, 1))
                    except ValueError:
                        pass
            return CheckResult(True, 0.0)
        return CheckResult(False, 0.0)
    except Exception:
        return CheckResult(False, 0.0)

# ─── HTTP 204 check ───────────────────────────────────────────────────────────
async def check_http(timeout: float, proxy_url: str | None = None) -> CheckResult:
    t0 = time.perf_counter()
    try:
        connector = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=connector) as session:
            async with session.get(
                "http://www.gstatic.com/generate_204",
                timeout=aiohttp.ClientTimeout(total=timeout),
                proxy=proxy_url,
                allow_redirects=False,
            ) as resp:
                ok = resp.status == 204
                return CheckResult(ok, round((time.perf_counter() - t0) * 1000, 1))
    except Exception:
        return CheckResult(False, round((time.perf_counter() - t0) * 1000, 1))

# ─── Location lookup ─────────────────────────────────────────────────────────
_location_cache: dict[str, dict] = {}

async def get_location(host: str) -> dict:
    if host in _location_cache:
        return _location_cache[host]
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"http://ip-api.com/json/{host}?fields=status,country,countryCode,city,isp,query",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                d = await resp.json()
                if d.get("status") == "success":
                    loc = {
                        "ip":      d.get("query", ""),
                        "country": d.get("country", ""),
                        "cc":      d.get("countryCode", ""),
                        "city":    d.get("city", ""),
                        "isp":     d.get("isp", ""),
                    }
                    _location_cache[host] = loc
                    return loc
    except Exception:
        pass
    return {}

# ─── Full server check ────────────────────────────────────────────────────────
async def check_server(srv: dict, timeout: float, proxy_url: str | None = None) -> ServerResult:
    info = parse_vless(srv["vless_link"])
    if not info:
        return ServerResult(
            server_id=srv["id"], remark=srv["remark"],
            host="", port=0, ok=False
        )

    host, port = info["host"], info["port"]

    tcp, icmp, http = await asyncio.gather(
        check_tcp(host, port, timeout),
        check_icmp(host),
        check_http(timeout, proxy_url),
    )

    overall_ok = tcp.ok
    loc = await get_location(host) if tcp.ok else {}

    return ServerResult(
        server_id=srv["id"],
        remark=srv["remark"],
        host=host,
        port=port,
        ok=overall_ok,
        tcp=tcp,
        icmp=icmp,
        http=http,
        location=loc,
    )

# ─── Bulk check (semaphore-limited) ───────────────────────────────────────────
async def check_all(servers: list[dict], timeout: float, proxy_url: str | None = None,
                    concurrency: int = 50) -> list[ServerResult]:
    sem = asyncio.Semaphore(concurrency)

    async def _guarded(srv):
        async with sem:
            return await check_server(srv, timeout, proxy_url)

    return await asyncio.gather(*[_guarded(s) for s in servers])
