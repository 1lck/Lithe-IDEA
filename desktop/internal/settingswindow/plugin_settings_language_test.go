package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

// presentedFormSource loads the contract's settings fixture as an installed package with its
// l10n/zh-Hans.json, the way the plugin service does, and records the language of each load.
// Its action asks for confirmation with the manifest's title, as Core plans it.
type presentedFormSource struct {
	store     *pluginsettings.Store
	manifest  []byte
	directory string
	mu        sync.Mutex
	languages []i18n.Language
}

func (s *presentedFormSource) Load(ctx context.Context, _ string, language i18n.Language) (pluginservice.SettingsEditor, error) {
	s.mu.Lock()
	s.languages = append(s.languages, language)
	s.mu.Unlock()
	snapshot, err := s.store.LoadPresented(ctx, s.manifest, "", pluginsettings.Presentation{Language: language.Code(), Package: s.directory})
	return pluginservice.SettingsEditor{Snapshot: snapshot}, err
}

func (s *presentedFormSource) Save(ctx context.Context, editor pluginservice.SettingsEditor, scope string, edits []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	return s.store.Save(ctx, editor.Snapshot, scope, edits, nil)
}

func (s *presentedFormSource) Action(_ context.Context, _ pluginservice.SettingsEditor, id string, _ bool) (pluginservice.SettingsActionResult, error) {
	return pluginservice.SettingsActionResult{Plan: core.PluginSettingsActionPlan{Kind: "confirmationRequired", ActionID: id, Title: "Rebuild PLT"}}, nil
}

func (s *presentedFormSource) loads() []i18n.Language {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]i18n.Language(nil), s.languages...)
}

// The plugin's own text follows the window's language: a clean form reloads in the new
// language, a form with a draft keeps its text and the draft until the draft is gone, and the
// confirmation of an action names it the way its translated button does.
func TestPluginSettingsTextFollowsTheWindowLanguageWithoutDiscardingDrafts(t *testing.T) {
	directory := contractfixture.Path("fixtures/settings")
	manifest, err := os.ReadFile(filepath.Join(directory, "settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	source := &presentedFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, directory: directory}
	var language atomic.Int32
	current := func() i18n.Language { return i18n.Language(language.Load()) }
	w := newWindow(NewController(Options{
		PluginSettings:     source,
		Language:           current,
		Text:               func() *i18n.Messages { return i18n.For(current()) },
		SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.lithe.fixture.settings", Version: "0.1.0"}, Enabled: true}})
		},
	}), Values{Theme: "dark"})
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	d.until("the plugin's pages", func() bool { return w.dynamic.loaded && len(w.dynamic.pages) > 0 })
	key := ""
	for _, page := range w.dynamic.pages {
		if page.Kind == "language" {
			key = page.Key
		}
	}
	if key == "" {
		t.Fatalf("no language page in %+v", w.dynamic.pages)
	}
	w.selectSettingsPage(pageLanguages, key)
	d.until("the English form", func() bool { return w.pluginSettings.loaded && d.text("Dialyzer") })
	form := w.pluginSettings

	language.Store(int32(i18n.Chinese))
	d.until("the Chinese form", func() bool { return form.loaded && d.text("Dialyzer 静态分析") })
	if got := source.loads(); len(got) != 2 || got[0] != i18n.English || got[1] != i18n.Chinese {
		t.Fatalf("loads %v", got)
	}

	// A draft on another page of the same plugin still belongs to this form.
	checks := -1
	for index, row := range form.editor.Snapshot.State.Rows {
		if row.Declaration.ID == "checks" {
			checks = index
		}
	}
	if checks < 0 {
		t.Fatal("no checks row")
	}
	control := &form.controls[form.scope][checks]
	baseline := append([]bool(nil), control.input.Checks...)
	control.input.Checks = []bool{!baseline[0], baseline[1]}
	if !form.hasDraft() {
		t.Fatal("the test did not make a draft")
	}
	language.Store(int32(i18n.English))
	for range 3 {
		w.inv.Invalidate()
		d.pump()
	}
	// A reload would have started on the first of these paints and cleared loaded.
	if !form.loaded || len(source.loads()) != 2 || !d.text("Dialyzer 静态分析") || control.input.Checks[0] == baseline[0] {
		t.Fatalf("a language change replaced a draft: loaded=%v loads=%v", form.loaded, source.loads())
	}
	control.input.Checks = baseline
	d.until("the English form after the draft", func() bool { return form.loaded && d.text("Dialyzer") })
	if got := source.loads(); len(got) != 3 || got[2] != i18n.English {
		t.Fatalf("loads %v", got)
	}

	language.Store(int32(i18n.Chinese))
	d.until("the Chinese action", func() bool { return form.loaded && d.has("重建 PLT") })
	d.click("重建 PLT")
	d.until("the confirmation", func() bool { return form.actionConfirmation != nil })
	if form.actionConfirmation.Title != "重建 PLT" {
		t.Fatalf("confirmation title %q", form.actionConfirmation.Title)
	}
	w.inv.Invalidate()
	d.pump()
	if !d.textContaining("重建 PLT") || d.textContaining("Rebuild PLT") {
		t.Fatal("the confirmation does not name the translated action")
	}
}
