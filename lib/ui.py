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
    # Normalize worktreePath in live records for path comparison (macOS resolves symlinks)
    for r in live:
        if r.get("worktreePath"):
            r["_normalized_path"] = str(Path(r["worktreePath"]).resolve())

    projects_data = read_json(PROJECTS)
    # Create a map from resolved primary path back to original primary path
    primary_map = {}
    for p in projects_data:
        orig_primary = p.get("primaryPath", "")
        if orig_primary:
            resolved_primary = str(Path(orig_primary).resolve())
            primary_map[resolved_primary] = orig_primary

    projects = []
    for p in sorted(projects_data, key=lambda x: x.get("project", "")):
        primary = p.get("primaryPath", "")
        exists = os.path.isdir(primary)
        wts = []
        if exists:
            for wt in worktrees(primary):
                normalized_wt_path = str(Path(wt["path"]).resolve())
                services = [r for r in live if r.get("_normalized_path") == normalized_wt_path]
                # Preserve the path format: if we have a mapping, use it; otherwise use the resolved path
                wt_path = primary_map.get(normalized_wt_path, wt["path"])
                wts.append({**wt, "path": wt_path, "services": services})
        projects.append({**p, "exists": exists, "worktrees": wts})
    return {"projects": projects}


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
        else:
            self.send_json({"error": "not found"}, 404)


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
