package security

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureLocalClientPKIGeneratesAndReuses(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	first, err := EnsureLocalClientPKI("lab")
	if err != nil {
		t.Fatalf("EnsureLocalClientPKI() first call error = %v", err)
	}
	if len(first.CACertPEM) == 0 {
		t.Fatal("expected generated CA PEM")
	}
	for _, p := range []string{first.CACertPath, first.CAKeyPath, first.ClientCertPath, first.ClientKeyPath} {
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatalf("missing generated file %s: %v", p, err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("file %s permissions = %o, want 600", p, fi.Mode().Perm())
		}
	}
	dirInfo, err := os.Stat(first.TargetDir)
	if err != nil {
		t.Fatalf("stat target dir: %v", err)
	}
	if dirInfo.Mode().Perm() != 0o700 {
		t.Fatalf("target dir permissions = %o, want 700", dirInfo.Mode().Perm())
	}

	second, err := EnsureLocalClientPKI("lab")
	if err != nil {
		t.Fatalf("EnsureLocalClientPKI() second call error = %v", err)
	}
	if first.CACertPath != second.CACertPath || first.ClientCertPath != second.ClientCertPath {
		t.Fatalf("expected stable paths across calls")
	}
	if string(first.CACertPEM) != string(second.CACertPEM) {
		t.Fatalf("expected stable CA PEM across calls")
	}
}

func TestEnsureLocalClientPKIRejectsPartialState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	targetDir := filepath.Join(home, ".local", "share", "appcorectl", "pki", "lab")
	if err := os.MkdirAll(targetDir, 0o700); err != nil {
		t.Fatalf("mkdir target dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(targetDir, "client-ca.pem"), []byte("pem"), 0o600); err != nil {
		t.Fatalf("write partial file: %v", err)
	}

	if _, err := EnsureLocalClientPKI("lab"); err == nil {
		t.Fatal("expected partial PKI state error")
	}
}
