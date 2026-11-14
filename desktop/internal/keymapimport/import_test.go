package keymapimport

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func importCatalog() []Action {
	return []Action{
		{ID: "editor.find", Keys: []string{"meta+f"}},
		{ID: "navigate.gotoLine", Keys: []string{"meta+l"}},
		{ID: "search.findAction", Keys: []string{"meta+shift+a"}},
		{ID: "debug.toggleBreakpoint", Keys: []string{"f9"}},
	}
}
func TestImportVSCodeJSONCAndExplicitAliases(t *testing.T) {
	content := "\ufeff[ // user override\n" + `{"command":"workbench.action.gotoLine","key":"SHIFT+CMD+G",},` + `{"command":"actions.find","key":"ctrl++"},]`
	p, err := Parse("vscode", content, importCatalog())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.Proposal["navigate.gotoLine"], []string{"shift+meta+g"}) || !reflect.DeepEqual(p.Proposal["editor.find"], []string{"ctrl++"}) {
		t.Fatalf("proposal: %+v", p)
	}
	if len(p.Skipped) != 0 || len(p.Conflicts) != 0 {
		t.Fatalf("unexpected diagnostics %+v", p)
	}
}
func TestImportSkipsContextSequencesAndArgumentsWithoutFlatteningAction(t *testing.T) {
	for _, extra := range []string{`"key":"ctrl+k ctrl+g"`, `"key":"ctrl+g","when":"editorTextFocus"`, `"key":"ctrl+g","args":{"line":1}`} {
		t.Run(extra, func(t *testing.T) {
			p, err := Parse("vscode", `[{"command":"workbench.action.gotoLine","key":"alt+g"},{"command":"workbench.action.gotoLine",`+extra+`}]`, importCatalog())
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Imported) != 0 || len(p.Skipped) != 1 || len(p.Proposal) != 0 {
				t.Fatalf("unsafe partial action: %+v", p)
			}
		})
	}
}
func TestImportRemovalDoesNotDeleteUserKeysOrOtherCommands(t *testing.T) {
	catalog := importCatalog()
	catalog[1].Customized = true
	catalog[1].Keys = []string{"alt+l"}
	p, err := Parse("vscode", `[{"command":"-workbench.action.gotoLine","key":"alt+l"},{"command":"actions.find","key":"ctrl+f"}]`, catalog)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.Proposal["navigate.gotoLine"], []string{"alt+l"}) || len(p.Skipped) != 1 {
		t.Fatalf("removal changed host: %+v", p)
	}
}
func TestImportDefaultDisplacementCustomizedConflictAndSwaps(t *testing.T) {
	content := `[{"command":"workbench.action.gotoLine","key":"cmd+f"}]`
	p, err := Parse("vscode", content, importCatalog())
	if err != nil {
		t.Fatal(err)
	}
	if keys, ok := p.Proposal["editor.find"]; !ok || len(keys) != 0 || len(p.Displaced) != 1 {
		t.Fatalf("default not explicitly unbound: %+v", p)
	}
	catalog := importCatalog()
	catalog[0].Customized = true
	p, err = Parse("vscode", content, catalog)
	if err != nil {
		t.Fatal(err)
	}
	if p.Proposal != nil || len(p.Conflicts) != 1 {
		t.Fatalf("customization overwritten: %+v", p)
	}
	p, err = Parse("vscode", `[{"command":"workbench.action.gotoLine","key":"cmd+f"},{"command":"actions.find","key":"cmd+l"}]`, catalog)
	if err != nil || len(p.Conflicts) != 0 || len(p.Imported) != 2 {
		t.Fatalf("swap rejected: %+v %v", p, err)
	}
}
func TestImportIncomingCollisionReturnsNoPartialProposal(t *testing.T) {
	p, err := Parse("vscode", `[{"command":"actions.find","key":"ctrl+g"},{"command":"workbench.action.gotoLine","key":"ctrl+g"}]`, importCatalog())
	if err != nil || p.Proposal != nil || len(p.Conflicts) != 1 {
		t.Fatalf("partial collision: %+v %v", p, err)
	}
}
func TestImportIDEAXMLUnbindingInheritanceAndSequences(t *testing.T) {
	p, err := Parse("idea", `<?xml version="1.0"?><keymap name="Custom" parent="Mac OS X 10.5+"><action id="Find"/><action id="GotoLine"><keyboard-shortcut first-keystroke="shift meta G"/></action><action id="ToggleLineBreakpoint"><keyboard-shortcut first-keystroke="ctrl K" second-keystroke="ctrl B"/></action></keymap>`, importCatalog())
	if err != nil {
		t.Fatal(err)
	}
	if !p.Inherited || len(p.Imported) != 2 || len(p.Skipped) != 1 {
		t.Fatalf("preview %+v", p)
	}
	if keys, ok := p.Proposal["editor.find"]; !ok || len(keys) != 0 {
		t.Fatalf("explicit clearing lost %+v", p)
	}
	if !reflect.DeepEqual(p.Proposal["navigate.gotoLine"], []string{"shift+meta+g"}) {
		t.Fatalf("keys %+v", p)
	}
}
func TestImportRejectsMalformedUnsafeOrOversizedDocuments(t *testing.T) {
	cases := []struct{ format, content string }{
		{"vscode", `null`}, {"vscode", `{}`}, {"vscode", `[null]`}, {"vscode", `[{"command":"actions.find","key":true}]`},
		{"vscode", `[{"command":"actions.find","key":"ctrl+f","when":false}]`},
		{"vscode", strings.Repeat("[", 100) + strings.Repeat("]", 100)},
		{"vscode", strings.Repeat(" ", maxSourceBytes+1)},
		{"vscode", string([]byte{'[', 0xff, ']'})},
		{"idea", `<!DOCTYPE keymap [<!ENTITY x SYSTEM "file:///secret">]><keymap/>`},
		{"idea", `<keymap><action id="Find"></keymap>`},
		{"idea", `<keymap/><keymap/>`}, {"idea", `<application/>`},
		{"idea", `<keymap><action id="Find"/><action id="Find"/></keymap>`},
		{"idea", `<keymap><action id="Find" id="GotoLine"/></keymap>`},
		{"idea", `<keymap><action id="Find"><keyboard-shortcut first-keystroke="ctrl F">oops</keyboard-shortcut></action></keymap>`},
	}
	for i, tc := range cases {
		t.Run(tc.format+string(rune('A'+i)), func(t *testing.T) {
			if _, err := Parse(tc.format, tc.content, importCatalog()); !errors.Is(err, ErrDocument) {
				t.Fatalf("accepted %q: %v", tc.content[:min(100, len(tc.content))], err)
			}
		})
	}
}
func TestImportPreservesUnknownRulesAndIsDeterministic(t *testing.T) {
	content := `[{"command":"extension.custom","key":"ctrl+y"},{"command":"workbench.action.debug.start","key":"f5"},{"command":"actions.find","key":"ctrl+f"}]`
	first, err := Parse("vscode", content, importCatalog())
	if err != nil {
		t.Fatal(err)
	}
	for range 5 {
		next, err := Parse("vscode", content, importCatalog())
		if err != nil || !reflect.DeepEqual(first, next) {
			t.Fatalf("nondeterministic: %+v %v", next, err)
		}
	}
	if len(first.Skipped) != 2 || len(first.Imported) != 1 {
		t.Fatalf("missing skip diagnostics %+v", first)
	}
}
func TestImportSourceVerificationNeverWritesAndRejectsChangedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "keybindings.json")
	before := []byte(`[{"command":"actions.find","key":"ctrl+f"}]`)
	if err := os.WriteFile(path, before, 0600); err != nil {
		t.Fatal(err)
	}
	ctx := t.Context()
	snapshot, err := Read(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if err = snapshot.Revalidate(ctx); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("read wrote source %v", err)
	}
	if err = os.WriteFile(path, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	if err = snapshot.Revalidate(ctx); !errors.Is(err, ErrChanged) {
		t.Fatalf("stale preview allowed: %v", err)
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = snapshot.Revalidate(ctx); !errors.Is(err, ErrChanged) {
		t.Fatalf("deleted source allowed: %v", err)
	}
}
func TestImportSourceRejectsInvalidEncodingSizeMissingAndCanceledRead(t *testing.T) {
	for _, bytes := range [][]byte{{0xff}, []byte(strings.Repeat("x", maxSourceBytes+1))} {
		path := filepath.Join(t.TempDir(), "source")
		if err := os.WriteFile(path, bytes, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Read(t.Context(), path); !errors.Is(err, ErrSource) {
			t.Fatalf("bad source accepted: %v", err)
		}
	}
	path := filepath.Join(t.TempDir(), "missing")
	if _, err := Read(t.Context(), path); !errors.Is(err, ErrSource) {
		t.Fatalf("missing accepted: %v", err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := Read(ctx, path); err == nil {
		t.Fatal("canceled read succeeded")
	}
}
func TestImportNativeKeyValidationMatchesDispatcher(t *testing.T) {
	for _, key := range []string{"a", "shift+a", "shift+space", "ctrl+ctrl+f", "ctrl+k ctrl+f", "[KeyA]"} {
		p, err := Parse("vscode", `[{"command":"actions.find","key":"`+key+`"}]`, importCatalog())
		if err != nil {
			t.Fatal(err)
		}
		if len(p.Imported) != 0 || len(p.Skipped) != 1 {
			t.Fatalf("unsupported %q accepted %+v", key, p)
		}
	}
}

func TestImportSourceRejectsReplacedIdentityEvenWithIdenticalBytes(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "selected.json")
	if err := os.WriteFile(path, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot, err := Read(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	replacement := filepath.Join(root, "replacement.json")
	if err = os.WriteFile(replacement, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	if err = snapshot.Revalidate(t.Context()); !errors.Is(err, ErrChanged) {
		t.Fatalf("replaced identity accepted: %v", err)
	}
}
