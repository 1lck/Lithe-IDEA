package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// Go to Declaration or Usages follows IntelliJ IDEA: Command+B (Control+B elsewhere) and the
// modifier-click open the declaration from a use, and on the declaration itself they show its
// usages, without the declaration, instead of jumping to where the caret already is.

// pressDeclaration presses Command+B (Control+B elsewhere) in the focused editor.
func pressDeclaration(t *testing.T, f *semanticFixture) {
	t.Helper()
	handled, err := f.h.driver.ShortcutChord(primaryModifier(), 'b')
	if err != nil {
		t.Fatal(err)
	}
	if !handled {
		t.Fatal("Go to Declaration or Usages was not handled")
	}
}

// ownDeclaration is a definition answer naming the identifier at the start of A.java's first
// line, which is where the fixture's caret sits.
func ownDeclaration(f *semanticFixture) core.PluginSemanticLocation {
	return locationAt(f.d.path, 0, 0)
}

func writeJava(t *testing.T, root, name, text string) string {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCommandBFromAUseOpensTheDeclaration(t *testing.T) {
	f := newSemanticFixture(t)
	target := writeJava(t, f.p.root, "B.java", "zero\n  one\n")
	f.d.view.GoToNavigation(0, 1, false)
	pressDeclaration(t, f)
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != pluginSemanticDefinition || request.Position == nil || request.Position.UTF16Column != 1 {
		t.Fatalf("definition request = %+v", request)
	}
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, locationAt(target, 1, 2)))
	awaitDocumentState(t, f.h, func() bool { return f.p.docs.byPath(target) != nil })
	if line, column := f.p.docs.byPath(target).view.CaretUTF16(); line != 1 || column != 2 {
		t.Fatalf("caret = %d:%d, want 1:2", line, column)
	}
	if f.kernel.requestCount() != 1 {
		t.Fatalf("a use asked for usages: %+v", f.kernel.request(1))
	}
}

func TestCommandBOnTheDeclarationListsItsUsages(t *testing.T) {
	f := newSemanticFixture(t)
	first := writeJava(t, f.p.root, "B.java", "zero\n  one\n")
	second := writeJava(t, f.p.root, "C.java", "zero\n  one\n")
	f.d.view.GoToNavigation(0, 1, false)
	pressDeclaration(t, f)
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, ownDeclaration(f)))
	f.waitForRequests(t, 2)
	usages := f.kernel.request(1)
	if usages.Operation != pluginSemanticReferences || usages.IncludeDeclaration == nil || *usages.IncludeDeclaration {
		t.Fatalf("usages request = %+v, want references without the declaration", usages)
	}
	if usages.Position == nil || usages.Position.Line != 0 || usages.Position.UTF16Column != 1 {
		t.Fatalf("usages position = %+v", usages.Position)
	}
	f.deliver(t, "op-2", pluginMethodReferences, locationsResult(t, locationAt(first, 1, 2), locationAt(second, 1, 2)))
	if !f.h.app.semantics.definition.open || len(f.h.app.semantics.definition.targets) != 2 {
		t.Fatalf("usages list = %+v", f.h.app.semantics.definition)
	}
	if f.h.app.chrome.isOpen(catalogIndex[itemReferences]) {
		t.Fatal("the usages of a declaration filled the References tool window")
	}
	if f.p.docs.byPath(first) != nil || f.p.docs.byPath(second) != nil {
		t.Fatal("a usage opened before one was chosen")
	}
}

func TestCommandBOnTheDeclarationOpensASingleUsage(t *testing.T) {
	f := newSemanticFixture(t)
	target := writeJava(t, f.p.root, "B.java", "zero\n  one\n")
	f.d.view.GoToNavigation(0, 3, false) // right after the name: still on the declaration
	pressDeclaration(t, f)
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, ownDeclaration(f)))
	f.waitForRequests(t, 2)
	f.deliver(t, "op-2", pluginMethodReferences, locationsResult(t, locationAt(target, 1, 2)))
	awaitDocumentState(t, f.h, func() bool { return f.p.docs.byPath(target) != nil })
	if line, column := f.p.docs.byPath(target).view.CaretUTF16(); line != 1 || column != 2 {
		t.Fatalf("caret = %d:%d, want 1:2", line, column)
	}
	if f.h.app.semantics.definition.open {
		t.Fatal("a single usage opened a list")
	}
}

func TestCommandBOnAnUnusedDeclarationSaysSo(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 1, false)
	pressDeclaration(t, f)
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, ownDeclaration(f)))
	f.waitForRequests(t, 2)
	f.deliver(t, "op-2", pluginMethodReferences, locationsResult(t))
	if !f.h.shows("未找到引用。") {
		t.Fatalf("no notice for an unused declaration: %v", f.h.driver.Snapshot().Labels)
	}
	if f.h.app.semantics.definition.open {
		t.Fatal("an empty usages answer opened a list")
	}
}

func TestModifierClickOnTheDeclarationAsksForUsages(t *testing.T) {
	f := newSemanticFixture(t)
	target := writeJava(t, f.p.root, "B.java", "zero\n  one\n")
	// Place the caret elsewhere first: the click, not the caret, names the symbol.
	f.d.view.GoToNavigation(0, 1, false)
	f.h.settle()
	rect, ok := f.d.view.CaretRect()
	if !ok {
		t.Fatal("the view has no caret rect")
	}
	f.d.view.GoToNavigation(0, 4, false)
	result := f.h.app.documentPointer(f.p, f.d, gfx.PointerEvent{
		Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, Modifiers: primaryModifier(),
		X: rect.X + 1, Y: rect.Y + rect.Height/2,
	})
	if !result.Handled {
		t.Fatal("the modifier-click was not handled")
	}
	f.waitForRequests(t, 1)
	click := f.kernel.request(0)
	if click.Operation != pluginSemanticDefinition || click.Position == nil || click.Position.Line != 0 || click.Position.UTF16Column != 1 {
		t.Fatalf("definition request = %+v", click)
	}
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, ownDeclaration(f)))
	f.waitForRequests(t, 2)
	usages := f.kernel.request(1)
	if usages.Operation != pluginSemanticReferences || usages.IncludeDeclaration == nil || *usages.IncludeDeclaration ||
		usages.Position == nil || usages.Position.UTF16Column != 1 {
		t.Fatalf("usages request = %+v", usages)
	}
	f.deliver(t, "op-2", pluginMethodReferences, locationsResult(t, locationAt(target, 1, 2)))
	awaitDocumentState(t, f.h, func() bool { return f.p.docs.byPath(target) != nil })
}

func TestFindUsagesStillListsTheDeclaration(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 1, false)
	if err := f.h.driver.Key(gfx.KeyF12, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	if request := f.kernel.request(0); request.Operation != pluginSemanticReferences || request.IncludeDeclaration != nil {
		t.Fatalf("Find Usages request = %+v, want Core's default with the declaration", request)
	}
}
