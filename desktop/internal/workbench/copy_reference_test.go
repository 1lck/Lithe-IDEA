package workbench

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestCopyReferenceLocationWithoutServerCopiesFileLine(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	path := filepath.Join(root, "reference.go")
	if err := os.WriteFile(path, []byte("package main\nfunc work() {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("document not opened")
	}
	d.view.GoToLine(2)
	h.app.copyReferenceLocation(p, d)
	h.await("copy file and line", func() bool {
		return h.driver.Clipboard() == path+"#L2"
	})
}

func TestCopyReferenceLocationUsesLanguageSymbols(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureDocumentSymbols: true}
	f.d.view.SetSelection(0, 0)
	f.h.app.copyReferenceLocation(f.p, f.d)
	f.h.await("reference symbol request submitted", func() bool {
		req := f.h.app.editor.copyReference.request
		return req != nil && req.pending != nil && req.pending.operation != ""
	})
	pending := f.h.app.editor.copyReference.request.pending
	f.deliver(t, pending.operation, pluginMethodDocumentSymbols, symbolsResult(t,
		symbolAt("DemoClass", 5, 0, 1,
			symbolAt("goHome(String,Integer)", 6, 0, 1)),
	))
	f.h.await("symbol reference request settled", func() bool {
		return f.h.app.editor.copyReference.request == nil
	})
	if got := f.h.driver.Clipboard(); got != "DemoClass#goHome(String,Integer)#L1" {
		t.Fatalf("copied %q, want method reference", got)
	}
}

func TestCopyReferenceLocationDiscardsOldDocumentRevision(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureDocumentSymbols: true}
	f.h.app.copyReferenceLocation(f.p, f.d)
	f.h.await("stale-reference symbol request submitted", func() bool {
		req := f.h.app.editor.copyReference.request
		return req != nil && req.pending != nil && req.pending.operation != ""
	})
	pending := f.h.app.editor.copyReference.request.pending
	f.h.app.insertForTest(f.d, "changed")
	f.deliver(t, pending.operation, pluginMethodDocumentSymbols, symbolsResult(t,
		symbolAt("Outdated", 5, 0, 1),
	))
	f.h.settleChain()
	if got := f.h.driver.Clipboard(); strings.Contains(got, "Outdated") {
		t.Fatalf("stale reference copied: %q", got)
	}
	if f.h.app.editor.copyReference.request != nil {
		t.Fatal("a reference request for an edited document stays pending")
	}
}

func TestEditorContextMenuCopiesReferenceAtSecondaryPress(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	path := filepath.Join(root, "reference.txt")
	if err := os.WriteFile(path, []byte("one\ntwo\nthree\n"), 0600); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("document missing")
	}
	bounds := h.topHit(d.hit)
	at := center(bounds)
	line, _, ok := d.view.PositionAt(at.X, at.Y)
	if !ok {
		t.Fatal("editor has not painted")
	}
	h.rightClickAt(bounds)
	h.clickNamed(h.shared("native.copySourceLocation"))
	h.await("right-click location copied", func() bool {
		return h.driver.Clipboard() == path+"#L"+strconv.Itoa(line+1)
	})
}
