#!/usr/bin/env python3
"""Open one localhost test tab in Safari through Switcheroo's actual launcher."""
import http.server
import os
import queue
import subprocess
import threading

requests = queue.Queue()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/switcheroo-check":
            requests.put(self.headers.get("User-Agent", ""))
        body = b"<!doctype html><title>Switcheroo routing check</title><h1>Switcheroo routing check passed</h1><p>You can close this test tab.</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    test_environment = dict(os.environ)
    test_environment["SWITCHEROO_SAFARI_SMOKE_URL"] = f"http://127.0.0.1:{server.server_port}/switcheroo-check"
    subprocess.run(["swift", "test", "--filter", "safariReceivesExplicitLaunch"],
                   env=test_environment, check=True, timeout=60)
    user_agent = requests.get(timeout=30)
    assert "Safari/" in user_agent and "Chrome/" not in user_agent, "Unexpected browser received the link"
    print("PASS: Safari fetched the local test page through BrowserLauncher", flush=True)
finally:
    server.shutdown()
