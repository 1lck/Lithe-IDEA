package settingswindow

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

type nativeFormFixture struct {
	reads atomic.Int32
	settingsFormSource
	native  pluginsettings.SourceEditor
	saves   chan []core.SourceSettingsEdits
	failure error
}

func (s *nativeFormFixture) Action(context.Context, pluginservice.SettingsEditor, string, bool) (pluginservice.SettingsActionResult, error) {
	s.reads.Add(1)
	return pluginservice.SettingsActionResult{Plan: core.PluginSettingsActionPlan{Kind: "invoke", ActionID: "compiler", SourceEditor: true}, Sources: &s.native}, nil
}
func (s *nativeFormFixture) SaveSources(ctx context.Context, _ pluginservice.SettingsEditor, _ string, editor pluginsettings.SourceEditor, edits []core.SourceSettingsEdits) (pluginsettings.SourceEditor, error) {
	s.saves <- edits
	return editor, s.failure
}
func nativeFormSource(t *testing.T, adjust ...func(*core.SourceSettingsSnapshot)) *nativeFormFixture {
	t.Helper()
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/source-editor.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "child"), 0700); err != nil {
		t.Fatal(err)
	}
	contents := []byte(`{"target":"two"}`)
	if err := os.WriteFile(filepath.Join(root, "child/tool.json"), contents, 0600); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-sources.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Snapshot core.SourceSettingsSnapshot `json:"snapshot"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Snapshot.Sources[1].Revision = fmt.Sprintf("sha256:%x", sha256.Sum256(contents))
	for _, fn := range adjust {
		fn(&fixture.Snapshot)
	}
	raw, err := json.Marshal(fixture.Snapshot)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	state, err := core.NewClient().ReadSourceSettings(ctx, raw)
	if err != nil {
		t.Fatal(err)
	}
	native, err := pluginsettings.CaptureSources(ctx, root, state, nil)
	if err != nil {
		t.Fatal(err)
	}
	return &nativeFormFixture{settingsFormSource: settingsFormSource{store: pluginsettings.New(core.NewClient(), t.TempDir()), manifest: manifest, workspace: root}, native: native, saves: make(chan []core.SourceSettingsEdits, 2)}
}
func nativeFormWindow(t *testing.T, source *nativeFormFixture, language i18n.Language, theme string) *window {
	t.Helper()
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "dev.lithe.test.source-settings", Name: "Fictional Compiler", LatestVersion: "1.0.0"}}}}, nil
	}
	w := newWindow(NewController(Options{Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language }, SystemLanguage: language, SystemDark: func() bool { return theme == "dark" }, PluginSettings: source,
		SettingsNavigation: core.NewClient().SettingsNavigation,
		SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
			return core.NewClient().SettingsPages(ctx, []core.SettingsContribution{{Manifest: source.manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.lithe.test.source-settings", Version: "1.0.0"}, Enabled: true}})
		}, Marketplace: fetch, MarketplaceInstalled: fetch, PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} }, InstalledPlugins: func() []PluginFacts {
			return []PluginFacts{{ID: "dev.lithe.test.source-settings", Name: "Fictional Compiler", Version: "1.0.0", Settings: 1}}
		}}), Values{Theme: theme, Language: language.Code()})
	w.sess.page = pagePlugins
	w.installed.tab = installedSettings
	return w
}
func openNativeForm(t *testing.T, w *window, d *windowDriver) {
	t.Helper()
	d.until("source action", func() bool { return w.pluginSettings.loaded })
	d.click("Compiler settings")
	d.until("native form", func() bool { return w.pluginSettings.sources != nil })
}
func TestNativeSettingsFormKeepsInheritanceAndSavesOnlyAnExplicitModuleEdit(t *testing.T) {
	source := nativeFormSource(t)
	source.failure = configfile.ErrConflict
	w := nativeFormWindow(t, source, i18n.English, "dark")
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	openNativeForm(t, w, d)
	p := w.pluginSettings.sources
	if len(p.pending) != 0 || !d.hit(i18n.Shared(i18n.English, "desktop.pluginSettings.save")).Disabled {
		t.Fatal("displaying inherited values created a draft")
	}
	select {
	case <-source.saves:
		t.Fatal("opening the form wrote a source")
	default:
	}
	// Target is also the first form control; choose the module's last matching
	// accessible control, whose current explicit value is Version 2.
	d.click("Child module Target")
	d.click("Version 1")
	d.pump()
	if len(p.pending) != 1 || len(p.pending["child"]) != 1 || p.pending["child"]["target"].Choice != "one" {
		t.Fatalf("module draft: %+v", p.pending)
	}
	d.click(i18n.Shared(i18n.English, "desktop.pluginSettings.save"))
	d.until("native conflict", func() bool { return p.stale })
	select {
	case edits := <-source.saves:
		if len(edits) != 1 || edits[0].SourceID != "child" || len(edits[0].Values) != 1 {
			t.Fatalf("save changed unrelated sources: %+v", edits)
		}
	default:
		t.Fatal("explicit save did not reach the native adapter")
	}
	if p.controls["child"]["target"].input.Choice != "one" {
		t.Fatal("a conflict discarded the user's draft")
	}
	data, err := os.ReadFile(filepath.Join(source.workspace, "child/tool.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"target":"two"}` {
		t.Fatal("a rejected draft changed its native file")
	}
}

func TestNativeCompilerPageRequiresAnExplicitRead(t *testing.T) {
	source := nativeFormSource(t)
	w := nativeFormWindow(t, source, i18n.English, "dark")
	d := openWindow(t, w)
	d.until("compiler page", func() bool { return len(w.dynamic.pages) == 1 })
	w.selectSettingsPage(pageBuild, "compiler:fictional")
	d.until("compiler action", func() bool { return w.pluginSettings.pageKey == w.dynamicPage && w.pluginSettings.loaded })
	if source.reads.Load() != 0 {
		t.Fatal("opening a compiler page executed the project tool")
	}
	d.click("Compiler settings")
	d.until("native compiler form", func() bool { return w.pluginSettings.sources != nil })
	if source.reads.Load() != 1 {
		t.Fatal("the explicit read did not query exactly once")
	}
}

// A source the plugin projects read-only shows every item of a list, one per line, and
// offers no Reset: an ellipsized single line hid all but the first item.
func TestNativeSettingsFormShowsReadOnlyListsInFull(t *testing.T) {
	items := []string{"web/lib/*.jar", "Server Runtime — 2 JARs", "Global Utils — IDE library"}
	source := nativeFormSource(t, func(snapshot *core.SourceSettingsSnapshot) {
		snapshot.Sources[0].Writable = false
		for index := range snapshot.Sources[0].Fields {
			if field := &snapshot.Sources[0].Fields[index]; field.ID == "files" {
				value, _ := json.Marshal(items)
				field.Value, field.EffectiveValue = value, value
			}
		}
	})
	w := nativeFormWindow(t, source, i18n.English, "light")
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	openNativeForm(t, w, d)
	d.pump()
	for _, item := range items {
		if !d.text(item) {
			t.Fatalf("read-only list item %q is not shown", item)
		}
	}
	if hit := d.hit("Referenced files"); !hit.ReadOnly {
		t.Fatalf("the read-only list accepts input: %+v", hit)
	}
	for _, action := range []string{"desktop.pluginSettings.reset", "desktop.pluginSettings.browse"} {
		if d.has(i18n.Shared(i18n.English, action)) {
			t.Fatalf("a read-only source offers %s", action)
		}
	}
}
