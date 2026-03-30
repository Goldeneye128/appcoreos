#!/usr/bin/env python3
import datetime
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_FILE = Path("/var/lib/appcoreos/state.json")
HOST = "127.0.0.1"
PORT = 9090


def log(message: str) -> None:
  timestamp = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
  print(f"{timestamp} [agent-debug] {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
  def log_message(self, format: str, *args) -> None:
    return

  def _write_text(self, code: int, body: str, content_type: str) -> None:
    data = body.encode("utf-8")
    self.send_response(code)
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(data)))
    self.end_headers()
    self.wfile.write(data)

  def do_GET(self) -> None:
    if self.path == "/state":
      log("GET /state")
      if STATE_FILE.exists():
        try:
          content = STATE_FILE.read_text(encoding="utf-8")
          json.loads(content)
          self._write_text(200, content, "application/json")
        except Exception:
          self._write_text(500, '{"error":"state unavailable"}\n', "application/json")
      else:
        self._write_text(404, '{"error":"state file not found"}\n', "application/json")
      return

    if self.path == "/logs":
      log("GET /logs")
      result = subprocess.run(
        ["journalctl", "-n", "200", "--no-pager"],
        check=False,
        capture_output=True,
        text=True,
      )
      if result.returncode == 0:
        self._write_text(200, result.stdout, "text/plain; charset=utf-8")
      else:
        self._write_text(500, result.stderr or "journalctl failed\n", "text/plain; charset=utf-8")
      return

    log(f"GET {self.path} (not found)")
    self._write_text(404, "not found\n", "text/plain; charset=utf-8")


def main() -> None:
  server = ThreadingHTTPServer((HOST, PORT), Handler)
  log(f"debug server listening on {HOST}:{PORT}")
  server.serve_forever()


if __name__ == "__main__":
  main()
