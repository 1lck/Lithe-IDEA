package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
		a.addRunConfigDraft(p, runProviderShell, nil)
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
		a.addRunConfigDraft(p, runProviderExecutable, nil)
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
	h.app.post(func(a *App) { a.copyRunConfigDraft(p) })
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
	applyDialog(t, h, p, runConfigDialogOK)
	if names := listedNames(p); len(names) != 2 {
		t.Fatalf("configurations %v, failure %q", names, d.failure)
	}
}

// Closing the group of the selected configuration leaves the selection on the group's row, and
// the group stays closed when the dialog opens again.
func TestRunConfigDialogGroupsClose(t *testing.T) {
	h, p, _ := emptyProcessRunHarness(t)
	d := &p.runConfigs.dialog
	newRunConfigDraft(t, h, p, runProviderShell)
	h.settle()
	group := runProcessKindKey(runProviderShell)
	if len(d.rows) != 2 || d.runConfigDialogRowIndex() != 1 {
		t.Fatalf("rows %+v, selected row %d", d.rows, d.runConfigDialogRowIndex())
	}
	h.app.post(func(*App) { p.toggleRunConfigDialogGroup(group) })
	h.settle()
	if d.selected != "" || d.group != group || len(d.rows) != 1 || d.runConfigDialogRowIndex() != 0 {
		t.Fatalf("selected %q group %q rows %+v", d.selected, d.group, d.rows)
	}
	h.app.post(func(a *App) {
		a.closeRunConfigDialog(p)
		a.openRunConfigDialog(p, "")
	})
	if !d.closed[group] {
		t.Fatal("the closed group opened again with the dialog")
	}
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
