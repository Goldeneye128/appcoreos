# AppCoreOS Full OS Setup

## 1. Project Structure

- `Containerfile`: immutable OS image build definition.
- `system_files/`: filesystem overlay copied into image (`/etc`, `/usr/lib/appcoreos`, systemd units).
- `build.sh`: image and qcow2 build pipeline.
- `runvm.sh`: local QEMU runner.
- `dev.sh`: clean build + run helper.
- `docs/`: API and setup documentation.

## 2. Build

Build bootable qcow2 artifact:

```bash
./build.sh --target proxmox
```

Optional clean rebuild:

```bash
./build.sh --target proxmox -d
```

Artifact output:

- `build/appcoreos.qcow2`

Build logs:

- `build/logs/build-<timestamp>.log`

## 3. Run VM

```bash
./runvm.sh
```

QEMU mode:

- software emulation (`tcg`), x86_64 guest
- user-mode network with subnet `192.168.122.0/24`
- host port forward: `127.0.0.1:9090 -> guest:9090`

## 4. Console/TUI

- TUI owns serial console.
- Shows machine info, networking, config source, and API key.
- No SSH intended for operations.

## 5. Runtime Model

### Machine config bootstrap

Startup flow:

1. try ISO config: `/mnt/config/machine-config.yaml`
2. fallback runtime config: `/var/lib/appcoreos/config.yaml`
3. apply hostname/network settings

### Container runtime

- Source config: `/var/lib/appcoreos/config.yaml`
- Quadlet generation target: `/etc/containers/systemd/*.container`
- Regeneration is idempotent each cycle.

### State reporting

- Generated file: `/var/lib/appcoreos/state.json`
- Timer-driven update via `state.timer`.

### Agent

- Polls remote config endpoint (`http://<gateway>:8081/config/<machine-id>`)
- Applies validated changes
- Exposes HTTPS API on `9090`

## 6. Key Paths

- Runtime state: `/var/lib/appcoreos/`
- Internal scripts: `/usr/lib/appcoreos/`
- Systemd units: `/etc/systemd/system/`
- Quadlet units: `/etc/containers/systemd/`

## 7. Security Posture

- Immutable, image-based OS model
- API-driven management
- HTTPS local API + API key auth
- Console-first appliance behavior

## 8. Typical Operator Workflow

1. Build image (`build.sh`).
2. Boot VM (`runvm.sh`).
3. Read API key from TUI.
4. Use `/v1/*` API for diagnostics and operations.
5. Push machine config updates through API.

## 9. Next Production Steps

- Replace API-key-only model with mTLS + RBAC.
- Trust/pin node certificates from provisioning data.
- Add full strategic merge patch for machine config.
- Add dedicated rollback semantics for host updates.

## 10. Host Update Policy

- `bootc-fetch-apply-updates.timer` handles image-based update staging.
- `appcoreos-reboot-window.timer` runs every 15 minutes and reboots only if:
  - a staged deployment is pending, and
  - current UTC time is in configured maintenance window.
- API endpoint `POST /v1/host/update` triggers immediate stage check (`update-os.service`).
- Update staging requires a reachable container image source (not `localhost/...`).
