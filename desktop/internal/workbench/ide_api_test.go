package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
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
	if !strings.Contains(string(configuration), helper) {
		t.Fatalf("configuration does not name the helper: %s", configuration)
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
	failure, ok := (&App{}).ideAPIDispatch(context.Background(), conn, "lithe_run_start", nil).(map[string]any)
	if !ok || failure["error"] == nil {
		t.Fatalf("unwired tool = %#v", failure)
	}
}
