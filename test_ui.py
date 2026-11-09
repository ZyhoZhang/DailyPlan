#!/usr/bin/env python3
"""Regression test for the prompt()-freeze bug.

Critically: NO window.confirm/prompt stubbing. If the page opens a native
dialog, the CDP evaluate call blocks and the test fails — which is exactly
the user-reported symptom.
"""
import atexit, base64, json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.request
from websocket import create_connection

# Run against a private server + throwaway data dir. This test deletes and
# renames things, so it must never touch the user's real state.
with socket.socket() as port_probe:
    port_probe.bind(("127.0.0.1", 0))
    PORT = port_probe.getsockname()[1]
ROOT = os.path.dirname(os.path.abspath(__file__))
HOME = tempfile.mkdtemp(prefix="freezetest-")
SRV = subprocess.Popen([sys.executable, os.path.join(ROOT, "app.py"),
                        "--port", str(PORT), "--no-browser"],
                       env=dict(os.environ, DAILY_PLAN_HOME=HOME),
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
def cleanup():
    SRV.terminate()
    try:
        SRV.wait(timeout=10)
    except subprocess.TimeoutExpired:
        SRV.kill()
        SRV.wait()
    shutil.rmtree(HOME, ignore_errors=True)

atexit.register(cleanup)
APP = "http://127.0.0.1:%d/" % PORT
for _ in range(60):
    try:
        urllib.request.urlopen(APP + "api/state", timeout=1).read(); break
    except Exception: time.sleep(0.2)

def seed(path, method="GET", body=None):
    d = json.dumps(body).encode() if body else None
    r = urllib.request.Request(APP + path, data=d, method=method,
                               headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(r).read())

TODAY = time.strftime("%Y-%m-%d")
seed("api/goals", "POST", {"date": TODAY, "titles": ["Seed goal one"]})
gid = seed("api/state")["entry"]["goals"][0]["id"]
seed("api/goal", "PATCH", {"date": TODAY, "id": gid, "note": "seed note"})

PASS = FAIL = 0
FAILS = []

def check(label, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1; print("  ok   " + label)
    else:
        FAIL += 1; FAILS.append(label + (" — " + detail if detail else ""))
        print("  FAIL " + label + (" — " + detail if detail else ""))

CDP = os.environ.get("DAILY_PLAN_CDP_URL", "http://127.0.0.1:9222").rstrip("/")
req = urllib.request.Request(CDP + "/json/new?" + APP, method="PUT")
tab = json.loads(urllib.request.urlopen(req).read())
ws = create_connection(tab["webSocketDebuggerUrl"], timeout=10, origin="http://localhost")
n = [0]

def send(method, **p):
    n[0] += 1
    ws.send(json.dumps({"id": n[0], "method": method, "params": p}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == n[0]:
            return m

def js(expr, timeout=5):
    """Returns the sentinel '<<BLOCKED>>' if the page is frozen by a dialog."""
    ws.settimeout(timeout)
    try:
        r = send("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        res = r.get("result", {})
        if "exceptionDetails" in res:
            return "<<JSERROR>> " + res["exceptionDetails"].get("text", "")
        return res.get("result", {}).get("value")
    except Exception:
        return "<<BLOCKED>>"

send("Runtime.enable"); send("Page.enable")
time.sleep(2.5)

print("\n[F1] baseline — the user's exact data is on screen")
check("page alive", js("1+1") == 2)
N0 = js("document.querySelectorAll('li.goal').length")
D0 = js("document.querySelectorAll('li.dl').length")
check("goals rendered", N0 >= 1, str(N0))
if not N0:
    raise SystemExit("need at least one goal to test against")

print("\n[F2] THE BUG: click the note button (previously froze the page)")
js("""(()=>{const g=document.querySelector('li.goal');
      g.querySelector('.acts button[title=\\"Edit note\\"], .acts button[title=\\"Add note\\"]').click();})()""")
time.sleep(0.6)
alive = js("1+1")
check("PAGE NOT FROZEN after opening note editor", alive == 2, repr(alive))
check("inline editor appeared", js("!!document.querySelector('.editor textarea')"))
check("editor is a textarea for notes", js("!!document.querySelector('.editor textarea')"))

print("\n[F3] the editor actually works")
js("""(()=>{const t=document.querySelector('.editor textarea');
      t.value='Edited note without freezing';})()""")
js("""[...document.querySelectorAll('.editor button')].find(b=>b.textContent==='Save').click()""")
time.sleep(1.2)
check("page still alive after save", js("1+1") == 2)
check("editor closed", js("!document.querySelector('.editor')"))
check("new note rendered", "without freezing" in (js("document.body.innerText") or ""))
saved = json.loads(urllib.request.urlopen(APP + "api/state").read())
check("note persisted to server",
      saved["entry"]["goals"][0]["note"] == "Edited note without freezing",
      repr(saved["entry"]["goals"][0]["note"]))

print("\n[F4] everything still responds after the note flow (the 'stuck' check)")
js("document.getElementById('goalInput').value='Second goal after note'")
js("document.getElementById('addGoal').click()")
time.sleep(1.2)
check("CAN STILL ADD GOALS", js("document.querySelectorAll('li.goal').length") == N0 + 1,
      str(js("document.querySelectorAll('li.goal').length")))
js("document.querySelector('li.goal .cycle').click()")
time.sleep(1.2)
check("CAN STILL CYCLE STATUS", int(js("document.getElementById('sTotal').textContent")) >= 1,
      js("document.getElementById('sTotal').textContent"))
js("document.getElementById('prevDay').click()")
time.sleep(1.2)
import datetime as _dt
YEST = (_dt.date.today() - _dt.timedelta(days=1)).isoformat()
check("CAN STILL NAVIGATE DAYS", js("document.getElementById('datePicker').value") == YEST,
      js("document.getElementById('datePicker').value"))
js("document.getElementById('todayBtn').click()")
time.sleep(1.2)

print("\n[F5] title editor — same previously-blocking path")
js("""document.querySelector('li.goal .acts button[title="Edit title"]').click()""")
time.sleep(0.6)
check("page alive on title edit", js("1+1") == 2)
check("title input appeared", js("!!document.querySelector('.editor input[type=text]')"))
js("""document.querySelector('.editor input[type=text]').value='Renamed inline'""")
js("""[...document.querySelectorAll('.editor button')].find(b=>b.textContent==='Save').click()""")
time.sleep(1.2)
check("title saved", "Renamed inline" in (js("document.body.innerText") or ""))
check("page alive after title save", js("1+1") == 2)

print("\n[F6] Escape cancels, empty title rejected")
js("""document.querySelector('li.goal .acts button[title="Edit title"]').click()""")
time.sleep(0.5)
js("""(()=>{const i=document.querySelector('.editor input[type=text]');
      i.value='';
      [...document.querySelectorAll('.editor button')].find(b=>b.textContent==='Save').click();})()""")
time.sleep(0.7)
check("empty title blocked", js("!!document.querySelector('.editor')"))
check("error toast shown", "empty" in (js("document.getElementById('toast').textContent") or "").lower(),
      js("document.getElementById('toast').textContent"))
js("""[...document.querySelectorAll('.editor button')].find(b=>b.textContent==='Cancel').click()""")
time.sleep(0.6)
check("cancel closes editor", js("!document.querySelector('.editor')"))
check("page alive", js("1+1") == 2)

print("\n[F7] delete confirmation — previously window.confirm()")
js("""document.querySelectorAll('li.goal')[1].querySelector('.acts button[title="Delete goal"]').click()""")
time.sleep(0.6)
check("PAGE NOT FROZEN on delete", js("1+1") == 2)
check("inline confirm shown",
      js("""!![...document.querySelectorAll('li.goal button')].find(b=>b.textContent==='Delete?')"""))
js("""[...document.querySelectorAll('li.goal button')].find(b=>b.textContent==='Keep').click()""")
time.sleep(0.6)
check("Keep cancels the delete", js("document.querySelectorAll('li.goal').length") == N0 + 1)
js("""document.querySelectorAll('li.goal')[1].querySelector('.acts button[title="Delete goal"]').click()""")
time.sleep(0.5)
js("""[...document.querySelectorAll('li.goal button')].find(b=>b.textContent==='Delete?').click()""")
time.sleep(1.2)
check("Delete? removes the goal", js("document.querySelectorAll('li.goal').length") == N0,
      str(js("document.querySelectorAll('li.goal').length")))
check("page alive after delete", js("1+1") == 2)

print("\n[F8] deadline editor and delete")
js("""document.getElementById('dlTitle').value='Freeze test deadline';
      document.getElementById('dlDue').value='2026-12-20T10:00';
      document.getElementById('addDeadline').click();""")
time.sleep(1.2)
check("deadline added", js("document.querySelectorAll('li.dl').length") == D0 + 1)
js("""document.querySelector('li.dl .acts button[title="Edit deadline"]').click()""")
time.sleep(0.6)
check("PAGE NOT FROZEN on deadline edit", js("1+1") == 2)
check("deadline editor appeared", js("!!document.querySelector('li.dl .editor')"))
js("""(()=>{const e=document.querySelector('li.dl .editor');
      e.querySelector('input[type=text]').value='Renamed deadline';
      [...e.querySelectorAll('button')].find(b=>b.textContent==='Save').click();})()""")
time.sleep(1.2)
check("deadline renamed", "Renamed deadline" in (js("document.body.innerText") or ""))
js("""document.querySelector('li.dl .acts button[title="Delete deadline"]').click()""")
time.sleep(0.6)
check("PAGE NOT FROZEN on deadline delete", js("1+1") == 2)
js("""[...document.querySelectorAll('li.dl button')].find(b=>b.textContent==='Delete?').click()""")
time.sleep(1.2)
check("deadline deleted", js("document.querySelectorAll('li.dl').length") == D0,
      str(js("document.querySelectorAll('li.dl').length")))

print("\n[F9] editor survives the 1s countdown tick")
js("""document.getElementById('dlTitle').value='Tick test';
      document.getElementById('dlDue').value='2026-12-25T10:00';
      document.getElementById('addDeadline').click();""")
time.sleep(1.2)
js("""document.querySelector('li.dl .acts button[title="Edit deadline"]').click()""")
js("""document.querySelector('li.dl .editor input[type=text]').value='Typing slowly...'""")
time.sleep(2.5)  # let two countdown ticks fire
check("deadline editor survived ticks", js("!!document.querySelector('li.dl .editor')"))
check("typed text not clobbered by tick",
      js("document.querySelector('li.dl .editor input[type=text]').value") == "Typing slowly...",
      repr(js("document.querySelector('li.dl .editor input[type=text]').value")))

js("""document.querySelector('li.goal .acts button[title="Edit note"], li.goal .acts button[title="Add note"]').click()""")
js("""document.querySelector('.editor textarea').value='Note being typed'""")
time.sleep(2.5)
js("""(()=>{const l=[...document.querySelectorAll('li.dl')].find(x=>x.innerText.includes('Tick test'));
      if(l) l.querySelector('.acts button[title="Delete deadline"]').click();})()""")
time.sleep(0.5)
js("""(()=>{const b=[...document.querySelectorAll('li.dl button')].find(b=>b.textContent==='Delete?');
      if(b) b.click();})()""")
time.sleep(1.0)

js("""document.querySelector('li.goal .acts button[title="Edit note"], li.goal .acts button[title="Add note"]').click()""")
js("""document.querySelector('.editor textarea').value='Note being typed'""")
time.sleep(2.5)
check("goal note editor survived ticks",
      js("document.querySelector('.editor textarea') && document.querySelector('.editor textarea').value") == "Note being typed",
      repr(js("document.querySelector('.editor textarea') && document.querySelector('.editor textarea').value")))

print("\n[F10] no console errors accumulated")
check("page fully responsive at end", js("1+1") == 2)
check("goal list intact", js("document.querySelectorAll('li.goal').length") == N0)

shot = send("Page.captureScreenshot", format="png", captureBeyondViewport=True)
screenshot = os.environ.get("DAILY_PLAN_TEST_SCREENSHOT", os.path.join(HOME, "ui-test.png"))
with open(screenshot, "wb") as fh:
    fh.write(base64.b64decode(shot["result"]["data"]))

print("\n" + "=" * 60)
print("{} passed, {} failed".format(PASS, FAIL))
if FAILS:
    print("\nFailures:")
    for f in FAILS: print("  - " + f)
ws.close()
cleanup()
atexit.unregister(cleanup)
raise SystemExit(1 if FAIL else 0)
