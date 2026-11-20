package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestSettingsPublicationReachesMatchingWindowsAndKeepsProjectLayers(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	const id = "dev.example.settings"
	fixture.Manifest["settings"] = []any{map[string]any{"id": "flag", "type": "boolean", "title": "Flag", "default": true, "scope": "project", "effect": "reload"}}
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, id, "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	preference := func() *store.Store {
		t.Helper()
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		s := store.At(root)
		if err := pluginstate.New(s).SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
		return s
	}
	shared, other := preference(), preference()
	rootA, rootB := t.TempDir(), t.TempDir()
	makeWindow := func(s *store.Store, root string) *harness {
		t.Helper()
		kernel := &testKernel{Client: core.NewClient()}
		h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, PluginRoot: pluginRoot, Store: s, Languages: []string{"en"}})
		h.open(root)
		h.app.project.build = buildState{selected: -1, instances: []buildInstance{{PluginID: id, modelLoaded: true}}}
		return h
	}
	windows := []*harness{makeWindow(shared, rootA), makeWindow(shared, rootA), makeWindow(shared, rootB), makeWindow(other, rootA)}
	// B owns an override. A's global save may invalidate B's model, but the
	// model's next native read must still use B's own value.
	if err := os.MkdirAll(filepath.Join(rootB, ".lithe"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rootB, ".lithe", "plugin-settings.json"), []byte(`{"dev.example.settings":{"flag":true}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	source := pluginSettingsSources{app: windows[0].app}
	editor, err := source.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	// Display data cannot redirect a committed change to a different plugin/version.
	editor.Snapshot.State.PluginID = "forged.plugin"
	editor.Snapshot.State.Metadata.Version = "9.9.9"
	result, err := source.Save(ctx, editor, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("false")}})
	if err != nil || !result.Committed {
		t.Fatalf("global publication=%+v %v", result, err)
	}
	for index, h := range windows {
		h.app.drain()
		if got := h.app.project.build.instances[0].modelLoaded; got != (index == 3) {
			t.Errorf("global window %d loaded=%v", index, got)
		}
	}
	b, err := windows[2].app.plugins.LoadSettingsEditor(ctx, id, rootB, "")
	if err != nil {
		t.Fatal(err)
	}
	if string(b.Snapshot.State.Rows[0].Effective.Value) != "true" || b.Snapshot.State.Rows[0].Effective.Source != "project" {
		t.Fatalf("global delivery leaked A's layer: %+v", b.Snapshot.State.Rows)
	}
	for _, h := range windows {
		h.app.project.build.instances[0].modelLoaded = true
	}
	editor, err = source.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	result, err = source.Save(ctx, editor, "project", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("true")}})
	if err != nil || !result.Committed {
		t.Fatalf("project publication=%+v %v", result, err)
	}
	for index, h := range windows {
		h.app.drain()
		if got := h.app.project.build.instances[0].modelLoaded; got != (index >= 2) {
			t.Errorf("project window %d loaded=%v", index, got)
		}
	}
	// Closing a subscribed window releases queue ownership before any late save.
	closed := windows[1].app
	closed.unsubscribeSettings()
	if err := windows[0].app.publishSettings(editor, "global", []string{"reload"}); err != nil {
		t.Fatal(err)
	}
	if len(closed.settingsSubscription.notices) != 0 {
		t.Fatal("closed window received a late publication")
	}
	// Reopening the same pathname is a new project lifetime, even with the same inode.
	target := windows[2].app
	target.project.build.instances[0].modelLoaded = true
	replacement := rootB
	target.toolchainRoot.Store(&replacement)
	target.drain()
	if !target.project.build.instances[0].modelLoaded {
		t.Fatal("queued publication reached a replacement project lifetime")
	}
}
