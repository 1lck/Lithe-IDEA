package pluginservice

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
)

// workspaceResolver places one known document and nothing else.
func workspaceResolver(uri, fileKey, displayPath string) Resolver {
	return func(candidate string) (string, string, bool) {
		if candidate != uri {
			return "", "", false
		}
		return fileKey, displayPath, true
	}
}

const diagnosticURI = "file:///workspace/Main.java"

func intPointer(value int) *int { return &value }

func TestDiagnosticsFromEventMapsTheContractFields(t *testing.T) {
	event := core.PluginDiagnosticsEvent{
		URI:     diagnosticURI,
		Version: func() *int64 { value := int64(7); return &value }(),
		Diagnostics: []core.PluginDiagnostic{{
			Range: core.PluginDiagnosticRange{
				Start: core.PluginDiagnosticPosition{Line: 2, UTF16Column: 4},
				End:   core.PluginDiagnosticPosition{Line: 2, UTF16Column: 9},
			},
			Severity: intPointer(2),
			Message:  "Unused declaration",
			Source:   "fixture-lsp",
			Code:     "unused",
		}},
	}
	records := DiagnosticsFromEvent(event, workspaceResolver(diagnosticURI, "Main.java", "src/Main.java"))
	if len(records) != 1 {
		t.Fatalf("records = %+v", records)
	}
	record := records[0]
	if record.FileKey != "Main.java" || record.DisplayPath != "src/Main.java" {
		t.Fatalf("identity = %q %q", record.FileKey, record.DisplayPath)
	}
	// The marker starts where the diagnostic starts; the end of the range is not
	// needed to draw a squiggle under a token.
	if record.Line != 2 || record.Column != 4 {
		t.Fatalf("position = %d:%d", record.Line, record.Column)
	}
	if record.Severity != plugindiag.SeverityWarning {
		t.Fatalf("severity = %d", record.Severity)
	}
	if record.Message != "Unused declaration" || record.Source != "fixture-lsp" || record.Code != "unused" {
		t.Fatalf("record = %+v", record)
	}
}

func TestDiagnosticsFromEventMapsEverySeverity(t *testing.T) {
	cases := []struct {
		severity *int
		want     plugindiag.Severity
	}{
		{severity: intPointer(1), want: plugindiag.SeverityError},
		{severity: intPointer(2), want: plugindiag.SeverityWarning},
		{severity: intPointer(3), want: plugindiag.SeverityInformation},
		{severity: intPointer(4), want: plugindiag.SeverityHint},
		{severity: nil, want: plugindiag.SeverityInformation},
		{severity: intPointer(9), want: plugindiag.SeverityInformation},
	}
	resolver := workspaceResolver(diagnosticURI, "Main.java", "src/Main.java")
	for _, tc := range cases {
		event := core.PluginDiagnosticsEvent{
			URI: diagnosticURI,
			Diagnostics: []core.PluginDiagnostic{{
				Severity: tc.severity,
				Message:  "x",
			}},
		}
		records := DiagnosticsFromEvent(event, resolver)
		if len(records) != 1 || records[0].Severity != tc.want {
			t.Fatalf("severity %v mapped to %+v", tc.severity, records)
		}
	}
}

func TestDiagnosticsFromEventDropsDocumentsOutsideTheWorkspace(t *testing.T) {
	event := core.PluginDiagnosticsEvent{
		URI: "file:///elsewhere/Other.java",
		Diagnostics: []core.PluginDiagnostic{{
			Severity: intPointer(1),
			Message:  "x",
		}},
	}
	if records := DiagnosticsFromEvent(event, workspaceResolver(diagnosticURI, "Main.java", "src/Main.java")); records != nil {
		t.Fatalf("records = %+v", records)
	}
	// A client without a resolver stores nothing rather than inventing a key.
	if records := DiagnosticsFromEvent(event, nil); records != nil {
		t.Fatalf("records = %+v", records)
	}
}

func TestDiagnosticsFromEventReturnsNothingForAnEmptySet(t *testing.T) {
	event := core.PluginDiagnosticsEvent{URI: diagnosticURI}
	if records := DiagnosticsFromEvent(event, workspaceResolver(diagnosticURI, "Main.java", "src/Main.java")); records != nil {
		t.Fatalf("records = %+v", records)
	}
}

func TestFileKeyFor(t *testing.T) {
	resolver := workspaceResolver(diagnosticURI, "Main.java", "src/Main.java")
	if key, ok := FileKeyFor(diagnosticURI, resolver); !ok || key != "Main.java" {
		t.Fatalf("key = %q, ok = %v", key, ok)
	}
	if _, ok := FileKeyFor("file:///elsewhere/Other.java", resolver); ok {
		t.Fatal("a document outside the workspace reported a key")
	}
	if _, ok := FileKeyFor(diagnosticURI, nil); ok {
		t.Fatal("a missing resolver reported a key")
	}
}

func TestDiagnosticsFromEventStoresIntoTheSet(t *testing.T) {
	set := plugindiag.NewSet()
	event := core.PluginDiagnosticsEvent{
		URI: diagnosticURI,
		Diagnostics: []core.PluginDiagnostic{
			{Severity: intPointer(1), Message: "first"},
			{Severity: intPointer(3), Message: "second"},
		},
	}
	resolver := workspaceResolver(diagnosticURI, "Main.java", "src/Main.java")
	records := DiagnosticsFromEvent(event, resolver)
	if err := set.Replace("Main.java", records); err != nil {
		t.Fatalf("replace: %v", err)
	}
	if got := set.Counts(); got[plugindiag.SeverityError] != 1 || got[plugindiag.SeverityInformation] != 1 {
		t.Fatalf("counts = %v", got)
	}
	// A later empty event clears the document.
	clear := DiagnosticsFromEvent(core.PluginDiagnosticsEvent{URI: diagnosticURI}, resolver)
	if err := set.Replace("Main.java", clear); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if len(set.All()) != 0 {
		t.Fatalf("diagnostics survived a clear: %+v", set.All())
	}
}
