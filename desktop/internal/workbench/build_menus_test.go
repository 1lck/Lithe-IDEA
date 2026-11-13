package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The Build tool window's context menus run a target through the build system's run that
// applies to it, open a project's build file and run a task, as the earlier client's build
// tool window did.
func TestBuildRowMenusRunTargetsAndOpenTheBuildFile(t *testing.T) {
	root := t.TempDir()
	buildFile := filepath.Join(root, "app", "server", "engine.build")
	if err := os.MkdirAll(filepath.Dir(buildFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(buildFile, []byte("engine\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h := newHarness(t, gate)
	h.open(root)
	p := h.app.project
	// The build root is a directory of the workspace and the project's path is relative to it,
	// so the build file is found under both.
	instance := runConfigInstance("app")
	instance.Manifest = []byte(`{"buildSystems":[{"id":"engine","detection":{"markers":["engine.build"]}}]}`)
	h.app.post(func(a *App) {
		p.build.instances, p.build.loaded = []buildInstance{instance}, true
		a.reduceChrome(core.ToggleChrome(itemBuild))
	})
	// The choices list holds the projects, dependencies, targets and tasks; a tall window
	// shows every section.
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()

	// A target runs through each run that applies to it.
	h.rightClickAt(h.labelBounds("Main"))
	h.click(center(h.popupHit(h.app.text.Build.RunTarget("Run"))))
	awaitStateWithin(t, h, 10*time.Second, "the provider run request", func() bool { return len(gate.requests) == 1 })
	if request := <-gate.requests; request.Run != "application" || request.Target == nil || request.Target.Name != "Main" {
		t.Fatalf("run request = %+v", request)
	}
	if p.build.targetID != "main" {
		t.Fatalf("the menu ran target %q without choosing it", p.build.targetID)
	}
	// What it prints shows in the Run window's build console, beside the Build window.
	if !h.app.chrome.isOpen(h.app.chrome.index[itemRun]) || !h.app.chrome.isOpen(h.app.chrome.index[itemBuild]) || p.build.view != "" {
		t.Fatalf("after a run the Run window is open %v, the Build window %v, and the Run window shows %q",
			h.app.chrome.isOpen(h.app.chrome.index[itemRun]), h.app.chrome.isOpen(h.app.chrome.index[itemBuild]), p.build.view)
	}
	awaitStateWithin(t, h, 10*time.Second, "the refused run to end", func() bool { return p.build.operation == nil })

	// A project opens the build file its build system detects in its directory.
	h.settle()
	h.rightClickAt(h.labelBounds("server"))
	h.click(center(h.popupHit(i18n.SharedFormat(h.app.language(), "native.open", map[string]string{"arg1": "engine.build"}))))
	awaitStateWithin(t, h, 10*time.Second, "the build file", func() bool { return p.docs.byPath(buildFile) != nil })
}
