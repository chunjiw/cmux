#!/usr/bin/env python3
"""Live check: an agent moves a browser tab between browser profiles in place (cx-d0d.83,
plans/cmux-next/data-model.md 5).

  scripts/cmux-next/browser-profile-move-live.py --tag <tag> [--out DIR] [--app PATH] [--engines webkit,cef]

Launches the tagged app (no activation, automation socket, empty config) and drives it only
through the bundled `cmux` CLI, as an agent does. A local page sets and prints a cookie,
localStorage, sessionStorage and an IndexedDB value. For each engine:

  1. `browser-profile create` makes profiles A and B (new and empty);
  2. `tab new-browser --profile A --engine E` opens the page in A and sets the values "a";
  3. `browser-profile move-tab --target tab:TAB --browser-profile B` (the daemon moves the record,
     the app re-makes the page): same tab id and position, the page reloads, every value is empty;
  4. the page sets "b" in B;
  5. move back to A: A's cookie, localStorage and IndexedDB show "a" again (sessionStorage
     belongs to the page and starts empty);
  6. `tab new-browser --profile B` opens a tab straight in B: it shows "b".

Every read is printed and every step leaves a page screenshot in --out. GUI host only (nx-remote
--needs gui --app-from-fleet). The app is quit and the tag's daemons stopped at the end. Exits 1
when a check fails.
"""
import argparse, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-profile-move-"))
parser.add_argument("--app", default=os.environ.get("NX_APP"), help="tagged .app (default: $NX_APP, else DerivedData)")
parser.add_argument("--engines", default="webkit,cef")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
RUN = str(os.getpid())
failures = []

PAGE = """<!doctype html><meta charset=utf-8><title>loading</title>
<style>body{font:26px -apple-system,sans-serif;margin:36px}#out{white-space:pre-wrap;background:#e8eefc;padding:18px}</style>
<h2>Storage this page sees</h2><div id=out>reading</div>
<script>
const set = new URLSearchParams(location.search).get('set');
function db() { return new Promise((ok, no) => { const r = indexedDB.open('proof', 1);
  r.onupgradeneeded = () => r.result.createObjectStore('kv'); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); }); }
async function idbGet() { const d = await db(); return new Promise(ok => { const g = d.transaction('kv').objectStore('kv').get('v');
  g.onsuccess = () => ok(g.result || ''); g.onerror = () => ok('ERROR'); }); }
async function idbPut(v) { const d = await db(); return new Promise(ok => { const t = d.transaction('kv', 'readwrite');
  t.objectStore('kv').put(v, 'v'); t.oncomplete = () => ok(); }); }
(async () => {
  if (set) { document.cookie = 'proof=' + set + '; max-age=86400; path=/'; localStorage.setItem('proof', set);
    sessionStorage.setItem('proof', set); await idbPut(set); }
  const cookie = (document.cookie.match(/(?:^|; )proof=([^;]*)/) || [])[1] || '';
  const v = {cookie, local: localStorage.getItem('proof') || '', session: sessionStorage.getItem('proof') || '', idb: await idbGet()};
  document.getElementById('out').textContent = 'cookie: ' + v.cookie + '\\nlocalStorage: ' + v.local +
    '\\nsessionStorage: ' + v.session + '\\nIndexedDB: ' + v.idb;
  window.proofValues = v; document.title = 'ready';
})();
</script>"""


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def cli(*args, timeout=90):
    """The agent's call: the bundled CLI against this tag's socket, with --json."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    run = subprocess.run([CLI, "--app-socket", SOCKET, "--json", *args], capture_output=True, text=True, timeout=timeout,
                         env=env, stdin=subprocess.DEVNULL)
    text = run.stdout.strip()
    print(f"$ cmux {' '.join(args)}\n  -> exit {run.returncode} {text[:600]} {run.stderr.strip()[:300]}", flush=True)
    try:
        return run.returncode, json.loads(text) if text else {}
    except ValueError:
        return run.returncode, {"text": text}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def created_tab(result):
    ids = result.get("created") or []
    return next((i for i in ids if isinstance(i, str) and i.startswith("tab_")), None)


def tab_row(tab):
    _, listed = cli("browser", tab, "tabs")
    rows = listed.get("tabs") or []
    index = next((n for n, row in enumerate(rows) if row.get("id") == tab), None)
    return (rows[index] if index is not None else {}), index, rows


def read(tab, step):
    """Waits for the page to finish its reads; returns {cookie, local, session, idb} and saves a screenshot."""
    code, _ = cli("browser", tab, "wait", "--function", "document.title === 'ready'", "--timeout-ms", "30000")
    _, value = cli("browser", tab, "eval", "JSON.stringify(window.proofValues || null)")
    values = json.loads(value.get("value") or "null") if isinstance(value.get("value"), str) else value.get("value")
    cli("browser", tab, "screenshot", "--out", os.path.join(opts.out, f"{step}.png"))
    print(f"READ {step}: {json.dumps(values)}", flush=True)
    return values or {}


def profile_id(name, engine):
    """Creates profile NAME (`browser-profile create`) and learns its id from a probe tab opened in it."""
    cli("browser-profile", "create", "--name", name)
    _, opened = cli("browser-profile", "new-tab", "--browser-profile", name, "--url", "about:blank")
    probe = created_tab(opened)
    state = quiet_wait(lambda: cli("browser", probe, "state")[1].get("profile"), 20) if probe else None
    if probe:
        cli("browser", probe, "close")
    return state


def move(tab, name):
    return cli("browser-profile", "move-tab", "--target", f"tab:{tab}", "--browser-profile", name)


def run_engine(engine, url):
    a_name, b_name = f"Proof A {engine} {RUN}", f"Proof B {engine} {RUN}"
    a, b = profile_id(a_name, engine), profile_id(b_name, engine)
    check(bool(a) and bool(b) and a != b and "default" not in (a, b), f"{engine}: new profiles A {a} and B {b}")
    code, opened = cli("tab", "new-browser", "--url", url + "?set=a", "--profile", a or "", "--engine", engine)
    tab = created_tab(opened)
    check(code == 0 and bool(tab), f"{engine}: tab opened in A: {tab}")
    if not tab:
        return
    _, index, _ = tab_row(tab)
    first = read(tab, f"{engine}-1-A-set")
    check(first.get("cookie") == "a" and first.get("local") == "a" and first.get("idb") == "a", f"{engine}: A has a/a/a: {first}")

    code, _ = move(tab, b_name)
    state = quiet_wait(lambda: (lambda s: s if s.get("profile") == b else None)(cli("browser", tab, "state")[1]), 20)
    check(code == 0 and bool(state), f"{engine}: same tab id {tab} now reports profile B: {state}")
    _, moved_index, _ = tab_row(tab)
    check(moved_index == index, f"{engine}: tab kept its position {index} -> {moved_index}")
    empty = read(tab, f"{engine}-2-B-empty")
    check(all(empty.get(k) == "" for k in ("cookie", "local", "session", "idb")), f"{engine}: B shows every value empty: {empty}")

    cli("browser", tab, "navigate", url + "?set=b")
    second = read(tab, f"{engine}-3-B-set")
    check(second.get("cookie") == "b" and second.get("local") == "b" and second.get("idb") == "b", f"{engine}: B has b/b/b: {second}")

    move(tab, a_name)
    quiet_wait(lambda: cli("browser", tab, "state")[1].get("profile") == a, 20)
    back = read(tab, f"{engine}-4-back-in-A")
    check(back.get("cookie") == "a" and back.get("local") == "a" and back.get("idb") == "a" and back.get("session") == "",
          f"{engine}: back in A shows a/a/a, sessionStorage empty: {back}")

    code, opened = cli("tab", "new-browser", "--url", url, "--profile", b or "", "--engine", engine)
    other = created_tab(opened)
    check(code == 0 and bool(other), f"{engine}: new tab opened straight in B: {other}")
    if other:
        state = cli("browser", other, "state")[1]
        check(state.get("profile") == b, f"{engine}: the new tab reports profile B: {state.get('profile')}")
        fresh = read(other, f"{engine}-5-new-tab-in-B")
        check(fresh.get("cookie") == "b" and fresh.get("local") == "b" and fresh.get("idb") == "b", f"{engine}: new tab in B shows b/b/b: {fresh}")
    shot = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{engine}-window.png")}, timeout=60)
    print(f"window snapshot {engine}: {json.dumps(shot)[:200]}", flush=True)


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"browser-profile-move-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}/proof"
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,860"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, page {URL}, out {opts.out}", flush=True)
try:
    ready = quiet_wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180)
    check(bool(ready), "the app opened a window")
    if ready:
        for engine in opts.engines.split(","):
            run_engine(engine.strip(), URL)
finally:
    print("quit:", json.dumps(rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=15))[:200], flush=True)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()
    server.shutdown()
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
