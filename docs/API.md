# AppCoreOS API Reference

## Overview

AppCoreOS exposes a local management API from the agent on port `9090`.

- Base URL (host side in QEMU user-net): `https://127.0.0.1:9090`
- Health endpoint (no auth): `GET /health`
- Compatibility alias: `GET /healthz`
- Versioned management endpoints: `/v1/*`

## Security

- Transport: HTTPS (self-signed certificate generated on first boot).
- Auth: API key (Bearer token).
- API key location on node: `/var/lib/appcoreos/api-auth.key`.
- For now, the API key is shown in the TUI.

### Request header

```http
Authorization: Bearer <API_KEY>
```

## Quick Start

```bash
# health (no auth)
curl -k https://127.0.0.1:9090/health

# state
curl -k -H "Authorization: Bearer <API_KEY>" \
  https://127.0.0.1:9090/v1/state
```

## Endpoint Reference

### Health and Info

- `GET /health`
- `GET /healthz`
- `GET /v1/health`
- `GET /v1/info`
- `GET /v1/state`

### Logs

- `GET /v1/logs/journal?tail=200&unit=<unit>&since=<time>`
- `GET /v1/logs/kernel?tail=200`
- `GET /v1/logs/file?path=/var/log/messages&tail=200`

Legacy alias:
- `GET /logs?tail=200`

### Services (systemd)

- `GET /v1/services`
- `GET /v1/services/<name>`
- `POST /v1/services/<name>/start`
- `POST /v1/services/<name>/stop`
- `POST /v1/services/<name>/restart`

### Containers (Podman/Quadlet)

- `GET /v1/containers`
- `GET /v1/containers/<name>`
- `GET /v1/containers/<name>/logs?tail=200`
- `POST /v1/containers/<name>/start`
- `POST /v1/containers/<name>/stop`
- `POST /v1/containers/<name>/restart`
- `POST /v1/containers/apply`

Legacy aliases:
- `GET /containers`
- `GET /containers/<name>/logs?tail=200`
- `POST /containers/<name>/{start|stop|restart}`

### Stacks (podman-compose)

- `GET /v1/stacks`
- `PUT /v1/stacks/<name>` (body = compose YAML)
- `DELETE /v1/stacks/<name>`

### Network

- `GET /v1/network/interfaces`
- `GET /v1/network/routes`
- `PUT /v1/network/config`

Network config payload (DHCP):

```json
{
  "mode": "dhcp",
  "interface": "ens3"
}
```

Network config payload (static):

```json
{
  "mode": "static",
  "interface": "ens3",
  "address": "192.168.122.50/24",
  "gateway": "192.168.122.1",
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

### Machine Config

- `GET /v1/machine-config`
- `PUT /v1/machine-config?mode=auto|no-reboot|reboot|staged|try&try_seconds=120`
- `PATCH /v1/machine-config?mode=auto|no-reboot|reboot|staged|try&try_seconds=120`
- `POST /v1/machine-config/confirm`

`mode=staged` writes to:
- `/var/lib/appcoreos/config.staged.yaml`

`mode=try` schedules automatic rollback unless confirmed.

### Host Operations

- `POST /v1/host/reboot`
- `POST /v1/host/shutdown`
- `POST /v1/host/update` (stage host update check/apply, no immediate reboot)
- `GET /v1/host/update-status`
- `POST /v1/host/rollback` (currently returns not implemented)

Note: staging requires the host to track a reachable image reference. If the deployment is based on `localhost/...` (common in local test builds), staging will fail until rebased to a registry URL.

### Disk and Mounts

- `GET /v1/disks`
- `GET /v1/disks/usage`
- `GET /v1/mounts`

## Talos-Inspired Model

This API follows Talos-style principles adapted for AppCoreOS:

- API-driven operations (no SSH/shell required)
- Declarative machine config as source of truth
- Explicit host lifecycle actions
- Strong auth and encrypted transport

## Current Limits

- TLS is self-signed (client should use trust pinning in production).
- API key is bootstrap auth; mTLS RBAC is planned.
- `PATCH /v1/machine-config` currently appends YAML patch text (minimal behavior).
- `POST /v1/host/rollback` placeholder only.

## Update Window Config

Optional fields in `/var/lib/appcoreos/config.yaml`:

```yaml
updates:
  auto_reboot: true
  maintenance_window_utc:
    start: "03:00"
    end: "05:00"
```

- Staging runs via bootc/rpm-ostree update flow.
- Reboot occurs only when a staged deployment exists and current UTC time is inside the window.
