#!/usr/bin/env python3
"""Check cold and warm Chromium profile routing with isolated, disposable profiles."""
import argparse
import http.server
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--browser", default="/Applications/Brave Browser.app")
args = parser.parse_args()
reports = queue.Queue()
root = pathlib.Path(tempfile.mkdtemp(prefix="switcheroo-routing-"))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/report":
            reports.put((query.get("token", [""])[0], query.get("profile", [""])[0]))
            body = b"ok"
            content_type = "text/plain"
        elif parsed.path == "/check":
            body = b"""<!doctype html><title>Switcheroo routing check</title>
<h1>Switcheroo routing check</h1><p>This window uses a disposable test profile.</p>
<script>
const query = new URLSearchParams(location.search);
if (query.has('seed')) localStorage.setItem('profile', query.get('seed'));
document.title = 'Switcheroo: ' + localStorage.getItem('profile');
fetch('/report?' + new URLSearchParams({token: query.get('token'),
  profile: localStorage.getItem('profile') || 'missing'}));
</script>"""
            content_type = "text/html"
        else:
            body = b""
            content_type = "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    cases = [
        ("Default", "personal", "personal"),
        ("Profile 1", "work", "work"),
        ("Default", None, "personal"),
        ("Profile 1", None, "work"),
    ]
    for index, (directory, seed, expected) in enumerate(cases):
        query = {"token": str(index)}
        if seed:
            query["seed"] = seed
        url = f"http://127.0.0.1:{server.server_port}/check?{urllib.parse.urlencode(query)}"
        launch = subprocess.run([
            "/usr/bin/open", "-n", "-a", args.browser, "--args",
            f"--user-data-dir={root}", f"--profile-directory={directory}",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--", url,
        ], timeout=15, capture_output=True, text=True)
        if launch.returncode:
            raise RuntimeError(launch.stderr.strip() or "Browser launch failed")
        token, actual = reports.get(timeout=40)
        assert (token, actual) == (str(index), expected), (token, actual, expected)
        print(f"PASS {index + 1}: {directory} opened in {actual}", flush=True)
    print("PASS: cold launch and warm forwarding preserve both profile stores", flush=True)
finally:
    # Only terminate processes carrying this run's unique, disposable data directory.
    try:
        processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
        pids = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
                if f"--user-data-dir={root}" in line]
        for pid in pids:
            subprocess.run(["kill", "-TERM", str(pid)], capture_output=True)
        deadline = time.monotonic() + 5
        while pids and time.monotonic() < deadline:
            remaining = []
            for pid in pids:
                try:
                    os.kill(pid, 0)
                    remaining.append(pid)
                except ProcessLookupError:
                    pass
            pids = remaining
            if pids:
                time.sleep(0.1)
    except (PermissionError, subprocess.CalledProcessError):
        print("Process inspection was denied; cleanup could not verify browser termination.", flush=True)
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)
