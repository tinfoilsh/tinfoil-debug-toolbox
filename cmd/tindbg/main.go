package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	defaultSocket = "/run/tinfoil/containers.sock"
	defaultConfig = "/run/root/tinfoil-config.debug.yml"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	command := os.Args[1]
	args := os.Args[2:]
	var err error
	switch command {
	case "template":
		err = template(args)
	case "boot":
		err = configRequest("/v1/boot", args)
	case "status":
		err = request(http.MethodGet, "/v1/status", "", os.Stdout)
	case "ps":
		err = docker(append([]string{"ps"}, args...))
	case "inspect":
		err = docker(append([]string{"inspect"}, args...))
	case "logs":
		err = docker(append([]string{"logs"}, args...))
	case "exec":
		err = docker(append([]string{"exec"}, args...))
	case "run":
		err = docker(append([]string{"run"}, args...))
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "tindbg: %v\n", err)
		os.Exit(1)
	}
}

func template(args []string) error {
	configPath := defaultConfig
	if len(args) > 1 {
		return fmt.Errorf("usage: tindbg template [config-file]")
	}
	if len(args) == 1 {
		configPath = args[0]
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(configPath), ".tinfoil-config-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := request(http.MethodGet, "/v1/template", "", temporary); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, configPath); err != nil {
		return err
	}
	fmt.Println(configPath)
	return nil
}

func configRequest(path string, args []string) error {
	configPath := defaultConfig
	if len(args) > 1 {
		return fmt.Errorf("usage: tindbg %s [config-file]", filepath.Base(path))
	}
	if len(args) == 1 {
		configPath = args[0]
	}
	return request(http.MethodPost, path, configPath, os.Stdout)
}

func request(method, path, bodyPath string, output io.Writer) error {
	var body io.Reader
	if bodyPath != "" {
		file, err := os.Open(bodyPath)
		if err != nil {
			return err
		}
		defer file.Close()
		body = file
	}
	socket := os.Getenv("TINFOIL_CONTAINERS_SOCKET")
	if socket == "" {
		socket = defaultSocket
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	client := &http.Client{Transport: transport}
	req, err := http.NewRequest(method, "http://unix"+path, body)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/yaml")
	}
	response, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("connecting to %s: %w", socket, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		return fmt.Errorf("%s: %s", response.Status, data)
	}
	_, err = io.Copy(output, response.Body)
	return err
}

func docker(args []string) error {
	command := exec.Command("docker", args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage: tindbg COMMAND [ARGS]

Runtime configuration:
  template [config-file]      restore the verified config as an editable file
  boot [config-file]          replace and start the debug runtime
  status                      show manager state

Reset to the verified boot config with: tindbg template && tindbg boot

Container debugging:
  ps [docker-ps-args]
  inspect CONTAINER
  logs [docker-logs-args] CONTAINER
  exec [docker-exec-args] CONTAINER COMMAND...
  run [docker-run-args] IMAGE COMMAND...`)
}
