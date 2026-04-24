import importlib.util
import os
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
AGENT_API_PATH = REPO_ROOT / "system_files/usr/lib/appcoreos/agent-debug-server.py"
GENERATE_CONTAINERS_PATH = REPO_ROOT / "system_files/usr/lib/appcoreos/generate-containers.sh"


def load_agent_api_module():
    spec = importlib.util.spec_from_file_location("appcoreos_agent_api", AGENT_API_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@contextmanager
def fake_yq_on_path():
    script = r"""#!/usr/bin/env python3
import re
import sys
from pathlib import Path

def parse_yaml(path: str):
    data = {"hostname": "", "containers": []}
    current = None
    reading_ports = False
    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if line.startswith("hostname:"):
            data["hostname"] = line.split(":", 1)[1].strip()
            current = None
            reading_ports = False
            continue
        if stripped == "containers: []":
            data["containers"] = []
            current = None
            reading_ports = False
            continue
        if stripped == "containers:":
            current = None
            reading_ports = False
            continue
        match = re.match(r"^\s*-\s*name:\s*(.+)$", line)
        if match:
            current = {"name": match.group(1).strip(), "image": "", "ports": []}
            data["containers"].append(current)
            reading_ports = False
            continue
        if current is not None:
            match = re.match(r"^\s*image:\s*(.+)$", line)
            if match:
                current["image"] = match.group(1).strip()
                continue
            if re.match(r"^\s*ports:\s*$", line):
                reading_ports = True
                continue
            match = re.match(r"^\s*-\s*(.+)$", line)
            if reading_ports and match:
                current["ports"].append(match.group(1).strip())
                continue
            if stripped and not line.startswith(" "):
                current = None
                reading_ports = False
    return data

def main():
    args = sys.argv[1:]
    raw = False
    expr = None
    path = None
    index = 0
    while index < len(args):
        if args[index] == "-r":
            raw = True
            expr = args[index + 1]
            path = args[index + 2]
            break
        if args[index] == "-e":
            expr = args[index + 1]
            path = args[index + 2]
            break
        index += 1
    if expr is None or path is None:
        return 1

    try:
        data = parse_yaml(path)
    except Exception:
        return 1

    if expr == ".":
        return 0
    if expr == '(.hostname | type) == "!!str" and (.hostname | length) > 0 and (.containers | type) == "!!seq"':
        hostname = data.get("hostname", "")
        containers = data.get("containers", [])
        return 0 if isinstance(hostname, str) and hostname and isinstance(containers, list) else 1
    if expr == ".containers // [] | length":
        print(len(data.get("containers", [])))
        return 0

    match = re.match(r'^\.containers\[(\d+)\]\.name // ""$', expr)
    if match:
        index = int(match.group(1))
        containers = data.get("containers", [])
        print(containers[index].get("name", "") if index < len(containers) else "")
        return 0

    match = re.match(r'^\.containers\[(\d+)\]\.image // ""$', expr)
    if match:
        index = int(match.group(1))
        containers = data.get("containers", [])
        print(containers[index].get("image", "") if index < len(containers) else "")
        return 0

    match = re.match(r'^\.containers\[(\d+)\]\.ports // \[\] \| \.\[\]$', expr)
    if match:
        index = int(match.group(1))
        containers = data.get("containers", [])
        ports = containers[index].get("ports", []) if index < len(containers) else []
        for port in ports:
            print(port)
        return 0

    return 1

if __name__ == "__main__":
    raise SystemExit(main())
"""
    original_path = os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory() as tmpdir:
        shim = Path(tmpdir) / "yq"
        shim.write_text(script, encoding="utf-8")
        shim.chmod(0o755)
        os.environ["PATH"] = f"{tmpdir}:{original_path}"
        try:
            yield
        finally:
            os.environ["PATH"] = original_path


class AgentApiHardeningTests(unittest.TestCase):
    def test_bootstrap_status_omits_secret_token(self):
        module = load_agent_api_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            module.read_machine_id = lambda: "machine-123"
            module.bootstrap_claimed = lambda: False
            module.read_bootstrap_token = lambda: "super-secret-token"
            module.CLIENT_CA = str(Path(tmpdir) / "client-ca.crt")

            payload = module.bootstrap_status_payload()

        self.assertEqual(payload["machine_id"], "machine-123")
        self.assertTrue(payload["bootstrap_token_present"])
        self.assertNotIn("bootstrap_token", payload)

    def test_claimed_mode_requires_mtls_and_api_key(self):
        module = load_agent_api_module()

        self.assertFalse(module.request_is_authenticated(True, False, "test-key", "Bearer test-key", ""))
        self.assertFalse(module.request_is_authenticated(True, True, "test-key", "", ""))
        self.assertTrue(module.request_is_authenticated(True, True, "test-key", "Bearer test-key", ""))
        self.assertTrue(module.request_is_authenticated(True, True, "test-key", "", "test-key"))

    def test_log_path_resolution_blocks_symlink_escape(self):
        module = load_agent_api_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            allowed_root = root / "allowed"
            outside_root = root / "outside"
            allowed_root.mkdir()
            outside_root.mkdir()

            inside_log = allowed_root / "inside.log"
            inside_log.write_text("ok\n", encoding="utf-8")
            outside_log = outside_root / "outside.log"
            outside_log.write_text("nope\n", encoding="utf-8")
            escape_log = allowed_root / "escape.log"
            escape_log.symlink_to(outside_log)

            module.LOG_FILE_ALLOWLIST = [str(allowed_root) + "/"]

            self.assertEqual(module.resolve_log_file_path(str(inside_log)), inside_log.resolve())
            self.assertIsNone(module.resolve_log_file_path(str(escape_log)))

    def test_validate_machine_config_accepts_expected_shape(self):
        with fake_yq_on_path():
            module = load_agent_api_module()
            valid, reason = module.validate_machine_config("hostname: node1\ncontainers: []\n")
            self.assertTrue(valid, reason)


class GenerateContainersTests(unittest.TestCase):
    def test_generator_only_reconciles_managed_quadlets(self):
        with fake_yq_on_path():
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                state_dir = root / "state"
                quadlet_dir = root / "quadlets"
                config_path = root / "config.yaml"
                managed_list_path = state_dir / "generated-containers.list"
                state_dir.mkdir()
                quadlet_dir.mkdir()

                config_path.write_text(
                    "hostname: node1\ncontainers:\n  - name: app\n    image: quay.io/example/app:latest\n",
                    encoding="utf-8",
                )

                unmanaged_file = quadlet_dir / "third-party.container"
                unmanaged_file.write_text("[Container]\nImage=busybox\n", encoding="utf-8")

                managed_file = quadlet_dir / "old-managed.container"
                managed_file.write_text("# old\n", encoding="utf-8")
                managed_list_path.write_text(str(managed_file) + "\n", encoding="utf-8")

                env = os.environ.copy()
                env.update(
                    {
                        "APPCOREOS_CONFIG_PATH": str(config_path),
                        "APPCOREOS_QUADLET_DIR": str(quadlet_dir),
                        "APPCOREOS_STATE_DIR": str(state_dir),
                        "APPCOREOS_MANAGED_CONTAINER_LIST": str(managed_list_path),
                    }
                )

                subprocess.run(
                    ["bash", str(GENERATE_CONTAINERS_PATH)],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )

                self.assertTrue(unmanaged_file.exists())
                self.assertFalse(managed_file.exists())

                generated_file = quadlet_dir / "app.container"
                self.assertTrue(generated_file.exists())
                generated_text = generated_file.read_text(encoding="utf-8")
                self.assertIn("Generated by AppCoreOS", generated_text)
                self.assertIn("Image=quay.io/example/app:latest", generated_text)

                managed_list = managed_list_path.read_text(encoding="utf-8").strip().splitlines()
                self.assertEqual(managed_list, [str(generated_file)])


if __name__ == "__main__":
    unittest.main()
