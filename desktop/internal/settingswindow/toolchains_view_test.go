package settingswindow

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

type fakeToolchainLoader struct {
	snapshot toolchain.Snapshot
	loaded   chan struct{}
	saved    chan []toolchain.Edit
	saveErr  error
}

func (f *fakeToolchainLoader) Load(context.Context) (toolchain.Snapshot, error) {
	if f.loaded != nil {
		close(f.loaded)
	}
	return f.snapshot, nil
}

func (f *fakeToolchainLoader) Save(_ context.Context, snapshot toolchain.Snapshot, edits []toolchain.Edit) (toolchain.Snapshot, error) {
	if f.saved != nil {
		select {
		case f.saved <- edits:
		default:
		}
	}
	if f.saveErr != nil {
		return snapshot, f.saveErr
	}
	// The page keeps painting from its own snapshot while this runs on the effect goroutine, and
	// that snapshot shares the Tools array with the argument. Like the real loader, which rereads
	// the project instead of editing its input, the fake returns a new array.
	snapshot.Tools = slices.Clone(snapshot.Tools)
	for _, edit := range edits {
		for index := range snapshot.Tools {
			if snapshot.Tools[index].ID == edit.Tool {
				snapshot.Tools[index].Pin = edit.Pin
			}
		}
	}
	return snapshot, nil
}

func fixtureSnapshot() toolchain.Snapshot {
	return toolchain.Snapshot{
		Root:      "/fixture",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:          "dev.example:compiler",
			DisplayName: "Compiler",
			PluginID:    "dev.example",
			Installations: []core.ToolchainInstallation{{
				Home: "/fixture/compiler", Version: "1.2.3", Provider: "host:system",
			}},
		}},
	}
}

// toolchainWindow opens a settings window on the Build page with loader and waits for its
// first load.
func toolchainWindow(t *testing.T, loader *fakeToolchainLoader) (*window, *windowDriver) {
	t.Helper()
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	w.sess.page = pageBuild
	d := openWindow(t, w)
	d.until("the toolchains to load", func() bool { return w.toolchains.loaded })
	return w, d
}

func installationLabel() string {
	return i18n.SharedFormat(i18n.English, "desktop.toolchains.installation", map[string]string{
		"home": "/fixture/compiler", "version": "1.2.3", "provider": "host:system",
	})
}

func TestToolchainDraftSavesOnlyExplicitChanges(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	if len(state.snapshot.Tools) != 1 {
		t.Fatalf("load state = %+v", state)
	}
	if state.hasDraft() {
		t.Fatal("a freshly loaded page already had a draft")
	}
	save := i18n.Shared(i18n.English, "desktop.toolchains.save")
	if !d.hit(save).Disabled {
		t.Fatal("Save is enabled without a draft")
	}
	d.click(installationLabel())
	if !state.hasDraft() {
		t.Fatal("choosing an installation did not create a draft")
	}
	select {
	case edits := <-loader.saved:
		t.Fatalf("choosing wrote %+v", edits)
	default:
	}
	d.click(save)
	d.until("the save to finish", func() bool { return state.saved })
	select {
	case edits := <-loader.saved:
		if len(edits) != 1 || edits[0].Pin == nil || edits[0].Pin.Home != "/fixture/compiler" {
			t.Fatalf("edits = %+v", edits)
		}
	default:
		t.Fatal("save was not requested")
	}
	if state.snapshot.Tools[0].Pin == nil {
		t.Fatalf("saved state = %+v", state)
	}
}

func TestToolchainDraftCancelWritesNothing(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1)}
	w, d := toolchainWindow(t, loader)
	d.click(installationLabel())
	d.click("Cancel")
	select {
	case edits := <-loader.saved:
		t.Fatalf("cancel wrote %+v", edits)
	default:
	}
	if !w.toolchains.hasDraft() {
		t.Fatal("cancel must keep the draft until the window is gone")
	}
	if !w.sess.finished.Load() {
		t.Fatal("Cancel did not end the session")
	}
}

func TestToolchainSaveConflictKeepsDraft(t *testing.T) {
	loader := &fakeToolchainLoader{
		snapshot: fixtureSnapshot(), saved: make(chan []toolchain.Edit, 1),
		saveErr: toolchain.ErrPinConflict,
	}
	w, d := toolchainWindow(t, loader)
	state := w.toolchains
	d.click(installationLabel())
	d.click(i18n.Shared(i18n.English, "desktop.toolchains.save"))
	d.until("the conflict", func() bool { return state.failed != nil })
	message := toolchainFailureMessage(i18n.Chinese, state.failed)
	if !strings.Contains(message, "重新加载") || strings.Contains(message, toolchain.ErrPinConflict.Error()) {
		t.Fatalf("conflict did not use the selected language: %q", message)
	}
	if !d.text(toolchainFailureMessage(i18n.English, state.failed)) {
		t.Fatal("the conflict is not on the page")
	}
	if state.snapshot.Tools[0].Pin != nil {
		t.Fatal("a conflict changed the displayed pin")
	}
	if !state.hasDraft() {
		t.Fatal("a conflict dropped the draft")
	}
}

// A completed publication with failed readback must never reuse its old byte
// baseline, even when the user's draft remains visible for recovery.
func TestToolchainCommittedSaveRequiresReloadBeforeRetry(t *testing.T) {
	state := newToolchainState(&fakeToolchainLoader{})
	state.apply(fixtureSnapshot(), false)
	state.choose("dev.example:compiler", "/fixture/compiler")
	state.finish(toolchain.Snapshot{}, toolchain.ErrPinCommitted, true)
	if state.loaded {
		t.Error("failed readback left an editable source baseline")
	}
	if !state.hasDraft() {
		t.Error("failed readback discarded the draft")
	}
	state.beginSave()
	if state.saving {
		t.Error("retry reused a baseline from before the committed save")
	}
}

func TestToolchainSourceFailuresUseSelectedLanguage(t *testing.T) {
	for _, code := range []string{"plugin.toolchain.invalidDocument", "plugin.toolchain.invalidIgnore"} {
		message := toolchainFailureMessage(i18n.Chinese, &core.MarketplaceRejection{Code: code, Message: "invalid fixture diagnostic"})
		if !strings.Contains(message, "重新加载") || strings.Contains(message, "fixture") {
			t.Fatalf("source failure was not localized: %q", message)
		}
	}
}
