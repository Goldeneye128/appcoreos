# appcorectl

`appcorectl` is the official Rust operator CLI for AppCoreOS lifecycle management.

- Day-0 bootstrap claim flow
- Day-1 secure API access (`mTLS + API key`)
- Day-2 host, service, container, network, and log operations

## Install

Prerequisites:
- Rust toolchain with `cargo`

Build from source:

```bash
cargo build --release --locked
install -m 0755 target/release/appcorectl bin/appcorectl
```

Build via helper script:

```bash
./scripts/build.sh
```

Build release packages:

```bash
./scripts/package.sh
```

Release artifacts are written to `dist/`:

- `appcorectl-<version>-linux-x86_64.tar.gz`
- `appcorectl_<version>_amd64.deb`
- `appcorectl-<version>-1.x86_64.rpm`
- `SHA256SUMS`

Build and install:

```bash
./scripts/build_install.sh
# or system-wide
./scripts/build_install.sh --system
```

## First Target Setup

Add a target profile:

```bash
appcorectl target add lab --url https://host:9090 --ca ./ca.pem --api-key "$APPCORE_API_KEY"
```

Select active target:

```bash
appcorectl target use lab
```

Show profiles:

```bash
appcorectl target ls
```

Remove target profile only:

```bash
appcorectl target rm lab
```

Remove profile and generated local PKI:

```bash
appcorectl target rm lab --purge-pki
```

Config file location:
- `~/.config/appcorectl/config.yaml`

Audit log location:
- `~/.local/state/appcorectl/audit.log`

## Bootstrap Claim Flow

Check status:

```bash
appcorectl bootstrap status
```

Claim appliance:

```bash
appcorectl bootstrap claim --token <bootstrap-token> --client-ca-file ./client-ca.pem
```

Or let `appcorectl` generate local client PKI automatically:

```bash
appcorectl bootstrap claim --token <bootstrap-token>
```

By default, `bootstrap claim` waits for post-claim API readiness. You can tune or disable this:

```bash
appcorectl bootstrap claim --token <bootstrap-token> --wait-timeout 180 --wait-interval 3
appcorectl bootstrap claim --token <bootstrap-token> --wait=false
```

You can also wait explicitly:

```bash
appcorectl bootstrap wait --timeout 120 --interval 3
```

Generated files are stored under:
- `~/.local/share/appcorectl/pki/<target>/`

## Day-2 Examples

Info and state:

```bash
appcorectl info
appcorectl state
```

Services:

```bash
appcorectl services list
appcorectl services get sshd.service
appcorectl services restart sshd.service
```

Containers:

```bash
appcorectl containers list
appcorectl containers logs my-container --tail 200
```

Logs and network:

```bash
appcorectl logs journal --tail 200 --unit appcore-agent.service
appcorectl network interfaces
```

Host lifecycle:

```bash
appcorectl host update-status
appcorectl host update
appcorectl host reboot --yes
```

Shell completion:

```bash
appcorectl completion zsh
```

## Output Modes

Default output is table-formatted. For machine-readable output use JSON:

```bash
appcorectl info --output json
```

## Security Notes

- TLS certificate verification is enabled by default.
- `--insecure` is available for local development only and emits a warning.
- `target add` and bootstrap commands trust-pin the server certificate when possible.
- mTLS is supported through `--ca`, `--cert`, `--key` and target profile values.
- `bootstrap claim` auto-generates local client CA/cert/key if `--client-ca-file` is omitted.
- `bootstrap claim` waits for readiness by default; use `--wait=false` to skip.
- API key can be provided via profile, `APPCORECTL_API_KEY`, or `--api-key`.
- Secret values are redacted in profile listing output.

## Environment Variables

- `APPCORECTL_CONFIG`
- `APPCORECTL_TARGET`
- `APPCORECTL_URL`
- `APPCORECTL_CA`
- `APPCORECTL_CERT`
- `APPCORECTL_KEY`
- `APPCORECTL_API_KEY`
- `APPCORECTL_INSECURE`
- `APPCORECTL_OUTPUT`

## Exit Codes

- `0`: success
- `2`: validation error
- `3`: auth failure
- `4`: transport/TLS failure
- `5`: API/server failure

## Development

```bash
cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
# optional if cargo-audit is installed
cargo audit
./scripts/package.sh
```
