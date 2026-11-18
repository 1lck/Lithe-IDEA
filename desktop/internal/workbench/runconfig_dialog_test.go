package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// emptyProcessRunHarness opens an empty project without any build plugin and waits until Core
// resolved its configurations and listed the built-in kinds.
func emptyProcessRunHarness(t *testing.T) (*harness, *project, string) {
	t.Helper()
	root := t.TempDir()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the empty configuration list", func() bool {
		s := &p.runConfigs
		return s.generation > 0 && !s.loading && s.types != nil
	})
	if s := &p.runConfigs; s.failure != "" || len(s.list) != 0 {
		t.Fatalf("configurations = %+v failure %q", s.list, s.failure)
	}
	return h, p, root
}

// fillScriptText names form f, sets its script text and waits for the form that follows.
func fillScriptText(t *testing.T, h *harness, p *project, f *runConfigForm, name, text string) {
	t.Helper()
	h.app.post(func(a *App) {
		*f.texts["name"] = name
		*f.texts["source"] = "text"
		a.runConfigFormEdited(p, f)
	})
	awaitStateWithin(t, h, 10*time.Second, "the text field of "+name, func() bool { return !f.refreshing && f.texts["text"] != nil })
	h.app.post(func(*App) { *f.texts["text"] = text })
}

// applyDialog presses step once no draft is being read, as the buttons wait for, and waits until
// the save ended and the configurations resolved again.
func applyDialog(t *testing.T, h *harness, p *project, step runConfigDialogStep) {
	t.Helper()
	d := &p.runConfigs.dialog
	awaitStateWithin(t, h, 10*time.Second, "the drafts to be read", func() bool { return !d.busy() })
	pressed := false
	h.app.post(func(a *App) {
		a.applyRunConfigDialog(p, step)
		pressed = true
	})
	awaitStateWithin(t, h, 10*time.Second, "the save", func() bool {
		return pressed && !d.saving && !p.runConfigs.loading && p.runConfigs.pending == titleActionNone
	})
}

// listedNames is the names of the listed configurations.
func listedNames(p *project) []string {
	names := make([]string, 0, len(p.runConfigs.list))
	for _, configuration := range p.runConfigs.list {
		names = append(names, configuration.Name)
	}
	return names
}

// Apply saves every configuration created in the dialog in one press and keeps the dialog open
// on them under their saved IDs; Cancel drops what changed since; a removal waits for OK, and
// the selection moves to the configuration that takes the removed one's row.
func TestRunConfigDialogSavesWhatItHoldsTogether(t *testing.T) {
	h, p, root := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	one := newRunConfigDraft(t, h, p, runProviderShell)
	fillScriptText(t, h, p, one, "One", "echo one\n")
	var two *runConfigForm
	h.app.post(func(a *App) {
		a.addRunConfigDraft(p, builtInKind(runProviderShell), nil)
		two = d.drafts[d.selected].form
	})
	awaitStateWithin(t, h, 10*time.Second, "the second form", func() bool { return two != nil && two.ready() })
	fillScriptText(t, h, p, two, "Two", "echo two\n")
	h.settle()
	if !d.dirty() {
		t.Fatal("two new configurations show as nothing to save")
	}

	applyDialog(t, h, p, runConfigDialogApply)
	if names := listedNames(p); !d.open || len(names) != 2 {
		t.Fatalf("dialog open %v, configurations %v, failure %q / %q / %q", d.open, names, d.failure, one.failure, two.failure)
	}
	for key, draft := range d.drafts {
		if strings.HasPrefix(key, runConfigNewKey) || draft.key != key || draft.dirty() {
			t.Fatalf("draft %q = key %q dirty %v after Apply", key, draft.key, draft.dirty())
		}
	}
	if !strings.HasPrefix(d.selected, "user:") || d.selected != two.id || p.runConfigs.selected != two.id || p.runConfigs.currentFile {
		t.Fatalf("selected %q, title %q current file %v, want %q", d.selected, p.runConfigs.selected, p.runConfigs.currentFile, two.id)
	}
	if d.dirty() {
		t.Fatal("the dialog shows something to save after Apply")
	}
	local := filepath.Join(root, ".lithe", "run", "local.yaml")
	saved, err := os.ReadFile(local)
	if err != nil || !strings.Contains(string(saved), "One") || !strings.Contains(string(saved), "Two") {
		t.Fatalf("local.yaml = %s, %v", saved, err)
	}

	// Cancel drops a removal and a new configuration together.
	oneID := one.id
	h.app.post(func(a *App) {
		a.selectRunConfigDraft(p, oneID)
		a.removeRunConfigDraft(p)
		a.addRunConfigDraft(p, builtInKind(runProviderExecutable), nil)
		a.closeRunConfigDialog(p)
	})
	h.settle()
	if data, _ := os.ReadFile(local); string(data) != string(saved) || len(p.runConfigs.list) != 2 {
		t.Fatalf("Cancel wrote: %s, configurations %v", data, listedNames(p))
	}

	// A removal waits for OK; − moves the selection to the configuration below.
	h.app.post(func(a *App) {
		a.openRunConfigDialog(p, oneID)
		a.removeRunConfigDraft(p)
	})
	h.settle()
	if !d.removed[oneID] || d.selected != two.id || h.shows("One") || len(p.runConfigs.list) != 2 {
		t.Fatalf("removed %v selected %q, configurations %v", d.removed, d.selected, listedNames(p))
	}
	applyDialog(t, h, p, runConfigDialogOK)
	if names := listedNames(p); d.open || len(names) != 1 || names[0] != "Two" {
		t.Fatalf("dialog open %v, configurations %v, failure %q", d.open, names, d.failure)
	}
}

// Copy creates a new configuration with the values the selected one's form shows, named as a
// copy; the copy saves as a configuration of its own.
func TestRunConfigDialogCopiesAConfiguration(t *testing.T) {
	h, p, _ := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	original := newRunConfigDraft(t, h, p, runProviderShell)
	fillScriptText(t, h, p, original, "Greet", "echo hello\n")
	h.settle()
	h.app.post(func(a *App) {
		key := d.selected
		a.addRunConfigFolder(p)
		a.selectRunConfigDraft(p, key)
		a.copyRunConfigDraft(p)
	})
	var copied *runConfigForm
	awaitStateWithin(t, h, 10*time.Second, "the copy's form", func() bool {
		if draft := d.drafts[d.selected]; draft != nil && draft.form != original {
			copied = draft.form
		}
		return copied != nil && copied.ready()
	})
	want := i18n.SharedFormat(h.app.language(), "desktop.runConfig.copyName", map[string]string{"name": "Greet"})
	if *copied.texts["name"] != want || *copied.texts["text"] != "echo hello\n" || len(d.added) != 2 {
		t.Fatalf("copy = name %q text %q, added %v", *copied.texts["name"], *copied.texts["text"], d.added)
	}
	// The copy goes in the original's folder, and both are saved there.
	folder := i18n.Shared(h.app.language(), "desktop.runConfig.newFolderName")
	if got := p.runConfigDialogFolder(d.selected); got != folder {
		t.Fatalf("the copy is in folder %q, want %q", got, folder)
	}
	applyDialog(t, h, p, runConfigDialogOK)
	if names := listedNames(p); len(names) != 2 {
		t.Fatalf("configurations %v, failure %q", names, d.failure)
	}
	for _, configuration := range p.runConfigs.list {
		if configuration.Folder != folder {
			t.Fatalf("%s is in folder %q, want %q", configuration.Name, configuration.Folder, folder)
		}
	}
}

// Closing the group of the selected configuration leaves the selection on the group's row, and
// the group stays closed when the dialog opens again.
func TestRunConfigDialogGroupsClose(t *testing.T) {
	h, p, _ := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	newRunConfigDraft(t, h, p, runProviderShell)
	h.settle()
	group := runConfigDialogNode{group: runProcessKindKey(runProviderShell)}
	if len(d.rows) != 2 || d.runConfigDialogRowIndex() != 1 {
		t.Fatalf("rows %+v, selected row %d", d.rows, d.runConfigDialogRowIndex())
	}
	h.app.post(func(*App) { p.toggleRunConfigDialogNode(group) })
	h.settle()
	if d.selected != "" || d.node != group || len(d.rows) != 1 || d.runConfigDialogRowIndex() != 0 {
		t.Fatalf("selected %q node %+v rows %+v", d.selected, d.node, d.rows)
	}
	h.app.post(func(a *App) {
		a.closeRunConfigDialog(p)
		a.openRunConfigDialog(p, "")
	})
	h.settle()
	if !d.closed[group] {
		t.Fatal("the closed group opened again with the dialog")
	}
}

// savedShellRuns saves shell runs of names through the dialog, which stays open on them.
func savedShellRuns(t *testing.T, h *harness, p *project, names ...string) map[string]string {
	t.Helper()
	d := &p.runConfigs.dialog
	forms := make([]*runConfigForm, 0, len(names))
	for index, name := range names {
		var f *runConfigForm
		if index == 0 {
			f = newRunConfigDraft(t, h, p, runProviderShell)
		} else {
			h.app.post(func(a *App) {
				a.addRunConfigDraft(p, builtInKind(runProviderShell), nil)
				f = d.drafts[d.selected].form
			})
			awaitStateWithin(t, h, 10*time.Second, "the form of "+name, func() bool { return f != nil && f.ready() })
		}
		fillScriptText(t, h, p, f, name, "echo "+name+"\n")
		forms = append(forms, f)
	}
	h.settle()
	applyDialog(t, h, p, runConfigDialogApply)
	ids := map[string]string{}
	for index, f := range forms {
		if f.id == "" {
			t.Fatalf("%s was not saved: dialog failure %q, form failure %q", names[index], d.failure, f.failure)
		}
		ids[names[index]] = f.id
	}
	if got := listedNames(p); len(got) != len(names) {
		t.Fatalf("configurations %v, failure %q", got, d.failure)
	}
	return ids
}

// dialogRowKeys is the configuration keys of the tree's rows, "" for a group's or folder's row.
func dialogRowKeys(d *runConfigDialog) []string {
	keys := make([]string, 0, len(d.rows))
	for _, row := range d.rows {
		keys = append(keys, row.key)
	}
	return keys
}

// With no configuration, the dialog shows what IDEA does: that none was added and the link that
// adds one beside its keys in the tree, and the link that adds one over "or select one to edit"
// in the pane. Each link, and ⌃N or Alt+Insert, opens the menu of kinds.
func TestRunConfigDialogEmptyStateOffersToAdd(t *testing.T) {
	h, p, _ := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, "") })
	awaitStateWithin(t, h, 10*time.Second, "the list the dialog reads again", func() bool {
		return d.open && !p.runConfigs.loading && p.runConfigs.types != nil
	})
	h.settle()
	language := h.app.language()
	for _, key := range []string{"emptyTree", "addNew", "addNewConfiguration", "orSelectToEdit"} {
		if text := i18n.Shared(language, "desktop.runConfig."+key); !h.shows(text) {
			t.Fatalf("%q is not shown", text)
		}
	}
	shell := i18n.Shared(language, "desktop.runConfig.typeShell")
	if h.shows(shell) {
		t.Fatal("the kinds show before the menu opens")
	}

	// The keys open the menu while the keyboard is in the tree's column, as it is on opening.
	if runtime.GOOS == "darwin" {
		if _, err := h.driver.ShortcutChord(gfx.ModifierControl, 'n'); err != nil {
			t.Fatal(err)
		}
	} else if err := h.driver.Key(gfx.KeyInsert, gfx.ModifierAlt); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if d.newMenu != runConfigNewMenuToolbar || !h.shows(shell) {
		t.Fatalf("menu %v, kinds shown %v after the add keys", d.newMenu, h.shows(shell))
	}
	h.app.post(func(*App) { d.newMenu = runConfigNewMenuClosed })
	h.settle()

	for _, link := range []struct {
		key  string
		menu runConfigNewMenu
	}{{"addNew", runConfigNewMenuTree}, {"addNewConfiguration", runConfigNewMenuPane}} {
		h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.runConfig."+link.key))))
		if d.newMenu != link.menu || !h.shows(shell) {
			t.Fatalf("%s: menu %v, kinds shown %v", link.key, d.newMenu, h.shows(shell))
		}
		h.app.post(func(*App) { d.newMenu = runConfigNewMenuClosed })
		h.settle()
	}

	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.runConfig.addNew"))))
	h.popupClick(shell)
	if draft := d.drafts[d.selected]; draft == nil || draft.form == nil || draft.form.kind != builtInKind(runProviderShell) || d.newMenu != runConfigNewMenuClosed {
		t.Fatalf("selected %q, menu %v after choosing a kind", d.selected, d.newMenu)
	}
}

// A folder holds the configuration selected when it is made and is selected to be renamed; the
// folder is saved in the configuration, so the list and the dialog show it again. Taking the
// folder away puts its configurations back in their kind.
func TestRunConfigDialogFoldersAreSavedInTheConfiguration(t *testing.T) {
	h, p, root := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	ids := savedShellRuns(t, h, p, "Alpha", "Beta")
	language := h.app.language()
	h.app.post(func(a *App) {
		a.selectRunConfigDraft(p, ids["Beta"])
		a.addRunConfigFolder(p)
	})
	h.settle()
	base := i18n.Shared(language, "desktop.runConfig.newFolderName")
	folder := runConfigDialogNode{group: runProcessKindKey(runProviderShell), folder: base}
	if d.node != folder || !slices.Equal(dialogRowKeys(d), []string{"", "", ids["Beta"], ids["Alpha"]}) {
		t.Fatalf("node %+v rows %v", d.node, dialogRowKeys(d))
	}
	if !h.shows(i18n.Shared(language, "desktop.runConfig.folderHint")) {
		t.Fatal("the folder's pane is not shown")
	}

	// A second folder takes the next free name; a name another folder has, or none, is refused.
	h.app.post(func(a *App) {
		a.selectRunConfigDraft(p, ids["Alpha"])
		a.addRunConfigFolder(p)
	})
	h.settle()
	if want := base + " 2"; d.node.folder != want {
		t.Fatalf("second folder %q, want %q", d.node.folder, want)
	}
	for _, refused := range []struct{ name, key string }{{base, "folderNameTaken"}, {"  ", "folderNameEmpty"}, {"a\tb", "folderNameInvalid"}} {
		h.app.post(func(a *App) {
			d.folderName = refused.name
			a.renameRunConfigFolder(p)
		})
		h.settle()
		if want := i18n.Shared(language, "desktop.runConfig."+refused.key); d.folderError != want || d.node.folder != base+" 2" || !h.shows(want) {
			t.Fatalf("%q: error %q node %+v", refused.name, d.folderError, d.node)
		}
	}
	h.app.post(func(a *App) {
		d.folderName = " Servers "
		a.renameRunConfigFolder(p)
	})
	h.settle()
	if d.folderError != "" || d.node.folder != "Servers" || p.runConfigDialogFolder(ids["Alpha"]) != "Servers" {
		t.Fatalf("rename: error %q node %+v", d.folderError, d.node)
	}

	applyDialog(t, h, p, runConfigDialogApply)
	for name, want := range map[string]string{"Alpha": "Servers", "Beta": base} {
		if configuration := p.runConfigs.configuration(ids[name]); configuration == nil || configuration.Folder != want {
			t.Fatalf("%s = %+v, failure %q", name, configuration, d.failure)
		}
	}
	local := filepath.Join(root, ".lithe", "run", "local.yaml")
	if data, err := os.ReadFile(local); err != nil || !strings.Contains(string(data), "folder: Servers") {
		t.Fatalf("local.yaml = %s, %v", data, err)
	}
	if d.dirty() {
		t.Fatal("the dialog shows something to save after Apply")
	}

	// The folders show again when the dialog opens, and − on a folder takes it away.
	h.app.post(func(a *App) {
		a.closeRunConfigDialog(p)
		a.openRunConfigDialog(p, "")
	})
	h.settle()
	if !h.shows("Servers") || !h.shows(base) {
		t.Fatal("the saved folders are not shown")
	}
	h.app.post(func(a *App) {
		d.selectRunConfigDialogNode(runConfigDialogNode{group: folder.group, folder: "Servers"})
		a.removeRunConfigSelection(p)
	})
	h.settle()
	if d.node != (runConfigDialogNode{group: folder.group}) || p.runConfigDialogFolder(ids["Alpha"]) != "" || h.shows("Servers") {
		t.Fatalf("node %+v, Alpha in %q", d.node, p.runConfigDialogFolder(ids["Alpha"]))
	}
	applyDialog(t, h, p, runConfigDialogOK)
	if configuration := p.runConfigs.configuration(ids["Alpha"]); d.open || configuration == nil || configuration.Folder != "" {
		t.Fatalf("dialog open %v, Alpha = %+v, failure %q", d.open, configuration, d.failure)
	}
}

// Turning the sort off keeps the order the tree shows and lets a configuration be dragged to
// another place; the order is saved for this machine only, and the list follows it.
func TestRunConfigDialogOrdersTheListWhenNotSorted(t *testing.T) {
	h, p, root := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	ids := savedShellRuns(t, h, p, "Alpha", "Beta", "Gamma")
	if p.runConfigs.manualOrder || !p.runConfigDialogSorted() {
		t.Fatal("a new project lists its configurations unsorted")
	}
	// Sorted, a configuration only moves between folders: before another one is refused.
	if p.runConfigDialogCanDrop(3, 1, ui.TreeDropBefore) {
		t.Fatal("a sorted list takes a new place")
	}
	h.app.post(func(*App) { p.toggleRunConfigDialogSort() })
	h.settle()
	if !slices.Equal(dialogRowKeys(d), []string{"", ids["Alpha"], ids["Beta"], ids["Gamma"]}) || !d.dirty() {
		t.Fatalf("turning the sort off moved the rows: %v", dialogRowKeys(d))
	}
	h.app.post(func(a *App) { a.dropRunConfigDialogRow(p, ui.TreeMove{From: 3, To: 1, Where: ui.TreeDropBefore}) })
	h.settle()
	if want := []string{"", ids["Gamma"], ids["Alpha"], ids["Beta"]}; !slices.Equal(dialogRowKeys(d), want) || d.selected != ids["Gamma"] {
		t.Fatalf("rows %v selected %q, want %v", dialogRowKeys(d), d.selected, want)
	}
	applyDialog(t, h, p, runConfigDialogApply)
	if names := listedNames(p); !slices.Equal(names, []string{"Gamma", "Alpha", "Beta"}) || !p.runConfigs.manualOrder {
		t.Fatalf("configurations %v manual %v, failure %q", names, p.runConfigs.manualOrder, d.failure)
	}
	project := filepath.Join(root, ".lithe", "run", "configurations.yaml")
	if data, err := os.ReadFile(project); err == nil && strings.Contains(string(data), "arrangement") {
		t.Fatalf("the order went to the project file: %s", data)
	}
	local, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "local.yaml"))
	if err != nil || !strings.Contains(string(local), "sortAlphabetically: false") {
		t.Fatalf("local.yaml = %s, %v", local, err)
	}

	// A configuration added while the list is ordered goes after the others and keeps its place.
	var added *runConfigForm
	h.app.post(func(a *App) {
		a.addRunConfigDraft(p, builtInKind(runProviderShell), nil)
		added = d.drafts[d.selected].form
	})
	awaitStateWithin(t, h, 10*time.Second, "the new form", func() bool { return added != nil && added.ready() })
	fillScriptText(t, h, p, added, "Delta", "echo delta\n")
	h.settle()
	applyDialog(t, h, p, runConfigDialogApply)
	if names := listedNames(p); !slices.Equal(names, []string{"Gamma", "Alpha", "Beta", "Delta"}) {
		t.Fatalf("configurations %v, failure %q", names, d.failure)
	}

	// Sorting again lists by name.
	h.app.post(func(*App) { p.toggleRunConfigDialogSort() })
	applyDialog(t, h, p, runConfigDialogOK)
	if names := listedNames(p); !slices.Equal(names, []string{"Alpha", "Beta", "Delta", "Gamma"}) || p.runConfigs.manualOrder {
		t.Fatalf("configurations %v manual %v, failure %q", names, p.runConfigs.manualOrder, d.failure)
	}
}

// ⌫ on macOS, and Delete elsewhere, takes the selected configuration out of the tree like −, and
// the keyboard stays in the tree on the row that took its place, so the key goes on removing.
func TestRunConfigDialogDeleteKeyRemovesTheSelection(t *testing.T) {
	h, p, _ := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	ids := savedShellRuns(t, h, p, "One", "Two")
	key := gfx.KeyDelete
	if runtime.GOOS == "darwin" {
		key = gfx.KeyBackspace
	}
	h.click(center(h.labelBounds("One")))
	if d.selected != ids["One"] {
		t.Fatalf("selected %q after clicking One", d.selected)
	}
	for _, name := range []string{"One", "Two"} {
		if err := h.driver.Key(key, 0); err != nil {
			t.Fatal(err)
		}
		h.settle()
		h.settle()
		if !d.removed[ids[name]] || slices.Contains(dialogRowKeys(d), ids[name]) {
			t.Fatalf("after the key: removed %v, rows %v", d.removed, dialogRowKeys(d))
		}
	}
	if len(d.rows) != 0 || len(p.runConfigs.list) != 2 {
		t.Fatalf("rows %v, configurations %v", dialogRowKeys(d), listedNames(p))
	}
	// Like −, the key only marks the removal: closing the dialog without Apply keeps both.
	h.app.post(func(a *App) {
		a.closeRunConfigDialog(p)
		a.openRunConfigDialog(p, ids["One"])
	})
	h.settle()
	if d.removed[ids["One"]] || len(d.rows) != 3 || d.selected != ids["One"] {
		t.Fatalf("after Cancel: removed %v rows %v selected %q", d.removed, dialogRowKeys(d), d.selected)
	}
}

// A copy of a plugin run is made by Core on Apply with every choice the original saved, and the
// original stays listed. Until then the pane holds the copy's name only.
func TestRunConfigDialogCopiesAPluginRun(t *testing.T) {
	root := t.TempDir()
	h, p := loadedRunConfigs(t, &testKernel{Client: core.NewClient()}, root)
	original := p.runConfigs.selected
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, original) })
	awaitStateWithin(t, h, 10*time.Second, "the original's editor", func() bool {
		draft := d.drafts[original]
		return draft != nil && draft.editor != nil && !draft.editor.loading
	})
	h.app.post(func(a *App) { a.copyRunConfigDraft(p) })
	h.settle()
	language := h.app.language()
	draft := d.drafts[d.selected]
	name := i18n.SharedFormat(language, "desktop.runConfig.copyName", map[string]string{"name": p.runConfigs.configuration(original).Name})
	if draft == nil || draft.copyOf != original || draft.copyName != name || !h.shows(i18n.Shared(language, "desktop.runConfig.copyPendingHint")) {
		t.Fatalf("copy %+v", draft)
	}
	if h.app.runConfigDialogRunnable(p) || p.runConfigCopyable(d.selected) {
		t.Fatal("a copy not made yet runs or copies")
	}
	applyDialog(t, h, p, runConfigDialogApply)
	if names := listedNames(p); len(names) != 2 || !slices.Contains(names, name) {
		t.Fatalf("configurations %v, failure %q", names, d.failure)
	}
	copied := d.selected
	if copied == original || p.runConfigs.configuration(copied) == nil || p.runConfigs.configuration(original) == nil {
		t.Fatalf("selected %q, original %q", copied, original)
	}
	document, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "plugin", "dev.example.engine.local.toml"))
	if err != nil || !strings.Contains(string(document), name) {
		t.Fatalf("the plugin's local document = %s, %v", document, err)
	}
	// The copy then opens in its own editor, as any plugin run does.
	awaitStateWithin(t, h, 10*time.Second, "the copy's editor", func() bool {
		draft := d.drafts[copied]
		return draft != nil && draft.copyOf == "" && draft.editor != nil && !draft.editor.loading
	})
}

// Off Windows a batch script is created, edited and saved like any other run, under a warning
// that it cannot run here: the dialog's Run is off, the tree marks it, and the title bar's Run
// says why instead of starting it.
func TestBatchRunIsEditedButNotRunOffWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows runs batch scripts")
	}
	h, p, root := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	f := newRunConfigDraft(t, h, p, runProviderBatch)
	if f.availability == nil || f.availability.Code != "unsupportedPlatform" {
		t.Fatalf("availability = %+v", f.availability)
	}
	fillScriptText(t, h, p, f, "Package", "@echo off\r\ncall build.cmd\r\n")
	h.settle()
	want := i18n.Shared(h.app.language(), "desktop.runConfig.unavailableBatchPlatform")
	if !h.shows(want) || h.app.runConfigDialogRunnable(p) || h.app.runConfigDraftUnavailable(p, d.selected) != want {
		t.Fatalf("warning shown %v, runnable %v", h.shows(want), h.app.runConfigDialogRunnable(p))
	}

	applyDialog(t, h, p, runConfigDialogOK)
	configuration := p.titleConfiguration()
	if d.open || configuration == nil || configuration.Name != "Package" || !configuration.Unavailable() {
		t.Fatalf("dialog open %v, title configuration %+v, failure %q / %q", d.open, configuration, d.failure, f.failure)
	}
	if got := h.app.runConfigUnavailableText(*configuration); got != want {
		t.Fatalf("unavailable text = %q, want %q", got, want)
	}
	if data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "local.yaml")); err != nil || !strings.Contains(string(data), "call build.cmd") {
		t.Fatalf("local.yaml = %s, %v", data, err)
	}

	h.app.post(func(a *App) { a.titleRun(p) })
	h.settle()
	if got := lastNotice(h); got != want || len(p.build.runs) != 0 {
		t.Fatalf("notice %q, want %q; runs %d", got, want, len(p.build.runs))
	}
}
