# appcorectl

`appcorectl` is the official operator CLI for AppCoreOS lifecycle management.

- Day-0 bootstrap claim flow
- Day-1 secure API access (API key + mTLS)
- Day-2 host, service, container, network, and log operations

## Install

Prerequisites:
- Go 1.24+

Build from source:

```bash
go build -o bin/appcorectl ./cmd/appcorectl
```

Install to your Go bin path:

```bash
go install ./cmd/appcorectl
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
- mTLS is supported through `--ca`, `--cert`, `--key` and target profile values.
- `bootstrap claim` auto-generates local client CA/cert/key if `--client-ca-file` is omitted.
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
make test
make lint
make vuln
```
