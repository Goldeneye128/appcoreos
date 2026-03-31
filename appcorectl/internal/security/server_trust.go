package security

import (
	"crypto/tls"
	"encoding/pem"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// PinServerCertificate fetches the current server certificate over TLS and saves
// it as a local trust anchor for this target. This is a TOFU helper for day-0.
func PinServerCertificate(targetName, rawURL string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return "", fmt.Errorf("parse target URL: %w", err)
	}
	if parsed.Scheme != "https" {
		return "", fmt.Errorf("target URL must use https")
	}

	host := parsed.Hostname()
	if host == "" {
		return "", fmt.Errorf("target URL missing hostname")
	}
	port := parsed.Port()
	if port == "" {
		port = "443"
	}
	addr := net.JoinHostPort(host, port)

	dialer := &net.Dialer{Timeout: 8 * time.Second}
	conn, err := tls.DialWithDialer(
		dialer,
		"tcp",
		addr,
		&tls.Config{
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: true,
			ServerName:         host,
		},
	)
	if err != nil {
		return "", fmt.Errorf("tls connect to %s failed: %w", addr, err)
	}
	defer conn.Close()

	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return "", fmt.Errorf("no peer certificates received from %s", addr)
	}
	leaf := state.PeerCertificates[0]
	if err := leaf.VerifyHostname(host); err != nil {
		return "", fmt.Errorf("server certificate is not valid for %q: %w", host, err)
	}

	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})
	if len(pemBytes) == 0 {
		return "", fmt.Errorf("encode server certificate PEM failed")
	}

	targetDir, err := LocalPKITargetDir(targetName)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(targetDir, 0o700); err != nil {
		return "", fmt.Errorf("create target PKI directory: %w", err)
	}

	caPath := filepath.Join(targetDir, "server-ca.pem")
	if err := os.WriteFile(caPath, pemBytes, 0o600); err != nil {
		return "", fmt.Errorf("write pinned server certificate: %w", err)
	}
	return caPath, nil
}
