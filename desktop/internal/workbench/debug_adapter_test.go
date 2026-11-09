package workbench

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestDebugAdapterRunner is the fixture DAP adapter. The host starts the
// copied test binary with the manifest's -test.run argument and the fixture
// workspace as its working directory. It only speaks DAP; Core owns every
// protocol decision.
func TestDebugAdapterRunner(t *testing.T) {
	if _, err := os.Stat("debug.marker"); err != nil {
		t.Skip("not the debug adapter fixture workspace")
	}
	if mode, _ := os.ReadFile("debug.marker"); string(mode) == "exit" {
		os.Exit(0)
	}
	workspace, err := os.Getwd()
	if err != nil {
		os.Exit(2)
	}
	source := filepath.Join(workspace, "tests", "debug_source.go")
	reader := bufio.NewReader(os.Stdin)
	seq := 1
	write := func(value map[string]any) {
		value["seq"] = seq
		seq++
		body, err := json.Marshal(value)
		if err != nil {
			os.Exit(2)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(3)
		}
	}
	event := func(name string, body any) {
		write(map[string]any{"type": "event", "event": name, "body": body})
	}
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(4)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(5)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(6)
		}
		var request struct {
			Seq     int             `json:"seq"`
			Type    string          `json:"type"`
			Command string          `json:"command"`
			Body    json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			os.Exit(7)
		}
		if request.Type != "request" {
			continue
		}
		respond := func(result any) {
			write(map[string]any{"type": "response", "request_seq": request.Seq, "success": true, "command": request.Command, "body": result})
		}
		switch request.Command {
		case "initialize":
			respond(map[string]any{"supportsConfigurationDoneRequest": true})
			event("initialized", map[string]any{})
		case "launch", "configurationDone", "disconnect", "terminate":
			respond(map[string]any{})
			if request.Command == "launch" {
				event("stopped", map[string]any{"reason": "breakpoint", "threadId": 7})
			}
			if request.Command == "disconnect" {
				os.Exit(0)
			}
		case "setBreakpoints":
			respond(map[string]any{"breakpoints": []any{map[string]any{"verified": true, "line": 3}}})
		case "stackTrace":
			respond(map[string]any{"stackFrames": []any{
				map[string]any{"id": 1, "name": "main", "line": 3, "column": 1, "source": map[string]any{"path": source}},
				map[string]any{"id": 2, "name": "worker", "line": 8, "column": 2, "source": map[string]any{"path": source}},
			}})
		case "threads":
			respond(map[string]any{"threads": []any{map[string]any{"id": 7, "name": "main"}}})
		case "continue":
			respond(map[string]any{"allThreadsContinued": true})
			event("continued", map[string]any{"threadId": 7, "allThreadsContinued": true})
		case "pause":
			respond(map[string]any{})
			event("stopped", map[string]any{"reason": "pause", "threadId": 7})
		default:
			respond(map[string]any{})
		}
	}
}
