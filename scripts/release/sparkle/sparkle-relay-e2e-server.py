"""Local update feed for test-sparkle-relay-e2e.sh.

Serves files with ETag/Range/If-Range like GitHub release assets. Environment switches:
DROP_FIRST=1 cuts the first archive transfer at 40%, EXIT_AFTER_DROP=1 then stops the
server, IGNORE_IF_RANGE=1 answers 206 even for a stale If-Range (as GitHub's CDN does).
"""
import hashlib, http.server, json, os, sys, threading

ROOT, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]
dropped = set()
lock = threading.Lock()

def log(entry):
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        name = self.path.split("?")[0].lstrip("/")
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
            log({"path": name, "status": 404}); return
        data = open(path, "rb").read()
        etag = '"%s"' % hashlib.sha256(data).hexdigest()[:16]
        start, status = 0, 200
        rng, if_range = self.headers.get("Range"), self.headers.get("If-Range")
        if rng and rng.startswith("bytes=") and (if_range is None or if_range == etag or os.environ.get("IGNORE_IF_RANGE") == "1"):
            start = int(rng[6:].split("-")[0]); status = 206
        body = data[start:]
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        self.end_headers()
        drop = os.environ.get("DROP_FIRST") == "1" and name.endswith((".zip", ".delta")) and name not in dropped
        log({"path": name, "status": status, "range": rng, "ifRange": if_range, "drop": drop, "bytes": len(body)})
        if drop:
            dropped.add(name)
            cut = len(body) * 2 // 5
            self.wfile.write(body[:cut])
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(2)
            if os.environ.get("EXIT_AFTER_DROP") == "1":
                os._exit(0)
            return
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the relay cancels responses it rejects

class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # clients reset connections the relay abandons; the log records the requests

Server(("127.0.0.1", PORT), Handler).serve_forever()
