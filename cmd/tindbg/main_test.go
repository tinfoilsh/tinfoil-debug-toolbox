package main

import (
	"context"
	"net"
	"net/http"
	"os"
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
		if r.Method != http.MethodPost || r.URL.Path != "/v1/boot" {
			t.Fatalf("request = %s %s, want POST /v1/boot", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusNoContent)
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Shutdown(context.Background()) })
	t.Setenv("TINFOIL_CONTAINERS_SOCKET", socket)

	var output strings.Builder
	if err := request(http.MethodPost, "/v1/boot", "", &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "" {
		t.Fatalf("output = %q", output.String())
	}
}

func TestTemplateReadsPublicConfig(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "config.yml")
	destination := filepath.Join(directory, "debug.yml")
	if err := os.WriteFile(source, []byte("containers: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TINFOIL_PUBLIC_CONFIG", source)
	if err := template([]string{destination}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "containers: []\n" {
		t.Fatalf("template = %q", data)
	}
}

func TestStatusReadsPublicStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "container-status.json")
	if err := os.WriteFile(path, []byte(`{"containers":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TINFOIL_STATUS_PATH", path)
	var output strings.Builder
	if err := status(&output); err != nil {
		t.Fatal(err)
	}
	if output.String() != `{"containers":[]}` {
		t.Fatalf("status = %q", output.String())
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

	err = request(http.MethodPost, "/v1/boot", "", &strings.Builder{})
	if err == nil || !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "invalid config") {
		t.Fatalf("request() error = %v", err)
	}
}

func TestDockerAliasesExecuteDockerCLI(t *testing.T) {
	directory := t.TempDir()
	argumentsPath := filepath.Join(directory, "arguments")
	dockerPath := filepath.Join(directory, "docker")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$DOCKER_ARGUMENTS\"\n"
	if err := os.WriteFile(dockerPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DOCKER_ARGUMENTS", argumentsPath)

	if err := docker([]string{"exec", "-it", "workload", "sh"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(argumentsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "exec\n-it\nworkload\nsh\n" {
		t.Fatalf("docker arguments = %q", data)
	}
}
