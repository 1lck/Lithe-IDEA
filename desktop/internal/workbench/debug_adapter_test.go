package workbench

import (
	"bufio"
	"encoding/base64"
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
	os.Exit(serveFixtureAdapter(os.Stdin, os.Stdout, workspace))
}

// serveFixtureAdapter speaks the fixture DAP over any byte stream, so the same
// adapter answers over a process's stdio and over a TCP connection. It returns
// the exit code the stdio runner reports, and 0 when the peer disconnects.
func serveFixtureAdapter(input io.Reader, output io.Writer, workspace string) int {
	source := filepath.Join(workspace, "tests", "debug_source.go")
	reader := bufio.NewReader(input)
	seq := 1
	write := func(value map[string]any) {
		value["seq"] = seq
		seq++
		body, err := json.Marshal(value)
		if err != nil {
			panic(err)
		}
		if _, err := fmt.Fprintf(output, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			// The peer is gone; the read below ends the loop.
			return
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
				return 0
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					return 4
				}
			}
		}
		if length < 0 || length > 1<<20 {
			return 5
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			return 6
		}
		var request struct {
			Seq     int             `json:"seq"`
			Type    string          `json:"type"`
			Command string          `json:"command"`
			Body    json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return 7
		}
		if request.Type != "request" {
			continue
		}
		respond := func(result any) {
			write(map[string]any{"type": "response", "request_seq": request.Seq, "success": true, "command": request.Command, "body": result})
		}
		switch request.Command {
		case "initialize":
			respond(map[string]any{
				"supportsConfigurationDoneRequest":      true,
				"supportsSetVariable":                   true,
				"supportsDisassembleRequest":            true,
				"supportsSteppingGranularity":           true,
				"supportsReadMemoryRequest":             true,
				"supportsSingleThreadExecutionRequests": true,
				"supportsInstructionBreakpoints":        true,
				"exceptionBreakpointFilters": []any{
					map[string]any{"filter": "uncaught", "label": "Uncaught Exceptions", "default": true},
					map[string]any{"filter": "caught", "label": "Caught Exceptions", "default": false},
				},
			})
			event("initialized", map[string]any{})
		case "launch", "configurationDone", "disconnect", "terminate":
			respond(map[string]any{})
			if request.Command == "launch" {
				event("stopped", map[string]any{"reason": "breakpoint", "threadId": 7})
			}
			if request.Command == "disconnect" {
				return 0
			}
		case "setInstructionBreakpoints":
			var arguments struct {
				Breakpoints []any `json:"breakpoints"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			verified := make([]any, len(arguments.Breakpoints))
			for index := range verified {
				verified[index] = map[string]any{"verified": true}
			}
			respond(map[string]any{"breakpoints": verified})
		case "setBreakpoints":
			respond(map[string]any{"breakpoints": []any{map[string]any{"verified": true, "line": 3}}})
		case "stackTrace":
			respond(map[string]any{"stackFrames": []any{
				map[string]any{"id": 1, "name": "main", "line": 3, "column": 1, "source": map[string]any{"path": source}, "instructionPointerReference": "0x1000"},
				map[string]any{"id": 2, "name": "worker", "line": 8, "column": 2, "source": map[string]any{"path": source}},
			}})
		case "scopes":
			respond(map[string]any{"scopes": []any{
				map[string]any{"name": "Locals", "variablesReference": 100, "namedVariables": 3, "presentationHint": "locals"},
				map[string]any{"name": "Globals", "variablesReference": 101, "expensive": true},
			}})
		case "variables":
			var arguments struct {
				Reference int    `json:"variablesReference"`
				Filter    string `json:"filter"`
				Start     int    `json:"start"`
				Count     int    `json:"count"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			switch arguments.Reference {
			case 100:
				respond(map[string]any{"variables": []any{
					map[string]any{"name": "count", "value": "1", "type": "int", "variablesReference": 0},
					map[string]any{"name": "items", "value": "List(250)", "type": "List", "variablesReference": 200, "indexedVariables": 250},
					map[string]any{"name": "label", "value": "\"x\"", "type": "string", "variablesReference": 0},
				}})
			case 200:
				variables := []any{}
				for index := arguments.Start; index < arguments.Start+arguments.Count && index < 250; index++ {
					variables = append(variables, map[string]any{"name": fmt.Sprintf("[%d]", index), "value": strconv.Itoa(index * 2), "variablesReference": 0})
				}
				respond(map[string]any{"variables": variables})
			default:
				respond(map[string]any{"variables": []any{}})
			}
		case "setVariable":
			var arguments struct {
				Name  string `json:"name"`
				Value string `json:"value"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			respond(map[string]any{"value": arguments.Value, "type": "int"})
		case "disassemble":
			var arguments struct {
				Offset int `json:"instructionOffset"`
				Count  int `json:"instructionCount"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			instructions := []any{}
			for index := 0; index < arguments.Count; index++ {
				instructions = append(instructions, map[string]any{
					"address":     fmt.Sprintf("0x%x", 0x1000+4*(arguments.Offset+index)),
					"instruction": "nop",
				})
			}
			respond(map[string]any{"instructions": instructions})
		case "setExceptionBreakpoints":
			respond(map[string]any{})
		case "threads":
			respond(map[string]any{"threads": []any{
				map[string]any{"id": 7, "name": "main"},
				map[string]any{"id": 8, "name": "worker"},
			}})
		case "readMemory":
			var arguments struct {
				Reference string `json:"memoryReference"`
				Offset    int64  `json:"offset"`
				Count     int    `json:"count"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			if arguments.Reference == "0x1000" && arguments.Offset == 0 {
				// The instruction pointer: four readable bytes, then two that are not.
				respond(map[string]any{
					"address":         "0x1000",
					"unreadableBytes": 2,
					"data":            base64.StdEncoding.EncodeToString([]byte{0x48, 0x8b, 0x05, 0x10}),
				})
				continue
			}
			// Any other numeric address reads as bytes that are the low byte of their address.
			start, err := strconv.ParseUint(strings.TrimPrefix(arguments.Reference, "0x"), 16, 64)
			if err != nil {
				write(map[string]any{"type": "response", "request_seq": request.Seq, "success": false,
					"command": request.Command, "message": "unknown memory reference"})
				continue
			}
			start = uint64(int64(start) + arguments.Offset)
			data := make([]byte, arguments.Count)
			for index := range data {
				data[index] = byte(start + uint64(index))
			}
			respond(map[string]any{
				"address": fmt.Sprintf("0x%x", start),
				"data":    base64.StdEncoding.EncodeToString(data),
			})
		case "next", "stepIn", "stepOut":
			var arguments struct {
				Granularity string `json:"granularity"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			if arguments.Granularity != "" && arguments.Granularity != "instruction" {
				// Only the adapter default and the disassembly view's instruction
				// granularity are expected.
				write(map[string]any{"type": "response", "request_seq": request.Seq, "success": false,
					"command": request.Command, "message": "unexpected stepping granularity"})
				continue
			}
			respond(map[string]any{})
			if arguments.Granularity == "instruction" {
				event("output", map[string]any{"category": "console", "output": "stepped instruction\n"})
			} else {
				event("output", map[string]any{"category": "console", "output": "stepped statement\n"})
			}
			event("stopped", map[string]any{"reason": "step", "threadId": 7})
		case "evaluate":
			var arguments struct {
				Expression string `json:"expression"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			if arguments.Expression == "missing" {
				write(map[string]any{"type": "response", "request_seq": request.Seq, "success": false,
					"command": request.Command, "message": "cannot evaluate"})
				continue
			}
			respond(map[string]any{"result": "42", "type": "int", "variablesReference": 0})
		case "continue", "pause":
			var arguments struct {
				ThreadID     int  `json:"threadId"`
				SingleThread bool `json:"singleThread"`
			}
			_ = json.Unmarshal(request.Body, &arguments)
			thread := 7
			if arguments.SingleThread {
				thread = arguments.ThreadID
			}
			if request.Command == "continue" {
				respond(map[string]any{"allThreadsContinued": !arguments.SingleThread})
				event("continued", map[string]any{"threadId": thread, "allThreadsContinued": !arguments.SingleThread})
			} else {
				respond(map[string]any{})
				event("stopped", map[string]any{"reason": "pause", "threadId": thread})
			}
		default:
			respond(map[string]any{})
		}
	}
}
