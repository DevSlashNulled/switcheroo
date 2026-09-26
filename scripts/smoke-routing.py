#!/usr/bin/env python3
"""Check real picker/rule routing and browser focus with disposable profiles."""
import argparse
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--browser", default="/Applications/Brave Browser.app")
args = parser.parse_args()
root = pathlib.Path(tempfile.mkdtemp(prefix="switcheroo-routing-"))
browser = root / pathlib.Path(args.browser).name
data = root / "data"
reports = root / "reports"
reports.mkdir()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/report":
            token = query.get("token", [""])[0]
            if token in {"0", "1", "2", "3"} and query.get("focused") == ["true"]:
                report = {"token": token, "profile": query.get("profile", [""])[0], "focused": True}
                temporary = reports / f"{token}.tmp"
                temporary.write_text(json.dumps(report))
                temporary.replace(reports / f"{token}.json")
            body = b"ok"
            content_type = "text/plain"
        elif parsed.path == "/check":
            body = b"""<!doctype html><title>Switcheroo routing check</title>
<h1>Switcheroo routing check</h1><p>This window uses a disposable test profile.</p>
<script>
const query = new URLSearchParams(location.search);
if (query.has('seed')) localStorage.setItem('profile', query.get('seed'));
document.title = 'Switcheroo: ' + localStorage.getItem('profile');
const report = () => {
  if (!document.hasFocus()) return;
  clearInterval(timer);
  fetch('/report?' + new URLSearchParams({token: query.get('token'),
    profile: localStorage.getItem('profile') || 'missing', focused: 'true'}));
};
const timer = setInterval(report, 100);
report();
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
    subprocess.run(["swift", "build", "--build-tests"], check=True)
    products = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], text=True).strip())
    platform = pathlib.Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip())
    frameworks = platform / "Developer/Library/Frameworks"
    host = root / "Switcheroo Focus Tests.app"
    executable = host / "Contents/MacOS/FocusTestHost"
    executable.parent.mkdir(parents=True)
    test_bundle = host / "Contents/PlugIns/SwitcherooAppTests.xctest"
    source_bundle = next(path for name in ["SwitcherooAppTests.xctest", "SwitcherooPackageTests.xctest"]
                         if (path := products / name).exists())
    shutil.copytree(source_bundle, test_bundle)
    with (host / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "local.switcheroo.focus-tests.host", "CFBundleExecutable": "FocusTestHost",
                      "CFBundleName": "Switcheroo Focus Tests", "CFBundlePackageType": "APPL", "LSUIElement": True}, info)
    subprocess.run(["swiftc", "-parse-as-library", "scripts/focus-test-host.swift", "-F", str(frameworks),
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                    "-Xlinker", "-rpath", "-Xlinker", str(platform / "Developer/usr/lib"),
                    "-o", str(executable)], check=True)
    # A separate app path prevents activation checks from matching a personal browser process.
    subprocess.run(["/bin/cp", "-cR", args.browser, str(browser)], check=True)
    for directory in ["Default", "Profile 1"]:
        (data / directory).mkdir(parents=True)
    (data / "First Run").touch()
    test_environment = dict(os.environ)
    test_environment.update({
        "SWITCHEROO_ROUTING_SMOKE_URL": f"http://127.0.0.1:{server.server_port}/check",
        "SWITCHEROO_ROUTING_SMOKE_APP": str(browser),
        "SWITCHEROO_ROUTING_SMOKE_ROOT": str(data),
        "SWITCHEROO_ROUTING_SMOKE_REPORTS": str(reports),
        "SWITCHEROO_FOCUS_TEST_BUNDLE": str(test_bundle),
        "SWITCHEROO_FOCUS_RESULT": str(root / "result"),
    })
    stdout = root / "stdout.log"
    stderr = root / "stderr.log"
    try:
        subprocess.run(["/usr/bin/open", "-n", "-W", "-a", str(host), "--stdout", str(stdout), "--stderr", str(stderr),
                        "--args", "--filter", "chromiumPickerAndRuleFocus"],
                       env=test_environment, check=True, timeout=240)
    finally:
        for output in [stdout, stderr]:
            if output.exists():
                print(output.read_text(), end="", flush=True)
    assert (root / "result").read_text() == "0", "Native focus test failed"
    for index, expected in enumerate(["personal", "work", "personal", "work"]):
        report = json.loads((reports / f"{index}.json").read_text())
        assert report == {"token": str(index), "profile": expected, "focused": True}, report
    print("PASS: cold, warm, hidden, and saved-rule launches select the right profile and foreground browser", flush=True)
finally:
    # Only terminate browser and host processes belonging to this run.
    cleanup_complete = True
    try:
        processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
        pids = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
                if f"--user-data-dir={data}" in line
                or str(root / "Switcheroo Focus Tests.app/Contents/MacOS/FocusTestHost") in line]
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
        cleanup_complete = not pids
    except (PermissionError, subprocess.CalledProcessError):
        cleanup_complete = False
        print("Process inspection was denied; cleanup could not verify browser termination.", flush=True)
    server.shutdown()
    if cleanup_complete:
        lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for bundle in [browser, root / "Switcheroo Focus Tests.app"]:
            if bundle.exists():
                subprocess.run([lsregister, "-u", str(bundle)], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)
    else:
        print(f"Test processes are still running; fixtures preserved at {root}", flush=True)
