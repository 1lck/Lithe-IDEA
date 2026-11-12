package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
)

// ErrDiagnostics reports a diagnostics payload this client cannot decode.
var ErrDiagnostics = errors.New("plugin diagnostics payload is not readable")

// Display severities the problems list uses. A language server reports an LSP
// number; a hint and an information item both read as info to a user.
const (
	DisplaySeverityError   = "error"
	DisplaySeverityWarning = "warning"
	DisplaySeverityInfo    = "info"
)

// PluginDiagnosticPosition is a position in a document: a zero-based line and a
// zero-based UTF-16 column, which is the shape Core relays.
type PluginDiagnosticPosition struct {
	Line        int `json:"line"`
	UTF16Column int `json:"utf16Column"`
}

// PluginDiagnosticRange is a half-open range in a document.
type PluginDiagnosticRange struct {
	Start PluginDiagnosticPosition `json:"start"`
	End   PluginDiagnosticPosition `json:"end"`
}

// PluginDiagnosticCode is the server's diagnostic code, which LSP allows as either
// a number or a string. It is kept as text so both forms survive.
type PluginDiagnosticCode string

// UnmarshalJSON accepts a string, a number or null.
func (c *PluginDiagnosticCode) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*c = ""
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		*c = PluginDiagnosticCode(text)
		return nil
	}
	var number json.Number
	if err := json.Unmarshal(data, &number); err == nil {
		*c = PluginDiagnosticCode(number.String())
		return nil
	}
	return fmt.Errorf("%w: a diagnostic code is neither a string nor a number", ErrDiagnostics)
}

// PluginDiagnostic is one diagnostic Core relayed from a language server.
type PluginDiagnostic struct {
	// Range is where the diagnostic applies.
	Range PluginDiagnosticRange `json:"range"`
	// Severity is the LSP number: 1 error, 2 warning, 3 information, 4 hint. It is
	// null when the server did not say.
	Severity *int `json:"severity"`
	// Message is the server's own text, which is not translated.
	Message string `json:"message"`
	// Source names the tool that produced the diagnostic.
	Source string `json:"source,omitempty"`
	// Code is the server's own code.
	Code PluginDiagnosticCode `json:"code,omitempty"`
	// Tags carries LSP DiagnosticTag values such as unnecessary or deprecated.
	Tags []int `json:"tags,omitempty"`
	// RelatedInformation is opaque related context, kept byte for byte.
	RelatedInformation json.RawMessage `json:"relatedInformation,omitempty"`
}

// DisplaySeverity is the severity name the problems list shows.
func (d PluginDiagnostic) DisplaySeverity() string {
	if d.Severity == nil {
		return DisplaySeverityInfo
	}
	switch *d.Severity {
	case 1:
		return DisplaySeverityError
	case 2:
		return DisplaySeverityWarning
	default:
		// Information, hint and any number a future protocol adds read as info
		// rather than as a severity this client would have to invent.
		return DisplaySeverityInfo
	}
}

// PluginDiagnosticsEvent is the payload of the session's diagnostics event.
//
// Core accepts diagnostics only for documents open in the current session and only
// when a versioned payload matches the document's current version, so a payload
// that reaches the host already belongs to the document it names.
type PluginDiagnosticsEvent struct {
	// URI is the document the diagnostics belong to.
	URI string `json:"uri"`
	// Version is the document version they were computed for, when the server
	// versioned them.
	Version *int64 `json:"version,omitempty"`
	// Diagnostics is the complete set for the document: an empty list clears it.
	Diagnostics []PluginDiagnostic `json:"diagnostics"`
}

// DecodePluginDiagnostics decodes the payload of one diagnostics event.
func DecodePluginDiagnostics(raw json.RawMessage) (PluginDiagnosticsEvent, error) {
	if len(raw) == 0 {
		return PluginDiagnosticsEvent{}, fmt.Errorf("%w: the payload is empty", ErrDiagnostics)
	}
	var event PluginDiagnosticsEvent
	if err := json.Unmarshal(raw, &event); err != nil {
		return PluginDiagnosticsEvent{}, fmt.Errorf("%w: %w", ErrDiagnostics, err)
	}
	if err := validateDiagnostics(event); err != nil {
		return PluginDiagnosticsEvent{}, err
	}
	return event, nil
}

// PluginDiagnosticsFromEvent decodes the diagnostics one runtime event carries.
//
// Core relays the document identity on the event itself and may put a bare array
// in the diagnostics field, so this accepts both that shape and a payload that
// repeats the identity.
func PluginDiagnosticsFromEvent(event BackendEvent) (PluginDiagnosticsEvent, error) {
	raw := event.Diagnostics
	if len(raw) == 0 {
		return PluginDiagnosticsEvent{}, fmt.Errorf("%w: the event carries no diagnostics", ErrDiagnostics)
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return PluginDiagnosticsEvent{}, fmt.Errorf("%w: the event carries no diagnostics", ErrDiagnostics)
	}
	if trimmed[0] != '[' {
		return DecodePluginDiagnostics(raw)
	}
	var diagnostics []PluginDiagnostic
	if err := json.Unmarshal(trimmed, &diagnostics); err != nil {
		return PluginDiagnosticsEvent{}, fmt.Errorf("%w: %w", ErrDiagnostics, err)
	}
	decoded := PluginDiagnosticsEvent{URI: event.URI, Version: event.Version, Diagnostics: diagnostics}
	if err := validateDiagnostics(decoded); err != nil {
		return PluginDiagnosticsEvent{}, err
	}
	return decoded, nil
}

// validateDiagnostics checks what the host relies on when it stores the records.
func validateDiagnostics(event PluginDiagnosticsEvent) error {
	if event.URI == "" {
		return fmt.Errorf("%w: the payload names no document", ErrDiagnostics)
	}
	for _, diagnostic := range event.Diagnostics {
		if diagnostic.Range.Start.Line < 0 || diagnostic.Range.Start.UTF16Column < 0 ||
			diagnostic.Range.End.Line < 0 || diagnostic.Range.End.UTF16Column < 0 {
			return fmt.Errorf("%w: a range is negative", ErrDiagnostics)
		}
		if diagnostic.Message == "" {
			return fmt.Errorf("%w: a diagnostic has no message", ErrDiagnostics)
		}
	}
	return nil
}
