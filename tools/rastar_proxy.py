# Static file server + same-origin reverse proxy for the Rastar Center API.
#
# Use this to serve a Defold HTML5 bundle during development AND in production
# when the Rastar API does not send Access-Control-Allow-Origin (browsers block
# direct cross-origin calls otherwise). The game calls /rastarapi/<path> on its
# own origin and this server forwards it to the API.
#
#   python rastar_proxy.py [--dir <bundle_dir>] [--port 8123] [--upstream https://rastar-center-api.rastar.ir]
#
# Notes baked in from production debugging:
#  * threaded (a stuck client connection must not block everyone)
#  * cache validators stripped BOTH ways (the API sends ETags; a revalidating
#    client would get "304 Not Modified" with an EMPTY body, which game code
#    that expects JSON treats as an error)
#  * no-store on everything (no stale wasm/archive during development)
import argparse, http.server, socketserver, urllib.request, urllib.error

ap = argparse.ArgumentParser()
ap.add_argument("--dir", default=".", help="folder with the HTML5 bundle (index.html)")
ap.add_argument("--port", type=int, default=8123)
ap.add_argument("--prefix", default="/rastarapi")
ap.add_argument("--upstream", default="https://rastar-center-api.rastar.ir")
args = ap.parse_args()

HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer",
       "proxy-authorization", "proxy-authenticate", "upgrade", "host",
       "content-length", "accept-encoding"}
REQ_STRIP = HOP | {"if-none-match", "if-modified-since"}
RESP_STRIP = HOP | {"etag", "last-modified", "cache-control", "expires"}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=args.dir, **kw)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        # CORS: allow HTML5 builds served from other local ports (e.g. the Defold
        # editor's built-in server) to call this proxy cross-origin.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, x-app-id")
        super().end_headers()

    def do_OPTIONS(self):  # CORS preflight
        self.send_response(204)
        self.end_headers()

    def _proxy(self):
        url = args.upstream + self.path[len(args.prefix):]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else None
        req = urllib.request.Request(url, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in REQ_STRIP:
                req.add_header(k, v)
        req.add_header("Accept-Encoding", "identity")
        try:
            resp = urllib.request.urlopen(req, timeout=20)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(('{"code":"PROXY_ERROR","meta":{"message":"%s"}}' % e).encode())
            return
        data = resp.read()
        self.send_response(getattr(resp, "status", None) or resp.code)
        for k, v in resp.headers.items():
            if k.lower() not in RESP_STRIP:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _route(self, fallback):
        if self.path.startswith(args.prefix):
            self._proxy()
        else:
            fallback()

    def do_GET(self):    self._route(super().do_GET)
    def do_HEAD(self):   self._route(super().do_HEAD)
    def do_POST(self):   self._route(lambda: (self.send_response(405), self.end_headers()))
    def do_PATCH(self):  self._route(lambda: (self.send_response(405), self.end_headers()))
    def do_PUT(self):    self._route(lambda: (self.send_response(405), self.end_headers()))
    def do_DELETE(self): self._route(lambda: (self.send_response(405), self.end_headers()))

    def log_message(self, *a):
        pass

Handler.extensions_map.update({".wasm": "application/wasm", ".js": "text/javascript"})

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(("", args.port), Handler) as httpd:
    print("serving", args.dir, "on", args.port, "| proxy", args.prefix, "->", args.upstream)
    httpd.serve_forever()
