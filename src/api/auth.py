"""
JWT authentication helpers
"""
import time, hmac, hashlib, base64, json
from functools import wraps
from fastapi import HTTPException, Request

SECRET = None  # set at startup from a random key file

def _load_secret():
    global SECRET
    import os
    from pathlib import Path
    key_file = Path("/opt/vless-monitor/data/.jwt_secret")
    if key_file.exists():
        SECRET = key_file.read_text().strip()
    else:
        SECRET = os.urandom(32).hex()
        key_file.parent.mkdir(parents=True, exist_ok=True)
        key_file.write_text(SECRET)

def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def _unb64(s: str) -> bytes:
    pad = 4 - len(s) % 4
    return base64.urlsafe_b64decode(s + "=" * pad)

def create_token(username: str, expires_in: int = 86400 * 7) -> str:
    if SECRET is None:
        _load_secret()
    header  = _b64(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
    payload = _b64(json.dumps({"sub": username, "exp": int(time.time()) + expires_in}).encode())
    sig_input = f"{header}.{payload}".encode()
    sig = _b64(hmac.new(SECRET.encode(), sig_input, hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"

def verify_token(token: str) -> str | None:
    """Returns username if valid, else None."""
    if SECRET is None:
        _load_secret()
    try:
        header, payload, sig = token.split(".")
        sig_input = f"{header}.{payload}".encode()
        expected  = _b64(hmac.new(SECRET.encode(), sig_input, hashlib.sha256).digest())
        if not hmac.compare_digest(sig, expected):
            return None
        data = json.loads(_unb64(payload))
        if data.get("exp", 0) < time.time():
            return None
        return data.get("sub")
    except Exception:
        return None

def get_current_user(request: Request) -> str:
    token = request.cookies.get("token") or \
            request.headers.get("Authorization", "").removeprefix("Bearer ")
    user = verify_token(token) if token else None
    if not user:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return user

# init secret on import
_load_secret()

