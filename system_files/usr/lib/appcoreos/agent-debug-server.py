#!/usr/bin/env python3
import datetime
import json
import os
import re
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

STATE_FILE = Path("/var/lib/appcoreos/state.json")
CONFIG_FILE = Path("/var/lib/appcoreos/config.yaml")
STAGED_CONFIG_FILE = Path("/var/lib/appcoreos/config.staged.yaml")
MACHINE_ID_FILE = Path("/var/lib/appcoreos/machine-id")
STACKS_DIR = Path("/var/lib/appcoreos/stacks")

HOST = os.environ.get("APPCOREOS_API_HOST", "0.0.0.0")
PORT = int(os.environ.get("APPCOREOS_API_PORT", "9090"))
API_KEY = os.environ.get("APPCOREOS_API_KEY", "")
TLS_CERT = os.environ.get("APPCOREOS_TLS_CERT", "")
TLS_KEY = os.environ.get("APPCOREOS_TLS_KEY", "")
REQUIRE_MTLS = os.environ.get("APPCOREOS_REQUIRE_MTLS", "0") == "1"
CLIENT_CA = os.environ.get("APPCOREOS_CLIENT_CA", "/var/lib/appcoreos/pki/client-ca.crt")
BOOTSTRAP_TOKEN_FILE = Path(os.environ.get("APPCOREOS_BOOTSTRAP_TOKEN_FILE", "/var/lib/appcoreos/bootstrap/token"))
BOOTSTRAP_CLAIMED_FILE = Path(os.environ.get("APPCOREOS_BOOTSTRAP_CLAIMED_FILE", "/var/lib/appcoreos/bootstrap/claimed"))
MAX_LOG_TAIL = 5000
MAX_CONFIG_BYTES = 1024 * 1024
LOG_FILE_ALLOWLIST = ["/var/log/", "/var/lib/appcoreos/"]
VALID_CONFIG_MODES = {"auto", "no-reboot", "reboot", "staged", "try"}


def log(message: str) -> None:
  timestamp = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
  print(f"{timestamp} [agent-api] {message}", flush=True)


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


def run_shell(cmd: str) -> tuple[int, str, str]:
  return run_command(["bash", "-lc", cmd])


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


def parse_int(value: str | None, default: int, minimum: int, maximum: int) -> int:
  if value is None:
    return default
  try:
    parsed = int(value)
  except ValueError:
    return default
  return max(minimum, min(maximum, parsed))


def is_valid_name(name: str) -> bool:
  return re.match(r"^[A-Za-z0-9_.-]+$", name) is not None


def safe_log_file_path(requested_path: str) -> bool:
  if not requested_path.startswith("/"):
    return False
  return any(requested_path.startswith(prefix) for prefix in LOG_FILE_ALLOWLIST)


def read_os_release() -> dict[str, str]:
  data: dict[str, str] = {}
  try:
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
      if "=" not in line:
        continue
      key, value = line.split("=", 1)
      data[key.strip()] = value.strip().strip('"')
  except Exception:
    pass
  return data


def read_machine_id() -> str:
  try:
    return MACHINE_ID_FILE.read_text(encoding="utf-8").strip()
  except Exception:
    return ""


def bootstrap_claimed() -> bool:
  return BOOTSTRAP_CLAIMED_FILE.exists()


def read_bootstrap_token() -> str:
  try:
    return BOOTSTRAP_TOKEN_FILE.read_text(encoding="utf-8").strip()
  except Exception:
    return ""


def file_as_json(path: Path) -> tuple[int, dict | list | None, str]:
  try:
    content = path.read_text(encoding="utf-8")
  except FileNotFoundError:
    return (404, None, "file not found")
  except Exception as exc:
    return (500, None, str(exc))

  try:
    return (200, json.loads(content), "")
  except Exception:
    return (500, None, "invalid json")


def validate_machine_config(config_text: str) -> tuple[bool, str]:
  if len(config_text.encode("utf-8")) >= MAX_CONFIG_BYTES:
    return (False, f"config too large (max {MAX_CONFIG_BYTES} bytes)")

  check_yaml_cmd = "cat >/tmp/appcoreos-api-config-check.yaml && yq -e '.' /tmp/appcoreos-api-config-check.yaml >/dev/null"
  rc, _, err = run_shell(f"{check_yaml_cmd} <<'EOF'\n{config_text}\nEOF")
  if rc != 0:
    return (False, f"invalid YAML: {err.strip()}")

  shape_cmd = "cat >/tmp/appcoreos-api-config-shape.yaml && yq -e '(.hostname | type) == \"!!str\" and (.hostname | length) > 0 and (.containers | type) == \"!!seq\"' /tmp/appcoreos-api-config-shape.yaml >/dev/null"
  rc, _, err = run_shell(f"{shape_cmd} <<'EOF'\n{config_text}\nEOF")
  if rc != 0:
    return (False, "missing/invalid required fields: hostname:string, containers:array")

  return (True, "")


def apply_machine_config(config_text: str, mode: str, try_seconds: int) -> tuple[int, dict]:
  valid, reason = validate_machine_config(config_text)
  if not valid:
    return (400, {"error": reason})

  backup_text = ""
  if CONFIG_FILE.exists():
    backup_text = CONFIG_FILE.read_text(encoding="utf-8")

  CONFIG_FILE.write_text(config_text, encoding="utf-8")

  rc, out, err = run_command(["/usr/lib/appcoreos/apply-machine-config.sh", str(CONFIG_FILE)])
  if rc != 0:
    if backup_text:
      CONFIG_FILE.write_text(backup_text, encoding="utf-8")
    return (500, {"error": "failed to apply machine config", "stderr": err.strip()})

  run_command(["/usr/lib/appcoreos/generate-containers.sh"])
  run_command(["systemctl", "daemon-reload"])
  run_command(["systemctl", "restart", "containers.service"])

  if mode == "reboot":
    run_command(["systemctl", "reboot"])
    return (202, {"result": "accepted", "mode": mode, "message": "reboot requested"})

  if mode == "try":
    if backup_text:
      rollback_file = Path("/var/lib/appcoreos/config.try.rollback.yaml")
      rollback_file.write_text(backup_text, encoding="utf-8")
      rollback_cmd = (
        f"systemd-run --unit appcoreos-config-try-rollback --on-active={try_seconds} "
        f"/bin/bash -lc 'if [ -f /var/lib/appcoreos/config.try.rollback.yaml ]; then "
        f"cp /var/lib/appcoreos/config.try.rollback.yaml /var/lib/appcoreos/config.yaml; "
        f"/usr/lib/appcoreos/apply-machine-config.sh /var/lib/appcoreos/config.yaml || true; "
        f"rm -f /var/lib/appcoreos/config.try.rollback.yaml; fi'"
      )
      run_shell(rollback_cmd)
    return (
      202,
      {
        "result": "accepted",
        "mode": mode,
        "message": "try mode applied; call POST /v1/machine-config/confirm before timer expires",
        "try_seconds": try_seconds,
      },
    )

  return (200, {"result": "ok", "mode": mode})


def collect_services() -> tuple[int, dict]:
  rc, out, err = run_command(["systemctl", "list-units", "--type=service", "--all", "--no-legend", "--no-pager"])
  if rc != 0:
    return (500, {"error": err.strip() or "failed to list services"})

  services = []
  for line in out.splitlines():
    if not line.strip():
      continue
    parts = line.split(None, 4)
    if len(parts) < 4:
      continue
    unit, load, active, sub = parts[:4]
    description = parts[4] if len(parts) >= 5 else ""
    services.append(
      {
        "name": unit,
        "load": load,
        "active": active,
        "sub": sub,
        "description": description,
      }
    )
  return (200, {"services": services})


def get_service(name: str) -> tuple[int, dict]:
  rc, out, err = run_command(
    [
      "systemctl",
      "show",
      name,
      "--no-pager",
      "-p",
      "Id,Description,LoadState,ActiveState,SubState,UnitFileState,FragmentPath",
    ]
  )
  if rc != 0:
    return (404, {"error": err.strip() or "service not found"})

  data: dict[str, str] = {}
  for line in out.splitlines():
    if "=" not in line:
      continue
    key, value = line.split("=", 1)
    data[key] = value
  return (200, data)


def collect_containers() -> tuple[int, dict]:
  rc, out, err = run_command([
    "podman",
    "ps",
    "-a",
    "--format",
    "{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}",
  ])
  if rc != 0:
    return (500, {"error": err.strip() or "podman ps failed"})

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
  return (200, {"containers": containers})


def get_update_status() -> tuple[int, dict]:
  if not Path("/run/ostree-booted").exists():
    return (200, {"ostree_booted": False, "pending_deployment": False})

  rc, out, err = run_command(["rpm-ostree", "status", "--json"])
  if rc != 0:
    return (500, {"error": err.strip() or "failed to query rpm-ostree status"})

  try:
    status_data = json.loads(out)
  except Exception:
    return (500, {"error": "invalid rpm-ostree status json"})

  deployments = status_data.get("deployments", [])
  pending = any(deployment.get("booted") is not True for deployment in deployments)
  booted = next((deployment for deployment in deployments if deployment.get("booted") is True), None)
  staged = next((deployment for deployment in deployments if deployment.get("staged") is True), None)

  return (
    200,
    {
      "ostree_booted": True,
      "pending_deployment": pending,
      "booted_checksum": (booted or {}).get("checksum", ""),
      "staged_checksum": (staged or {}).get("checksum", ""),
      "deployments": len(deployments),
    },
  )


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

  def _read_body(self) -> bytes:
    try:
      length = int(self.headers.get("Content-Length", "0"))
    except ValueError:
      length = 0
    if length <= 0:
      return b""
    return self.rfile.read(length)

  def _read_json_body(self) -> tuple[dict | None, str]:
    raw = self._read_body()
    if not raw:
      return ({}, "")
    try:
      parsed = json.loads(raw.decode("utf-8"))
    except Exception:
      return (None, "invalid JSON body")
    if not isinstance(parsed, dict):
      return (None, "JSON body must be an object")
    return (parsed, "")

  def _is_authenticated(self) -> bool:
    if not API_KEY:
      return True

    auth_header = self.headers.get("Authorization", "")
    api_key_header = self.headers.get("X-API-Key", "")

    if api_key_header == API_KEY:
      return True

    if auth_header.startswith("Bearer "):
      token = auth_header.split(" ", 1)[1].strip()
      if token == API_KEY:
        return True

    return False

  def _require_auth(self, path: str) -> bool:
    if path in {"/health", "/healthz", "/v1/health", "/v1/bootstrap/status"}:
      return True

    if path == "/v1/bootstrap/claim" and not bootstrap_claimed():
      return True

    if self._is_authenticated():
      return True

    self._write_json(401, {"error": "unauthorized", "hint": "use Authorization: Bearer <api-key>"})
    return False

  def do_GET(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path
    params = parse_qs(parsed.query)

    if not self._require_auth(path):
      return

    if path in {"/health", "/healthz", "/v1/health"}:
      self._write_json(200, {"status": "ok"})
      return

    if path == "/v1/bootstrap/status":
      token = read_bootstrap_token()
      payload = {
        "machine_id": read_machine_id(),
        "claimed": bootstrap_claimed(),
        "require_mtls": REQUIRE_MTLS,
        "client_ca_present": Path(CLIENT_CA).exists(),
        "claim_endpoint": "/v1/bootstrap/claim",
      }
      if not bootstrap_claimed():
        payload["bootstrap_token"] = token
      self._write_json(200, payload)
      return

    if path in {"/state", "/v1/state"}:
      log(f"GET {path}")
      status, payload, error = file_as_json(STATE_FILE)
      if status == 200:
        self._write_json(200, payload if isinstance(payload, dict | list) else {})
      else:
        self._write_json(status, {"error": error})
      return

    if path == "/v1/info":
      log("GET /v1/info")
      os_release = read_os_release()
      boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip() if Path("/proc/sys/kernel/random/boot_id").exists() else ""
      uptime_seconds = 0.0
      try:
        uptime_seconds = float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0])
      except Exception:
        uptime_seconds = 0.0
      self._write_json(
        200,
        {
          "machine_id": read_machine_id(),
          "hostname": os.uname().nodename,
          "boot_id": boot_id,
          "uptime_seconds": uptime_seconds,
          "os": {
            "name": os_release.get("NAME", ""),
            "pretty_name": os_release.get("PRETTY_NAME", ""),
            "version_id": os_release.get("VERSION_ID", ""),
          },
          "api": {
            "version": "v1",
            "tls_enabled": bool(TLS_CERT and TLS_KEY),
            "auth": "api-key" if API_KEY else "none",
          },
        },
      )
      return

    if path == "/v1/host/update-status":
      log("GET /v1/host/update-status")
      code, payload = get_update_status()
      self._write_json(code, payload)
      return

    if path in {"/logs", "/v1/logs/journal"}:
      tail = parse_tail(params.get("tail", [None])[0])
      unit = params.get("unit", [""])[0].strip()
      since = params.get("since", [""])[0].strip()
      log(f"GET {path}")
      cmd = ["journalctl", "-n", str(tail), "--no-pager"]
      if unit:
        cmd.extend(["-u", unit])
      if since:
        cmd.extend(["--since", since])
      rc, out, err = run_command(cmd)
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_text(500, err or "journalctl failed\n", "text/plain; charset=utf-8")
      return

    if path == "/v1/logs/kernel":
      tail = parse_tail(params.get("tail", [None])[0])
      log("GET /v1/logs/kernel")
      rc, out, err = run_command(["journalctl", "-k", "-n", str(tail), "--no-pager"])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_text(500, err or "kernel log query failed\n", "text/plain; charset=utf-8")
      return

    if path == "/v1/logs/file":
      requested = params.get("path", [""])[0]
      tail = parse_tail(params.get("tail", [None])[0])
      log("GET /v1/logs/file")
      if not requested:
        self._write_json(400, {"error": "missing path query parameter"})
        return
      if not safe_log_file_path(requested):
        self._write_json(403, {"error": "path is outside allowed log roots"})
        return
      rc, out, err = run_command(["tail", "-n", str(tail), requested])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_json(404, {"error": err.strip() or "file not found"})
      return

    if path in {"/containers", "/v1/containers"}:
      log(f"GET {path}")
      code, payload = collect_containers()
      self._write_json(code, payload)
      return

    if path == "/v1/services":
      log("GET /v1/services")
      code, payload = collect_services()
      self._write_json(code, payload)
      return

    service_match = re.match(r"^/v1/services/([^/]+)$", path)
    if service_match:
      name = service_match.group(1)
      if not is_valid_name(name):
        self._write_json(400, {"error": "invalid service name"})
        return
      log(f"GET /v1/services/{name}")
      code, payload = get_service(name)
      self._write_json(code, payload)
      return

    container_match = re.match(r"^/v1/containers/([^/]+)$", path)
    if container_match:
      name = container_match.group(1)
      if not is_valid_name(name):
        self._write_json(400, {"error": "invalid container name"})
        return
      log(f"GET /v1/containers/{name}")
      rc, out, err = run_command(["podman", "inspect", name])
      if rc == 0:
        try:
          self._write_json(200, json.loads(out)[0])
        except Exception:
          self._write_json(500, {"error": "invalid inspect output"})
      else:
        self._write_json(404, {"error": err.strip() or "container not found"})
      return

    container_logs_match = re.match(r"^/containers/([^/]+)/logs$|^/v1/containers/([^/]+)/logs$", path)
    if container_logs_match:
      name = container_logs_match.group(1) or container_logs_match.group(2)
      tail = parse_tail(params.get("tail", [None])[0])
      if not name or not is_valid_name(name):
        self._write_json(400, {"error": "invalid container name"})
        return
      log(f"GET {path}")
      rc, out, err = run_command(["podman", "logs", "--tail", str(tail), name])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        status = 404 if "no container" in err.lower() else 500
        self._write_json(status, {"error": err.strip() or "podman logs failed"})
      return

    if path == "/v1/network/interfaces":
      log("GET /v1/network/interfaces")
      rc, out, err = run_command(["ip", "-j", "addr", "show"])
      if rc == 0:
        self._write_text(200, out, "application/json")
      else:
        self._write_json(500, {"error": err.strip() or "failed to query interfaces"})
      return

    if path == "/v1/network/routes":
      log("GET /v1/network/routes")
      rc, out, err = run_command(["ip", "-j", "route", "show"])
      if rc == 0:
        self._write_text(200, out, "application/json")
      else:
        self._write_json(500, {"error": err.strip() or "failed to query routes"})
      return

    if path == "/v1/machine-config":
      log("GET /v1/machine-config")
      if not CONFIG_FILE.exists():
        self._write_json(404, {"error": "machine config not found"})
        return
      self._write_text(200, CONFIG_FILE.read_text(encoding="utf-8"), "text/yaml; charset=utf-8")
      return

    if path == "/v1/disks":
      log("GET /v1/disks")
      rc, out, err = run_command(["lsblk", "-J", "-o", "NAME,KNAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL"])
      if rc == 0:
        self._write_text(200, out, "application/json")
      else:
        self._write_json(500, {"error": err.strip() or "failed to query disks"})
      return

    if path == "/v1/disks/usage":
      log("GET /v1/disks/usage")
      rc, out, err = run_command(["df", "-hT"])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_json(500, {"error": err.strip() or "failed to query usage"})
      return

    if path == "/v1/mounts":
      log("GET /v1/mounts")
      rc, out, err = run_command(["mount"])
      if rc == 0:
        self._write_text(200, out, "text/plain; charset=utf-8")
      else:
        self._write_json(500, {"error": err.strip() or "failed to query mounts"})
      return

    if path == "/v1/stacks":
      log("GET /v1/stacks")
      STACKS_DIR.mkdir(parents=True, exist_ok=True)
      stacks = [p.name for p in sorted(STACKS_DIR.glob("*.yaml"))] + [p.name for p in sorted(STACKS_DIR.glob("*.yml"))]
      self._write_json(200, {"stacks": sorted(set(stacks))})
      return

    log(f"GET {path} (not found)")
    self._write_text(404, "not found\n", "text/plain; charset=utf-8")

  def do_POST(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path

    if not self._require_auth(path):
      return

    if path == "/v1/bootstrap/claim":
      log("POST /v1/bootstrap/claim")
      if bootstrap_claimed():
        self._write_json(409, {"error": "node is already claimed"})
        return

      expected_token = read_bootstrap_token()
      provided_token = self.headers.get("X-Bootstrap-Token", "").strip()
      if not expected_token:
        self._write_json(500, {"error": "bootstrap token not initialized"})
        return
      if provided_token != expected_token:
        self._write_json(401, {"error": "invalid bootstrap token"})
        return

      body, err = self._read_json_body()
      if body is None:
        self._write_json(400, {"error": err})
        return

      client_ca_pem = str(body.get("client_ca_pem", "")).strip()
      if not client_ca_pem:
        self._write_json(400, {"error": "missing client_ca_pem"})
        return
      if "BEGIN CERTIFICATE" not in client_ca_pem or "END CERTIFICATE" not in client_ca_pem:
        self._write_json(400, {"error": "client_ca_pem is not a valid PEM certificate"})
        return

      client_ca_path = Path(CLIENT_CA)
      client_ca_path.parent.mkdir(parents=True, exist_ok=True)
      tmp_ca_path = client_ca_path.with_suffix(".tmp")
      tmp_ca_path.write_text(client_ca_pem.rstrip() + "\n", encoding="utf-8")
      tmp_ca_path.replace(client_ca_path)
      try:
        client_ca_path.chmod(0o600)
      except Exception:
        pass

      BOOTSTRAP_CLAIMED_FILE.parent.mkdir(parents=True, exist_ok=True)
      BOOTSTRAP_CLAIMED_FILE.write_text(datetime.datetime.now(datetime.timezone.utc).isoformat() + "\n", encoding="utf-8")

      # Restart agent shortly after returning so TLS mode switches to mTLS.
      run_command(
        [
          "systemd-run",
          "--unit",
          "appcoreos-agent-restart",
          "--on-active=1",
          "/usr/bin/systemctl",
          "restart",
          "agent.service",
        ]
      )

      self._write_json(
        202,
        {
          "result": "accepted",
          "message": "bootstrap claim accepted; agent restart scheduled to enforce mTLS",
        },
      )
      return

    container_action_match = re.match(r"^/containers/([^/]+)/(start|restart|stop)$|^/v1/containers/([^/]+)/(start|restart|stop)$", path)
    if container_action_match:
      name = container_action_match.group(1) or container_action_match.group(3)
      action = container_action_match.group(2) or container_action_match.group(4)
      if not name or not action or not is_valid_name(name):
        self._write_json(400, {"error": "invalid container request"})
        return
      log(f"POST {path}")
      rc, _, err = run_command(["systemctl", action, f"{name}.service"])
      if rc == 0:
        self._write_json(200, {"result": "ok", "container": name, "action": action, "mode": "systemd"})
        return
      rc2, _, err2 = run_command(["podman", action, name])
      if rc2 == 0:
        self._write_json(200, {"result": "ok", "container": name, "action": action, "mode": "podman-fallback"})
        return
      self._write_json(500, {"error": "container action failed", "systemd": err.strip(), "podman": err2.strip()})
      return

    service_action_match = re.match(r"^/v1/services/([^/]+)/(start|stop|restart)$", path)
    if service_action_match:
      name, action = service_action_match.groups()
      if not is_valid_name(name):
        self._write_json(400, {"error": "invalid service name"})
        return
      log(f"POST /v1/services/{name}/{action}")
      rc, _, err = run_command(["systemctl", action, name])
      if rc == 0:
        self._write_json(200, {"result": "ok", "service": name, "action": action})
      else:
        self._write_json(500, {"error": err.strip() or "service action failed"})
      return

    if path == "/v1/containers/apply":
      log("POST /v1/containers/apply")
      rc1, _, e1 = run_command(["/usr/lib/appcoreos/generate-containers.sh"])
      rc2, _, e2 = run_command(["systemctl", "daemon-reload"])
      rc3, _, e3 = run_command(["systemctl", "restart", "containers.service"])
      if rc1 == 0 and rc2 == 0 and rc3 == 0:
        self._write_json(200, {"result": "ok"})
      else:
        self._write_json(500, {"error": "container apply failed", "generate": e1.strip(), "reload": e2.strip(), "restart": e3.strip()})
      return

    if path == "/v1/machine-config/confirm":
      log("POST /v1/machine-config/confirm")
      rollback_file = Path("/var/lib/appcoreos/config.try.rollback.yaml")
      rollback_file.unlink(missing_ok=True)
      run_command(["systemctl", "stop", "appcoreos-config-try-rollback.service"])
      self._write_json(200, {"result": "ok", "message": "try rollback canceled"})
      return

    if path in {"/v1/host/reboot", "/v1/host/shutdown", "/v1/host/update", "/v1/host/rollback"}:
      log(f"POST {path}")
      if path == "/v1/host/reboot":
        run_command(["systemctl", "reboot"])
        self._write_json(202, {"result": "accepted", "action": "reboot"})
        return
      if path == "/v1/host/shutdown":
        run_command(["systemctl", "poweroff"])
        self._write_json(202, {"result": "accepted", "action": "shutdown"})
        return
      if path == "/v1/host/update":
        rc, _, err = run_command(["systemctl", "start", "update-os.service"])
        if rc == 0:
          self._write_json(202, {"result": "accepted", "action": "update-stage"})
        else:
          _, j_out, _ = run_command(["journalctl", "-u", "update-os.service", "-n", "20", "--no-pager"])
          self._write_json(
            500,
            {
              "error": "failed to stage host update",
              "systemctl": err.strip() or "failed to trigger update-os.service",
              "journal_tail": (j_out or "").strip()[-4000:],
            },
          )
        return
      self._write_json(501, {"error": "rollback not implemented"})
      return

    self._write_text(404, "not found\n", "text/plain; charset=utf-8")

  def do_PUT(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path

    if not self._require_auth(path):
      return

    if path == "/v1/network/config":
      log("PUT /v1/network/config")
      body, err = self._read_json_body()
      if body is None:
        self._write_json(400, {"error": err})
        return

      mode = str(body.get("mode", "dhcp")).strip().lower()
      interface = str(body.get("interface", "")).strip()
      if mode not in {"dhcp", "static"}:
        self._write_json(400, {"error": "mode must be dhcp or static"})
        return
      if not is_valid_name(interface):
        self._write_json(400, {"error": "invalid interface"})
        return

      if mode == "dhcp":
        cmd = f"nmcli connection add type ethernet ifname {interface} con-name appcoreos-{interface} ipv4.method auto >/dev/null 2>&1 || true; nmcli connection modify appcoreos-{interface} ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns ''"
        rc, _, cmd_err = run_shell(cmd)
        if rc != 0:
          self._write_json(500, {"error": cmd_err.strip() or "failed to configure dhcp"})
          return
        run_command(["nmcli", "connection", "up", f"appcoreos-{interface}"])
        self._write_json(200, {"result": "ok", "mode": "dhcp", "interface": interface})
        return

      address = str(body.get("address", "")).strip()
      gateway = str(body.get("gateway", "")).strip()
      dns_list = body.get("dns", [])
      if not address or not gateway:
        self._write_json(400, {"error": "static mode requires address and gateway"})
        return
      if dns_list and not isinstance(dns_list, list):
        self._write_json(400, {"error": "dns must be an array"})
        return
      dns_str = ",".join(str(item).strip() for item in dns_list if str(item).strip())
      cmd = (
        f"nmcli connection add type ethernet ifname {interface} con-name appcoreos-{interface} ipv4.method manual >/dev/null 2>&1 || true; "
        f"nmcli connection modify appcoreos-{interface} ipv4.method manual ipv4.addresses '{address}' ipv4.gateway '{gateway}'"
      )
      if dns_str:
        cmd += f" ipv4.dns '{dns_str}'"
      rc, _, cmd_err = run_shell(cmd)
      if rc != 0:
        self._write_json(500, {"error": cmd_err.strip() or "failed to configure static network"})
        return
      run_command(["nmcli", "connection", "up", f"appcoreos-{interface}"])
      self._write_json(200, {"result": "ok", "mode": "static", "interface": interface})
      return

    stack_match = re.match(r"^/v1/stacks/([^/]+)$", path)
    if stack_match:
      name = stack_match.group(1)
      if not is_valid_name(name):
        self._write_json(400, {"error": "invalid stack name"})
        return
      log(f"PUT /v1/stacks/{name}")
      raw = self._read_body().decode("utf-8", errors="replace")
      if not raw.strip():
        self._write_json(400, {"error": "empty compose payload"})
        return
      STACKS_DIR.mkdir(parents=True, exist_ok=True)
      compose_file = STACKS_DIR / f"{name}.yaml"
      compose_file.write_text(raw, encoding="utf-8")
      rc, out, err = run_command(["podman-compose", "-f", str(compose_file), "up", "-d"])
      if rc == 0:
        self._write_json(200, {"result": "ok", "stack": name})
      else:
        self._write_json(500, {"error": err.strip() or out.strip() or "podman-compose up failed"})
      return

    if path == "/v1/machine-config":
      log("PUT /v1/machine-config")
      mode = parse_qs(parsed.query).get("mode", ["auto"])[0].strip().lower()
      try_seconds = parse_int(parse_qs(parsed.query).get("try_seconds", [None])[0], default=120, minimum=30, maximum=1800)
      if mode not in VALID_CONFIG_MODES:
        self._write_json(400, {"error": f"invalid mode '{mode}'"})
        return

      content_type = self.headers.get("Content-Type", "")
      if "application/json" in content_type:
        body, err = self._read_json_body()
        if body is None:
          self._write_json(400, {"error": err})
          return
        config_text = str(body.get("config", ""))
      else:
        config_text = self._read_body().decode("utf-8", errors="replace")

      if mode == "staged":
        valid, reason = validate_machine_config(config_text)
        if not valid:
          self._write_json(400, {"error": reason})
          return
        STAGED_CONFIG_FILE.write_text(config_text, encoding="utf-8")
        self._write_json(202, {"result": "accepted", "mode": "staged", "path": str(STAGED_CONFIG_FILE)})
        return

      code, payload = apply_machine_config(config_text, mode, try_seconds)
      self._write_json(code, payload)
      return

    self._write_text(404, "not found\n", "text/plain; charset=utf-8")

  def do_PATCH(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path

    if not self._require_auth(path):
      return

    if path != "/v1/machine-config":
      self._write_text(404, "not found\n", "text/plain; charset=utf-8")
      return

    log("PATCH /v1/machine-config")
    if not CONFIG_FILE.exists():
      self._write_json(404, {"error": "machine config not found"})
      return

    body, err = self._read_json_body()
    if body is None:
      self._write_json(400, {"error": err})
      return

    patch_text = str(body.get("patch", "")).strip()
    if not patch_text:
      self._write_json(400, {"error": "missing patch field"})
      return

    # Minimal patch strategy for now: append YAML snippet to existing config.
    # Full strategic merge can be added later.
    merged = CONFIG_FILE.read_text(encoding="utf-8").rstrip() + "\n" + patch_text + "\n"
    mode = parse_qs(parsed.query).get("mode", ["auto"])[0].strip().lower()
    try_seconds = parse_int(parse_qs(parsed.query).get("try_seconds", [None])[0], default=120, minimum=30, maximum=1800)
    if mode not in VALID_CONFIG_MODES:
      self._write_json(400, {"error": f"invalid mode '{mode}'"})
      return
    code, payload = apply_machine_config(merged, mode, try_seconds)
    self._write_json(code, payload)

  def do_DELETE(self) -> None:
    parsed = urlparse(self.path)
    path = parsed.path

    if not self._require_auth(path):
      return

    stack_match = re.match(r"^/v1/stacks/([^/]+)$", path)
    if stack_match:
      name = stack_match.group(1)
      if not is_valid_name(name):
        self._write_json(400, {"error": "invalid stack name"})
        return
      log(f"DELETE /v1/stacks/{name}")
      compose_file = STACKS_DIR / f"{name}.yaml"
      if compose_file.exists():
        run_command(["podman-compose", "-f", str(compose_file), "down"])
        compose_file.unlink(missing_ok=True)
      self._write_json(200, {"result": "ok", "deleted": name})
      return

    self._write_text(404, "not found\n", "text/plain; charset=utf-8")


def main() -> None:
  server = ThreadingHTTPServer((HOST, PORT), Handler)
  if TLS_CERT and TLS_KEY and Path(TLS_CERT).exists() and Path(TLS_KEY).exists():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=TLS_CERT, keyfile=TLS_KEY)
    if REQUIRE_MTLS:
      if not CLIENT_CA or not Path(CLIENT_CA).exists():
        raise RuntimeError("mTLS required but client CA is missing")
      context.load_verify_locations(cafile=CLIENT_CA)
      context.verify_mode = ssl.CERT_REQUIRED
    server.socket = context.wrap_socket(server.socket, server_side=True)
    if REQUIRE_MTLS:
      log(f"api listening on https://{HOST}:{PORT} (tls + mtls + api-key)")
    else:
      log(f"api listening on https://{HOST}:{PORT} (tls + api-key)")
  else:
    log(f"api listening on http://{HOST}:{PORT} (api-key)")

  server.serve_forever()


if __name__ == "__main__":
  main()
