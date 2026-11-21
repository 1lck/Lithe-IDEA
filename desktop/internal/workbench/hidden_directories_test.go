package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// hiddenFoldersManifest is a fictional plugin whose build system, found by a fixture.build file,
// hides the folders named names in every workspace.
func hiddenFoldersManifest(t *testing.T, id, system string, names ...string) []byte {
	t.Helper()
	quoted, err := json.Marshal(names)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Appendf(nil, `{
  "schemaVersion": 0,
  "id": %q,
  "displayName": "Hidden Folders Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:%s"],
  "languages": [],
  "buildSystems": [{
    "id": %q,
    "displayName": "Fixture Build",
    "detection": {"markers": ["fixture.build"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "tasks": [{"id": "build", "displayName": "Build", "group": "build", "scopes": ["project"], "arguments": ["build"]}],
    "layout": {"hiddenDirectoryNames": %s}
  }]
}`, id, system, system, quoted)
}

// installHiddenFoldersPlugin installs and enables manifest as plugin id under pluginRoot.
func installHiddenFoldersPlugin(t *testing.T, preferences *store.Store, pluginRoot, id string, manifest []byte) {
	t.Helper()
	installed := filepath.Join(pluginRoot, id, "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
		t.Fatal(err)
	}
}

// makeFolders makes each folder under root.
func makeFolders(t *testing.T, root string, folders ...string) {
	t.Helper()
	for _, folder := range folders {
		if err := os.MkdirAll(filepath.Join(root, folder), 0o700); err != nil {
			t.Fatal(err)
		}
	}
}

// clearHiddenFolders lets every later test start with no hidden folder names, which Core and the
// file icons each keep for the whole process, also after a failed assertion.
func clearHiddenFolders(t *testing.T) {
	t.Cleanup(func() {
		if _, err := core.NewClient().ConfigureVisibility(context.Background(), nil); err != nil {
			t.Errorf("clearing the hidden folders: %v", err)
		}
		fileicons.SetHiddenDirectoryNames(nil)
		setRemoteWatchExcludes(nil)
	})
}

// settleTabsUntil settles every tab until condition holds, a step at a time, as settleUntil does
// for one.
func settleTabsUntil(h *harness, what string, condition func() bool) {
	h.t.Helper()
	for range 12 {
		h.settleTabs()
		if condition() {
			return
		}
	}
	h.t.Fatalf("%s did not happen", what)
}

// visibilityFailures counts the logged failures of workspace.configureVisibility.
func visibilityFailures(logger *treeRecordingLog) int {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	count := 0
	for _, event := range logger.events {
		if event.Event == backgroundFailedEvent && event.Fields["operation"] == "workspace_visibility" {
			count++
		}
	}
	return count
}

// An enabled plugin's build system hides the folders its layout names from a project tree
// listed before Core knew them, as the tree is at startup, and disabling the plugin shows them
// again. A plugin whose names Core rejects hides nothing and is logged, while the others still
// apply.
func TestPluginDeclaredFoldersLeaveTheProjectTree(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	const declaring = "dev.lithe.test.hidden-folders"
	installHiddenFoldersPlugin(t, preferences, pluginRoot, declaring, hiddenFoldersManifest(t, declaring, "fixture-hidden", "fixture-out"))
	const invalid = "dev.lithe.test.invalid-hidden-folder"
	installHiddenFoldersPlugin(t, preferences, pluginRoot, invalid, hiddenFoldersManifest(t, invalid, "fixture-invalid", "fixture/out"))
	root := t.TempDir()
	makeFolders(t, root, "fixture-out", "src")
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"en-US"},
	})
	clearHiddenFolders(t)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	// The harness does not run the window, so the plugins are read once the tree is listed.
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	h.settleUntil("the tree to list fixture-out", func() bool {
		return p.tree.root != nil && p.tree.root.listed && p.tree.find("fixture-out") != nil
	})

	h.app.reloadPluginLanguages()
	h.settleUntil("the declared folder to leave the tree", func() bool {
		return p.tree.find("src") != nil && p.tree.find("fixture-out") == nil
	})
	if got := visibilityFailures(logger); got != 1 {
		t.Fatalf("the rejected plugin was logged %d times, want once: %+v", got, logger.events)
	}

	if err := pluginstate.New(preferences).SetEnabled(declaring, false); err != nil {
		t.Fatal(err)
	}
	h.app.reloadPluginLanguages()
	h.settleUntil("the folder to come back once its plugin is disabled", func() bool {
		return p.tree.find("fixture-out") != nil
	})
}

// The tree lists its folders again when Core hides other folder names, not when the names are
// the same in another case, and a failed call keeps the names Core still has.
func TestHiddenFoldersListTheTreeAgainOnlyWhenTheyChange(t *testing.T) {
	k := &countedTreeFilterKernel{testKernel: &testKernel{Client: core.NewClient()}, filtered: make(chan struct{}, 1)}
	h := newHarness(t, k)
	clearHiddenFolders(t)
	root := t.TempDir()
	makeFolders(t, root, "src")
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && !p.tree.reading })
	h.settle()
	logger := &treeRecordingLog{}
	h.app.logSink = logger

	before := k.listings.Load()
	h.app.applyHiddenDirectories(hiddenDirectories{names: []string{"fixture-out"}, answered: true})
	h.settle()
	changed := k.listings.Load()
	if changed == before {
		t.Fatal("new hidden folder names did not list the tree again")
	}
	h.app.applyHiddenDirectories(hiddenDirectories{names: []string{"FIXTURE-OUT"}, answered: true})
	h.settle()
	if got := k.listings.Load(); got != changed {
		t.Fatalf("the same names in another case listed the tree again: %d to %d", changed, got)
	}

	h.app.applyHiddenDirectories(hiddenDirectories{err: errors.New("fixture visibility failure")})
	h.settle()
	if got := k.listings.Load(); got != changed {
		t.Fatalf("a failed call listed the tree again: %d to %d", changed, got)
	}
	if fileicons.SetHiddenDirectoryNames([]string{"fixture-out"}) {
		t.Fatal("a failed call changed the hidden folder names")
	}
	if got := visibilityFailures(logger); got != 1 {
		t.Fatalf("the failed call was logged %d times, want once: %+v", got, logger.events)
	}
}

// Core keeps one list for every tab, so the tab that hands it the new names lists the tree of
// every other open tab again too.
func TestHiddenFoldersLeaveTheTreeOfEveryOpenTab(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	clearHiddenFolders(t)
	makeFolders(t, alpha, "fixture-out")
	makeFolders(t, beta, "fixture-out")
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	second := h.app.sessions.active
	if second == h.app || second.project == nil {
		t.Fatal("beta did not open in a second tab")
	}
	trees := []*fileTree{&h.app.project.tree, &second.project.tree}
	shown := func(want bool) func() bool {
		return func() bool {
			for _, tree := range trees {
				if tree.root == nil || !tree.root.listed || (tree.find("fixture-out") != nil) != want {
					return false
				}
			}
			return true
		}
	}
	settleTabsUntil(h, "both trees to list fixture-out", shown(true))

	configuration, err := core.NewClient().ConfigureVisibility(context.Background(), []json.RawMessage{
		hiddenFoldersManifest(t, "dev.lithe.test.hidden-folders", "fixture-hidden", "fixture-out"),
	})
	if err != nil || len(configuration.Rejected) != 0 {
		t.Fatalf("configureVisibility = %+v, %v", configuration, err)
	}
	h.app.applyHiddenDirectories(hiddenDirectories{names: configuration.HiddenDirectoryNames, answered: true})
	settleTabsUntil(h, "both trees to hide fixture-out", shown(false))
}
