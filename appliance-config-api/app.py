#!/usr/bin/env python3
import json
import logging
from pathlib import Path

import requests
from flask import Flask, Response

app = Flask(__name__)

BASE_DIR = Path(__file__).resolve().parent
CONFIG_DIR = BASE_DIR / "configs"
DEFAULT_CONFIG = CONFIG_DIR / "default.yaml"
MACHINES_FILE = CONFIG_DIR / "machines.json"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [api] %(message)s",
)
logger = logging.getLogger(__name__)


def _resolve_config(machine_id: str) -> Path:
    machine_config = CONFIG_DIR / f"{machine_id}.yaml"
    if machine_config.exists():
        return machine_config
    return DEFAULT_CONFIG


def _load_machine_mapping() -> dict[str, str]:
    if not MACHINES_FILE.exists():
        return {}
    try:
        return json.loads(MACHINES_FILE.read_text(encoding="utf-8"))
    except Exception:
        logger.error("failed to parse machines mapping file=%s", MACHINES_FILE)
        return {}


def _proxy_debug(machine_id: str, endpoint: str) -> Response:
    machines = _load_machine_mapping()
    machine_ip = machines.get(machine_id)
    if not machine_ip:
        logger.warning("machine-id=%s endpoint=%s failed reason=unknown-machine", machine_id, endpoint)
        return Response('{"error":"unknown machine-id"}\n', status=404, mimetype="application/json")

    url = f"http://{machine_ip}:9090/{endpoint}"
    logger.info("machine-id=%s endpoint=%s proxy-url=%s", machine_id, endpoint, url)

    try:
        upstream = requests.get(url, timeout=5)
    except requests.RequestException as exc:
        logger.warning("machine-id=%s endpoint=%s failed reason=%s", machine_id, endpoint, exc)
        return Response('{"error":"upstream unavailable"}\n', status=502, mimetype="application/json")

    logger.info(
        "machine-id=%s endpoint=%s success status=%s",
        machine_id,
        endpoint,
        upstream.status_code,
    )

    content_type = upstream.headers.get("Content-Type", "text/plain; charset=utf-8")
    return Response(upstream.text, status=upstream.status_code, content_type=content_type)


@app.get("/config/<machine_id>")
def get_config(machine_id: str):
    logger.info("incoming request path=/config/%s", machine_id)

    config_file = _resolve_config(machine_id)
    logger.info("machine-id=%s using config file=%s", machine_id, config_file.name)

    body = config_file.read_text(encoding="utf-8")
    return Response(body, status=200, mimetype="text/yaml")


@app.get("/state/<machine_id>")
def get_state(machine_id: str):
    return _proxy_debug(machine_id, "state")


@app.get("/logs/<machine_id>")
def get_logs(machine_id: str):
    return _proxy_debug(machine_id, "logs")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
