package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	run := respond
	if len(os.Args) > 1 && os.Args[1] == "provider" {
		run = provide
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func respond() error {
	var port int
	if chosen := os.Getenv("LITHE_FIXTURE_SERVICE_PORT"); chosen != "" {
		value, err := strconv.Atoi(chosen)
		if err != nil {
			return err
		}
		port = value
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := listener.SetDeadline(time.Now().Add(45 * time.Second)); err != nil {
		return err
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	connection, err := listener.AcceptTCP()
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	challenge := make([]byte, len("lithe"))
	if _, err := io.ReadFull(connection, challenge); err != nil {
		return err
	}
	if string(challenge) != "lithe" {
		return fmt.Errorf("incorrect attach challenge %q", challenge)
	}
	if _, err := io.WriteString(connection, "linux"); err != nil {
		return err
	}
	if port == 0 {
		return nil
	}
	if err := connection.Close(); err != nil {
		return err
	}
	// The provider-owned process stays alive after DAP attaches so the test can stop it.
	extra, err := listener.AcceptTCP()
	if err != nil {
		return err
	}
	extra.Close()
	return fmt.Errorf("unexpected second attach")
}

func provide() error {
	input := bufio.NewReader(os.Stdin)
	for {
		var size int
		for {
			header, err := input.ReadString('\n')
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return err
			}
			if strings.TrimSpace(header) == "" {
				break
			}
			if key, value, ok := strings.Cut(header, ":"); ok && strings.EqualFold(key, "Content-Length") {
				size, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					return err
				}
			}
		}
		if size < 1 || size > 1<<20 {
			return fmt.Errorf("invalid provider frame size %d", size)
		}
		body := make([]byte, size)
		if _, err := io.ReadFull(input, body); err != nil {
			return err
		}
		var request struct {
			ID     json.RawMessage
			Method string
			Params struct {
				LaunchOptions struct {
					Debug struct {
						Target struct{ Port int }
					}
				}
			}
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return err
		}
		if request.Method == "exit" {
			return nil
		}
		if len(request.ID) == 0 {
			continue
		}
		var result any
		switch request.Method {
		case "initialize":
			result = map[string]any{"capabilities": map[string]any{
				"experimental": map[string]any{"litheBuild": map[string]int{"version": 0}},
			}}
		case "lithe/build/model":
			result = map[string]any{
				"format": "litheBuildModel", "version": 0,
				"projects": []any{map[string]string{"path": ".", "name": "fixture"}},
				"targets":  []any{map[string]any{"project": ".", "path": ".", "name": "app", "tags": []string{"app"}}},
			}
		case "lithe/build/prepareRun":
			port := request.Params.LaunchOptions.Debug.Target.Port
			if port <= 0 {
				return fmt.Errorf("the provider received no owned debug endpoint")
			}
			// The run contract takes a PATH command. The fixture lives in the
			// remote working directory and exec keeps it in the owned session.
			result = map[string]any{
				"executable": map[string]string{"kind": "command", "value": "sh"},
				"arguments":  []string{"-c", "exec ./debuggee"}, "workingDirectory": ".",
				"environment": map[string]string{"LITHE_FIXTURE_SERVICE_PORT": strconv.Itoa(port)},
			}
		case "shutdown":
		default:
			return fmt.Errorf("unexpected provider method %q", request.Method)
		}
		reply, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result})
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(reply), reply); err != nil {
			return err
		}
	}
}
