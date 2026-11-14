package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// ignoredPathsManifest is a declarative build system found wherever a fixture.build file is, with one
// option, so its instances open the Build options with an instance section.
const ignoredPathsManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.ignored-paths",
  "displayName": "Ignored Paths Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:fixture-ignored"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-ignored",
    "displayName": "Fixture Build",
    "detection": {"markers": ["fixture.build"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "options": [{"id": "release", "displayName": "Release Profile", "kind": "boolean", "arguments": ["--release"]}],
    "tasks": [{"id": "build", "displayName": "Build", "group": "build", "scopes": ["project"], "arguments": ["build"]}]
  }]
}`

// openIgnoredPathsProject installs the fixture build system, opens a project with a fixture.build file
// in its root, in .claude/copy and in tools, writes team as the team Build options document when it is not
// empty, and opens the Build tool window once detection has finished.
func openIgnoredPathsProject(t *testing.T, team string) (*harness, *project) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.ignored-paths", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(ignoredPathsManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.ignored-paths", true); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for _, folder := range []string{".", ".claude/copy", "tools"} {
		if err := os.MkdirAll(filepath.Join(root, folder), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, folder, "fixture.build"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if team != "" {
		if err := os.MkdirAll(filepath.Join(root, ".lithe", "build"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(buildTeamOptionsFile)), []byte(team), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"en-US"},
	})
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	h.app.reduceChrome(core.ToggleChrome(itemBuild))
	h.awaitBuildDetection(p)
	return h, p
}

// settleUntil settles the window until condition holds, a step at a time: each settle waits for the
// background work queued so far and paints its results, so a chain of steps ends within a few.
func (h *harness) settleUntil(what string, condition func() bool) {
	h.t.Helper()
	for range 12 {
		h.settle()
		if condition() {
			return
		}
	}
	h.t.Fatalf("%s did not happen", what)
}

// awaitBuildDetection waits until the Build tool window has detected the instances of p.
func (h *harness) awaitBuildDetection(p *project) {
	h.t.Helper()
	h.settleUntil("build detection", func() bool {
		return p.build.loaded && !p.build.loading && !p.build.reloadPending
	})
	if p.build.failed != "" {
		h.t.Fatalf("build detection failed: %s", p.build.failed)
	}
}

// buildRoots are the roots of the detected instances, sorted.
func buildRoots(p *project) []string {
	var roots []string
	for _, instance := range p.build.instances {
		roots = append(roots, instance.Root)
	}
	slices.Sort(roots)
	return roots
}

// storedIgnoredPaths is the ignored-path list Core picks from what the project stores now.
func (h *harness) storedIgnoredPaths(p *project) core.BuildIgnoredPaths {
	h.t.Helper()
	ctx := context.Background()
	docs, err := h.app.readBuildOptionDocuments(ctx, p.root)
	if err != nil {
		h.t.Fatal(err)
	}
	storage, err := core.NewClient().ResolveStoredBuildOptions(ctx, docs.team, docs.local)
	if err != nil {
		h.t.Fatal(err)
	}
	return storage.IgnoredPaths
}

// awaitIgnoredPathsLoaded waits until the open Build options dialog shows the ignored paths Core picked.
func (h *harness) awaitIgnoredPathsLoaded(p *project) {
	h.t.Helper()
	h.settleUntil("the ignored paths", func() bool {
		e := &p.build.options
		return e.open && e.ignored.loaded && !e.ignored.restoring
	})
}

// typeIgnoredPaths replaces the ignored-path field of the open dialog with text, typed into the field.
func (h *harness) typeIgnoredPaths(p *project, text string) {
	h.t.Helper()
	h.typeInto(h.shared("desktop.build.ignoredPaths"), func() {
		h.app.post(func(*App) { p.build.options.ignored.text = "" })
	}, text)
	if got := p.build.options.ignored.text; got != text {
		h.t.Fatalf("the ignored-path field holds %q, want %q", got, text)
	}
}

// Detection skips every dot-named folder until the project stores its own list. The Build window's header
// opens the Build options on the ignored paths alone; a list typed there is saved on this machine and the
// build systems are detected again with it, and Restore Default removes it.
func TestBuildOptionsIgnoredPathsAreSavedOnThisMachineAndRestored(t *testing.T) {
	h, p := openIgnoredPathsProject(t, "")
	if got := buildRoots(p); !slices.Equal(got, []string{".", "tools"}) {
		t.Fatalf("by default the build systems are at %q, want the dot-named folder skipped", got)
	}

	h.clickNamed(h.shared("desktop.build.optionsTitle"))
	h.awaitIgnoredPathsLoaded(p)
	e := &p.build.options
	if e.instance != "" || len(e.fields) != 0 {
		t.Fatalf("the header opened the options of instance %q with %d fields, want the ignored paths alone", e.instance, len(e.fields))
	}
	if e.ignored.text != ".*" || !h.showsWrapped(h.shared("desktop.build.ignoredPathsDefault")) {
		t.Fatalf("the field holds %q under %q, want the default", e.ignored.text, e.ignored.source)
	}
	if _, shown := h.findPageHit(h.shared("native.restoreDefault")); shown {
		t.Fatal("Restore Default is offered while the default applies")
	}

	h.typeIgnoredPaths(p, ".*\n!.claude\n\n/tools")
	h.clickNamed(h.shared("ui.save"))
	h.settleUntil("the dialog to close", func() bool { return !p.build.options.open })
	h.awaitBuildDetection(p)
	if got := buildRoots(p); !slices.Equal(got, []string{".", ".claude/copy"}) {
		t.Fatalf("after the edit the build systems are at %q", got)
	}
	if got := h.storedIgnoredPaths(p); !slices.Equal(got.Patterns, []string{".*", "!.claude", "/tools"}) || got.Source != core.BuildIgnoredPathsLocal {
		t.Fatalf("the project stores %+v, want the typed list on this machine", got)
	}

	h.clickNamed(h.shared("desktop.build.optionsTitle"))
	h.awaitIgnoredPathsLoaded(p)
	if !h.showsWrapped(h.shared("desktop.build.ignoredPathsLocal")) {
		t.Fatal("the dialog does not say the list is the one saved on this machine")
	}
	h.clickNamed(h.shared("native.restoreDefault"))
	h.awaitIgnoredPathsLoaded(p)
	if e := &p.build.options; e.ignored.text != ".*" || !e.ignored.inherit {
		t.Fatalf("Restore Default shows %q (inherit %v), want the default list", e.ignored.text, e.ignored.inherit)
	}
	if got := h.storedIgnoredPaths(p); got.Source != core.BuildIgnoredPathsLocal {
		t.Fatalf("Restore Default stored %+v before Save", got)
	}
	h.clickNamed(h.shared("ui.save"))
	h.settleUntil("the dialog to close", func() bool { return !p.build.options.open })
	h.awaitBuildDetection(p)
	if got := buildRoots(p); !slices.Equal(got, []string{".", "tools"}) {
		t.Fatalf("after Restore Default the build systems are at %q", got)
	}
	if got := h.storedIgnoredPaths(p); got.Source != core.BuildIgnoredPathsDefault {
		t.Fatalf("after Restore Default the project stores %+v, want no list", got)
	}
}

// A build system's options open with the ignored paths above them, here the team file's list. A pattern
// Core refuses keeps the dialog open, names its line in the field and stores nothing.
func TestBuildOptionsNameTheLineOfARefusedIgnoredPath(t *testing.T) {
	h, p := openIgnoredPathsProject(t, `{"version":1,"systems":{},"ignoredPaths":["/tools"]}`)
	if got := buildRoots(p); !slices.Equal(got, []string{".", ".claude/copy"}) {
		t.Fatalf("with the team's list the build systems are at %q", got)
	}

	h.clickNamed(h.shared("desktop.build.options"))
	h.awaitIgnoredPathsLoaded(p)
	e := &p.build.options
	if selected := p.selectedBuildInstance(); selected == nil || e.instance != selected.ID || len(e.fields) != 1 || e.name != "Fixture Build" {
		t.Fatalf("the group's options opened instance %q named %q with %d fields", e.instance, e.name, len(e.fields))
	}
	team := i18n.SharedFormat(h.app.language(), "desktop.build.ignoredPathsTeam", map[string]string{"file": buildTeamOptionsFile})
	if e.ignored.text != "/tools" || !h.showsWrapped(team) {
		t.Fatalf("the field holds %q under %q, want the team's list", e.ignored.text, e.ignored.source)
	}

	h.typeIgnoredPaths(p, "/tools\n\n# note")
	h.clickNamed(h.shared("ui.save"))
	h.settleUntil("the refusal", func() bool { return !p.build.options.saving })
	want := i18n.SharedFormat(h.app.language(), "desktop.build.invalidIgnoredPath", map[string]string{"line": "3"})
	if e := &p.build.options; !e.open || e.failure != want || !h.showsWrapped(want) {
		t.Fatalf("the refused list left the dialog open %v with %q, want %q", e.open, e.failure, want)
	}
	if got := h.storedIgnoredPaths(p); got.Source != core.BuildIgnoredPathsTeam {
		t.Fatalf("the refused list stored %+v", got)
	}
}
