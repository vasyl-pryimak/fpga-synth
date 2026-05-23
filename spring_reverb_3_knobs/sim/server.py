#!/usr/bin/env python3
# server.py — Spring Reverb Simulator UI
#
# Usage:
#   python3 sim/server.py
#   open http://localhost:8765

import http.server
import json
import os
import re
import subprocess
import threading
import socketserver
from pathlib import Path

ROOT      = Path(__file__).parent.parent.parent  # fpga-synth/
SIM_DIR   = Path(__file__).parent
SIM_BIN   = SIM_DIR / "reverb-sim"
INPUT_WAV = ROOT / "input.wav"
OUTPUT_WAV= ROOT / "output.wav"
INDEX_HTML= SIM_DIR / "index.html"
PORT      = 8765

render_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self._serve(INDEX_HTML, "text/html; charset=utf-8")
        elif path == "/output.wav":
            self._serve(OUTPUT_WAV, "audio/wav", no_cache=True)
        elif path == "/input.wav":
            self._serve(INPUT_WAV, "audio/wav")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/render":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            volume   = max(0.0, min(1.0, float(body.get("volume",   1.0))))
            wet      = max(0.0, min(1.0, float(body.get("wet",      0.8))))
            decay    = max(0.0, min(1.0, float(body.get("decay",    0.6))))
            pitch    = max(0.0, min(1.0, float(body.get("pitch",    0.5))))

            print(f"  render  vol={volume:.2f}  wet={wet:.2f}  decay={decay:.2f}  pitch={pitch:.2f} ...", flush=True)
            t0 = __import__('time').time()

            with render_lock:
                # Updated to pass --pitch instead of --predelay
                result = subprocess.run(
                    [str(SIM_BIN), str(INPUT_WAV), str(OUTPUT_WAV),
                     f"--volume={volume:.4f}", f"--wet={wet:.4f}",
                     f"--decay={decay:.4f}", f"--pitch={pitch:.4f}"],
                    capture_output=True, text=True
                )

            elapsed = __import__('time').time() - t0
            ok = result.returncode == 0
            if ok:
                print(f"  done    {elapsed:.1f}s", flush=True)
            else:
                print(f"  ERROR   {result.stderr}", flush=True)

            self._json({"ok": ok, "log": result.stderr if not ok else ""})
        else:
            self.send_error(404)

    def _serve(self, path, ctype, no_cache=False):
        try:
            data  = Path(path).read_bytes()
            total = len(data)

            # Range request support — needed for audio seeking
            rng = self.headers.get("Range", "")
            m   = re.match(r"bytes=(\d+)-(\d*)", rng)
            if m:
                start = int(m.group(1))
                end   = int(m.group(2)) if m.group(2) else total - 1
                end   = min(end, total - 1)
                chunk = data[start:end + 1]
                self.send_response(206)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(chunk)))
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                self.send_header("Accept-Ranges", "bytes")
                if no_cache:
                    self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.end_headers()
                self.wfile.write(chunk)
                return

            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(total))
            self.send_header("Accept-Ranges", "bytes")
            if no_cache:
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # browser cancelled request — normal
        except FileNotFoundError:
            self.send_error(404)

    def _json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass  # suppress default request logs


if __name__ == "__main__":
    if not SIM_BIN.exists():
        print(f"Build first: cd sim && make")
        exit(1)
    if not INPUT_WAV.exists():
        print(f"Convert audio first:\n  ffmpeg -i your.mp3 -ar 48000 -ac 1 -sample_fmt s16 input.wav")
        exit(1)

    print(f"sim    : {SIM_BIN}")
    print(f"input  : {INPUT_WAV}")
    print(f"output : {OUTPUT_WAV}")
    print(f"→ http://localhost:{PORT}", flush=True)

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = ThreadedServer(("localhost", PORT), Handler)
    server.serve_forever()
