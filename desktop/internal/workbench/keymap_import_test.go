package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/keymapimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
)

// The settings page's effect has its own driver tests. This exercises its output
// across the remaining boundary: persisted schemes and real workbench key events.
func TestBuiltinKeymapImportShortcutsWorkAndSurviveReload(t *testing.T) {
	for _, source := range []struct {
		format, content string
		key             rune
	}{
		{"vscode", `[{"command":"workbench.action.gotoLine","key":"ctrl+alt+g"}]`, 'g'},
		{"idea", `<keymap name="test"><action id="GotoLine"><keyboard-shortcut first-keystroke="ctrl alt J"/></action></keymap>`, 'j'},
	} {
		t.Run(source.format, func(t *testing.T) {
			h, _, _ := essentialsDocument(t, strings.Repeat("example line\n", 90))
			catalog := make([]keymapimport.Action, 0)
			for _, action := range shortcuts.All() {
				keys := make([]string, 0)
				for _, chord := range h.app.settings.Keymap.Effective(action) {
					keys = append(keys, shortcuts.Encode(chord))
				}
				catalog = append(catalog, keymapimport.Action{ID: action.ID, Keys: keys, Customized: h.app.settings.Keymap.Changed(action.ID)})
			}
			path := filepath.Join(t.TempDir(), "keys")
			if err := os.WriteFile(path, []byte(source.content), 0600); err != nil {
				t.Fatal(err)
			}
			snapshot, err := keymapimport.Read(t.Context(), path)
			if err != nil {
				t.Fatal(err)
			}
			preview, err := keymapimport.Parse(source.format, snapshot.Content(), catalog)
			if err != nil || len(preview.Imported) != 1 || len(preview.Conflicts) != 0 {
				t.Fatalf("preview=%+v error=%v", preview, err)
			}
			client := core.NewClient()
			copied, err := client.ReduceKeymapSchemes(t.Context(), core.KeymapSchemeRequest{State: h.app.settings.KeymapSchemes, Current: h.app.settings.Keymap, Operation: "saveAs", ID: "imported", Name: "Imported keys"})
			if err != nil {
				t.Fatal(err)
			}
			imported, err := client.ReduceKeymapSchemes(t.Context(), core.KeymapSchemeRequest{State: copied.State, Operation: "update", Bindings: preview.Proposal})
			if err != nil {
				t.Fatal(err)
			}
			// Publish the same result as SetKeymapSchemes, then paint fresh bindings.
			h.app.settings.KeymapSchemes = imported.State
			h.app.settings.Keymap = shortcuts.Overrides(imported.Bindings)
			h.app.saveSettings()
			h.app.invalidator.Invalidate()
			h.settleChain()
			assertImportedGoToLine(t, h, source.key, "42:1", 41)
			// A new App reads the actual saved store, with no in-memory keymap injection.
			reloaded := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: client}, Store: h.store, Languages: []string{"en-US"}})
			reloaded.open(h.app.project.root)
			reloaded.app.openFile(reloaded.app.project, h.app.project.selectedDocument(h.app.project.docs.group).path)
			reloaded.settleChain()
			if reloaded.app.settings.KeymapSchemes.Active != "imported" {
				t.Fatal("saved scheme was not selected after reload")
			}
			assertImportedGoToLine(t, reloaded, source.key, "73:1", 72)
			defaults, err := client.ReduceKeymapSchemes(t.Context(), core.KeymapSchemeRequest{State: reloaded.app.settings.KeymapSchemes, Current: reloaded.app.settings.Keymap, Operation: "select", ID: "default"})
			if err != nil {
				t.Fatal(err)
			}
			reloaded.app.settings.KeymapSchemes = defaults.State
			reloaded.app.settings.Keymap = shortcuts.Overrides(defaults.Bindings)
			reloaded.app.invalidator.Invalidate()
			reloaded.settleChain()
			if _, err := reloaded.driver.ShortcutChord(gfx.ModifierControl|gfx.ModifierAlt, source.key); err != nil {
				t.Fatal(err)
			}
			if reloaded.app.navigation.open {
				t.Fatal("imported shortcut remained active after selecting Default")
			}
			modifier, key := gfx.ModifierControl, 'g'
			if runtime.GOOS == "darwin" {
				modifier, key = gfx.ModifierMeta, 'l'
			}
			if handled, err := reloaded.driver.ShortcutChord(modifier, key); err != nil || !handled {
				t.Fatalf("default shortcut handled=%v error=%v", handled, err)
			}
			awaitDocumentState(t, reloaded, func() bool { return reloaded.app.navigation.target != nil })
			if err := reloaded.driver.Key(gfx.KeyEscape, 0); err != nil {
				t.Fatal(err)
			}
			unchanged, err := os.ReadFile(path)
			if err != nil || string(unchanged) != source.content {
				t.Fatal("import changed the source file")
			}
		})
	}
}

func assertImportedGoToLine(t *testing.T, h *harness, key rune, input string, wantLine int) {
	t.Helper()
	h.app.navigation.delay = -1
	doc := h.app.project.selectedDocument(h.app.project.docs.group)
	awaitDocumentState(t, h, func() bool { return doc.view.Owns(h.driver.Snapshot().Focused) })
	if handled, err := h.driver.ShortcutChord(gfx.ModifierControl|gfx.ModifierAlt, key); err != nil || !handled {
		t.Fatalf("imported shortcut handled=%v error=%v", handled, err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	if err := h.driver.Type(input); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.validated == input })
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !h.app.navigation.open })
	line, column := doc.view.CaretUTF16()
	if line != wantLine || column != 0 {
		t.Fatalf("caret=%d:%d, want=%d:0", line, column, wantLine)
	}
}
