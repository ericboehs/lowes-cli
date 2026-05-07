"""
Reusable: install fetch hook in /quotes, perform the action specified
on the command line, dump captured fetches.

Actions:
  install  — just install the hook (then perform the action manually if you want)
  dump     — dump the buffer and clear

Usage:
  uv run python /tmp/api-investigate.py install
  uv run python /tmp/api-investigate.py dump
"""
import json, sys, time, urllib.request, websocket

action = sys.argv[1] if len(sys.argv) > 1 else "install"

ws_url = json.loads(urllib.request.urlopen('http://127.0.0.1:9222/json/version').read())['webSocketDebuggerUrl']
ws = websocket.create_connection(ws_url, timeout=10, max_size=None)
mid = [0]
def s(m, p=None, sess=None):
    mid[0] += 1; msg = {"id": mid[0], "method": m, "params": p or {}}
    if sess: msg["sessionId"] = sess
    ws.send(json.dumps(msg)); return mid[0]
def w(tid, t=5):
    ws.settimeout(t); end = time.time() + t
    while time.time() < end:
        try: m = json.loads(ws.recv())
        except Exception: return None
        if m.get("id") == tid: return m
def evp(expr, sess, t=5, prom=False):
    i = s("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": prom}, sess=sess)
    return (w(i, t) or {}).get("result", {}).get("result", {}).get("value")

i = s("Target.getTargets"); m = w(i)
tgt = next(x for x in m["result"]["targetInfos"] if x["type"]=="page" and "lowes" in (x.get("url") or ""))
i = s("Target.attachToTarget", {"targetId": tgt["targetId"], "flatten": True}); m = w(i)
sess = m["result"]["sessionId"]

HOOK = '''
(()=>{
  if (window.__loggedFetches) return 'already';
  window.__loggedFetches = [];
  const orig = window.fetch;
  window.fetch = async function(input, init) {
    const url = typeof input === 'string' ? input : input.url;
    const method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
    const body = init && init.body;
    let resp; try { resp = await orig.apply(this, arguments); } catch(e){
      window.__loggedFetches.push({url, method, body: body && body.toString().slice(0,4000), error: e.message});
      throw e;
    }
    let txt=''; try { txt = await resp.clone().text(); } catch(e){}
    window.__loggedFetches.push({url, method, status: resp.status, body: body && body.toString().slice(0,4000), response: txt.slice(0,8000), via:'fetch'});
    return resp;
  };
  const oOpen = XMLHttpRequest.prototype.open;
  const oSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method,url,...rest){this._lurl=url;this._lmethod=method;return oOpen.call(this,method,url,...rest)};
  XMLHttpRequest.prototype.send = function(body){
    this.addEventListener('load', ()=>{
      window.__loggedFetches.push({url:this._lurl, method:this._lmethod, status:this.status, body: body && body.toString().slice(0,4000), response: (this.responseText||'').slice(0,8000), via:'xhr'});
    });
    return oSend.call(this, body);
  };
  return 'installed';
})()
'''

if action == "install":
    r = evp(HOOK, sess)
    print("hook:", r)
elif action == "dump":
    raw = evp("JSON.stringify(window.__loggedFetches || [])", sess)
    arr = json.loads(raw or "[]")
    # Clear buffer for next dump
    evp("window.__loggedFetches = []", sess)
    NOISE = ("fullstory","mpulse","liadm","pinterest","doubleclick","wandzapi","signifyd","insight.adsrvr","go-mpulse","feedback.lowes","xthevi","baymax","/_sec/","/cf-data","c.go-mpulse","rs.fullstory","ad.doubleclick","rp.liadm","imgs.signifyd","ct.pinterest","cfs.wandzapi","autocomplete","google-analytics","analytics.google","collect?v=2","/oneapp/","/_next/data","jsd-collector","/pagead/","/ccm/","/rmkt/","www.googleadservices","amazon-adsystem","/baymax/","/cookieguardian")
    print(f"=== {len(arr)} total ===")
    relevant = [r for r in arr if not any(n in (r.get('url','') or '') for n in NOISE)]
    print(f"=== {len(relevant)} relevant ===")
    for r in relevant:
        print(f"\n{r.get('method')} {r.get('status','--')} {r.get('url','')[:140]}")
        if r.get('body'): print(f"  REQ: {r['body'][:600]}")
        if r.get('response'): print(f"  RES: {r['response'][:600]}")
    with open("/tmp/api-dump.json","w") as f: json.dump(arr, f, indent=2)
    print(f"\n→ full dump: /tmp/api-dump.json")
elif action == "fill_clear":
    evp("window.__loggedFetches = []", sess)
    print("cleared")
else:
    print(f"unknown action: {action}")
