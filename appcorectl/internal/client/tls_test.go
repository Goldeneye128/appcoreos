package client

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBuildTLSConfigRejectsHalfMTLS(t *testing.T) {
	_, err := buildTLSConfig(Options{CertPath: "/tmp/client.crt"})
	if err == nil {
		t.Fatal("expected error when cert provided without key")
	}
}

func TestBuildTLSConfigRejectsInvalidCA(t *testing.T) {
	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, []byte("not-pem"), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	_, err := buildTLSConfig(Options{CAPath: caFile})
	if err == nil {
		t.Fatal("expected CA parse error")
	}
}
