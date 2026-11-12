package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

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
