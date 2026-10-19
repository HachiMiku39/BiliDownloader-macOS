"""Local deterministic media server for download/HTTP Range integration tests."""
import email.utils
import http.server
import json
import pathlib
import sys
import threading
import time

root = pathlib.Path(sys.argv[1])
blob = bytes(range(251)) * (8 * 1024 * 1024 // 251 + 1)
blob = blob[:8 * 1024 * 1024]
stats = {"active": 0, "peak": 0, "ranges": []}
stats_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/stats", "/reset"):
            with stats_lock:
                if self.path == "/reset":
                    stats.update(active=0, peak=0, ranges=[])
                payload = json.dumps(stats).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/forbidden":
            self.send_response(403)
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.write(b"forbidden")
            return
        if self.path in ("/blob", "/no-range", "/bad-range", "/changed"):
            data = blob
        elif self.path in ("/video.mp4", "/audio.m4a"):
            data = (root / self.path[1:]).read_bytes()
        else:
            self.send_error(404)
            return
        offset = 0
        end = len(data) - 1
        range_requested = self.headers.get("Range", "").startswith("bytes=") and self.path != "/no-range"
        if range_requested:
            start_text, end_text = self.headers["Range"][6:].split("-", 1)
            offset = int(start_text)
            if end_text:
                end = min(int(end_text), end)
        probe = range_requested and offset == 0 and end == 0
        if self.path == "/changed" and not probe:
            data = bytes(value ^ 0x55 for value in data)
        with stats_lock:
            stats["ranges"].append([self.path, offset, end, range_requested])
            stats["active"] += 1
            stats["peak"] = max(stats["peak"], stats["active"])
        self.send_response(206 if range_requested else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"bilimac-fixture-v2"' if self.path == "/changed" and not probe else '"bilimac-fixture-v1"')
        self.send_header("Last-Modified", email.utils.formatdate(1700000000, usegmt=True))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - offset + 1))
        if range_requested:
            reported_start = offset + 1 if self.path == "/bad-range" and not probe else offset
            self.send_header("Content-Range", f"bytes {reported_start}-{end}/{len(data)}")
        self.end_headers()
        try:
            for start in range(offset, end + 1, 16384):
                self.wfile.write(data[start:min(start + 16384, end + 1)])
                self.wfile.flush()
                if len(data) >= 8 * 1024 * 1024 and start + 16384 <= end:
                    time.sleep(0.003)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with stats_lock:
                stats["active"] -= 1

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
