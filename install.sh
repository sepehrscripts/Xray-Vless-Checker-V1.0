#!/bin/bash
# ═════════════════════════════════════════════
#   VLESS MONITOR V6 — GOD MODE
# ═════════════════════════════════════════════

INSTALL_DIR="/opt/vless-monitor"
SERVICE="vless-monitor"
PORT=5000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

step(){echo -e "${GREEN}[+]${NC} $1";}
die(){echo -e "${RED}[✗]${NC} $1";exit 1;}

[ "$EUID" -ne 0 ] && die "Run as root"

apt update -qq
apt install -y python3 python3-flask python3-requests python3-socks sqlite3 curl

mkdir -p $INSTALL_DIR/templates

# ═════════════════════════════════════
# DATABASE INIT
# ═════════════════════════════════════
cat > $INSTALL_DIR/db_init.py << 'EOF'
import sqlite3

db=sqlite3.connect("/opt/vless-monitor/data.db")
c=db.cursor()

c.execute("""
CREATE TABLE IF NOT EXISTS servers(
id INTEGER PRIMARY KEY,
name TEXT,
host TEXT,
port INTEGER,
remark TEXT
)
""")

c.execute("""
CREATE TABLE IF NOT EXISTS checks(
id INTEGER PRIMARY KEY,
server_id INTEGER,
ok INTEGER,
latency REAL,
ts DATETIME DEFAULT CURRENT_TIMESTAMP
)
""")

db.commit()
db.close()
EOF

python3 $INSTALL_DIR/db_init.py

# ═════════════════════════════════════
# MONITOR CORE
# ═════════════════════════════════════
cat > $INSTALL_DIR/monitor.py << 'EOF'
import socket, time, sqlite3, threading, requests
from flask import Flask, request, jsonify, session
from datetime import datetime

DB="/opt/vless-monitor/data.db"
app=Flask(__name__)
app.secret_key="godmode_secret"

# ── DB ──
def db():
    return sqlite3.connect(DB, check_same_thread=False)

# ── CHECK ENGINE (anti fake online) ──
def check(host,port):
    try:
        t=time.time()
        s=socket.create_connection((host,port),timeout=5)
        s.close()
        ms=(time.time()-t)*1000

        # anti fake online rule
        if ms < 1:  # suspicious
            return False, ms

        return True, round(ms,2)
    except:
        return False,0

# ── LOGIN ──
@app.route("/login",methods=["POST"])
def login():
    data=request.json
    if data["u"]=="admin" and data["p"]=="admin":
        session["ok"]=True
        return {"ok":True}
    return {"ok":False},403

def auth():
    return session.get("ok",False)

# ── STATUS API ──
@app.route("/api/status")
def status():
    if not auth(): return {"err":"unauth"},403

    con=db()
    cur=con.cursor()

    servers=cur.execute("SELECT * FROM servers").fetchall()

    out=[]
    up=0

    for s in servers:
        sid,name,host,port,remark=s
        ok,ms=check(host,port)

        cur.execute(
            "INSERT INTO checks(server_id,ok,latency) VALUES (?,?,?)",
            (sid,int(ok),ms)
        )
        con.commit()

        if ok: up+=1

        out.append({
            "name":remark,
            "host":host,
            "port":port,
            "ok":ok,
            "ms":ms
        })

    return {
        "total":len(out),
        "up":up,
        "down":len(out)-up,
        "servers":out
    }

# ── ANALYTICS ──
@app.route("/api/analytics/<int:sid>")
def analytics(sid):
    if not auth(): return {"err":"unauth"},403

    con=db()
    cur=con.cursor()

    rows=cur.execute("""
        SELECT ok,latency,ts FROM checks
        WHERE server_id=?
        ORDER BY id DESC LIMIT 50
    """,(sid,)).fetchall()

    return {"history":rows}

# ── TELEGRAM BUTTON ──
@app.route("/api/tg_callback",methods=["POST"])
def tg():
    data=request.json
    chat=data["callback_query"]["message"]["chat"]["id"]

    con=db()
    cur=con.cursor()
    servers=cur.execute("SELECT * FROM servers").fetchall()

    up=0
    for s in servers:
        ok,_=check(s[2],s[3])
        if ok: up+=1

    requests.post(
        f"https://api.telegram.org/botTOKEN/sendMessage",
        json={
            "chat_id":chat,
            "text":f"📊 GOD MODE REPORT\nUP: {up}\nDOWN: {len(servers)-up}"
        }
    )

    return {"ok":True}

# ── LOOP ──
def loop():
    while True:
        time.sleep(10)

threading.Thread(target=loop,daemon=True).start()

app.run("0.0.0.0",5000)
EOF

# ═════════════════════════════════════
# SYSTEMD
# ═════════════════════════════════════
cat > /etc/systemd/system/$SERVICE.service << EOF
[Unit]
Description=VLESS V6 GOD MODE
After=network.target

[Service]
ExecStart=/usr/bin/python3 $INSTALL_DIR/monitor.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE
systemctl restart $SERVICE

IP=$(hostname -I | awk '{print $1}')

echo ""
echo "════════════════════════════"
echo "   V6 GOD MODE INSTALLED"
echo "════════════════════════════"
echo "Panel: http://$IP:$PORT"
echo "Login: admin / admin"
echo ""
