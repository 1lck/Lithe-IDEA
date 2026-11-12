package core

import (
	"encoding/json"
	"errors"
	"testing"
)

const diagnosticsPayload = `{
  "uri": "file:///C:/work/Main.java",
  "version": 7,
  "diagnostics": [
    {
      "range": {"start": {"line": 2, "utf16Column": 4}, "end": {"line": 2, "utf16Column": 9}},
      "severity": 2,
      "message": "Unused declaration",
      "source": "fixture-lsp",
      "code": "unused",
      "tags": [1, 2, 99]
    }
  ]
}`

func TestDecodePluginDiagnostics(t *testing.T) {
	event, err := DecodePluginDiagnostics(json.RawMessage(diagnosticsPayload))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if event.URI != "file:///C:/work/Main.java" {
		t.Fatalf("uri = %q", event.URI)
	}
	if event.Version == nil || *event.Version != 7 {
		t.Fatalf("version = %v", event.Version)
	}
	if len(event.Diagnostics) != 1 {
		t.Fatalf("diagnostics = %+v", event.Diagnostics)
	}
	diagnostic := event.Diagnostics[0]
	if diagnostic.Range.Start.Line != 2 || diagnostic.Range.Start.UTF16Column != 4 {
		t.Fatalf("range = %+v", diagnostic.Range)
	}
	if diagnostic.Severity == nil || *diagnostic.Severity != 2 {
		t.Fatalf("severity = %v", diagnostic.Severity)
	}
	if diagnostic.Message != "Unused declaration" || diagnostic.Source != "fixture-lsp" || diagnostic.Code != "unused" {
		t.Fatalf("diagnostic = %+v", diagnostic)
	}
	if len(diagnostic.Tags) != 3 || diagnostic.Tags[2] != 99 {
		t.Fatalf("tags = %v", diagnostic.Tags)
	}
	if got := diagnostic.DisplaySeverity(); got != DisplaySeverityWarning {
		t.Fatalf("display severity = %q", got)
	}
}

func TestDisplaySeverityMatchesTheFixture(t *testing.T) {
	// shared/fixtures/lsp/diagnostic-code-actions-v1.json lists these cases.
	cases := []struct {
		severity *int
		want     string
	}{
		{severity: intPointer(1), want: DisplaySeverityError},
		{severity: intPointer(2), want: DisplaySeverityWarning},
		{severity: intPointer(3), want: DisplaySeverityInfo},
		{severity: intPointer(4), want: DisplaySeverityInfo},
		{severity: nil, want: DisplaySeverityInfo},
		{severity: intPointer(9), want: DisplaySeverityInfo},
	}
	for _, tc := range cases {
		diagnostic := PluginDiagnostic{Severity: tc.severity, Message: "x"}
		if got := diagnostic.DisplaySeverity(); got != tc.want {
			t.Fatalf("severity %v = %q, want %q", tc.severity, got, tc.want)
		}
	}
}

func intPointer(value int) *int { return &value }

func TestDecodePluginDiagnosticsAcceptsANumericCode(t *testing.T) {
	payload := `{"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,"utf16Column":0},"end":{"line":0,"utf16Column":1}},"message":"x","code":1234}]}`
	event, err := DecodePluginDiagnostics(json.RawMessage(payload))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if event.Diagnostics[0].Code != "1234" {
		t.Fatalf("code = %q", event.Diagnostics[0].Code)
	}
	// A payload without a version or a severity is still usable.
	if event.Version != nil || event.Diagnostics[0].Severity != nil {
		t.Fatalf("event = %+v", event)
	}
}

func TestDecodePluginDiagnosticsAcceptsAnEmptySet(t *testing.T) {
	event, err := DecodePluginDiagnostics(json.RawMessage(`{"uri":"file:///a","diagnostics":[]}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(event.Diagnostics) != 0 {
		t.Fatalf("diagnostics = %+v", event.Diagnostics)
	}
}

func TestDecodePluginDiagnosticsRefusesBadPayloads(t *testing.T) {
	cases := map[string]string{
		"empty":         ``,
		"not an object": `[]`,
		"no document":   `{"diagnostics":[]}`,
		"negative line": `{"uri":"file:///a","diagnostics":[{"range":{"start":{"line":-1,"utf16Column":0},"end":{"line":0,"utf16Column":0}},"message":"x"}]}`,
		"no message":    `{"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,"utf16Column":0},"end":{"line":0,"utf16Column":1}},"message":""}]}`,
		"broken json":   `{"uri":`,
		"broken code":   `{"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,"utf16Column":0},"end":{"line":0,"utf16Column":1}},"message":"x","code":{}}]}`,
	}
	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodePluginDiagnostics(json.RawMessage(payload)); !errors.Is(err, ErrDiagnostics) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}
