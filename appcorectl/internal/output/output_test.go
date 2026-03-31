package output

import (
	"bytes"
	"strings"
	"testing"
)

func TestPrintTableUnwrapsSingleCollectionKey(t *testing.T) {
	out := bytes.NewBuffer(nil)
	payload := map[string]any{
		"services": []map[string]any{
			{"name": "agent.service", "active": "active", "sub": "running"},
		},
	}

	if err := Print(out, "table", payload); err != nil {
		t.Fatalf("print table: %v", err)
	}

	got := out.String()
	if strings.Contains(got, "KEY\tVALUE") {
		t.Fatalf("expected unwrapped collection table, got map table: %s", got)
	}
	if !strings.Contains(got, "agent.service") {
		t.Fatalf("expected service row in output: %s", got)
	}
}

func TestPrintTableFormatsNestedValuesAsJSON(t *testing.T) {
	out := bytes.NewBuffer(nil)
	payload := map[string]any{
		"state": map[string]any{
			"status": "ok",
			"meta": map[string]any{
				"version": "v1",
			},
		},
	}

	if err := Print(out, "table", payload); err != nil {
		t.Fatalf("print table: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "{\"version\":\"v1\"}") {
		t.Fatalf("expected nested map to be rendered as JSON: %s", got)
	}
}
