#!/usr/bin/env python3
"""E2E-2: produce/consume round-trip against the live Railway Pulsar via WebSocket proxy."""
import json, sys, time, urllib.request
import websocket  # pip websocket-client

BASE = sys.argv[1].rstrip("/")          # e.g. https://pulsar-production-9ac4.up.railway.app
TOPIC = "public/default/e2e-ws"
REST = f"{BASE}/admin/v2/persistent/public/default/{TOPIC.split('/', 2)[2]}"
WS = f"{BASE.replace('https://', 'wss://')}/ws/v2/producer/persistent/public/default/e2e-ws"
READER = f"{BASE.replace('https://', 'wss://')}/ws/v2/reader/persistent/public/default/e2e-ws/messages?messageId=earliest"
MSG = {"e2e": True, "t": int(time.time()), "note": "railway template e2e"}

# 1. ensure topic exists (non-partitioned)
try:
    r = urllib.request.urlopen(urllib.request.Request(
        REST, data=b"", method="PUT",
        headers={"Content-Type": "application/json"}), timeout=20)
    print(f"topic create: HTTP {r.status}")
except urllib.error.HTTPError as e:
    print(f"topic create: HTTP {e.code} ({'exists' if e.code == 409 else 'unexpected'})")
    if e.code not in (409, 204, 201):
        sys.exit(1)

def ws_send_recv(ws_url, payload):
    """Open WS, send payload (bytes/str), return (ok, reply_text)."""
    ws = websocket.create_connection(ws_url, timeout=30)
    try:
        ws.send(payload)
        while True:
            frame = ws.recv()
            if isinstance(frame, bytes):
                frame = frame.decode()
            msg = json.loads(frame)
            if msg.get("type") in ("send", "error", "connected"):
                return msg["type"] == "send" or msg.get("errorCode") is None, frame
    finally:
        ws.close()

# 2. producer round-trip: send one message, expect send-receipt with message id
ok, receipt = ws_send_recv(WS, json.dumps({"payload": MSG.encode() if False else __import__('base64').b64encode(json.dumps(MSG).encode()).decode(), "properties": {"e2e": "true"}}))
print(f"producer receipt: {receipt}")
if not ok:
    sys.exit(1)

# 3. reader consumes from earliest and must see the message
reader_ws = READER
ws = websocket.create_connection(reader_ws, timeout=30)
got = None
deadline = time.time() + 25
while time.time() < deadline:
    ws.settimeout(max(1, deadline - time.time()))
    try:
        frame = ws.recv()
    except Exception:
        break
    if isinstance(frame, bytes):
        body = frame
        # last text frame before binary carries metadata; just decode payload directly
        import base64 as b64
        got = body.decode()
        break
    meta = json.loads(frame)
    if "data" in meta:  # some proxies inline base64 payload in the text frame
        got = b64.b64decode(meta["data"]).decode()
        break
ws.close()
print(f"consumer received: {got!r}")
assert got and json.loads(got) == MSG, "round-trip mismatch"

# 4. stats sanity
stats = json.loads(urllib.request.urlopen(f"{REST}/stats", timeout=20).read())
pubs = stats.get("publishers", [])
subs = {k: v.get("msgBacklog", -1) for k, v in stats.get("subscriptions", {}).items()}
print(f"stats: publishers={len(pubs)} subs={subs}")
print("E2E-2 PASS: WebSocket produce -> persist -> consume round-trip OK")
