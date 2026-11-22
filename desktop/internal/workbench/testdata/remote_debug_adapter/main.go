// This fixture speaks DAP over stdin/stdout in the remote project directory.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func main() {
	if err := serve(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func serve() error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	source := filepath.Join(root, "source.txt")
	input := bufio.NewReader(os.Stdin)
	seq := 0
	write := func(message map[string]any) error {
		seq++
		message["seq"] = seq
		body, err := json.Marshal(message)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body)
		return err
	}
	breakpoint := false
	for {
		header, err := input.ReadString('\n')
		if err != nil {
			return err
		}
		var size int
		if _, err := fmt.Sscanf(header, "Content-Length: %d", &size); err != nil || size <= 0 || size > 1<<20 {
			return fmt.Errorf("invalid DAP frame header")
		}
		separator, err := input.ReadString('\n')
		if err != nil || strings.TrimSpace(separator) != "" {
			return fmt.Errorf("invalid DAP frame separator")
		}
		body := make([]byte, size)
		if _, err := io.ReadFull(input, body); err != nil {
			return err
		}
		var request struct {
			Seq       int
			Command   string
			Arguments struct {
				Source      struct{ Path string }
				Breakpoints []struct{ Line int }
			}
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return err
		}
		var result, event any
		eventName := ""
		switch request.Command {
		case "initialize":
			result = map[string]bool{"supportsConfigurationDoneRequest": true}
			eventName = "initialized"
		case "setBreakpoints":
			lines := request.Arguments.Breakpoints
			breakpoint = request.Arguments.Source.Path == source && len(lines) == 1 && lines[0].Line == 3
			result = map[string]any{"breakpoints": []any{map[string]any{"verified": breakpoint, "line": 3}}}
		case "configurationDone":
			if !breakpoint {
				return fmt.Errorf("the remote source breakpoint did not reach the adapter")
			}
			eventName = "stopped"
			event = map[string]any{"reason": "breakpoint", "threadId": 1, "allThreadsStopped": true}
		case "threads":
			result = map[string]any{"threads": []any{map[string]any{"id": 1, "name": "fixture"}}}
		case "stackTrace":
			result = map[string]any{"stackFrames": []any{map[string]any{
				"id": 1, "name": "fixture-" + runtime.GOOS, "source": map[string]string{"path": source}, "line": 3, "column": 1,
			}}}
		case "scopes":
			result = map[string]any{"scopes": []any{}}
		}
		if err := write(map[string]any{"type": "response", "request_seq": request.Seq, "success": true, "command": request.Command, "body": result}); err != nil {
			return err
		}
		if eventName != "" {
			if err := write(map[string]any{"type": "event", "event": eventName, "body": event}); err != nil {
				return err
			}
		}
		if request.Command == "disconnect" {
			return nil
		}
	}
}
