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
		err = request(http.MethodGet, "/v1/config/template", "", os.Stdout)
	case "check":
		err = configRequest("/v1/config/check", args)
	case "apply":
		err = configRequest("/v1/config/apply", args)
	case "status":
		err = request(http.MethodGet, "/v1/status", "", os.Stdout)
	case "reset":
		err = request(http.MethodPost, "/v1/config/reset", "", os.Stdout)
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
  template                    print the current editable configuration
  check [config-file]         validate and plan a configuration
  apply [config-file]         apply a configuration
  status                      show manager state
  reset                       restore the boot-time configuration

Container debugging:
  ps [docker-ps-args]
  inspect CONTAINER
  logs [docker-logs-args] CONTAINER
  exec [docker-exec-args] CONTAINER COMMAND...
  run [docker-run-args] IMAGE COMMAND...`)
}
