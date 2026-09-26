#!/usr/bin/env python3
"""llm-front-door: the Homelab's face for the Box (AD-3; Stories 3.1-3.4). Standard library only, so it runs from a
stock python image with this file in a ConfigMap (the Box's repository has no image registry).

  POST /_srd/push     the Mode Agent's HMAC-signed state push; kept in memory and in STATE_FILE (an NFS PV)
  GET  /health        proxied to the Mode Agent; when the Box is silent, answered here: 503, source "cache"
  /v1/*               streamed to the Box's model proxy (:8741)
  everything else     streamed to the Chat Surface (:8742), WebSocket upgrades included
When the Box does not answer (connect timeout 2 s), a page load gets the state page and /api/, /ws/ and /v1/ get
503 JSON whose `detail` is the same sentence. It never invents a mode and never issues or relays a transition.
Request bodies go to the Box in 64 KiB pieces as they arrive, so an upload of any size fits the pod's 64Mi.
"""
import datetime, hashlib, hmac, html, http.client, json, os, select, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOX = os.environ.get("SRD_BOX", "llm-box.llm-front-door.svc.cluster.local")
CHAT_PORT, API_PORT, AGENT_PORT = (int(os.environ.get(k, d)) for k, d in
                                   (("SRD_CHAT_PORT", "8742"), ("SRD_API_PORT", "8741"), ("SRD_AGENT_PORT", "8740")))
CONNECT_S = float(os.environ.get("SRD_CONNECT_S", "2"))
REQUEST_S = float(os.environ.get("SRD_REQUEST_S", "900"))
STALE_S = float(os.environ.get("SRD_STALE_S", "180"))
SKEW_S = float(os.environ.get("SRD_SKEW_S", "300"))      # a push's sent_at must be this close to now (both run NTP)
PUSH_MAX = 4096
PUSH_KEY = os.environ.get("SRD_PUSH_KEY", "")
STATE_FILE = os.environ.get("SRD_STATE_FILE", "/data/state.json")
PIECE = 65536
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "content-length", "host"}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        try:
            self.last = json.load(open(STATE_FILE))
        except (OSError, ValueError):
            self.last = None

    def store(self, push):
        """Keep a push unless it is a replay: its sent_at must be near now and later than the last one kept."""
        try:
            sent = datetime.datetime.strptime(push["sent_at"], "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except (KeyError, TypeError, ValueError):
            return "a push needs sent_at"
        if abs(sent - time.time()) > SKEW_S:
            return "sent_at is %d s from now" % (sent - time.time())
        rec = dict(push, received=time.time(), sent=sent)
        with self.lock:
            if self.last and sent < self.last.get("sent", 0):     # equal is allowed: two pushes in one second
                return "an older push than the last one kept"
            self.last = rec
            try:
                tmp = STATE_FILE + ".tmp"
                json.dump(rec, open(tmp, "w"))
                os.replace(tmp, STATE_FILE)
            except OSError as e:
                print("could not persist the push: %s" % e, flush=True)
        return None

    def view(self):
        with self.lock:
            s = dict(self.last) if self.last else None
        if not s:
            return {"mode": "unknown", "stale": True, "last_heard": None}
        age = time.time() - s["received"]
        s["stale"] = age > STALE_S
        s["last_heard"] = time.strftime("%H:%M", time.localtime(s["received"]))
        return s


STATE = State()


def hhmm(iso):
    return iso[11:16] if isinstance(iso, str) and len(iso) >= 16 else "?"


def sentence(s):
    """The one line the household reads (the Homelab copy style: lowercase, terse)."""
    if s.get("stale") or s.get("mode") in (None, "unknown"):
        heard = s.get("last_heard")
        line = "the llm box is not answering%s." % (" (last heard %s)" % heard if heard else "")
    elif s["mode"] == "gaming":
        line = "gaming mode since %s, last heard %s. it comes back when ian switches it." % (hhmm(s.get("mode_since")), s["last_heard"])
    elif s["mode"] == "switching":
        line = "the llm box is switching modes, last heard %s. try again in a minute." % s["last_heard"]
    else:
        line = "the llm box is in llm mode but not answering here, last heard %s." % s["last_heard"]
    if s.get("outcome") == "failed":
        line += " last switch failed at %s." % hhmm(s.get("outcome_at"))
    return line


PAGE = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><meta http-equiv=refresh content=15>
<title>llm box</title><style>body{font:17px system-ui;margin:2.5em;max-width:30em;color:#222}</style>
<h1>llm box</h1><p>%s</p>"""


def make_handler():
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "llm-front-door"

        def log_message(self, fmt, *a):
            pass

        def send(self, code, body, ctype):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(code)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(data)))
            self.send_header("cache-control", "no-store")
            if self.close_connection:           # say so, or Envoy may reuse the connection before it sees the FIN
                self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def length(self):
            """The request body's content-length, or None after answering 411 (a chunked body; browsers and SDKs send a
            length) or 400 (a bad length). Either way the connection closes: a body left on it would be read as the next
            request."""
            if self.headers.get("transfer-encoding"):
                code, msg = 411, "a request body needs a content-length"
            else:
                try:
                    n = int(self.headers.get("content-length") or 0)
                    if n >= 0:
                        return n
                except ValueError:
                    pass
                code, msg = 400, "bad content-length"
            self.close_connection = True
            self.send(code, json.dumps({"message": msg}), "application/json")
            return None

        def pieces(self):
            """The rest of the request body, 64 KiB at a time. A short read means the client went away: the connection
            is then closed, and `gone` says there is nobody left to answer."""
            while self.unread:
                try:
                    piece = self.rfile.read(min(PIECE, self.unread))
                except OSError:
                    piece = b""
                if not piece:
                    self.unread, self.gone, self.close_connection = 0, True, True
                    return
                self.unread -= len(piece)
                yield piece

        def drain(self):
            """Drop what is left of the body before answering without the Box: an answer sent over an unread body can be
            lost to the reset the kernel sends when the socket closes, and a kept-alive socket would parse it."""
            for _ in self.pieces():
                pass

        def closed_door(self):
            s = STATE.view()
            if self.path.startswith(("/api/", "/ws/", "/v1/", "/socket.io/")):
                return self.send(503, json.dumps({"detail": sentence(s), "mode": s.get("mode"), "stale": s.get("stale")}), "application/json")
            return self.send(503, PAGE % html.escape(sentence(s)), "text/html; charset=utf-8")

        # ---- the push receiver (Story 3.2) --------------------------------------------------------------------
        def push(self):
            n = self.length()
            if n is None:
                return
            if n > PUSH_MAX:
                self.close_connection = True
                return self.send(413, '{"message":"push too large"}', "application/json")
            body = self.rfile.read(n)
            sig = self.headers.get("x-srd-signature", "")
            good = hmac.new(PUSH_KEY.encode(), body, hashlib.sha256).hexdigest()
            if not PUSH_KEY or not hmac.compare_digest(sig, good):
                return self.send(401, '{"message":"unsigned push refused"}', "application/json")
            try:
                push = json.loads(body)
            except ValueError:
                return self.send(400, '{"message":"bad push"}', "application/json")
            refused = STATE.store(push) if isinstance(push, dict) else "a push is an object"
            if refused:
                return self.send(409, json.dumps({"message": "push refused: " + refused}), "application/json")
            return self.send(204, b"", "text/plain")

        # ---- /health when the Box is silent (Story 3.4) --------------------------------------------------------
        def health(self):
            try:
                c = http.client.HTTPConnection(BOX, AGENT_PORT, timeout=CONNECT_S)
                c.connect()
                c.sock.settimeout(60)
                c.request("GET", "/health", headers={"authorization": self.headers.get("authorization", "")})
                r = c.getresponse()
                data = r.read()
                return self.send(r.status, data, r.getheader("content-type") or "application/json")
            except OSError:
                s = STATE.view()
                return self.send(503, json.dumps(dict(s, source="cache", reason=sentence(s))), "application/json")

        # ---- the proxy (Story 3.1) -----------------------------------------------------------------------------
        def upstream_port(self):
            return API_PORT if self.path.startswith("/v1/") else CHAT_PORT

        def proxy(self):
            if self.headers.get("upgrade", "").lower() == "websocket":
                return self.tunnel()
            n = self.length()
            if n is None:
                return
            self.unread, self.gone = n, False
            try:
                c = http.client.HTTPConnection(BOX, self.upstream_port(), timeout=CONNECT_S)
                c.connect()
            except OSError:
                self.drain()
                return self.closed_door()
            c.sock.settimeout(REQUEST_S)
            try:
                r = self.forward(c)
            except OSError:
                c.close()
                self.drain()
                return self.closed_door()
            if self.gone:                              # the client left mid-body: nobody to answer
                c.close()
                return
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            if self.command == "HEAD" or r.status in (204, 304) or r.status < 200:
                if self.command == "HEAD" and r.getheader("content-length"):
                    self.send_header("content-length", r.getheader("content-length"))
                self.end_headers()                     # no body, so no chunked framing and no stray terminator
                c.close()
                return
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            try:
                while True:
                    piece = r.read1(PIECE)
                    if not piece:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
                    self.wfile.flush()                       # no buffering: each chunk leaves as it arrives
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                c.close()

        def forward(self, c):
            """Send the request to the Box: its head, then the body piece by piece as it arrives. The Box sees the name
            the client asked for (as the WebSocket tunnel does), and the client is appended to X-Forwarded-For."""
            c.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            for k, v in self.headers.items():
                # expect: the 100 went to the client already (BaseHTTPRequestHandler), and the body follows at once
                if k.lower() not in HOP and k.lower() not in ("x-forwarded-for", "expect"):
                    c.putheader(k, v)
            c.putheader("host", self.headers.get("host") or "%s:%d" % (BOX, c.port))
            xff = self.headers.get("x-forwarded-for")
            c.putheader("x-forwarded-for", "%s, %s" % (xff, self.client_address[0]) if xff else self.client_address[0])
            if self.unread or self.command in ("POST", "PUT", "PATCH"):
                c.putheader("content-length", str(self.unread))
            c.endheaders()
            for piece in self.pieces():
                try:
                    c.send(piece)
                except OSError:                  # the Box answered early and hung up: drop the rest, read its answer
                    self.drain()
                    break
            return None if self.gone else c.getresponse()

        def tunnel(self):
            """WebSocket upgrade (Open WebUI's socket.io): replay the request head, then pipe bytes both ways."""
            try:
                up = socket.create_connection((BOX, CHAT_PORT), timeout=CONNECT_S)
            except OSError:
                return self.closed_door()
            head = "%s %s %s\r\n" % (self.command, self.path, self.request_version)
            head += "".join("%s: %s\r\n" % (k, v) for k, v in self.headers.items()) + "\r\n"
            up.sendall(head.encode())
            up.settimeout(None)
            down = self.connection
            try:
                while True:
                    r, _, _ = select.select([up, down], [], [], 300)
                    if not r:
                        break
                    for s in r:
                        data = s.recv(65536)
                        if not data:
                            return
                        (down if s is up else up).sendall(data)
            except OSError:
                pass
            finally:
                up.close()
                self.close_connection = True

        def do_POST(self):
            if self.path == "/_srd/push":
                return self.push()
            return self.proxy()

        def do_GET(self):
            if self.path == "/health":
                return self.health()
            if self.path == "/_srd/state":
                s = STATE.view()
                return self.send(200, json.dumps(dict(s, sentence=sentence(s))), "application/json")
            return self.proxy()

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = proxy
    return H


def main():
    port = int(os.environ.get("SRD_PORT", "8080"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), make_handler())
    srv.daemon_threads = True
    print("llm-front-door on :%d -> %s (chat %d, api %d, agent %d)" % (port, BOX, CHAT_PORT, API_PORT, AGENT_PORT), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
