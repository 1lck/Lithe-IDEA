package workbench

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"testing/synctest"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/winpath"
)

// newIDEAPIApp makes an App whose Core is the real kernel, with its store in a
// temporary directory, and a project whose root and helper exist on disk.
func newIDEAPIApp(t *testing.T) (*App, *project, string) {
	t.Helper()
	dir := t.TempDir()
	helper := filepath.Join(dir, "lithe-mcp")
	if err := os.WriteFile(helper, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	root := filepath.Join(dir, "project")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	app := &App{kernel: &testKernel{Client: core.NewClient()}, store: store.At(filepath.Join(dir, "config"))}
	p := &project{root: root, name: "project", ctx: ctx, cancel: cancel}
	return app, p, helper
}

func TestIDEAPIEnableAndDisable(t *testing.T) {
	app, p, helper := newIDEAPIApp(t)
	configuration, err := app.ideAPIEnable(p, core.IDEPermissions{}, helper)
	if err != nil {
		t.Fatalf("enable: %v", err)
	}
	// The configuration names the helper with the path the environment carried, which on Windows
	// can be the 8.3 short form; compare parsed paths instead of searching the document text.
	var configured struct {
		Servers map[string]struct {
			Command string `json:"command"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(configuration, &configured); err != nil {
		t.Fatalf("configuration = %s: %v", configuration, err)
	}
	if command := configured.Servers["lithe"].Command; !winpath.Equal(command, helper) {
		t.Fatalf("configuration names %q, want the helper %q", command, helper)
	}
	if _, err := app.ideAPIEnable(p, core.IDEPermissions{}, helper); err == nil {
		t.Fatal("a second enable of the same project succeeded")
	}
	if _, err := os.Stat(app.ideAPIDirectory()); err != nil {
		t.Fatalf("connection directory was not created: %v", err)
	}
	app.ideAPIDisable(p)
	app.tasks.running.Wait()
	if p.ideAPI.conn != nil {
		t.Fatal("connection still set after disable")
	}
	if _, err := app.ideAPIEnable(p, core.IDEPermissions{}, helper); err != nil {
		t.Fatalf("enable after disable: %v", err)
	}
	app.ideAPIDisable(p)
	app.tasks.running.Wait()
}

func TestIDEAPIEnableRequiresHelper(t *testing.T) {
	app, p, _ := newIDEAPIApp(t)
	if _, err := app.ideAPIEnable(p, core.IDEPermissions{}, filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("enable with a missing helper succeeded")
	}
	if p.ideAPI.conn != nil {
		t.Fatal("failed enable left a connection")
	}
}

// TestIDEAPIPolledToolCall uses the stdio configuration a user copies from Settings.
// An actual reply exercises poll ownership in the pinned Core, which discovery alone misses.
func TestIDEAPIPolledToolCall(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p, _ := ideAPIProject(t, h)
	app := h.app
	helper, err := app.ideAPIHelperPath()
	if err != nil {
		t.Fatalf("locate the staged helper (run with desktop-go.sh): %v", err)
	}
	configuration, err := app.ideAPIEnable(p, core.IDEPermissions{}, helper)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { app.ideAPIDisable(p) })
	var config struct {
		Servers map[string]struct {
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(configuration, &config); err != nil {
		t.Fatal(err)
	}
	server := config.Servers["lithe"]
	// Killing the helper on the local deadline also unblocks any pipe read or write.
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, server.Command, server.Args...)
	cmd.WaitDelay = time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		cancel()
		_ = cmd.Wait()
	}()
	in, out := json.NewEncoder(stdin), json.NewDecoder(stdout)
	id := 0
	request := func(method string, params any) json.RawMessage {
		t.Helper()
		id++
		if err := in.Encode(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		var reply struct {
			ID     int
			Result json.RawMessage
			Error  json.RawMessage
		}
		decoded := make(chan error, 1)
		go func() { decoded <- out.Decode(&reply) }()
		if err := awaitValueWithin(t, h, 10*time.Second, decoded, method+" reply"); err != nil {
			t.Fatalf("%s reply: %v (session: %v)", method, err, ctx.Err())
		}
		if reply.ID != id || len(reply.Result) == 0 {
			t.Fatalf("%s: expected reply %d, got %d, error %s", method, id, reply.ID, reply.Error)
		}
		return reply.Result
	}
	request("initialize", map[string]any{
		"protocolVersion": "2025-11-25", "capabilities": map[string]any{},
		"clientInfo": map[string]string{"name": "workbench-test", "version": "1"},
	})
	if err := in.Encode(map[string]string{"jsonrpc": "2.0", "method": "notifications/initialized"}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		tool string
		args map[string]any
		code string
	}{
		{"lithe_project_inspect", map[string]any{}, ""},
		{"lithe_run_start", map[string]any{"configurationID": "fixture"}, "PERMISSION_DENIED"},
		{"lithe_build_configure", map[string]any{"instanceID": "i", "optionID": "o", "value": nil}, "PERMISSION_DENIED"},
		{"lithe_operation_output", map[string]any{}, "INVALID_ARGUMENTS"},
		{"unknown", map[string]any{}, "NOT_SUPPORTED"},
		{"lithe_operations_list", map[string]any{}, ""},
		{"lithe_project_inspect", map[string]any{}, ""},
	} {
		raw := request("tools/call", map[string]any{"name": tc.tool, "arguments": tc.args})
		var result struct {
			IsError           bool
			StructuredContent struct {
				WorkspaceKey string
				Operations   []json.RawMessage
				Error        core.IDEFailure
			}
		}
		if err := json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		if result.IsError != (tc.code != "") || result.StructuredContent.Error.Code != tc.code ||
			(tc.tool == "lithe_project_inspect" && !winpath.Equal(result.StructuredContent.WorkspaceKey, p.root)) ||
			(tc.tool == "lithe_operations_list" && (result.StructuredContent.Operations == nil || len(result.StructuredContent.Operations) != 0)) {
			t.Fatalf("%s returned %s", tc.tool, raw)
		}
	}
}

func TestIDEAPICancelledWindowAction(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		app := &App{project: &project{root: "project"}}
		ctx, cancel := context.WithTimeout(t.Context(), ideAPICallTimeout)
		defer cancel()
		// Hold the window queue until the dispatch deadline passes in virtual time.
		result := app.ideAPIOnProject(ctx, &ideAPIConnection{workspaceKey: "project"}, func(*project) any {
			t.Fatal("the window executed a cancelled action")
			return nil
		})
		if code := ideAPIFailureCode(result); code != "TIMEOUT" {
			t.Fatalf("cancelled dispatch returned %q", code)
		}
		app.drain()
	})
}

func TestIDEAPIDispatchReportsUnwiredTools(t *testing.T) {
	conn := &ideAPIConnection{workspaceKey: "/project", permissions: core.IDEPermissions{Execute: true}}
	inspect, ok := (&App{}).ideAPIDispatch(context.Background(), conn, "lithe_project_inspect", nil).(map[string]any)
	if !ok || inspect["workspaceKey"] != "/project" {
		t.Fatalf("inspect = %#v", inspect)
	}
	// The environment and Maven tools are not served by this client, like any unknown tool.
	for _, tool := range []string{"lithe_environment_inspect", "lithe_no_such_tool"} {
		if code := ideAPIFailureCode((&App{}).ideAPIDispatch(context.Background(), conn, tool, nil)); code != "NOT_SUPPORTED" {
			t.Fatalf("%s answered %q, want NOT_SUPPORTED", tool, code)
		}
	}
	if code := ideAPIFailureCode((&App{}).ideAPIDispatch(context.Background(), conn, "lithe_run_start", nil)); code != "INVALID_ARGUMENTS" {
		t.Fatalf("a start without a configuration answered %q, want INVALID_ARGUMENTS", code)
	}
}
