package pluginservice

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
)

// Resolver maps a document URI to the identity the problems list uses: the
// platform's file key and the workspace-relative path.
//
// A document outside the workspace has no such identity, and ok is false for it.
type Resolver func(uri string) (fileKey, displayPath string, ok bool)

// DiagnosticsFromEvent converts one diagnostics event into the records the
// problems list stores.
//
// A document the resolver cannot place in the workspace is dropped rather than
// stored under a path the user cannot open. An event with no diagnostics returns
// nil, which clears the document.
func DiagnosticsFromEvent(event core.PluginDiagnosticsEvent, resolve Resolver) []plugindiag.Diagnostic {
	if len(event.Diagnostics) == 0 {
		return nil
	}
	fileKey, displayPath, ok := resolveIdentity(resolve, event.URI)
	if !ok {
		return nil
	}
	diagnostics := make([]plugindiag.Diagnostic, 0, len(event.Diagnostics))
	for _, diagnostic := range event.Diagnostics {
		diagnostics = append(diagnostics, plugindiag.Diagnostic{
			FileKey:     fileKey,
			DisplayPath: displayPath,
			Line:        diagnostic.Range.Start.Line,
			Column:      diagnostic.Range.Start.UTF16Column,
			Severity:    severityOf(diagnostic),
			Message:     diagnostic.Message,
			Source:      diagnostic.Source,
			Code:        string(diagnostic.Code),
		})
	}
	return diagnostics
}

// FileKeyFor reports the file key an event belongs to, so the caller can clear a
// document whose event carries no diagnostics.
func FileKeyFor(uri string, resolve Resolver) (string, bool) {
	fileKey, _, ok := resolveIdentity(resolve, uri)
	return fileKey, ok
}

func resolveIdentity(resolve Resolver, uri string) (string, string, bool) {
	if resolve == nil || uri == "" {
		return "", "", false
	}
	fileKey, displayPath, ok := resolve(uri)
	if !ok || fileKey == "" {
		return "", "", false
	}
	return fileKey, displayPath, true
}

// severityOf maps the server's LSP number onto the storage severity.
//
// A server may leave the severity out, and a future protocol may add a number this
// client does not know; both read as information rather than as a severity the
// host would have to invent.
func severityOf(diagnostic core.PluginDiagnostic) plugindiag.Severity {
	if diagnostic.Severity == nil {
		return plugindiag.SeverityInformation
	}
	switch plugindiag.Severity(*diagnostic.Severity) {
	case plugindiag.SeverityError, plugindiag.SeverityWarning,
		plugindiag.SeverityInformation, plugindiag.SeverityHint:
		return plugindiag.Severity(*diagnostic.Severity)
	default:
		return plugindiag.SeverityInformation
	}
}
