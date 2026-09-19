#!/usr/bin/env python3
"""Measure a local release build at idle without changing default-browser settings."""
import json
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent.parent
bundle = root / "dist/Switcheroo.app"
binary = bundle / "Contents/MacOS/Switcheroo"
capture_dir = root / ".build/captures"
capture_dir.mkdir(parents=True, exist_ok=True)

if subprocess.run(["pgrep", "-x", "Switcheroo"], capture_output=True).returncode == 0:
    raise SystemExit("Quit Switcheroo before this check so it can measure only its own instance.")

handler_source = """
import AppKit
var handlers: [String: String] = [:]
for scheme in ["http", "https"] {
    handlers[scheme] = NSWorkspace.shared.urlForApplication(toOpen: URL(string: scheme + "://example.com")!)?.path ?? "none"
}
print(String(data: try JSONSerialization.data(withJSONObject: handlers), encoding: .utf8)!)
"""


def handlers():
    result = subprocess.run(["swift", "-"], input=handler_source, text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def sample(pid):
    fields = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=,rss="], text=True).split()
    seconds = sum(float(part) * 60 ** index for index, part in enumerate(reversed(fields[0].split(":"))))
    return seconds, int(fields[1])


before = handlers()
with (capture_dir / "runtime.log").open("w") as log:
    process = subprocess.Popen([str(binary)], stdout=log, stderr=log)
    try:
        time.sleep(3)
        if process.poll() is not None:
            raise RuntimeError("Switcheroo exited during startup; inspect .build/captures/runtime.log")
        cpu_before, _ = sample(process.pid)
        started = time.monotonic()
        time.sleep(5)
        cpu_after, rss = sample(process.pid)
        elapsed = time.monotonic() - started
        after = handlers()
        result = {
            "appBundleBytes": sum(path.stat().st_size for path in bundle.rglob("*") if path.is_file()),
            "idleCPUPercent": round((cpu_after - cpu_before) / elapsed * 100, 2),
            "residentMemoryMiB": round(rss / 1024, 2),
            "sampleSeconds": round(elapsed, 2),
            "defaultBrowserUnchanged": before == after,
            "context": "Release build at idle; first-run Settings may be visible. RSS includes shared framework pages.",
        }
        (capture_dir / "release-runtime.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        assert before == after, "Default browser changed unexpectedly"
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
