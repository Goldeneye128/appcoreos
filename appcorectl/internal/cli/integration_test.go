package cli

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/appcoreos/appcorectl/internal/config"
	"github.com/appcoreos/appcorectl/internal/security"
)

func executeWithOutput(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	cmd := NewRootCommand()
	cmd.SetArgs(args)
	cmd.SetOut(stdout)
	cmd.SetErr(stderr)
	err := cmd.Execute()
	return stdout.String(), stderr.String(), err
}

func TestBootstrapStatusAndClaimIntegration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	var claimCalled bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/bootstrap/status":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"claimed":false,"token_required":true}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/bootstrap/claim":
			if r.Header.Get("X-Bootstrap-Token") != "abc123" {
				t.Fatalf("bootstrap token header mismatch")
			}
			claimCalled = true
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add failed: %v", err)
	}

	stdout, _, err := executeWithOutput(t, "--config", cfgPath, "--output", "json", "bootstrap", "status")
	if err != nil {
		t.Fatalf("bootstrap status failed: %v", err)
	}
	if !strings.Contains(stdout, `"claimed": false`) {
		t.Fatalf("unexpected bootstrap status output: %s", stdout)
	}

	caFile := filepath.Join(home, "client-ca.pem")
	if err := os.WriteFile(caFile, []byte("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"), 0o600); err != nil {
		t.Fatalf("write client CA file: %v", err)
	}
	if _, _, err := executeWithOutput(t, "--config", cfgPath, "bootstrap", "claim", "--token", "abc123", "--client-ca-file", caFile, "--wait=false"); err != nil {
		t.Fatalf("bootstrap claim failed: %v", err)
	}
	if !claimCalled {
		t.Fatal("expected claim endpoint to be called")
	}
}

func TestBootstrapClaimAutoGeneratesClientPKI(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	var claimBody string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/v1/bootstrap/claim" {
			body, err := io.ReadAll(r.Body)
			if err != nil {
				t.Fatalf("read request body: %v", err)
			}
			claimBody = string(body)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add failed: %v", err)
	}

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "bootstrap", "claim", "--token", "abc123", "--wait=false"); err != nil {
		t.Fatalf("bootstrap claim with generated PKI failed: %v", err)
	}
	if !strings.Contains(claimBody, "BEGIN CERTIFICATE") {
		t.Fatalf("expected generated client CA in request body, got: %s", claimBody)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	profile, ok := cfg.Targets["lab"]
	if !ok {
		t.Fatalf("target profile missing after claim")
	}
	if profile.CertPath == "" || profile.KeyPath == "" {
		t.Fatalf("expected generated client cert/key paths in target profile, got cert=%q key=%q", profile.CertPath, profile.KeyPath)
	}
	for _, p := range []string{profile.CertPath, profile.KeyPath} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("expected generated file %s: %v", p, err)
		}
	}
}

func TestLogsJournalPlainTextIntegration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/v1/logs/journal" {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = w.Write([]byte("line one\nline two\n"))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add failed: %v", err)
	}

	stdout, _, err := executeWithOutput(t, "--config", cfgPath, "logs", "journal", "--tail", "10")
	if err != nil {
		t.Fatalf("logs journal failed: %v", err)
	}
	if !strings.Contains(stdout, "line one") || !strings.Contains(stdout, "line two") {
		t.Fatalf("unexpected logs output: %s", stdout)
	}
}

func TestTargetRemoveWithAndWithoutPKIPurge(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add failed: %v", err)
	}
	pki, err := security.EnsureLocalClientPKI("lab")
	if err != nil {
		t.Fatalf("generate local PKI: %v", err)
	}
	if _, err := os.Stat(pki.TargetDir); err != nil {
		t.Fatalf("expected local PKI dir: %v", err)
	}

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "rm", "lab"); err != nil {
		t.Fatalf("target rm failed: %v", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if _, ok := cfg.Targets["lab"]; ok {
		t.Fatal("expected lab target to be removed")
	}
	if _, err := os.Stat(pki.TargetDir); err != nil {
		t.Fatalf("expected local PKI to remain without --purge-pki: %v", err)
	}

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add second time failed: %v", err)
	}
	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "rm", "lab", "--purge-pki"); err != nil {
		t.Fatalf("target rm with purge failed: %v", err)
	}
	if _, err := os.Stat(pki.TargetDir); !os.IsNotExist(err) {
		t.Fatalf("expected local PKI directory to be removed, err=%v", err)
	}
}

func TestAuthFailureExitCodeIntegration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--insecure"); err != nil {
		t.Fatalf("target add failed: %v", err)
	}

	_, _, err := executeWithOutput(t, "--config", cfgPath, "info")
	if err == nil {
		t.Fatal("expected auth failure")
	}
	if got := mapError(err).code; got != ExitCodeAuth {
		t.Fatalf("exit code = %d, want %d", got, ExitCodeAuth)
	}
}

func TestMTLSRequiredPathIntegration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	caCertPEM, caCert, caKey := makeCA(t)
	serverCertPEM, serverKeyPEM := makeLeafCert(t, caCert, caKey, false)
	clientCertPEM, clientKeyPEM := makeLeafCert(t, caCert, caKey, true)

	serverPair, err := tls.X509KeyPair(serverCertPEM, serverKeyPEM)
	if err != nil {
		t.Fatalf("load server key pair: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caCertPEM) {
		t.Fatal("append CA cert failed")
	}

	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"ok":true}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{serverPair},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
		MinVersion:   tls.VersionTLS12,
	}
	server.StartTLS()
	defer server.Close()

	caPath := filepath.Join(home, "ca.pem")
	clientCertPath := filepath.Join(home, "client.pem")
	clientKeyPath := filepath.Join(home, "client.key")
	if err := os.WriteFile(caPath, caCertPEM, 0o600); err != nil {
		t.Fatalf("write ca: %v", err)
	}
	if err := os.WriteFile(clientCertPath, clientCertPEM, 0o600); err != nil {
		t.Fatalf("write client cert: %v", err)
	}
	if err := os.WriteFile(clientKeyPath, clientKeyPEM, 0o600); err != nil {
		t.Fatalf("write client key: %v", err)
	}

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--ca", caPath); err != nil {
		t.Fatalf("target add failed: %v", err)
	}

	_, _, err = executeWithOutput(t, "--config", cfgPath, "info")
	if err == nil {
		t.Fatal("expected mTLS failure without client cert")
	}
	if got := mapError(err).code; got != ExitCodeTransport {
		t.Fatalf("exit code = %d, want %d", got, ExitCodeTransport)
	}

	if _, _, err := executeWithOutput(t, "--config", cfgPath, "target", "add", "lab", "--url", server.URL, "--ca", caPath, "--cert", clientCertPath, "--key", clientKeyPath); err != nil {
		t.Fatalf("target add with mTLS failed: %v", err)
	}
	stdout, _, err := executeWithOutput(t, "--config", cfgPath, "--output", "json", "info")
	if err != nil {
		t.Fatalf("info with mTLS failed: %v", err)
	}
	if !strings.Contains(stdout, `"ok": true`) {
		t.Fatalf("unexpected info output: %s", stdout)
	}
}

func makeCA(t *testing.T) ([]byte, *x509.Certificate, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "appcorectl-test-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA cert: %v", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return pemBytes, cert, key
}

func makeLeafCert(t *testing.T, caCert *x509.Certificate, caKey *rsa.PrivateKey, client bool) ([]byte, []byte) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		t.Fatalf("serial: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "appcorectl-test-leaf"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
	}
	if client {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	} else {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		tmpl.DNSNames = []string{"localhost"}
		tmpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf cert: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	return certPEM, keyPEM
}
