"""
SQLite database layer — aiosqlite-based async access
"""
import aiosqlite
import hashlib, os, json
from pathlib import Path

DB_PATH = Path("/opt/vless-monitor/data/monitor.db")

# ─── Schema ──────────────────────────────────────────────────────────────────
SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS users (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    username   TEXT UNIQUE NOT NULL,
    password   TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS servers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    remark      TEXT NOT NULL,
    vless_link  TEXT NOT NULL,
    enabled     INTEGER DEFAULT 1,
    interval    INTEGER DEFAULT 0,
    last_status TEXT DEFAULT 'UNKNOWN',
    last_check  TEXT,
    created_at  TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id  INTEGER REFERENCES servers(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    message    TEXT,
    ts         TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""

DEFAULT_SETTINGS = {
    "telegram_token":   "",
    "telegram_chat_id": "",
    "proxy_mode":       "none",
    "proxy_host":       "",
    "proxy_port":       "",
    "proxy_user":       "",
    "proxy_pass":       "",
    "vless_link":       "",
    "interval":         "300",
    "timeout":          "10",
    "report_interval":  "0",
}

# ─── Init ─────────────────────────────────────────────────────────────────────
async def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript(SCHEMA)
        # seed default settings
        for k, v in DEFAULT_SETTINGS.items():
            await db.execute(
                "INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)", (k, v)
            )
        # seed default admin if no users
        row = await db.execute_fetchall("SELECT COUNT(*) FROM users")
        if row[0][0] == 0:
            pw = _hash_password("admin")
            await db.execute(
                "INSERT INTO users(username,password) VALUES(?,?)", ("admin", pw)
            )
        await db.commit()

# ─── Password ─────────────────────────────────────────────────────────────────
def _hash_password(password: str) -> str:
    salt = os.urandom(16).hex()
    h = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
    return f"{salt}:{h}"

def verify_password(password: str, stored: str) -> bool:
    try:
        salt, h = stored.split(":", 1)
        return hashlib.sha256(f"{salt}{password}".encode()).hexdigest() == h
    except Exception:
        return False

# ─── Users ────────────────────────────────────────────────────────────────────
async def get_user(username: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM users WHERE username=?", (username,)
        ) as cur:
            row = await cur.fetchone()
            return dict(row) if row else None

async def update_password(username: str, new_password: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE users SET password=? WHERE username=?",
            (_hash_password(new_password), username)
        )
        await db.commit()

# ─── Settings ─────────────────────────────────────────────────────────────────
async def get_settings() -> dict:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT key,value FROM settings") as cur:
            rows = await cur.fetchall()
            return {r[0]: r[1] for r in rows}

async def set_settings(updates: dict):
    async with aiosqlite.connect(DB_PATH) as db:
        for k, v in updates.items():
            await db.execute(
                "INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (k, str(v))
            )
        await db.commit()

# ─── Servers ──────────────────────────────────────────────────────────────────
async def get_servers(enabled_only=False) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        q = "SELECT * FROM servers"
        if enabled_only:
            q += " WHERE enabled=1"
        q += " ORDER BY id"
        async with db.execute(q) as cur:
            rows = await cur.fetchall()
            return [dict(r) for r in rows]

async def get_server(server_id: int) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM servers WHERE id=?", (server_id,)
        ) as cur:
            row = await cur.fetchone()
            return dict(row) if row else None

async def add_server(remark: str, vless_link: str, interval: int = 0) -> int:
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute(
            "INSERT INTO servers(remark,vless_link,interval) VALUES(?,?,?)",
            (remark, vless_link, interval)
        )
        await db.commit()
        return cur.lastrowid

async def update_server(server_id: int, **kwargs):
    if not kwargs:
        return
    fields = ", ".join(f"{k}=?" for k in kwargs)
    values = list(kwargs.values()) + [server_id]
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(f"UPDATE servers SET {fields} WHERE id=?", values)
        await db.commit()

async def delete_server(server_id: int):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM servers WHERE id=?", (server_id,))
        await db.commit()

async def update_server_status(server_id: int, status: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE servers SET last_status=?, last_check=datetime('now') WHERE id=?",
            (status, server_id)
        )
        await db.commit()

# ─── Events ───────────────────────────────────────────────────────────────────
async def add_event(server_id: int | None, kind: str, message: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO events(server_id,kind,message) VALUES(?,?,?)",
            (server_id, kind, message)
        )
        # keep only last 1000
        await db.execute(
            "DELETE FROM events WHERE id NOT IN "
            "(SELECT id FROM events ORDER BY id DESC LIMIT 1000)"
        )
        await db.commit()

async def get_events(limit: int = 100, server_id: int | None = None) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        if server_id:
            q = "SELECT e.*, s.remark FROM events e LEFT JOIN servers s ON e.server_id=s.id WHERE e.server_id=? ORDER BY e.id DESC LIMIT ?"
            params = (server_id, limit)
        else:
            q = "SELECT e.*, s.remark FROM events e LEFT JOIN servers s ON e.server_id=s.id ORDER BY e.id DESC LIMIT ?"
            params = (limit,)
        async with db.execute(q, params) as cur:
            rows = await cur.fetchall()
            return [dict(r) for r in rows]

