package settingswindow

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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

func waitFor(t *testing.T, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the toolchain worker")
	}
}

func TestToolchainDraftSavesOnlyExplicitChanges(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), loaded: make(chan struct{}), saved: make(chan []toolchain.Edit, 1)}
	wake := make(chan struct{}, 2)
	state := newToolchainState(loader, func() { wake <- struct{}{} })
	state.beginLoad()
	waitFor(t, loader.loaded)
	waitFor(t, wake)
	state.drain()
	if !state.loaded || len(state.snapshot.Tools) != 1 {
		t.Fatalf("load state = %+v", state)
	}
	if state.hasDraft() {
		t.Fatal("a freshly loaded page already had a draft")
	}
	state.choose("dev.example:compiler", "/fixture/compiler")
	if !state.hasDraft() {
		t.Fatal("choosing an installation did not create a draft")
	}
	state.beginSave()
	waitFor(t, wake)
	select {
	case edits := <-loader.saved:
		if len(edits) != 1 || edits[0].Pin == nil || edits[0].Pin.Home != "/fixture/compiler" {
			t.Fatalf("edits = %+v", edits)
		}
	default:
		t.Fatal("save was not requested")
	}
	state.drain()
	if state.saved != true || state.snapshot.Tools[0].Pin == nil {
		t.Fatalf("saved state = %+v", state)
	}
}

func TestToolchainDraftCancelWritesNothing(t *testing.T) {
	loader := &fakeToolchainLoader{snapshot: fixtureSnapshot(), loaded: make(chan struct{}), saved: make(chan []toolchain.Edit, 1)}
	wake := make(chan struct{}, 2)
	state := newToolchainState(loader, func() { wake <- struct{}{} })
	state.beginLoad()
	waitFor(t, loader.loaded)
	waitFor(t, wake)
	state.drain()
	state.choose("dev.example:compiler", "/fixture/compiler")
	state.close()
	select {
	case edits := <-loader.saved:
		t.Fatalf("cancel wrote %+v", edits)
	default:
	}
	if !state.hasDraft() {
		t.Fatal("cancel must keep the draft until the window is gone")
	}
}

func TestToolchainSaveConflictKeepsDraft(t *testing.T) {
	loader := &fakeToolchainLoader{
		snapshot: fixtureSnapshot(), loaded: make(chan struct{}), saved: make(chan []toolchain.Edit, 1),
		saveErr: toolchain.ErrPinConflict,
	}
	wake := make(chan struct{}, 2)
	state := newToolchainState(loader, func() { wake <- struct{}{} })
	state.beginLoad()
	waitFor(t, loader.loaded)
	waitFor(t, wake)
	state.drain()
	state.choose("dev.example:compiler", "/fixture/compiler")
	state.beginSave()
	waitFor(t, wake)
	state.drain()
	if state.failed == "" {
		t.Fatal("a conflict was reported as success")
	}
	if state.snapshot.Tools[0].Pin != nil {
		t.Fatal("a conflict changed the displayed pin")
	}
	if !state.hasDraft() {
		t.Fatal("a conflict dropped the draft")
	}
}
