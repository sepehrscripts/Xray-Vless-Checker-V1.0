#!/usr/bin/env python3
"""
VLESS Monitor v3.0.1 — entry point
Run: python3 -m uvicorn main:app --host 0.0.0.0 --port 5000
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from api.app import app  # noqa: F401

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=5000, log_level="info")
