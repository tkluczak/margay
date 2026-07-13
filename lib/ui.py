#!/usr/bin/env python3
"""margay ui — local web control panel. Python 3 stdlib only.

Read-side: projects.json + live `git worktree list` + registry.json.
Write-side: shells out to the margay CLI; never edits margay's JSON files.
"""
import argparse
import http.client
import json
import os
import re
import select
import socket
import subprocess
import sys
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


PROXY = {"port": None}   # set by main() once the proxy listener binds


def slugify(name):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9-]", "-", str(name).lower())).strip("-")


def loopback_peer(ip):
    """True iff the TCP peer is a loopback address (guards the wildcard-bound proxy)."""
    return ip == "::1" or ip.startswith("127.") or ip.startswith("::ffff:127.")


def host_url(host):
    if PROXY["port"] in (None, 80):
        return "http://%s/" % host
    return "http://%s:%d/" % (host, PROXY["port"])


def leaf_services(rows):
    """Rows of one worktree -> services no sibling row's `uses` points at."""
    used = {r.get("uses") for r in rows if r.get("uses")}
    return [r for r in rows if "http://localhost:%s" % r.get("port") not in used]


def build_routes():
    """Host label -> upstream port for every live service.

    Root hosts: `<wtslug>.<pslug>.localhost` (or `<pslug>.localhost` for the
    primary checkout) map to the worktree's unique dependency leaf; every
    service also gets `<svcslug>.` prefixed onto the base. Slug collisions
    resolve to the earliest startedAt; losers get no hosts at all.
    Returns (routes, wt_info) with wt_info[worktreePath] =
    {"host": root host or None, "collision": bool}.
    """
    live = [r for r in read_json(REGISTRY) if pid_alive(r.get("pid"))]
    primaries = {}
    for p in read_json(PROJECTS):
        if isinstance(p, dict):
            primaries[p.get("project")] = p.get("primaryPath")
    by_wt = {}
    for r in live:
        by_wt.setdefault((r.get("project"), r.get("worktreePath")), []).append(r)
    routes, info = {}, {}
    claimed = set()
    ordered = sorted(by_wt.items(),
                     key=lambda kv: min(r.get("startedAt") or "" for r in kv[1]))
    for (project, wt_path), rows in ordered:
        pslug = slugify(project)
        is_primary = primaries.get(project) == wt_path
        base = ("%s.localhost" % pslug if is_primary
                else "%s.%s.localhost" % (slugify(os.path.basename(wt_path or "")), pslug))
        if base in claimed or base in routes:
            info[wt_path] = {"host": None, "collision": True}
            continue
        claimed.add(base)
        leaves = leaf_services(rows)
        root = leaves[0] if len(leaves) == 1 else None
        if root:
            routes.setdefault(base, root.get("port"))
        for r in rows:
            routes.setdefault("%s.%s" % (slugify(r.get("service")), base), r.get("port"))
        info[wt_path] = {"host": base if root else None, "collision": False}
    return routes, info


def state():
    live = [r for r in read_json(REGISTRY) if pid_alive(r.get("pid"))]
    _, wt_info = build_routes()
    proxy_up = PROXY["port"] is not None
    projects = []
    for p in sorted(read_json(PROJECTS), key=lambda x: x.get("project", "")):
        if not isinstance(p, dict):
            continue
        primary = p.get("primaryPath", "")
        pslug = slugify(p.get("project", ""))
        exists = os.path.isdir(primary)
        wts = []
        if exists:
            for wt in worktrees(primary):
                name = os.path.basename(wt["path"])
                is_primary = wt["path"] == primary
                slug = slugify(name)
                base = ("%s.localhost" % pslug if is_primary
                        else "%s.%s.localhost" % (slug, pslug))
                info = wt_info.get(wt["path"], {})
                services = []
                for r in live:
                    if r.get("worktreePath") != wt["path"]:
                        continue
                    r = dict(r)
                    svc_host = "%s.%s" % (slugify(r.get("service")), base)
                    r["url"] = (host_url(svc_host) if proxy_up and not info.get("collision")
                                else "http://localhost:%s" % r.get("port"))
                    services.append(r)
                wts.append({**wt, "name": name, "isPrimary": is_primary, "slug": slug,
                            "services": services,
                            "url": host_url(info["host"]) if proxy_up and info.get("host") else None,
                            "hintUrl": host_url(base) if proxy_up else None,
                            "collision": bool(info.get("collision"))})
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

    def origin_ok(self):
        port = self.server.server_address[1]
        host = self.headers.get("Host", "")
        if host not in ("127.0.0.1:%d" % port, "localhost:%d" % port):
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port):
            return False
        return True

    def do_GET(self):
        if not self.origin_ok():
            self.send_json({"error": "forbidden"}, 403)
            return
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
        if not self.origin_ok():
            self.send_json({"error": "forbidden"}, 403)
            return
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
            if not isinstance(wt, str) or not os.path.isdir(wt):
                self.send_json({"ok": False, "output": "no such worktree: %s" % wt}, 400)
                return
            self.run_margay([url.path.rsplit("/", 1)[1]], cwd=wt)
        elif url.path == "/api/unregister":
            path = body.get("primaryPath", "")
            if not isinstance(path, str) or not path:
                self.send_json({"ok": False, "output": "primaryPath required"}, 400)
                return
            self.run_margay(["unregister", path], cwd=None)
        else:
            self.send_json({"error": "not found"}, 404)

    def run_margay(self, argv, cwd):
        try:
            with mutate_lock:   # registry writes are not concurrent-safe
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


HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
               "te", "trailers", "transfer-encoding", "upgrade"}


class ProxyHandler(BaseHTTPRequestHandler):
    """Host-header reverse proxy: *.localhost -> 127.0.0.1:<registry port>."""
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self): self._proxy()
    def do_HEAD(self): self._proxy()
    def do_POST(self): self._proxy()
    def do_PUT(self): self._proxy()
    def do_PATCH(self): self._proxy()
    def do_DELETE(self): self._proxy()
    def do_OPTIONS(self): self._proxy()

    def _proxy(self):
        if not loopback_peer(self.client_address[0]):
            self._simple_error(403, "loopback connections only")
            return
        if self.headers.get("Transfer-Encoding"):
            self._simple_error(501, "chunked request bodies are not supported by this proxy")
            return
        routes, _ = build_routes()
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        port = routes.get(host)
        if port is None:
            self._gateway_page(routes)
            return
        if (self.headers.get("Upgrade") or "").lower() == "websocket":
            self._tunnel(port)
            return
        body = None
        n = self.headers.get("Content-Length")
        if n:
            try:
                length = int(n)
                if length < 0:
                    raise ValueError
            except ValueError:
                self._simple_error(400, "invalid Content-Length")
                return
            body = self.rfile.read(length)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=300)
        sent = False
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            self.send_response(resp.status)
            sent = True
            cl = resp.getheader("Content-Length")
            for k, v in resp.getheaders():
                if k.lower() not in HOP_HEADERS and k.lower() != "content-length":
                    self.send_header(k, v)
            if cl is not None:
                self.send_header("Content-Length", cl)
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except OSError as e:
            if sent:
                self.close_connection = True
            else:
                self._error_page("service on port %s is not answering (%s)" % (port, e))
        finally:
            conn.close()

    def _tunnel(self, port):
        try:
            up = socket.create_connection(("127.0.0.1", port), timeout=10)
        except OSError as e:
            self._error_page("service on port %s is not answering (%s)" % (port, e))
            return
        req = ["%s %s HTTP/1.1" % (self.command, self.path)]
        req += ["%s: %s" % (k, v) for k, v in self.headers.items()]
        try:
            up.sendall(("\r\n".join(req) + "\r\n\r\n").encode("latin-1"))
        except (OSError, UnicodeEncodeError) as e:
            try:
                up.close()
            except OSError:
                pass
            self.close_connection = True
            self._error_page("service on port %s dropped the connection (%s)" % (port, e))
            return
        client = self.connection
        up.settimeout(None)
        client.settimeout(None)
        try:
            while True:
                readable, _, _ = select.select([client, up], [], [], 3600)
                if not readable:
                    break
                for s in readable:
                    data = s.recv(65536)
                    if not data:
                        raise ConnectionError
                    (up if s is client else client).sendall(data)
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                up.close()
            except OSError:
                pass
            self.close_connection = True

    def _send_html(self, body, status=502):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _error_page(self, message, status=502):
        self._send_html("<!doctype html><title>margay proxy</title><h1>%d</h1><p>%s</p>" % (status, message), status)

    def _simple_error(self, status, message):
        """Reject the request outright (bad/unsupported request) and drop keep-alive."""
        self.close_connection = True
        self._error_page(message, status)

    def _gateway_page(self, routes):
        items = "".join('<li><a href="%s">%s</a></li>' % (u, u)
                        for u in sorted(host_url(h) for h in routes))
        self._send_html(
            "<!doctype html><title>margay proxy</title>"
            "<h1>no sandbox at this address</h1><p>live right now:</p><ul>%s</ul>"
            % (items or "<li>nothing is running</li>"))


def main():
    ap = argparse.ArgumentParser(prog="margay ui")
    ap.add_argument("--port", type=int, default=7997)
    ap.add_argument("--proxy-port", type=int, default=80)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        print("margay ui: cannot bind port %d (%s) — is another margay ui running? Try --port N" % (args.port, e))
        return 1
    proxy_srv, wildcard, bind_err = None, False, None
    attempts = ([("", args.proxy_port)] if os.environ.get("MARGAY_UI_WILDCARD")
                else [("127.0.0.1", args.proxy_port), ("", args.proxy_port)])
    for addr in attempts:
        try:
            proxy_srv = ThreadingHTTPServer(addr, ProxyHandler)
            wildcard = addr[0] == ""
            break
        except PermissionError as e:
            # macOS: binding a low port to a SPECIFIC address needs root;
            # the wildcard address is exempt — retry it (with the peer guard).
            bind_err = e
            continue
        except OSError as e:
            bind_err = e
            break
    if proxy_srv is not None:
        PROXY["port"] = args.proxy_port
        threading.Thread(target=proxy_srv.serve_forever, daemon=True).start()
        suffix = "" if args.proxy_port == 80 else ":%d" % args.proxy_port
        note = "   (wildcard bind, loopback-only)" if wildcard else ""
        print("margay proxy → http://<worktree>.<project>.localhost%s/%s" % (suffix, note))
    else:
        print("margay ui: warning: cannot bind proxy port %d (%s) — "
              "subdomain URLs disabled, falling back to port links" % (args.proxy_port, bind_err))
    sys.stdout.flush()
    url = "http://127.0.0.1:%d" % args.port
    print("margay ui → %s   (Ctrl-C to stop)" % url)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
