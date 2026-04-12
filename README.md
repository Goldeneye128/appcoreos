# AppCoreOS

AppCoreOS is an immutable, API-driven Linux appliance OS built on Fedora CoreOS/bootc concepts.

Goal: a Talos-style appliance experience without Kubernetes.

- Immutable/image-based host
- No SSH shell management
- TUI-first local console
- API-first remote operations
- Podman + Quadlet for workloads

## Current Status

- Public alpha: usable for development and local VM testing, not yet production-hardened.
- Custom image build via `Containerfile`
- VM image build (`qcow2`) via `build.sh`
- Local VM runner via `runvm.sh`
- Machine config bootstrap + network apply
- Container generation/reconciliation from machine config
- Local agent + HTTPS management API (`/v1/*`) with API key auth
- Local TUI dashboard on console

## Repository Layout

- `Containerfile`: AppCoreOS image definition
- `system_files/`: filesystem overlay copied into image
- `build.sh`: build container + qcow2
- `runvm.sh`: run qcow2 locally with QEMU
- `dev.sh`: clean/build/run helper
- `docs/`: API + OS setup documentation
- `appcorectl/`: Go CLI client for AppCoreOS API operations

## Quick Start

### 1. Build

```bash
./build.sh --target proxmox -d
```

Output image:

- `build/appcoreos.qcow2`

### 2. Run locally

```bash
./runvm.sh
```

The VM forwards guest API `:9090` to host `https://127.0.0.1:9090`.

### 3. Call API

Read API key from TUI, then:

```bash
curl -k https://127.0.0.1:9090/health
curl -k -H "Authorization: Bearer <API_KEY>" https://127.0.0.1:9090/v1/info
curl -k -H "Authorization: Bearer <API_KEY>" https://127.0.0.1:9090/v1/state
```

## Updates

- Container/workload updates: `podman-auto-update.timer`
- Host OS updates: image-based model (bootc/rpm-ostree flow)
- Staging: `bootc-fetch-apply-updates.timer`
- Controlled reboot policy: `appcoreos-reboot-window.timer` (maintenance-window gated)
- Daily image publication workflow exists in:
  - `.github/workflows/daily-image-build.yml`

If nodes track a published image tag (for example GHCR `:latest` or a channel tag), they can consume updates from that registry image.
For local qcow2 builds that reference `localhost/...`, host updates cannot be fetched until you rebase to a reachable registry image.

Optional machine-config policy:

```yaml
updates:
  auto_reboot: true
  maintenance_window_utc:
    start: "03:00"
    end: "05:00"
```

## Security Model

- No SSH intended for operations
- API over HTTPS
- API key required for management endpoints
- TUI is the primary local interface

## Day-0 Bootstrap (Claim)

On first boot the node is **unclaimed** and shows a bootstrap token in the TUI.

Claim flow:

1. Read `Bootstrap token` from TUI.
2. Submit client CA to claim endpoint:

```bash
curl -k -X POST \
  -H "X-Bootstrap-Token: <BOOTSTRAP_TOKEN>" \
  -H "Content-Type: application/json" \
  --data-binary @claim.json \
  https://127.0.0.1:9090/v1/bootstrap/claim
```

`claim.json`:

```json
{
  "client_ca_pem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"
}
```

After claim, agent restarts and API enforces mTLS.

## Documentation

- API reference: [`docs/API.md`](docs/API.md)
- OS setup/build/run: [`docs/OS_SETUP.md`](docs/OS_SETUP.md)

## License

This project is licensed under **GNU General Public License v3.0**.
See [`LICENSE`](LICENSE).
