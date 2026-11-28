package settingswindow

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

type fakeFileTypeMappingsSource struct {
	snap      FileTypeMappingsSnapshot
	loadCalls int
	saveCalls int
	saveErr   error
	issues    []core.FileTypeMappingIssue
}

func (f *fakeFileTypeMappingsSource) Load(context.Context) (FileTypeMappingsSnapshot, error) {
	f.loadCalls++
	return cloneFileTypeMappingsSnapshot(f.snap), nil
}

func (f *fakeFileTypeMappingsSource) Save(_ context.Context, _, next FileTypeMappingsSnapshot) (FileTypeMappingsSaveResult, error) {
	f.saveCalls++
	if f.saveErr != nil {
		return FileTypeMappingsSaveResult{}, f.saveErr
	}
	if len(f.issues) > 0 {
		return FileTypeMappingsSaveResult{Issues: append([]core.FileTypeMappingIssue(nil), f.issues...)}, nil
	}
	f.snap.Global = append([]core.FileTypeMapping(nil), next.Global...)
	f.snap.Project = append([]core.FileTypeMapping(nil), next.Project...)
	return FileTypeMappingsSaveResult{Snapshot: cloneFileTypeMappingsSnapshot(f.snap)}, nil
}

func waitFileTypeMappingsPage(t *testing.T, d *windowDriver, ready func() bool) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	d.pump()
	for !ready() {
		select {
		case <-d.driver.Wakes():
			d.pump()
		case <-deadline.C:
			t.Fatal("file type mappings settings page did not settle before deadline")
		}
	}
}

func TestFileTypeMappingsPageAddSaveDiscardAndConflict(t *testing.T) {
	src := &fakeFileTypeMappingsSource{
		snap: FileTypeMappingsSnapshot{
			HasWorkspace:       true,
			WorkspaceRoot:      "/tmp/demo",
			GlobalConfigPath:   "/tmp/store/file-type-mappings.json",
			ProjectConfigPath:  "/tmp/demo/.lithe/file-type-mappings.json",
			GlobalFingerprint:  "missing",
			ProjectFingerprint: "missing",
			Builtins: []core.FileTypeMapping{
				{Pattern: "uv.lock", LanguageID: "toml"},
				{Pattern: "bun.lock", LanguageID: "jsonc"},
			},
			KnownLanguageIDs: []string{"json", "jsonc", "toml", "yaml"},
		},
	}
	w := newWindow(NewController(Options{FileTypeMappings: src}), Values{Language: "en", Theme: "dark"})
	w.sess.page = pageFileTypeMappings
	d := openWindow(t, w)
	waitFileTypeMappingsPage(t, d, func() bool { return w.fileTypeDraft.ready && !w.fileTypeDraft.busy })
	if src.loadCalls != 1 || src.saveCalls != 0 {
		t.Fatalf("expected 1 load and 0 saves on open, got load=%d save=%d", src.loadCalls, src.saveCalls)
	}

	// Add rule and save.
	w.fileTypeDraft.patternField.SetText("*.lock")
	w.fileTypeDraft.langPick = "toml"
	w.inv.Invalidate()
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.add"))
	d.pump()
	if !w.fileTypeDraft.dirty || len(w.fileTypeDraft.working.Global) != 1 {
		t.Fatalf("expected dirty draft with 1 global rule, got dirty=%v rules=%+v", w.fileTypeDraft.dirty, w.fileTypeDraft.working.Global)
	}
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.save"))
	waitFileTypeMappingsPage(t, d, func() bool { return !w.fileTypeDraft.busy })
	if src.saveCalls != 1 || w.fileTypeDraft.dirty || !w.fileTypeDraft.saved || len(src.snap.Global) != 1 {
		t.Fatalf("save did not persist: saveCalls=%d dirty=%v saved=%v global=%+v", src.saveCalls, w.fileTypeDraft.dirty, w.fileTypeDraft.saved, src.snap.Global)
	}

	// Validation rejection keeps draft.
	src.issues = []core.FileTypeMappingIssue{{Scope: "global", Index: 0, Code: "invalid_pattern", Pattern: "/bad", LanguageID: "toml"}}
	w.fileTypeDraft.patternField.SetText("/bad")
	w.inv.Invalidate()
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.add"))
	d.pump()
	if !w.fileTypeDraft.dirty || len(w.fileTypeDraft.working.Global) != 2 {
		t.Fatalf("expected dirty draft with 2 global rules before save, got dirty=%v rules=%+v", w.fileTypeDraft.dirty, w.fileTypeDraft.working.Global)
	}
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.save"))
	waitFileTypeMappingsPage(t, d, func() bool { return !w.fileTypeDraft.busy })
	if w.fileTypeDraft.failure == "" || !w.fileTypeDraft.dirty || len(w.fileTypeDraft.working.Global) != 2 {
		t.Fatalf("validation rejection did not keep draft or show failure: failure=%q dirty=%v", w.fileTypeDraft.failure, w.fileTypeDraft.dirty)
	}

	// Discard restores snapshot.
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.discard"))
	d.pump()
	if w.fileTypeDraft.dirty || len(w.fileTypeDraft.working.Global) != 1 {
		t.Fatalf("discard did not restore snapshot: dirty=%v rules=%+v", w.fileTypeDraft.dirty, w.fileTypeDraft.working.Global)
	}

	// Conflict keeps draft and marks stale; reload clears stale.
	src.issues = nil
	src.saveErr = ErrFileTypeMappingsConflict
	w.fileTypeDraft.patternField.SetText("*.cfg")
	w.inv.Invalidate()
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.add"))
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.save"))
	waitFileTypeMappingsPage(t, d, func() bool { return !w.fileTypeDraft.busy })
	if !w.fileTypeDraft.stale || !w.fileTypeDraft.dirty || w.fileTypeDraft.failure == "" {
		t.Fatalf("conflict did not mark stale/keep draft: stale=%v dirty=%v failure=%q", w.fileTypeDraft.stale, w.fileTypeDraft.dirty, w.fileTypeDraft.failure)
	}
	src.saveErr = nil
	d.click(i18n.Shared(w.marketLanguage(), "desktop.fileTypeMappings.refresh"))
	waitFileTypeMappingsPage(t, d, func() bool { return !w.fileTypeDraft.busy && !w.fileTypeDraft.stale })
	if w.fileTypeDraft.dirty || len(w.fileTypeDraft.working.Global) != 1 {
		t.Fatalf("reload did not refresh state: dirty=%v rules=%+v", w.fileTypeDraft.dirty, w.fileTypeDraft.working.Global)
	}
}

func TestFileTypeMappingsPageWithoutWorkspaceDisablesProjectEditing(t *testing.T) {
	src := &fakeFileTypeMappingsSource{
		snap: FileTypeMappingsSnapshot{
			HasWorkspace:     false,
			GlobalConfigPath: "/tmp/store/file-type-mappings.json",
			KnownLanguageIDs: []string{"toml", "json"},
		},
	}
	w := newWindow(NewController(Options{FileTypeMappings: src}), Values{Language: "en", Theme: "light"})
	w.sess.page = pageFileTypeMappings
	d := openWindow(t, w)
	waitFileTypeMappingsPage(t, d, func() bool { return w.fileTypeDraft.ready && !w.fileTypeDraft.busy })
	w.fileTypeDraft.scope = fileTypeScopeProject
	w.inv.Invalidate()
	d.pump()
	if w.fileTypeDraft.scopeEditable() {
		t.Fatal("project scope must not be editable when no workspace is open")
	}
	if _, err := src.Save(t.Context(), src.snap, src.snap); err != nil {
		t.Fatal(err)
	}
	_ = errors.New("unused")
}
