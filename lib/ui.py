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
STATIC_ROUTES = MARGAY_HOME / "static-routes.json"
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


def port_alive(port):
    """True if something is accepting connections on localhost:<port>.

    Used to show a live/down dot for static routes, whose upstream margay
    doesn't manage (so there's no pid to check). Short timeout — this runs on
    every /state poll.
    """
    try:
        with socket.create_connection(("localhost", int(port)), timeout=0.3):
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
UI = {"port": None}      # set by main() once the control-panel listener binds
TRUSTED_PROXY = {"on": False}   # --trusted-proxy: honour X-Forwarded-* from a local reverse proxy


def slugify(name):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9-]", "-", str(name).lower())).strip("-")


def loopback_peer(ip):
    """True iff the TCP peer is a loopback address (guards the wildcard-bound proxy)."""
    return ip == "::1" or ip.startswith("127.") or ip.startswith("::ffff:127.")


# Base domain for sandbox hostnames. "localhost" (the default) keeps margay
# loopback-locked; any other value (--domain / MARGAY_DOMAIN) implies serving
# remote peers — the VPN/firewall is the perimeter then.
DOMAIN = {"name": os.environ.get("MARGAY_DOMAIN") or "localhost"}


def exposed():
    return DOMAIN["name"] != "localhost"


def peer_ok(ip):
    return exposed() or loopback_peer(ip)


def host_url(host, front=None):
    """URL a browser should use to reach `host` through the proxy.

    Default (`front` None): margay's own proxy on loopback — http, and the
    proxy port unless it's the http default (80). Behind a trusted TLS
    reverse proxy the browser never sees margay's port; pass `front` =
    (scheme, external_port) captured from the incoming request's
    X-Forwarded-* so the link carries the PUBLIC origin (https, standard port
    omitted) instead of leaking margay's internal :<proxy-port>.
    """
    if front is not None:
        scheme, port = front
        default = 443 if scheme == "https" else 80
        if port in (None, default):
            return "%s://%s/" % (scheme, host)
        return "%s://%s:%d/" % (scheme, host, port)
    if PROXY["port"] in (None, 80):
        return "http://%s/" % host
    return "http://%s:%d/" % (host, PROXY["port"])


RESERVED_LABEL = "margay"   # the control panel's own hostname label


def reserved_host():
    """The host the control panel reserves for itself: margay.<domain>."""
    return "%s.%s" % (RESERVED_LABEL, DOMAIN["name"])


def leaf_services(rows):
    """Rows of one worktree -> services no sibling row's `uses` points at."""
    used = {r.get("uses") for r in rows if r.get("uses")}
    return [r for r in rows if "http://localhost:%s" % r.get("port") not in used]


def static_routes():
    """User-defined host label -> localhost port, from static-routes.json.

    Each entry {"label": "<subdomain-prefix>", "port": <int>} publishes
    `<label>.<DOMAIN>` -> localhost:<port>, for upstreams margay doesn't manage
    as services (a shared Keycloak container, a docs server, ...). Unlike a
    service route these survive `up`/`down` churn — the host is stable. Live
    services always win a label collision (merged via setdefault in
    build_routes). Malformed entries are skipped, never fatal to routing.
    """
    out = {}
    for e in read_json(STATIC_ROUTES):
        if not isinstance(e, dict):
            continue
        label = str(e.get("label", "")).strip().lower().strip(".")
        port = e.get("port")
        if label and isinstance(port, int) and not isinstance(port, bool):
            out["%s.%s" % (label, DOMAIN["name"])] = port
    return out


def build_routes():
    """Host label -> upstream port for every live service.

    Hosts are FLAT single labels (hyphen-joined) so one `*.<domain>` wildcard
    cert covers them all: base `<pslug>` (primary) or `<pslug>-<wtslug>`
    (worktree) maps to the worktree's unique dependency leaf; every service also
    gets a `<base_label>-<svcslug>` host. Slug collisions resolve to the earliest
    startedAt; losers get no hosts at all.
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
    # The control panel reserves margay.<domain>. Seeded BEFORE the project
    # loop so a project slugged "margay" hits the existing `base in claimed`
    # branch and degrades to port links like any other slug collision — no
    # separate code path, and state()/ui.html need no changes. Gated on the
    # proxy too: with no proxy there is no margay.<domain> route at all.
    if UI["port"] is not None and PROXY["port"] is not None:
        reserved = reserved_host()
        routes[reserved] = UI["port"]
        claimed.add(reserved)
    ordered = sorted(by_wt.items(),
                     key=lambda kv: min(r.get("startedAt") or "" for r in kv[1]))
    for (project, wt_path), rows in ordered:
        pslug = slugify(project)
        is_primary = primaries.get(project) == wt_path
        # Flat single-label hostnames so ONE `*.<domain>` wildcard cert covers
        # every sandbox at any depth: `<pslug>[-<wtslug>]` is the worktree base
        # (leaf), `<base_label>-<svcslug>` per service. Nested `<svc>.<wt>.<pslug>`
        # hosts would need a fresh wildcard per level — uncoverable per-worktree.
        base_label = pslug if is_primary else "%s-%s" % (pslug, slugify(os.path.basename(wt_path or "")))
        base = "%s.%s" % (base_label, DOMAIN["name"])
        if base in claimed or base in routes:
            info[wt_path] = {"host": None, "collision": True}
            continue
        claimed.add(base)
        leaves = leaf_services(rows)
        root = leaves[0] if len(leaves) == 1 else None
        if root:
            routes.setdefault(base, root.get("port"))
        for r in rows:
            routes.setdefault("%s-%s.%s" % (base_label, slugify(r.get("service")), DOMAIN["name"]), r.get("port"))
        info[wt_path] = {"host": base if root else None, "collision": False}
    # Static routes fill in last so a live service never loses its host to one.
    for host, port in static_routes().items():
        routes.setdefault(host, port)
    return routes, info


CONF_CACHE = {}   # primaryPath -> (conf mtime, parsed conf-json or None)


def conf_meta(primary):
    """Dependency metadata from `margay conf-json`, cached by conf mtime."""
    conf = os.path.join(primary, ".margay.conf")
    try:
        mtime = os.path.getmtime(conf)
    except OSError:
        return None
    hit = CONF_CACHE.get(primary)
    if hit and hit[0] == mtime:
        return hit[1]
    data = None
    try:
        proc = subprocess.run([MARGAY_BIN, "conf-json"], cwd=primary,
                              capture_output=True, text=True, timeout=10)
        if proc.returncode == 0:
            data = json.loads(proc.stdout)
        if not isinstance(data, dict):
            data = None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        data = None
    CONF_CACHE[primary] = (mtime, data)
    return data


def stopped_services(allrows, live):
    """Recently-stopped services: a dead PID whose log file is still on disk.

    Surfaced so the webapp can show WHY a service went down or crashed —
    precisely when you want the log (the log file outlives the process; only
    the registry row's PID goes dead). Skips any service that has a live
    instance in the same worktree, and keeps only the newest stopped instance
    per (worktree, service). Returns {worktreePath: [row, ...]}.
    """
    live_keys = {(r.get("worktreePath"), r.get("service")) for r in live}
    latest = {}
    for r in allrows:
        if pid_alive(r.get("pid")):
            continue
        key = (r.get("worktreePath"), r.get("service"))
        if key in live_keys:
            continue
        log = r.get("log")
        if not (isinstance(log, str) and os.path.isfile(log)):
            continue
        cur = latest.get(key)
        if cur is None or (r.get("startedAt") or "") > (cur.get("startedAt") or ""):
            latest[key] = r
    by_wt = {}
    for r in latest.values():
        by_wt.setdefault(r.get("worktreePath"), []).append(r)
    return by_wt


def state(front=None):
    allrows = read_json(REGISTRY)
    live = [r for r in allrows if pid_alive(r.get("pid"))]
    stopped_by_wt = stopped_services(allrows, live)
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
                # Flat single-label hosts — must mirror build_routes().
                base_label = pslug if is_primary else "%s-%s" % (pslug, slug)
                base = "%s.%s" % (base_label, DOMAIN["name"])
                info = wt_info.get(wt["path"], {})
                services = []
                for r in live:
                    if r.get("worktreePath") != wt["path"]:
                        continue
                    r = dict(r)
                    svc_host = "%s-%s.%s" % (base_label, slugify(r.get("service")), DOMAIN["name"])
                    r["url"] = (host_url(svc_host, front) if proxy_up and not info.get("collision")
                                else "http://localhost:%s" % r.get("port"))
                    services.append(r)
                stopped = []
                for r in stopped_by_wt.get(wt["path"], []):
                    r = dict(r)
                    r["stopped"] = True
                    r["url"] = None
                    stopped.append(r)
                wts.append({**wt, "name": name, "isPrimary": is_primary, "slug": slug,
                            "services": services, "stoppedServices": stopped,
                            "url": host_url(info["host"], front) if proxy_up and info.get("host") else None,
                            "hintUrl": host_url(base, front) if proxy_up else None,
                            "collision": bool(info.get("collision"))})
        projects.append({**p, "exists": exists, "worktrees": wts,
                         "conf": conf_meta(primary) if exists else None})
    static = []
    for e in read_json(STATIC_ROUTES):
        if not isinstance(e, dict):
            continue
        label = str(e.get("label", "")).strip().lower().strip(".")
        port = e.get("port")
        if not (label and isinstance(port, int) and not isinstance(port, bool)):
            continue
        host = "%s.%s" % (label, DOMAIN["name"])
        static.append({"label": label, "host": host, "port": port,
                       "note": e.get("note", ""), "live": port_alive(port),
                       "url": host_url(host, front) if proxy_up else None})
    return {"projects": projects, "staticRoutes": static}


def pair_options(primary, service):
    """Live pairing candidates for `service` of the project registered at
    `primary`, per its conf dependency (needs > uses_project)."""
    none = {"dep": None, "optional": False, "mainPort": None, "candidates": []}
    meta = conf_meta(primary) or {}
    svc = next((s for s in meta.get("services", [])
                if isinstance(s, dict) and s.get("name") == service), None)
    if not svc:
        return none
    if svc.get("needs"):
        dep_proj, dep_svc = meta.get("project"), svc["needs"]
    elif svc.get("usesProject"):
        dep_proj, dep_svc = svc["usesProject"].split(":", 1)
    else:
        return none
    cands = [{"project": r.get("project"), "service": r.get("service"),
              "branch": r.get("branch"), "port": r.get("port"),
              "worktree": os.path.basename(r.get("worktreePath") or "")}
             for r in read_json(REGISTRY)
             if pid_alive(r.get("pid"))
             and r.get("project") == dep_proj and r.get("service") == dep_svc]
    return {"dep": dep_svc, "optional": bool(svc.get("usesOptional")),
            "mainPort": svc.get("mainPort"), "candidates": cands}


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
        hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
        schemes = {"http"}
        if exposed():
            hosts.add("%s:%d" % (DOMAIN["name"], port))
        # Requests arriving through the proxy carry the reserved host verbatim
        # (Host is not a hop header — see _proxy, lib/ui.py:443), so it must
        # be accepted or every control action via margay.<domain> 403s. Safe:
        # reaching this handler with that Host means the browser navigated to
        # it, which .localhost pins to loopback (RFC 6761) — a cross-origin
        # page cannot forge it. A browser omits the port from Host only when
        # it matches the scheme default (80 for http); on any other port it
        # includes it, so mirror exactly what the proxy's actual port implies.
        if PROXY["port"] is not None:
            reserved = reserved_host()
            hosts.add(reserved if PROXY["port"] == 80
                      else "%s:%d" % (reserved, PROXY["port"]))
        # Behind a trusted TLS-terminating reverse proxy (e.g. Nginx Proxy
        # Manager) the browser talks to the proxy's public origin, not ours:
        # Host loses margay's proxy port (443/80 is the scheme default) and
        # Origin carries https. Widen the allow-list to the panel's public
        # host + https — but ONLY the reserved host, and only when the request
        # reached us over loopback (i.e. forwarded by a local proxy). A
        # cross-origin attacker's Origin still fails the check (the host is
        # pinned to margay.<domain>), and X-Forwarded-* are never honoured from
        # a direct remote peer that could forge them.
        if (TRUSTED_PROXY["on"] and PROXY["port"] is not None
                and loopback_peer(self.client_address[0])):
            reserved = reserved_host()
            hosts.add(reserved)   # standard-port front (browser omits 80/443)
            fwd_host = self.headers.get("X-Forwarded-Host", "").split(",")[0].strip().lower()
            if fwd_host and fwd_host.split(":")[0] == reserved:
                hosts.add(fwd_host)   # non-standard external port, e.g. :8443
            schemes.add("https")
        if self.headers.get("Host", "") not in hosts:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {"%s://%s" % (s, h) for s in schemes for h in hosts}:
            return False
        return True

    def public_front(self):
        """External (scheme, port) this request reached the panel through, or
        None to fall back to margay's own proxy origin.

        Only trusts X-Forwarded-* under the exact conditions --trusted-proxy
        vouches for (see origin_ok): the flag is on, a proxy is bound, the peer
        is loopback (a local reverse proxy — never a forgeable remote peer),
        and the proxy declared https. The port is taken from X-Forwarded-Host
        so a non-standard TLS front (e.g. :8443) is carried through; a standard
        443 front has no port there and host_url omits it. This makes sandbox
        links point at the PUBLIC https origin instead of leaking margay's
        internal :<proxy-port>.
        """
        if not (TRUSTED_PROXY["on"] and PROXY["port"] is not None
                and loopback_peer(self.client_address[0])):
            return None
        proto = self.headers.get("X-Forwarded-Proto", "").split(",")[0].strip().lower()
        if proto != "https":
            return None
        fwd_host = self.headers.get("X-Forwarded-Host", "").split(",")[0].strip().lower()
        port = None
        if ":" in fwd_host:
            try:
                port = int(fwd_host.rsplit(":", 1)[1])
            except ValueError:
                port = None
        return ("https", port)

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
            self.send_json(state(self.public_front()))
        elif url.path == "/api/pair-options":
            q = parse_qs(url.query)
            self.send_json(pair_options(q.get("primary", [""])[0],
                                        q.get("service", [""])[0]))
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
            argv = [url.path.rsplit("/", 1)[1]]
            if url.path == "/api/up":
                svc = body.get("service")
                if svc is not None:
                    if not (isinstance(svc, str) and re.fullmatch(r"[A-Za-z0-9_-]+", svc)):
                        self.send_json({"ok": False, "output": "bad service name"}, 400)
                        return
                    argv.append(svc)
                use = body.get("use")
                if use is not None:
                    name = use.get("name") if isinstance(use, dict) else None
                    value = use.get("value") if isinstance(use, dict) else None
                    if not (isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+", name)
                            and isinstance(value, str)
                            and re.fullmatch(r"[0-9]+|none", value)):
                        self.send_json({"ok": False, "output": "bad use pairing"}, 400)
                        return
                    argv += ["--use", "%s=%s" % (name, value)]
            self.run_margay(argv, cwd=wt)
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
                    env={**os.environ, "MARGAY_DOMAIN": DOMAIN["name"]},
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


class ProxyServer(ThreadingHTTPServer):
    """Accept-level loopback guard: reject non-loopback peers before the
    stdlib even reads request bytes (matters when bound to the wildcard
    address, where any LAN host can otherwise reach the raw parser)."""

    def verify_request(self, request, client_address):
        return peer_ok(client_address[0])


class ProxyHandler(BaseHTTPRequestHandler):
    """Host-header reverse proxy: *.localhost -> 127.0.0.1:<registry port>."""
    protocol_version = "HTTP/1.1"
    timeout = 30   # bound the per-read wait on the wildcard bind (slowloris guard)

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
        if not peer_ok(self.client_address[0]):
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
        # Dial "localhost", not 127.0.0.1 — upstreams (vite among them) may
        # listen on ::1 only; name-based connect tries both loopback families.
        conn = http.client.HTTPConnection("localhost", port, timeout=300)
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
            # "localhost" (not 127.0.0.1): tries both loopback families — see _proxy.
            up = socket.create_connection(("localhost", port), timeout=10)
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

    def _front(self):
        """External (scheme, port) this request reached the proxy through, or
        None. Unlike the control panel (reached THROUGH margay's proxy, so its
        peer is loopback), the ProxyHandler's direct peer IS the fronting
        reverse proxy — so under --trusted-proxy we honour its X-Forwarded-*
        here without a loopback check, keeping the gateway page's links on the
        public https origin instead of leaking margay's internal :<proxy-port>.
        """
        if not (TRUSTED_PROXY["on"] and PROXY["port"] is not None):
            return None
        if self.headers.get("X-Forwarded-Proto", "").split(",")[0].strip().lower() != "https":
            return None
        fwd_host = self.headers.get("X-Forwarded-Host", "").split(",")[0].strip().lower()
        port = None
        if ":" in fwd_host:
            try:
                port = int(fwd_host.rsplit(":", 1)[1])
            except ValueError:
                port = None
        return ("https", port)

    def _gateway_page(self, routes):
        front = self._front()
        items = "".join('<li><a href="%s">%s</a></li>' % (u, u)
                        for u in sorted(host_url(h, front) for h in routes))
        self._send_html(
            "<!doctype html><title>margay proxy</title>"
            "<h1>no sandbox at this address</h1><p>live right now:</p><ul>%s</ul>"
            % (items or "<li>nothing is running</li>"))


def main():
    ap = argparse.ArgumentParser(prog="margay ui")
    ap.add_argument("--port", type=int, default=7997)
    ap.add_argument("--proxy-port", type=int, default=80)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--domain", default=DOMAIN["name"],
                    help="base domain for sandbox hostnames (default: localhost, "
                         "loopback-only; anything else serves remote peers too)")
    ap.add_argument("--trusted-proxy", action="store_true",
                    default=bool(os.environ.get("MARGAY_TRUSTED_PROXY")),
                    help="trust X-Forwarded-Proto/Host forwarded by a local reverse "
                         "proxy (e.g. Nginx Proxy Manager) so the control panel works "
                         "behind TLS termination on margay.<domain>")
    args = ap.parse_args()
    DOMAIN["name"] = args.domain
    TRUSTED_PROXY["on"] = args.trusted_proxy
    ui_addr = ("", args.port) if exposed() else ("127.0.0.1", args.port)
    try:
        srv = ThreadingHTTPServer(ui_addr, Handler)
    except OSError as e:
        print("margay ui: cannot bind port %d (%s) — is another margay ui running? Try --port N" % (args.port, e))
        return 1
    UI["port"] = args.port
    proxy_srv, wildcard, bind_err = None, False, None
    attempts = ([("", args.proxy_port)] if exposed() or os.environ.get("MARGAY_UI_WILDCARD")
                else [("127.0.0.1", args.proxy_port), ("", args.proxy_port)])
    for addr in attempts:
        try:
            proxy_srv = ProxyServer(addr, ProxyHandler)
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
        note = ("   (EXPOSED to the network — VPN/firewall is the perimeter)" if exposed()
                else "   (wildcard bind, loopback-only)" if wildcard else "")
        print("margay proxy → http://<worktree>.<project>.%s%s/%s"
              % (DOMAIN["name"], suffix, note))
        if TRUSTED_PROXY["on"]:
            print("margay ui: trusting X-Forwarded-* from a local reverse proxy "
                  "— control panel served under https://%s" % reserved_host())
    else:
        print("margay ui: warning: cannot bind proxy port %d (%s) — "
              "subdomain URLs disabled, falling back to port links" % (args.proxy_port, bind_err))
    # Prefer the pretty URL, but only when the proxy actually bound — with no
    # proxy there is no margay.<domain> route and the port is the only way in.
    if PROXY["port"] is not None:
        reserved = reserved_host()
        url = host_url(reserved)
        # Warn once if a KNOWN project would want this host. Keyed off
        # projects.json, not live registry rows, so it still fires when
        # nothing is running yet — the shadowing is a property of the name.
        if any(isinstance(p, dict) and slugify(p.get("project")) == RESERVED_LABEL
               for p in read_json(PROJECTS)):
            print("margay ui: warning: project 'margay' wants %s — reserved for "
                  "the control panel; that project falls back to port links" % reserved)
    else:
        url = "http://127.0.0.1:%d" % args.port
    print("margay ui → %s   (Ctrl-C to stop)" % url)
    sys.stdout.flush()
    if not args.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
