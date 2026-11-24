package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"os"
	"reflect"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// regionPlugin is the synthetic plugin whose settings page carries a region view.
const regionPlugin = "dev.lithe.test.region"

// viewPanelPlugin is the contract fixture that declares a settings region with a view.
const viewPanelPlugin = "dev.lithe.fixture.view-panel"

// The rows of regionEditor, by index.
const (
	regionWatch = iota
	regionMode
	regionChecks
	regionThreads
	regionName
	regionPaths
)

// regionEditor is Core's projection of the synthetic plugin's settings: one row of each kind
// a region binds or carries, editable in the global scope and not in the project's, and a
// region with a view on the plugin's own Settings tab.
func regionEditor() pluginservice.SettingsEditor {
	options := func(values ...string) []core.PluginSettingOption {
		var list []core.PluginSettingOption
		for _, value := range values {
			list = append(list, core.PluginSettingOption{Value: value, Title: "Option " + value})
		}
		return list
	}
	rows := []core.PluginSettingRow{
		{Declaration: core.PluginSettingDeclaration{ID: "watch", Kind: "boolean", Title: "Watch files"}, Effective: core.PluginSettingValue{Value: json.RawMessage(`true`)}},
		{Declaration: core.PluginSettingDeclaration{ID: "mode", Kind: "enum", Title: "Mode", Options: options("fast", "full")}, Effective: core.PluginSettingValue{Value: json.RawMessage(`"fast"`)}},
		{Declaration: core.PluginSettingDeclaration{ID: "checks", Kind: "multiSelect", Title: "Checks", Options: options("a", "b")}, Effective: core.PluginSettingValue{Value: json.RawMessage(`["a"]`)}},
		{Declaration: core.PluginSettingDeclaration{ID: "threads", Kind: "integer", Title: "Threads"}, Effective: core.PluginSettingValue{Value: json.RawMessage(`4`)}},
		{Declaration: core.PluginSettingDeclaration{ID: "name", Kind: "text", Title: "Name"}, Effective: core.PluginSettingValue{Value: json.RawMessage(`"core"`)}},
		{Declaration: core.PluginSettingDeclaration{ID: "paths", Kind: "stringList", Title: "Paths"}, Effective: core.PluginSettingValue{Value: json.RawMessage(`["src"]`)}},
	}
	inputs := []core.PluginSettingInput{
		{On: true}, {Selected: 0}, {Checks: []bool{true, false}}, {Text: "4"}, {Text: "core"}, {Text: "src"},
	}
	var global, project []core.PluginSettingEditorValue
	for index, input := range inputs {
		value := core.PluginSettingEditorValue{Value: rows[index].Effective.Value, Input: input, Editable: true}
		if index == regionThreads {
			value.ResetValue = json.RawMessage(`2`)
		}
		global = append(global, value)
		value.Editable = false
		project = append(project, value)
	}
	state := core.PluginSettingsState{
		PluginID: regionPlugin,
		Metadata: core.PluginSettingsMetadata{Version: "1.0.0"},
		Rows:     rows,
		Editors:  core.PluginSettingsEditors{Global: global, Project: project},
		Region:   &core.PluginSettingsRegion{ID: "overview"},
	}
	state.Region.View = &struct {
		Function string `json:"function"`
	}{Function: "settingsView"}
	return pluginservice.SettingsEditor{Snapshot: pluginsettings.Snapshot{State: state}}
}

// regionForm is a loaded form of the synthetic plugin, its drafts the values in force.
func regionForm() *pluginSettingsForm {
	p := newPluginSettingsForm(nil)
	p.applyLoad(regionEditor(), nil)
	return p
}

func TestRegionDraftValuesAreTypedAsTheSettingsStoreThem(t *testing.T) {
	p := regionForm()
	controls := p.controls[0]
	controls[regionWatch].input.On = false
	controls[regionMode].input.Selected = 1
	controls[regionChecks].input.Checks = []bool{false, true}
	controls[regionThreads].text = " 8 "
	controls[regionName].text = "app"
	controls[regionPaths].text = "src\n  \n lib "
	for _, tc := range []struct {
		row  int
		want any
	}{
		{regionWatch, false},
		{regionMode, "full"},
		{regionChecks, []string{"b"}},
		{regionThreads, int64(8)},
		{regionName, "app"},
		{regionPaths, []string{"src", " lib "}},
	} {
		got, ok := p.draftValue(tc.row)
		if !ok || !reflect.DeepEqual(got, tc.want) {
			t.Errorf("row %d: draft %#v, %v; want %#v", tc.row, got, ok, tc.want)
		}
	}
	controls[regionThreads].text = "eight"
	if got, ok := p.draftValue(regionThreads); ok {
		t.Errorf("an integer the text does not spell has the value %#v", got)
	}
	controls[regionMode].input.Selected = 5
	if got, ok := p.draftValue(regionMode); ok {
		t.Errorf("a choice outside the options has the value %#v", got)
	}
}

func TestRegionEventSettingsCarryWhatIsInForceAndTheChangedDrafts(t *testing.T) {
	p := regionForm()
	clean := p.viewSettings()
	want := map[string]string{"watch": `true`, "mode": `"fast"`, "checks": `["a"]`, "threads": `4`, "name": `"core"`, "paths": `["src"]`}
	if len(clean.Effective) != len(want) || len(clean.Draft) != 0 {
		t.Fatalf("a clean form carries %v and the drafts %v", clean.Effective, clean.Draft)
	}
	for id, value := range want {
		if string(clean.Effective[id]) != value {
			t.Errorf("%s in force = %s, want %s", id, clean.Effective[id], value)
		}
	}
	before := p.viewSettingsText()
	if again := p.viewSettingsText(); again != before {
		t.Fatalf("the same settings encode differently: %s and %s", before, again)
	}

	controls := p.controls[0]
	controls[regionWatch].input.On = false
	controls[regionName].text = "app"
	controls[regionThreads].reset = true
	drafts := p.viewSettings().Draft
	if len(drafts) != 3 || string(drafts["watch"]) != `false` || string(drafts["name"]) != `"app"` || string(drafts["threads"]) != `2` {
		t.Fatalf("drafts = %v, want watch off, the name app and the threads the reset leaves", drafts)
	}
	if p.viewSettingsText() == before {
		t.Fatal("changed drafts encode as the clean form")
	}

	controls[regionThreads].reset = false
	controls[regionThreads].text = "eight"
	if value, ok := p.viewSettings().Draft["threads"]; ok {
		t.Fatalf("an integer the text does not spell was carried as %s", value)
	}
}

func TestRegionBindingsEditTheFormDrafts(t *testing.T) {
	p := regionForm()
	s := regionSettings{p: p, hasSource: true}
	controls := p.controls[0]

	watch, ok := s.Binding("watch")
	if !ok || watch.On != &controls[regionWatch].input.On || watch.Title != "Watch files" || !watch.Editable {
		t.Fatalf("watch binding = %+v, %v", watch, ok)
	}
	*watch.On = false
	controls[regionWatch].reset, p.saved = true, true
	watch.Edited()
	if watch.Value() != false || controls[regionWatch].reset || p.saved {
		t.Fatalf("an edit left value %v, reset %v, saved %v", watch.Value(), controls[regionWatch].reset, p.saved)
	}

	mode, ok := s.Binding("mode")
	if !ok || mode.Selected != &controls[regionMode].input.Selected || !reflect.DeepEqual(mode.Options, []int{0, 1}) {
		t.Fatalf("mode binding = %+v, %v", mode, ok)
	}
	if mode.OptionLabel(1) != "Option full" || mode.OptionLabel(5) != "" {
		t.Fatalf("option labels %q and %q", mode.OptionLabel(1), mode.OptionLabel(5))
	}
	for _, tc := range []struct {
		id  string
		row int
	}{{"threads", regionThreads}, {"name", regionName}} {
		if binding, ok := s.Binding(tc.id); !ok || binding.Text != &controls[tc.row].text {
			t.Errorf("%s binds %+v, %v; want its text", tc.id, binding, ok)
		}
	}
	for _, id := range []string{"checks", "paths", "missing"} {
		if _, ok := s.Binding(id); ok {
			t.Errorf("%s has a control binding", id)
		}
	}

	if binding, _ := (regionSettings{p: p}).Binding("watch"); binding.Editable {
		t.Error("a scope without a file to write is editable")
	}
	p.running = true
	if binding, _ := s.Binding("watch"); binding.Editable {
		t.Error("a form saving is editable")
	}
	p.running, p.scope = false, 1
	if binding, _ := s.Binding("watch"); binding.Editable {
		t.Error("a setting Core does not let the scope edit is editable")
	}

	p.scope = 0
	p.controls[0] = p.controls[0][:regionThreads]
	if s.row("threads") != -1 || s.row("missing") != -1 || s.row("mode") != regionMode {
		t.Fatalf("rows threads %d, missing %d, mode %d", s.row("threads"), s.row("missing"), s.row("mode"))
	}
}

// regionCall is one event a region's view sent its plugin.
type regionCall struct {
	region, function string
	params           map[string]any
	closing          bool
}

// regionSource serves the synthetic plugin's form and answers every event of its region
// view with view, or one button without, recording the events in the order the window
// sends them.
type regionSource struct {
	calls chan regionCall
	view  json.RawMessage
}

func (s *regionSource) Load(context.Context, string, i18n.Language) (pluginservice.SettingsEditor, error) {
	return regionEditor(), nil
}

func (s *regionSource) Save(context.Context, pluginservice.SettingsEditor, string, []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	return pluginsettings.SaveResult{}, errors.New("unexpected save")
}

func (s *regionSource) View(_ context.Context, _ pluginservice.SettingsEditor, region, function string, event, _ json.RawMessage, closing bool) (json.RawMessage, bool, error) {
	var params map[string]any
	if err := json.Unmarshal(event, &params); err != nil {
		return nil, false, err
	}
	s.calls <- regionCall{region: region, function: function, params: params, closing: closing}
	if closing {
		return nil, false, nil
	}
	if s.view != nil {
		return s.view, true, nil
	}
	return json.RawMessage(`[{"type":"button","id":"probe","text":"Probe"}]`), true, nil
}

// next is the next event the view sent other than a settings event, which a draft change
// sends once the values settle.
func (s *regionSource) next(t *testing.T) regionCall {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case call := <-s.calls:
			if call.params["event"] == "settings" {
				continue
			}
			return call
		case <-deadline:
			t.Fatal("the view sent nothing within 5s")
			return regionCall{}
		}
	}
}

// regionSettingsParam is the settings an event carried, by kind and setting ID.
func regionSettingsParam(t *testing.T, call regionCall) (effective, draft map[string]any) {
	t.Helper()
	settings, ok := call.params["settings"].(map[string]any)
	if !ok {
		t.Fatalf("%v carries no settings", call.params)
	}
	effective, _ = settings["effective"].(map[string]any)
	draft, _ = settings["draft"].(map[string]any)
	return effective, draft
}

// A region can refer to a setting or tool the current page cannot draw. These
// synthetic nodes exercise the real settings host, including missing bindings
// and bindings of the wrong kind; the following label must keep drawing.
func TestRegionViewSkipsUnavailableNodesWithoutRenamingTheirNeighbors(t *testing.T) {
	for _, node := range []string{
		`{"type":"setting","setting":"missing"}`,
		`{"type":"tool","tool":"missing"}`,
		`{"type":"textField","id":"missing","setting":"missing"}`,
		`{"type":"select","id":"missing","setting":"name"}`,
		`{"type":"segmented","id":"missing","setting":"name"}`,
		`{"type":"toggle","id":"missing","setting":"name"}`,
	} {
		var kind struct{ Type string }
		if err := json.Unmarshal([]byte(node), &kind); err != nil {
			t.Fatal(err)
		}
		t.Run(kind.Type, func(t *testing.T) {
			source := &regionSource{calls: make(chan regionCall, 32), view: json.RawMessage(`[` + node + `,
				{"type":"label","text":"Region is available"},
				{"type":"label","text":"Available controls follow"},
				{"type":"button","id":"probe","text":"Probe"}]`)}
			fetch := func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: regionPlugin, Name: "Region Fixture", LatestVersion: "1.0.0"}}}}, nil
			}
			w := newWindow(NewController(Options{
				Text:        func() *i18n.Messages { return i18n.For(i18n.English) },
				Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source,
				PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
				InstalledPlugins: func() []PluginFacts {
					return []PluginFacts{{ID: regionPlugin, Name: "Region Fixture", Version: "1.0.0", Settings: len(regionEditor().Snapshot.State.Rows)}}
				},
			}), Values{Theme: "dark"})
			w.sess.page = pagePlugins
			w.installed.tab = installedSettings
			d := openWindow(t, w)
			d.until("the region after its unavailable node", func() bool { return d.text("Region is available") && d.has("Probe") })
			probe := d.hit("Probe").ID
			if event := source.next(t); event.params["event"] != "open" {
				t.Fatalf("the region opened with %v", event.params)
			}
			d.click("Probe")
			if got := d.hit("Probe").ID; got != probe {
				t.Fatalf("the neighboring button changed identity: %v -> %v", probe, got)
			}
			if event := source.next(t); event.params["event"] != "click" || event.params["node"] != "probe" {
				t.Fatalf("the neighboring button sent %v, want its click", event.params)
			}
		})
	}
}

// A region opens with the plugin's own Settings tab and carries the page's settings, a
// changed draft rides on the next event, and the view closes when the tab is left or the
// language changes, opening anew when it shows again.
func TestRegionViewOpensWithThePageAndClosesWhenThePageChanges(t *testing.T) {
	source := &regionSource{calls: make(chan regionCall, 32)}
	var language atomic.Int32
	current := func() i18n.Language { return i18n.Language(language.Load()) }
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: regionPlugin, Name: "Region Fixture", LatestVersion: "1.0.0"}}}}, nil
	}
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(current()) }, Language: current,
		Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source,
		PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
		InstalledPlugins: func() []PluginFacts {
			return []PluginFacts{{ID: regionPlugin, Name: "Region Fixture", Version: "1.0.0", Settings: len(regionEditor().Snapshot.State.Rows)}}
		},
	}), Values{Theme: "dark"})
	w.sess.page = pagePlugins
	w.installed.tab = installedSettings
	d := openWindow(t, w)
	d.until("the region's view", func() bool { return d.has("Probe") })

	opened := source.next(t)
	if opened.params["event"] != "open" || opened.region != "overview" || opened.function != "settingsView" || opened.closing {
		t.Fatalf("the first call = %+v, want open of the overview region", opened)
	}
	// The region lays out at the width of the page's content, which the paint measures.
	if width, _ := opened.params["width"].(float64); width < 100 || width != math.Floor(width) {
		t.Fatalf("the view opened at width %v, want the region's width in whole points", opened.params["width"])
	}
	if opened.params["language"] != i18n.English.Code() {
		t.Fatalf("the view opened in %v", opened.params["language"])
	}
	effective, draft := regionSettingsParam(t, opened)
	if effective["threads"] != float64(4) || effective["name"] != "core" || len(draft) != 0 {
		t.Fatalf("open carried %v in force and the drafts %v", effective, draft)
	}

	form := w.pluginSettings
	form.controls[0][regionName].text = "app"
	d.click("Probe")
	clicked := source.next(t)
	if _, draft := regionSettingsParam(t, clicked); clicked.params["event"] != "click" || clicked.params["node"] != "probe" || draft["name"] != "app" {
		t.Fatalf("the click = %v, want it on probe with the name draft", clicked.params)
	}
	form.controls[0][regionName].text = "core"

	w.installed.tab = installedFeatures
	w.inv.Invalidate()
	d.pump()
	if closed := source.next(t); !closed.closing || closed.params["event"] != "close" || closed.params["instance"] != opened.params["instance"] {
		t.Fatalf("leaving the tab sent %+v, want the view closed", closed)
	}
	if w.region != nil {
		t.Fatal("the window still holds the region of a tab not shown")
	}

	w.installed.tab = installedSettings
	d.until("the region's view again", func() bool { return d.has("Probe") })
	reopened := source.next(t)
	if reopened.params["event"] != "open" || reopened.params["instance"] == opened.params["instance"] {
		t.Fatalf("showing the tab again sent %v, want a new open", reopened.params)
	}

	language.Store(int32(i18n.Chinese))
	d.until("the view in Chinese", func() bool {
		return w.region != nil && w.region.key.language == i18n.Chinese && d.has("Probe")
	})
	if closed := source.next(t); !closed.closing || closed.params["instance"] != reopened.params["instance"] {
		t.Fatalf("a language change sent %+v, want the view closed", closed)
	}
	if chinese := source.next(t); chinese.params["event"] != "open" || chinese.params["language"] != i18n.Chinese.Code() {
		t.Fatalf("a language change then sent %v, want the view opened in Chinese", chinese.params)
	}
}

// A region's keywords find its page: the view-panel fixture's region, placed on a language
// page, makes the page a hit for words only the region declares, through Core's search.
func TestSearchFindsAPluginPageByItsRegionKeywords(t *testing.T) {
	data, err := os.ReadFile(contractfixture.Path("fixtures/ui/view-panel.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	regions, _ := manifest["settingRegions"].([]any)
	region, _ := regions[0].(map[string]any)
	if region == nil {
		t.Fatal("the view-panel fixture declares no settings region")
	}
	region["page"] = map[string]string{"languageID": "elixir"}
	placed, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: placed, Owner: core.PluginSettingsOwner{PluginID: viewPanelPlugin, Version: "1.0.0"}, Enabled: true}}, "")
		},
	}), Values{Theme: "dark"})
	d := openWindow(t, w)
	d.until("the region's page", func() bool { return len(w.dynamic.pages) == 1 })
	page := w.dynamic.pages[0]
	if len(page.Contributors) != 1 || page.Contributors[0].Region == nil || !slices.Contains(page.Contributors[0].Region.Keywords, "module graph") {
		t.Fatalf("Core placed %+v on the page, want the fixture's region with its keywords", page.Contributors)
	}
	listed := func() bool {
		for _, r := range w.rows {
			if r.dynamic == page.Key {
				return true
			}
		}
		return false
	}
	w.searchField.SetText("module graph")
	d.until("the page the region's keyword finds", listed)
	w.searchField.SetText("no such words")
	d.until("a search no region matches", func() bool { return w.query == foldQuery("no such words") && !listed() })
}

// regionToolWindow opens the synthetic plugin's Settings tab, its region one row of the fixture
// tool the loader serves, the tool's picker with choose, and waits for the row.
func regionToolWindow(t *testing.T, loader ToolchainLoader, choose bool) (*window, *windowDriver) {
	t.Helper()
	view, _ := json.Marshal([]map[string]any{{"type": "tool", "tool": fixtureTool, "choose": choose}})
	source := &regionSource{calls: make(chan regionCall, 32), view: view}
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: regionPlugin, Name: "Region Fixture", LatestVersion: "1.0.0"}}}}, nil
	}
	w := newWindow(NewController(Options{
		Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source, Toolchains: loader,
		PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
		InstalledPlugins: func() []PluginFacts {
			return []PluginFacts{{ID: regionPlugin, Name: "Region Fixture", Version: "1.0.0", Settings: len(regionEditor().Snapshot.State.Rows)}}
		},
	}), Values{})
	w.sess.page = pagePlugins
	w.installed.tab = installedSettings
	d := openWindow(t, w)
	d.until("the region's tool row", func() bool { return d.has("Compiler") })
	d.pump()
	return w, d
}

// A tool row with choose opens the tool's choices under it in the plugin page's scope; a
// choice is a draft of that scope that closes the choices and waits for the footer's Apply.
func TestRegionToolPickerChoosesIntoTheToolchainDraft(t *testing.T) {
	loader := &scopedToolchainLoader{fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}}
	w, d := regionToolWindow(t, loader, true)
	manage := en("desktop.pluginView.toolPickerToolchains")
	if d.has(manage) || d.has("/fixture/compiler") {
		t.Fatal("the tool's choices show before the row is pressed")
	}
	// The plugin page shows the global settings, and the project scope is the one the
	// Toolchains page shows; the picker follows the plugin page.
	w.toolchains.setScope(scopeProject)
	d.click("Compiler")
	d.until("the tool's choices", func() bool { return d.has(manage) && d.has("/fixture/compiler") })
	if w.toolchains.scope != scopeGlobal {
		t.Fatalf("the picker opened with the Toolchains page in the %s scope, want the plugin page's", w.toolchains.scope)
	}
	d.click("/fixture/compiler")
	d.pump()
	global := w.toolchains.scopes[scopeGlobal]
	if global.draft[fixtureTool] != "/fixture/compiler" || w.toolchains.drafts(scopeProject) != 0 {
		t.Fatalf("the choice drafted %v globally and %d in the project, want the installation globally", global.draft, w.toolchains.drafts(scopeProject))
	}
	if d.has(manage) || w.region.picker != "" {
		t.Fatal("the choices stayed open after a choice")
	}
	select {
	case edits := <-loader.saved:
		t.Fatalf("choosing wrote %+v before Apply", edits)
	default:
	}
	d.applyBuild()
	select {
	case edits := <-loader.saved:
		if len(edits) != 1 || edits[0].Tool != fixtureTool || edits[0].Pin == nil || edits[0].Pin.Home != "/fixture/compiler" {
			t.Fatalf("Apply wrote %+v, want the chosen installation pinned", edits)
		}
	default:
		t.Fatal("Apply did not write the choice")
	}
	if len(global.draft) != 0 {
		t.Fatalf("the applied choice is still a draft: %v", global.draft)
	}
}

// The picker's way to the Toolchains page, and a press on a row without choose, open the page
// in the plugin page's scope with the tool chosen.
func TestRegionToolRowOpensTheToolchainsPage(t *testing.T) {
	for _, choose := range []bool{true, false} {
		w, d := regionToolWindow(t, &scopedToolchainLoader{fakeToolchainLoader{snapshot: fixtureSnapshot()}}, choose)
		w.toolchains.setScope(scopeProject)
		d.click("Compiler")
		if choose {
			manage := en("desktop.pluginView.toolPickerToolchains")
			d.until("the tool's choices", func() bool { return d.has(manage) })
			d.click(manage)
		}
		d.until("the Toolchains page", func() bool { return w.sess.page == pageToolchains })
		if w.toolchains.scope != scopeGlobal || w.toolchains.selected != fixtureTool {
			t.Fatalf("choose %v: the Toolchains page opened in the %s scope on %q, want the global scope on the tool", choose, w.toolchains.scope, w.toolchains.selected)
		}
		if w.region != nil && w.region.picker != "" {
			t.Fatalf("choose %v: the picker stayed open after leaving for the Toolchains page", choose)
		}
	}
}

func TestRegionViewSettingsHashTracksStateAndDraftChanges(t *testing.T) {
	p := regionForm()
	base := p.viewSettingsHash()
	if again := p.viewSettingsHash(); again != base {
		t.Fatalf("viewSettingsHash was not deterministic: %d != %d", again, base)
	}
	if allocs := testing.AllocsPerRun(50, func() { _ = p.viewSettingsHash() }); allocs != 0 {
		t.Fatalf("viewSettingsHash allocated %.1f times per call, want 0", allocs)
	}

	p.controls[0][regionName].text = "app"
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on text draft edit")
	}
	p.controls[0][regionName].text = "core"

	p.controls[0][regionWatch].input.On = false
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on boolean draft edit")
	}
	p.controls[0][regionWatch].input.On = true

	p.controls[0][regionMode].input.Selected = 1
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on enum draft edit")
	}
	p.controls[0][regionMode].input.Selected = 0

	p.controls[0][regionChecks].input.Checks[1] = true
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on multiSelect draft edit")
	}
	p.controls[0][regionChecks].input.Checks[1] = false

	p.controls[0][regionThreads].reset = true
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on reset flag change")
	}
	p.controls[0][regionThreads].reset = false

	p.scope = 1
	if p.viewSettingsHash() == base {
		t.Fatal("viewSettingsHash did not change on scope switch")
	}
	p.scope = 0

	if restored := p.viewSettingsHash(); restored != base {
		t.Fatalf("viewSettingsHash after restoring state = %d, want %d", restored, base)
	}
}
