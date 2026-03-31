package client

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGetJSONInjectsAuthorizationHeader(t *testing.T) {
	t.Parallel()

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("Authorization header = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	c, err := New(Options{BaseURL: server.URL, APIKey: "test-key", Insecure: true})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	var out map[string]any
	if err := c.GetJSON(context.Background(), "/v1/info", nil, nil, &out); err != nil {
		t.Fatalf("GetJSON() error = %v", err)
	}
	if out["ok"] != true {
		t.Fatalf("expected ok=true, got %#v", out)
	}
}
