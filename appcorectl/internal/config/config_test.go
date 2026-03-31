package config

import (
	"path/filepath"
	"testing"
)

func TestLoadMissingFileReturnsDefaults(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "missing.yaml")
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Output != "table" {
		t.Fatalf("expected default output table, got %q", cfg.Output)
	}
	if len(cfg.Targets) != 0 {
		t.Fatalf("expected no targets, got %d", len(cfg.Targets))
	}
}

func TestMergeTargetWithEnvAndFlags(t *testing.T) {
	t.Setenv("APPCORECTL_API_KEY", "env-key")
	t.Setenv("APPCORECTL_CA", "/env/ca.pem")

	base := TargetProfile{URL: "https://node:9090", APIKey: "cfg-key", CAPath: "/cfg/ca.pem"}
	flags := TargetProfile{APIKey: "flag-key", CertPath: "/flag/cert.pem", KeyPath: "/flag/key.pem"}

	merged, err := MergeTarget(base, flags)
	if err != nil {
		t.Fatalf("MergeTarget() error = %v", err)
	}
	if merged.APIKey != "flag-key" {
		t.Fatalf("expected flag API key precedence, got %q", merged.APIKey)
	}
	if merged.CAPath != "/env/ca.pem" {
		t.Fatalf("expected env CA precedence, got %q", merged.CAPath)
	}
	if merged.CertPath != "/flag/cert.pem" || merged.KeyPath != "/flag/key.pem" {
		t.Fatalf("expected mTLS flag paths, got cert=%q key=%q", merged.CertPath, merged.KeyPath)
	}
}

func TestMergeTargetRejectsHalfMTLS(t *testing.T) {
	_, err := MergeTarget(TargetProfile{}, TargetProfile{CertPath: "/tmp/client.crt"})
	if err == nil {
		t.Fatal("expected error when cert provided without key")
	}
}
