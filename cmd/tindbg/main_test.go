package main

import (
	"context"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

func TestRequestUsesManagerUnixSocket(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "containers.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/status" {
			t.Fatalf("request = %s %s, want GET /v1/status", r.Method, r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"initialized":true}`))
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Shutdown(context.Background()) })
	t.Setenv("TINFOIL_CONTAINERS_SOCKET", socket)

	var output strings.Builder
	if err := request(http.MethodGet, "/v1/status", "", &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != `{"initialized":true}` {
		t.Fatalf("output = %q", output.String())
	}
}

func TestRequestReturnsManagerError(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "containers.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid config"}`, http.StatusBadRequest)
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Shutdown(context.Background()) })
	t.Setenv("TINFOIL_CONTAINERS_SOCKET", socket)

	err = request(http.MethodPost, "/v1/config/check", "", &strings.Builder{})
	if err == nil || !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "invalid config") {
		t.Fatalf("request() error = %v", err)
	}
}
