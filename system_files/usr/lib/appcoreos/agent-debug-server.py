#!/usr/bin/env python3
import datetime
import json
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

STATE_FILE = Path("/var/lib/appcoreos/state.json")
# Exposed on guest NIC for QEMU hostfwd-based testing workflows.
HOST = "0.0.0.0"
PORT = 9090
MAX_LOG_TAIL = 2000


def log(message: str) -> None:
  timestamp = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
  print(f"{timestamp} [agent-debug] {message}", flush=True)


def run_command(cmd: list[str]) -> tuple[int, str, str]:
  try:
    result = subprocess.run(
      cmd,
      check=False,
      capture_output=True,
      text=True,
    )
    return (result.returncode, result.stdout, result.stderr)
  except FileNotFoundError:
    return (127, "", f"command not found: {cmd[0]}")
  except Exception as exc:
    return (1, "", str(exc))


def parse_tail(value: str | None) -> int:
  if value is None:
    return 200
  try:
    tail = int(value)
  except ValueError:
    return 200
  if tail < 1:
    return 1
  if tail > MAX_LOG_TAIL:
    return MAX_LOG_TAIL
  return tail


def is_valid_container_name(name: str) -> bool:
  return re.match(r"^[A-Za-z0-9_.-]+$", name) is not None


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

  def _write_json(self, code: int, payload: dict | list) -> None:
    self._write_text(code, json.dumps(payload, indent=2) + "\n", "application/json")

  def do_GET(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path
    params = parse_qs(parsed.query)

    if path == "/state":
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

    if path == "/logs":
      tail = parse_tail(params.get("tail", [None])[0])
      log("GET /logs")
      rc, out, err = run_command(["journalctl", "-n", str(tail), "--no-pager"])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_text(500, err or "journalctl failed\n", "text/plain; charset=utf-8")
      return

    if path == "/containers":
      log("GET /containers")
      rc, out, err = run_command([
        "podman",
        "ps",
        "-a",
        "--format",
        "{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}",
      ])
      if rc != 0:
        self._write_json(500, {"error": err.strip() or "podman ps failed"})
        return

      containers = []
      for line in out.splitlines():
        if not line.strip():
          continue
        parts = line.split("|", 3)
        while len(parts) < 4:
          parts.append("")
        containers.append(
          {
            "name": parts[0].strip(),
            "image": parts[1].strip(),
            "state": parts[2].strip(),
            "status": parts[3].strip(),
          }
        )
      self._write_json(200, {"containers": containers})
      return

    match = re.match(r"^/containers/([^/]+)/logs$", path)
    if match:
      name = match.group(1)
      tail = parse_tail(params.get("tail", [None])[0])
      if not is_valid_container_name(name):
        self._write_json(400, {"error": "invalid container name"})
        return
      log(f"GET /containers/{name}/logs")
      rc, out, err = run_command(["podman", "logs", "--tail", str(tail), name])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        status = 404 if "no container with name or ID" in err.lower() else 500
        self._write_json(status, {"error": err.strip() or "podman logs failed"})
      return

    if path == "/healthz":
      self._write_json(200, {"status": "ok"})
      return

    log(f"GET {path} (not found)")
    self._write_text(404, "not found\n", "text/plain; charset=utf-8")

  def do_POST(self) -> None:
    path = urlparse(self.path).path
    match = re.match(r"^/containers/([^/]+)/(start|restart|stop)$", path)
    if not match:
      log(f"POST {path} (not found)")
      self._write_text(404, "not found\n", "text/plain; charset=utf-8")
      return

    name, action = match.groups()
    if not is_valid_container_name(name):
      self._write_json(400, {"error": "invalid container name"})
      return

    log(f"POST /containers/{name}/{action}")
    rc, out, err = run_command(["systemctl", action, f"{name}.service"])
    if rc == 0:
      self._write_json(
        200,
        {
          "result": "ok",
          "container": name,
          "action": action,
        },
      )
      return

    # Fallback to podman direct container control if systemd unit is absent.
    rc2, out2, err2 = run_command(["podman", action, name])
    if rc2 == 0:
      self._write_json(
        200,
        {
          "result": "ok",
          "container": name,
          "action": action,
          "mode": "podman-fallback",
        },
      )
      return

    self._write_json(
      500,
      {
        "error": "container action failed",
        "systemd": err.strip(),
        "podman": err2.strip(),
      },
    )


def main() -> None:
  server = ThreadingHTTPServer((HOST, PORT), Handler)
  log(f"debug server listening on {HOST}:{PORT}")
  server.serve_forever()


if __name__ == "__main__":
  main()
