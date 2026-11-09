package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
)

func TestDocumentMarkers(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	set := plugindiag.NewSet()
	if err := set.Replace("/w/A.java", []plugindiag.Diagnostic{
		{FileKey: "/w/A.java", Line: 2, Column: 4, EndLine: 2, EndColumn: 9, Severity: plugindiag.SeverityError, Message: "unused"},
		{FileKey: "/w/A.java", Line: 5, Column: 0, EndLine: 7, EndColumn: 3, Severity: plugindiag.SeverityInformation, Message: "spans lines"},
	}); err != nil {
		t.Fatal(err)
	}
	h.app.pluginDiagnostics = set

	markers := h.app.documentMarkers("/w/A.java")
	if len(markers) != 2 {
		t.Fatalf("markers = %+v", markers)
	}
	// A single-line diagnostic underlines the range the server reported.
	if markers[0].Line != 2 || markers[0].Start != 4 || markers[0].End != 9 {
		t.Fatalf("first marker = %+v", markers[0])
	}
	if markers[0].Severity != editorview.MarkerError {
		t.Fatalf("first severity = %d", markers[0].Severity)
	}
	// A diagnostic that spans lines underlines its first cell: the view draws one row
	// at a time.
	if markers[1].Line != 5 || markers[1].Start != 0 || markers[1].End != 1 {
		t.Fatalf("second marker = %+v", markers[1])
	}
	if markers[1].Severity != editorview.MarkerInfo {
		t.Fatalf("second severity = %d", markers[1].Severity)
	}

	if other := h.app.documentMarkers("/w/B.java"); len(other) != 0 {
		t.Fatalf("another file had markers: %+v", other)
	}
}

func TestDocumentMarkersWithoutAStore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if markers := h.app.documentMarkers("/w/A.java"); markers != nil {
		t.Fatalf("markers = %+v", markers)
	}
}

func TestPluginDocumentResolver(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "src", "Main.java")
	if err := os.WriteFile(path, []byte("class Main {}"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	resolve := h.app.pluginDocumentResolver()

	// Core may report a URI or a bare path; both place the same document. A relative
	// path is a workspace-relative identity, not an absolute one.
	for _, uri := range []string{"file://" + filepath.ToSlash(path), path, "src/Main.java"} {
		key, display, ok := resolve(uri)
		if !ok {
			t.Fatalf("%q did not resolve", uri)
		}
		if key != path {
			t.Fatalf("%q resolved to %q, want %q", uri, key, path)
		}
		if display != "src/Main.java" {
			t.Fatalf("%q displayed as %q", uri, display)
		}
	}

	// A document outside the workspace has no identity the problems list can open.
	if _, _, ok := resolve("file:///elsewhere/Other.java"); ok {
		t.Fatal("a document outside the workspace resolved")
	}
	if _, _, ok := resolve(""); ok {
		t.Fatal("an empty identity resolved")
	}
}

func TestApplyPluginDiagnosticsWithoutAProject(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	// A window with no plugin stack ignores diagnostics instead of storing markers
	// for a document it cannot place.
	h.app.applyPluginDiagnostics(core.PluginDiagnosticsEvent{URI: "file:///a.java"})
	if h.app.pluginDiagnostics != nil {
		t.Fatalf("diagnostics = %v", h.app.pluginDiagnostics)
	}
}
