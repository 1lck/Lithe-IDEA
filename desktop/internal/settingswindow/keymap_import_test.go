package settingswindow

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/keymapimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/ui"
)

func shortcutImportFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "keybindings.json")
	if err := os.WriteFile(path, []byte(`[{"command":"workbench.action.gotoLine","key":"ctrl+alt+g"}]`), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func importWindow(t *testing.T) (*window, *[]core.KeymapSchemeResult) {
	t.Helper()
	var saved []core.KeymapSchemeResult
	w := newWindow(NewController(Options{SetKeymapSchemes: func(value core.KeymapSchemeResult) { saved = append(saved, value) }}), Values{Language: "en"})
	w.sess.page = pageKeymap
	// Normalize through the same read-only reducer used by opening the Keymap page.
	if !w.reduceScheme(core.KeymapSchemeRequest{}) {
		t.Fatal(w.scheme.failure)
	}
	w.openKeymapImport()
	return w, &saved
}
func importPreview(t *testing.T, w *window, path string) keymapImportResult {
	t.Helper()
	state, current := w.keymapImportInputs()
	work := &keymapImportWork{Path: path, Format: "vscode", State: state, Current: current}
	result, err := runKeymapImport(t.Context(), work)
	if err != nil {
		t.Fatal(err)
	}
	w.keyImport.request = work
	w.finishKeymapImport(result, nil)
	return result
}
func TestBuiltinKeymapImportCreatesIndependentSchemeOnlyAfterConfirmation(t *testing.T) {
	w, saved := importWindow(t)
	original := w.sess.values.KeymapSchemes
	preview := importPreview(t, w, shortcutImportFile(t))
	if len(*saved) != 0 || !reflect.DeepEqual(w.sess.values.KeymapSchemes, original) {
		t.Fatal("preview wrote settings")
	}
	state, current := w.keymapImportInputs()
	work := &keymapImportWork{Format: "vscode", Name: "Imported keys", Snapshot: preview.Snapshot, State: state, Current: current, Apply: true}
	result, err := runKeymapImport(t.Context(), work)
	if err != nil {
		t.Fatal(err)
	}
	if len(*saved) != 0 {
		t.Fatal("background work published before baseline check")
	}
	w.keyImport.request = work
	w.finishKeymapImport(result, nil)
	if len(*saved) != 1 || len(w.sess.values.KeymapSchemes.Schemes) != 2 || w.sess.values.KeymapSchemes.Active == "default" {
		t.Fatalf("scheme not published: %+v", w.sess.values.KeymapSchemes)
	}
	if !reflect.DeepEqual(w.sess.values.Keymap[shortcuts.GoToLine], []string{"ctrl+alt+g"}) {
		t.Fatal("keys not applied")
	}
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "select", ID: "default"}) || len(w.sess.values.Keymap) != 0 {
		t.Fatal("original scheme changed")
	}
}
func TestBuiltinKeymapImportCancelAndStaleResultNeverPublish(t *testing.T) {
	for _, mode := range []string{"cancel", "changed"} {
		t.Run(mode, func(t *testing.T) {
			w, saved := importWindow(t)
			preview := importPreview(t, w, shortcutImportFile(t))
			state, current := w.keymapImportInputs()
			work := &keymapImportWork{Format: "vscode", Name: "Imported keys", Snapshot: preview.Snapshot, State: state, Current: current, Apply: true}
			result, err := runKeymapImport(t.Context(), work)
			if err != nil {
				t.Fatal(err)
			}
			w.keyImport.request = work
			if mode == "cancel" {
				w.keyImport.open = false
			} else {
				w.sess.values.Keymap = shortcuts.Overrides{shortcuts.GoToLine: []string{"alt+g"}}
			}
			w.finishKeymapImport(result, nil)
			if len(*saved) != 0 || len(w.sess.values.KeymapSchemes.Schemes) != 1 {
				t.Fatal("stale/canceled result published")
			}
			if mode == "changed" && !errors.Is(w.keyImport.failure, errKeymapImportStale) {
				t.Fatal("missing stale diagnostic")
			}
		})
	}
}
func TestBuiltinKeymapImportRejectsEditedSourceAndDuplicateNamesWithoutPartialScheme(t *testing.T) {
	w, saved := importWindow(t)
	path := shortcutImportFile(t)
	preview := importPreview(t, w, path)
	state, current := w.keymapImportInputs()
	work := &keymapImportWork{Format: "vscode", Name: "Copy", Snapshot: preview.Snapshot, State: state, Current: current, Apply: true}
	if err := os.WriteFile(path, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := runKeymapImport(t.Context(), work); !errors.Is(err, keymapimport.ErrChanged) {
		t.Fatalf("stale source allowed: %v", err)
	}
	preview = importPreview(t, w, shortcutImportFile(t))
	// Existing user name participates in the same scheme reducer validation.
	state.Schemes = append(state.Schemes, core.KeymapScheme{ID: "existing", Name: "Copy", Bindings: map[string][]string{}})
	work.Snapshot, work.State = preview.Snapshot, state
	if _, err := runKeymapImport(t.Context(), work); err == nil {
		t.Fatal("duplicate name accepted")
	}
	if len(*saved) != 0 || len(w.sess.values.KeymapSchemes.Schemes) != 1 {
		t.Fatal("failure partially published")
	}
}
func TestBuiltinKeymapImportVivaPreviewAndCancel(t *testing.T) {
	w, saved := importWindow(t)
	importPreview(t, w, shortcutImportFile(t))
	w.keyImport.name.SetText("Imported keys")
	d := openWindow(t, w)
	d.pump()
	if !d.has(i18n.Shared(i18n.English, "desktop.keymapImport.apply")) || !d.text(w.keymapImportActionTitle(shortcuts.GoToLine)) {
		t.Fatal("preview controls missing")
	}
	d.click(w.text.Settings.Cancel)
	d.pump()
	if w.keyImport.open || len(*saved) != 0 {
		t.Fatal("Cancel did not preserve settings")
	}
}
func TestBuiltinKeymapImportCopiesExplicitEmptyBindingsAndLogsSafeFailures(t *testing.T) {
	w, _ := importWindow(t)
	w.sess.values.Keymap = shortcuts.Overrides{"editor.find": []string{}}
	_, current := w.keymapImportInputs()
	if !reflect.DeepEqual(current, w.sess.values.Keymap) {
		t.Fatal("empty binding baseline changed during capture")
	}
	var logged error
	w.ctrl.opts.SettingsError = func(operation string, err error) {
		if operation != "keymap_import" {
			t.Fatalf("wrong operation %s", operation)
		}
		logged = err
	}
	state, current := w.keymapImportInputs()
	w.keyImport.request = &keymapImportWork{State: state, Current: current}
	w.finishKeymapImport(keymapImportResult{}, keymapimport.ErrDocument)
	if logged == nil || strings.Contains(logged.Error(), "keybindings.json") {
		t.Fatal("missing safe diagnostic")
	}
}

// Drive the real page-owned effect instead of injecting its completed result.
func TestBuiltinKeymapImportPageEffectFinishesAndPublishes(t *testing.T) {
	w, saved := importWindow(t)
	state, current := w.keymapImportInputs()
	w.startKeymapImport(&keymapImportWork{Path: shortcutImportFile(t), Format: "vscode", State: state, Current: current})
	d := openWindow(t, w)
	d.until("shortcut preview effect", func() bool { return !w.keyImport.busy })
	if !w.keyImport.ready || len(*saved) != 0 {
		t.Fatalf("preview did not finish: ready=%v err=%v", w.keyImport.ready, w.keyImport.failure)
	}
	w.keyImport.name.SetText("Native effect scheme")
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.keymapImport.apply"))
	d.until("shortcut scheme publication", func() bool { return len(*saved) == 1 })
	if w.keyImport.open {
		t.Fatal("successful import did not close")
	}
}

// A file picker returns after the frame's After callbacks. Starting work there
// must wake an otherwise idle native window; forced repaints would hide this bug.
func TestBuiltinKeymapImportFilePickerCompletionWakesIdlePage(t *testing.T) {
	w, _ := importWindow(t)
	d := openWindow(t, w)
	d.pump()
	started := make(chan struct{}, 1)
	w.keyImport.effect = ui.NewEffectKeyed[keymapImportResult, *keymapImportWork](func(ctx context.Context, work *keymapImportWork) (keymapImportResult, error) {
		started <- struct{}{}
		return runKeymapImport(ctx, work)
	})
	state, current := w.keymapImportInputs()
	w.startKeymapImport(&keymapImportWork{Path: shortcutImportFile(t), Format: "vscode", State: state, Current: current})
	d.pump()
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("file picker completion did not wake the idle page or start the import")
	}
	d.until("shortcut preview completion", func() bool { return !w.keyImport.busy })
	if !w.keyImport.ready {
		t.Fatal(w.keyImport.failure)
	}
}
