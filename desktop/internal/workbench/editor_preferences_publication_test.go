package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestEditorPreferencesPublicationProtectsEveryWindowSave(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	source := h.app.sessions.active
	// Independent native windows may create separate Store objects for one directory.
	second := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(h.store.Dir()), Languages: []string{"en"}})
	other := newHarness(t, &testKernel{Client: core.NewClient()})
	otherBefore := other.app.editorPreferences
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	set := func(on bool, colors []string) (core.EditorStoredPreferences, core.EditorPreferences) {
		t.Helper()
		stored := core.EditorStoredPreferences{
			RainbowBrackets: &on, RainbowVariables: &on,
			RainbowLightColors: colors,
			RainbowDarkColors:  []string{"#AABBCC", "#DDEEFF"},
		}
		resolved, err := core.NewClient().ResolveEditorPreferences(ctx, stored)
		if err != nil {
			t.Fatal(err)
		}
		source.setEditorPreferences(stored, resolved)
		return stored, resolved
	}
	_, _ = set(false, []string{"#112233", "#445566"})
	wantStored, wantResolved := set(true, []string{"#223344", "#556677"})
	// Save an unrelated preference before either target handles a wake. A stale
	// whole-settings write must not restore the old rainbow preferences on disk.
	for _, target := range []*App{h.app, second.app} {
		target.settings.HideProjectColors = true
		target.saveSettings()
		var saved settings
		if _, err := h.store.Load(settingsFile, &saved); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(saved.EditorPreferences, wantStored) {
			t.Fatalf("unrelated save restored stale editor preferences: %+v", saved.EditorPreferences)
		}
		target.drain()
		if !reflect.DeepEqual(target.editorPreferences, wantResolved) || !reflect.DeepEqual(target.settings.EditorPreferences, wantStored) {
			t.Fatalf("target did not receive the latest editor preferences: %+v", target.editorPreferences)
		}
	}
	other.app.drain()
	if !reflect.DeepEqual(other.app.editorPreferences, otherBefore) {
		t.Fatal("editor preferences leaked into another preferences directory")
	}
	// Retiring a project or closing a window releases its delivery ownership.
	second.app.unsubscribeSettings()
	_, _ = set(false, []string{"#778899", "#AABBCC"})
	second.app.drain()
	if !reflect.DeepEqual(second.app.editorPreferences, wantResolved) {
		t.Fatal("a closed window received a later editor preference change")
	}
}

func TestEditorPreferencesWatchReadsExternalChangesAndPreservesThemOnSave(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	on := true
	want := core.EditorStoredPreferences{RainbowVariables: &on, RainbowLightColors: []string{"#123456", "#ABCDEF"}}
	// A separate client has its own Store and no in-process publication. Write
	// before this client handles the directory notification, then save locally.
	external := store.At(h.store.Dir())
	if err := external.Save(settingsFile, settings{Theme: themeDark, EditorPreferences: want}); err != nil {
		t.Fatal(err)
	}
	h.app.settings.HideProjectColors = true
	h.app.saveSettings()
	var saved settings
	if _, err := external.Load(settingsFile, &saved); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(saved.EditorPreferences, want) {
		t.Fatal("a local save overwrote another client's newer editor preferences")
	}
	h.await("external editor preferences to reach the current window", func() bool {
		return reflect.DeepEqual(h.app.settings.EditorPreferences, want)
	})
	if !h.app.editorPreferences.RainbowVariables || !reflect.DeepEqual(h.app.editorPreferences.RainbowLightColors, want.RainbowLightColors) {
		t.Fatal("the external settings source did not reach editor presentation")
	}
}

func TestEditorPreferencesContendedSaveKeepsTheLatestSnapshot(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	unlock, err := filelock.Acquire(ctx, filepath.Join(h.store.Dir(), ".settings.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if unlock != nil {
			if err := unlock(); err != nil {
				t.Error(err)
			}
		}
	}()
	on := true
	want := core.EditorStoredPreferences{RainbowVariables: &on}
	resolved, err := core.NewClient().ResolveEditorPreferences(ctx, want)
	if err != nil {
		t.Fatal(err)
	}
	h.app.setEditorPreferences(want, resolved)
	h.app.settings.HideProjectColors = true
	h.app.saveSettings()
	var before settings
	if _, err := h.store.Load(settingsFile, &before); err != nil {
		t.Fatal(err)
	}
	if before.EditorPreferences.RainbowVariables != nil {
		t.Fatal("saving ignored another process's settings transaction lock")
	}
	if err := unlock(); err != nil {
		t.Fatal(err)
	}
	unlock = nil
	h.settle()
	var saved settings
	if _, err := h.store.Load(settingsFile, &saved); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(saved.EditorPreferences, want) || !saved.HideProjectColors {
		t.Fatalf("contended settings writes did not retain the latest snapshot: %+v", saved)
	}
}

func TestEditorPreferencesLeavesInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	preferences, err := store.Open()
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, preferences.Dir())
	if err := preferences.Save(settingsFile, settings{Theme: themeDark}); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: preferences, Languages: []string{"en"}})
	on := true
	stored := core.EditorStoredPreferences{RainbowVariables: &on}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveEditorPreferences(ctx, stored)
	if err != nil {
		t.Fatal(err)
	}
	h.app.setEditorPreferences(stored, resolved)
	h.settle()
	installedpackagetest.Outside(t, filepath.Join(preferences.Dir(), ".settings.lock"))
}

func TestEditorPreferencesFailedUnrelatedSaveDoesNotDiscardExternalRead(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	state := h.app.settingsSubscription.editorPreferences
	// Capture an in-flight source-read boundary before an unrelated save. The
	// completion is delivered explicitly, without racing native watcher timing.
	state.Lock()
	generation := state.latest.generation
	state.reading = true
	state.Unlock()
	on := true
	want := core.EditorStoredPreferences{RainbowVariables: &on}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveEditorPreferences(ctx, want)
	if err != nil {
		t.Fatal(err)
	}
	// A directory cannot serve as the transaction lock. This save advances the
	// attempted-save sequence and fails before replacing settings.json.
	lockPath := filepath.Join(h.store.Dir(), ".settings.lock")
	if err := os.Remove(lockPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if err := os.Mkdir(lockPath, 0o700); err != nil {
		t.Fatal(err)
	}
	h.app.settings.HideProjectColors = true
	if _, err := h.app.saveSettingsSnapshot(); err == nil {
		t.Fatal("the invalid transaction lock did not reject the unrelated save")
	}
	state.completeEditorPreferencesRead(want, resolved, generation, nil)
	h.app.drain()
	if !reflect.DeepEqual(h.app.settings.EditorPreferences, want) || !h.app.editorPreferences.RainbowVariables {
		t.Fatal("a failed unrelated save discarded the completed external preferences read")
	}
}
