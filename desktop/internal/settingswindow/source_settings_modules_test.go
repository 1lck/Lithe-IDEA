package settingswindow

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

func openModuleForm(t *testing.T, source *nativeFormFixture) (*windowDriver, *sourceSettingsForm) {
	t.Helper()
	w := nativeFormWindow(t, source, i18n.English, "light")
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1120, 1100 })
	openNativeForm(t, w, d)
	d.pump()
	return d, w.pluginSettings.sources
}

func entryValues(entries []core.SourceEntry) []string {
	values := make([]string, len(entries))
	for index, entry := range entries {
		values[index] = entry.Kind + ":" + entry.Value
	}
	return values
}

// A sidebar group lists its modules nested by parent; only the selected one is
// shown beside the list, one section per tab, and other groups stay one item.
func TestSourceModuleListShowsTheSelectedModuleOneTabAtATime(t *testing.T) {
	d, p := openModuleForm(t, moduleFormSource(t))
	for _, item := range []string{"example", "app", "core", "Workspace"} {
		if !d.has(item) {
			t.Fatalf("the module list has no %q", item)
		}
	}
	if p.selectedSource != "root" || !d.text("Runtime") {
		t.Fatalf("the first module is not shown: %q", p.selectedSource)
	}
	depths := map[string]int{}
	for _, item := range p.nav {
		if item.source >= 0 {
			depths[p.editor.State.Snapshot.Sources[item.source].ID] = item.depth
		}
	}
	if depths["root"] != 1 || depths["app"] != 2 || depths["core"] != 2 {
		t.Fatalf("modules are not nested by parent: %v", depths)
	}
	d.click("app")
	d.pump()
	if !d.has("Sources") || !d.has("Paths") || !d.has("Dependencies") {
		t.Fatal("the module's sections are not tabs")
	}
	if !d.has("src") || !d.has("test") || d.has("one.zip") {
		t.Fatal("the first tab does not show only the source folders")
	}
	d.click("Dependencies")
	d.pump()
	// Entry rows are named by their full title, though a narrow row ellipsizes it.
	if !d.has("one.zip") || !d.has("Legacy library") || d.has("src") {
		t.Fatal("the dependencies tab does not show only its fields")
	}
	d.click("Workspace")
	d.pump()
	if !d.text("Referenced files") || !d.text("Libraries") || d.text("Legacy library") {
		t.Fatal("a form group is not shown as one item with its section heading")
	}
	if len(p.pending) != 0 {
		t.Fatalf("navigating created drafts: %+v", p.pending)
	}
}

// Reordering, flagging and adding offered choices edits only the draft; Save
// sends the list in order, and Core drops the display text before the plugin.
func TestSourceEntryListEditsReachThePluginWithoutDisplayText(t *testing.T) {
	source := moduleFormSource(t)
	d, p := openModuleForm(t, source)
	d.click("app")
	d.pump()
	d.click("Dependencies")
	d.pump()
	d.click("one.zip")
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.sourceSettings.entryDown"))
	d.pump()
	d.click("Export one.zip")
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.sourceSettings.entryAdd"))
	d.pump()
	d.click(i18n.SharedFormat(i18n.English, "desktop.sourceSettings.entryKind", map[string]string{"title": "Library"}))
	d.until("library chooser", func() bool { return p.chooser.open })
	if !d.text("3 archives") {
		t.Fatal("the chooser does not show the choice's detail")
	}
	d.click("Shared library")
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.sourceSettings.entryAdd"))
	d.until("chooser closed", func() bool { return !p.chooser.open })
	control := p.controls["app"]["dependencies"]
	if got := entryValues(control.input.Entries); len(got) != 3 || got[0] != "library:lib:legacy" || got[1] != "archive:lib/one.zip" || got[2] != "library:lib:shared" {
		t.Fatalf("draft entries = %v", got)
	}
	if !entryBool(control.input.Entries[1], "exported") {
		t.Fatal("the Export column did not flag the entry")
	}
	if len(p.pending) != 1 || len(p.pending["app"]) != 1 {
		t.Fatalf("drafts touched other fields: %+v", p.pending)
	}
	d.click(i18n.Shared(i18n.English, "desktop.pluginSettings.save"))
	var edits []core.SourceSettingsEdits
	select {
	case edits = <-source.saves:
	case <-time.After(5 * time.Second):
		t.Fatal("explicit save did not reach the native adapter")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	writes, err := core.NewClient().PlanSourceSettingsEdits(ctx, p.editor.State.Snapshot, edits, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(writes) != 1 || writes[0].Path != "app/tool.xml" {
		t.Fatalf("writes = %+v", writes)
	}
	var written, want any
	if err := json.Unmarshal(writes[0].Values["dependencies"], &written); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(`[{"kind":"library","value":"lib:legacy","attributes":{"exported":true}},{"kind":"archive","value":"lib/one.zip","attributes":{"exported":true}},{"kind":"library","value":"lib:shared"}]`), &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(written, want) {
		t.Fatalf("written = %s", writes[0].Values["dependencies"])
	}
}

// Removing every entry is an explicit empty list, shown as such. Reset is offered
// only when the plugin knows the inherited list, and restores it.
func TestSourceEntryListRemovesToAnExplicitEmptyListAndResets(t *testing.T) {
	reset := i18n.Shared(i18n.English, "desktop.pluginSettings.reset")
	d, p := openModuleForm(t, moduleFormSource(t))
	d.click("app")
	d.pump()
	if d.has(reset) {
		t.Fatal("a list without a known inherited value offers Reset, which would empty it")
	}
	d, p = openModuleForm(t, moduleFormSource(t, func(snapshot *core.SourceSettingsSnapshot) {
		snapshot.Sources[1].Fields[0].InheritedValue = json.RawMessage(`[{"kind":"folder","value":"src"}]`)
	}))
	d.click("app")
	d.pump()
	for _, folder := range []string{"src", "test"} {
		d.click(folder)
		d.pump()
		d.click(i18n.Shared(i18n.English, "desktop.sourceSettings.entryRemove"))
		d.pump()
	}
	control := p.controls["app"]["roots"]
	if len(control.input.Entries) != 0 || control.input.Inherit || !d.text(i18n.Shared(i18n.English, "desktop.sourceSettings.entryEmpty")) {
		t.Fatalf("removing every folder: %+v", control.input)
	}
	if _, ok := p.pending["app"]["roots"]; !ok {
		t.Fatal("an emptied list is not a draft")
	}
	d.click(reset)
	d.pump()
	if got := entryValues(control.input.Entries); len(got) != 1 || got[0] != "folder:src" || !control.input.Inherit {
		t.Fatalf("reset: %v %+v", got, control.input)
	}
}

// A module whose dependencies belong to its build file shows them without the
// controls that would edit them.
func TestReadOnlyModuleShowsEntriesWithoutEditing(t *testing.T) {
	d, p := openModuleForm(t, moduleFormSource(t))
	d.click("core")
	d.pump()
	if p.selectedSource != "core" || !d.text("library-1.0.zip") {
		t.Fatal("the read-only module's entries are not shown")
	}
	for _, key := range []string{"desktop.sourceSettings.entryAdd", "desktop.sourceSettings.entryRemove", "desktop.pluginSettings.reset"} {
		if d.has(i18n.Shared(i18n.English, key)) {
			t.Fatalf("a read-only module offers %s", key)
		}
	}
	d.click("library-1.0.zip")
	d.pump()
	if p.controls["core"]["dependencies"].entry != -1 {
		t.Fatal("a read-only entry can be selected for editing")
	}
}

func TestEntryDraftsCompareWithoutDisplayTextAndSkipDuplicatePaths(t *testing.T) {
	a := core.SourceSettingInput{Entries: []core.SourceEntry{{Kind: "archive", Value: "lib/a.zip", Title: "a.zip", Attributes: map[string]any{"exported": true}}}}
	b := cloneSourceInput(a)
	b.Entries[0].Title, b.Entries[0].Detail = "", "elsewhere"
	if !sameSourceInput(a, b) {
		t.Fatal("display text made two drafts differ")
	}
	b.Entries[0].Attributes["exported"] = false
	if sameSourceInput(a, b) || a.Entries[0].Attributes["exported"] != true {
		t.Fatal("a cloned draft shares its attributes, or a changed attribute went unnoticed")
	}
	added := pathEntries(a.Entries, "archive", []string{"lib/a.zip", "/abs/b.jar", "/abs/b.jar", ""})
	if len(added) != 1 || added[0].Value != "/abs/b.jar" || added[0].Title != "b.jar" {
		t.Fatalf("picker paths = %+v", added)
	}
}
