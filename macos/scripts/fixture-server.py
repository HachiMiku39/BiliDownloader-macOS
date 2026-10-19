"""Local deterministic media server for download/HTTP Range integration tests."""
import email.utils
import http.server
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
blob = bytes(range(251)) * (8 * 1024 * 1024 // 251 + 1)
blob = blob[:8 * 1024 * 1024]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/forbidden":
            self.send_response(403)
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.write(b"forbidden")
            return
        if self.path == "/blob":
            data = blob
        elif self.path in ("/video.mp4", "/audio.m4a"):
            data = (root / self.path[1:]).read_bytes()
        else:
            self.send_error(404)
            return
        offset = 0
        if self.headers.get("Range", "").startswith("bytes="):
            offset = int(self.headers["Range"][6:].split("-", 1)[0])
        self.send_response(206 if offset else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"bilimac-fixture-v1"')
        self.send_header("Last-Modified", email.utils.formatdate(1700000000, usegmt=True))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data) - offset))
        if offset:
            self.send_header("Content-Range", f"bytes {offset}-{len(data)-1}/{len(data)}")
        self.end_headers()
        try:
            for start in range(offset, len(data), 16384):
                self.wfile.write(data[start:start + 16384])
                self.wfile.flush()
                if self.path == "/blob":
                    time.sleep(0.003)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
