package cli

import (
	"bytes"
	"path/filepath"
	"testing"
)

func execute(t *testing.T, args ...string) error {
	t.Helper()
	cmd := NewRootCommand()
	cmd.SetArgs(args)
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	return cmd.Execute()
}

func TestHostRebootRequiresYes(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgPath := filepath.Join(home, ".config", "appcorectl", "config.yaml")

	if err := execute(t, "--config", cfgPath, "target", "add", "lab", "--url", "https://host:9090", "--insecure"); err != nil {
		t.Fatalf("setup target add failed: %v", err)
	}
	err := execute(t, "--config", cfgPath, "host", "reboot")
	if err == nil {
		t.Fatal("expected validation error")
	}
	if got := mapError(err).code; got != ExitCodeValidate {
		t.Fatalf("exit code = %d, want %d", got, ExitCodeValidate)
	}
}

func TestTargetAddRequiresURL(t *testing.T) {
	err := execute(t, "target", "add", "lab")
	if err == nil {
		t.Fatal("expected validation error")
	}
	if got := mapError(err).code; got != ExitCodeValidate {
		t.Fatalf("exit code = %d, want %d", got, ExitCodeValidate)
	}
}

func TestTargetRemoveRequiresName(t *testing.T) {
	err := execute(t, "target", "rm")
	if err == nil {
		t.Fatal("expected validation error")
	}
	if got := mapError(err).code; got != ExitCodeValidate {
		t.Fatalf("exit code = %d, want %d", got, ExitCodeValidate)
	}
}
