#!/usr/bin/env python3
"""margay ui — local web control panel. Python 3 stdlib only.

Read-side: projects.json + live `git worktree list` + registry.json.
Write-side: shells out to the margay CLI; never edits margay's JSON files.
"""
import argparse
import json
import os
import subprocess
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

MARGAY_HOME = Path(os.environ.get("MARGAY_HOME", str(Path.home() / ".margay")))
PROJECTS = MARGAY_HOME / "projects.json"
REGISTRY = MARGAY_HOME / "registry.json"
LOG_DIR = MARGAY_HOME / "logs"
MARGAY_BIN = os.environ.get("MARGAY_BIN", str(Path(__file__).resolve().parent.parent / "margay"))
PAGE = Path(__file__).resolve().parent / "ui.html"
TAIL_BYTES = 65536

mutate_lock = threading.Lock()


def read_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def worktrees(primary):
    """Parse `git worktree list --porcelain` (same rules as engine.sh)."""
    try:
        out = subprocess.run(
            ["git", "-C", primary, "worktree", "list", "--porcelain"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows, path, branch = [], None, None
    for line in out.splitlines():
        if line.startswith("worktree "):
            if path:
                rows.append({"path": path, "branch": branch or "HEAD"})
            path, branch = line[len("worktree "):], None
        elif line.startswith("branch refs/heads/"):
            branch = line[len("branch refs/heads/"):]
        elif line == "detached":
            branch = "HEAD"
    if path:
        rows.append({"path": path, "branch": branch or "HEAD"})
    return rows


def state():
    live = [r for r in read_json(REGISTRY) if pid_alive(r.get("pid"))]
    projects = []
    for p in sorted(read_json(PROJECTS), key=lambda x: x.get("project", "")):
        primary = p.get("primaryPath", "")
        exists = os.path.isdir(primary)
        wts = []
        if exists:
            for wt in worktrees(primary):
                services = [r for r in live if r.get("worktreePath") == wt["path"]]
                wts.append({**wt, "services": services})
        projects.append({**p, "exists": exists, "worktrees": wts})
    return {"projects": projects}


def log_slice(file_param, offset):
    """Bytes from offset (or the last TAIL_BYTES if offset<0). None = refuse."""
    real = os.path.realpath(file_param)
    logs_root = os.path.realpath(str(LOG_DIR))
    if not real.startswith(logs_root + os.sep):
        return None
    if not os.path.isfile(real):
        return None
    try:
        size = os.path.getsize(real)
    except OSError:
        return None
    if offset < 0:
        offset = max(0, size - TAIL_BYTES)
    if offset > size:          # rotated or truncated: start over
        offset = 0
    with open(real, "rb") as f:
        f.seek(offset)
        data = f.read(TAIL_BYTES)
    return {"data": data.decode("utf-8", "replace"), "offset": offset + len(data)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):   # keep the terminal quiet
        pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/":
            if not PAGE.is_file():
                self.send_json({"error": "ui.html missing"}, 404)
                return
            body = PAGE.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif url.path == "/api/state":
            self.send_json(state())
        elif url.path == "/api/log":
            q = parse_qs(url.query)
            try:
                offset = int(q.get("offset", ["-1"])[0])
            except ValueError:
                offset = -1
            res = log_slice(q.get("file", [""])[0], offset)
            if res is None:
                self.send_json({"error": "no such log"}, 404)
            else:
                self.send_json(res)
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            self.send_json({"ok": False, "output": "bad json body"}, 400)
            return
        if url.path in ("/api/up", "/api/down"):
            wt = body.get("worktreePath", "")
            if not os.path.isdir(wt):
                self.send_json({"ok": False, "output": "no such worktree: %s" % wt}, 400)
                return
            self.run_margay([url.path.rsplit("/", 1)[1]], cwd=wt)
        elif url.path == "/api/unregister":
            path = body.get("primaryPath", "")
            if not path:
                self.send_json({"ok": False, "output": "primaryPath required"}, 400)
                return
            self.run_margay(["unregister", path], cwd=None)
        else:
            self.send_json({"error": "not found"}, 404)

    def run_margay(self, argv, cwd):
        with mutate_lock:   # registry writes are not concurrent-safe
            try:
                proc = subprocess.run(
                    [MARGAY_BIN] + argv, cwd=cwd,
                    capture_output=True, text=True, timeout=300,
                )
            except (OSError, subprocess.TimeoutExpired) as e:
                self.send_json({"ok": False, "output": str(e)}, 500)
                return
        ok = proc.returncode == 0
        self.send_json({"ok": ok, "output": proc.stdout + proc.stderr},
                       200 if ok else 500)


def main():
    ap = argparse.ArgumentParser(prog="margay ui")
    ap.add_argument("--port", type=int, default=7997)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = "http://127.0.0.1:%d" % args.port
    print("margay ui → %s   (Ctrl-C to stop)" % url)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
