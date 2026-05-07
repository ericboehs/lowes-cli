"""Inspect the /quotes page DOM for create/edit affordances."""
import json, urllib.request, websocket, sys, time

ws_url = json.loads(urllib.request.urlopen('http://127.0.0.1:9222/json/version').read())['webSocketDebuggerUrl']
ws = websocket.create_connection(ws_url, timeout=5, max_size=None)

mid = [0]
def send(method, params=None, sess=None):
    mid[0] += 1
    msg = {"id": mid[0], "method": method, "params": params or {}}
    if sess: msg["sessionId"] = sess
    ws.send(json.dumps(msg))
    return mid[0]

def wait_for(target_id, timeout=5):
    ws.settimeout(timeout)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            m = json.loads(ws.recv())
        except Exception: return None
        if m.get("id") == target_id:
            return m

# Find quotes tab
i = send("Target.getTargets")
m = wait_for(i)
target = next(t for t in m["result"]["targetInfos"] if t["type"]=="page" and "lowes.com" in (t.get("url") or ""))
i = send("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True})
m = wait_for(i)
sess = m["result"]["sessionId"]

probe = sys.argv[1] if len(sys.argv) > 1 else "buttons"
if probe == "buttons":
    js = """({
        title: document.title,
        url: location.href,
        h1: [...document.querySelectorAll('h1, h2')].map(h=>h.textContent.trim()).slice(0,8),
        buttons: [...document.querySelectorAll('button, a, [role=button]')]
            .map(el=>({tag:el.tagName, text:(el.innerText||'').trim().slice(0,80), href:el.getAttribute('href')||'', testid:el.getAttribute('data-testid')||el.getAttribute('data-qe-id')||''}))
            .filter(b=>b.text && /quote|create|new|add|cart|save/i.test(b.text))
            .slice(0, 40),
        forms: [...document.querySelectorAll('form')].map(f=>({action:f.action, method:f.method})),
        scripts: [...document.querySelectorAll('script[type*=json]')].length,
        next_data: !!document.getElementById('__NEXT_DATA__')
    })"""
elif probe == "next_data":
    js = "JSON.stringify(JSON.parse(document.getElementById('__NEXT_DATA__').textContent).props || {}).slice(0, 3000)"
else:
    js = probe

i = send("Runtime.evaluate", {"expression": js, "returnByValue": True}, sess=sess)
m = wait_for(i, 10)
print(json.dumps((m or {}).get("result", {}).get("result", {}).get("value"), indent=2, default=str))
