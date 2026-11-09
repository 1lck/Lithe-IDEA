package workbench

import (
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// applyPluginDiagnostics stores the diagnostics one language server published for
// one document.
//
// An empty set clears the document, which is how a server withdraws a problem it
// fixed. A document this window cannot place in the workspace is dropped: storing
// it under a path the user cannot open would only add a marker nobody can reach.
func (a *App) applyPluginDiagnostics(event core.PluginDiagnosticsEvent) {
	if a.plugins == nil {
		return
	}
	resolve := a.pluginDocumentResolver()
	fileKey, ok := pluginservice.FileKeyFor(event.URI, resolve)
	if !ok {
		return
	}
	records := pluginservice.DiagnosticsFromEvent(event, resolve)
	if a.pluginDiagnostics == nil {
		a.pluginDiagnostics = plugindiag.NewSet()
	}
	if err := a.pluginDiagnostics.Replace(fileKey, records); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_diagnostics", err))
	}
	a.refreshDocumentMarkers(fileKey)
}

// refreshDocumentMarkers redraws one open document's underlines.
//
// A document that is not open has nothing to draw: its diagnostics stay in the set
// so the markers appear when it is opened.
func (a *App) refreshDocumentMarkers(path string) {
	if a.project == nil {
		return
	}
	document := a.project.docs.byPath(path)
	if document == nil {
		return
	}
	document.view.SetMarkers(a.documentMarkers(path))
}

// documentMarkers turns the stored diagnostics of one file into view markers.
//
// A diagnostic that spans lines underlines only its first cell: the view draws one
// row at a time, and an underline that crossed rows would need the range of every
// row it covers.
func (a *App) documentMarkers(path string) []editorview.Marker {
	if a.pluginDiagnostics == nil {
		return nil
	}
	var markers []editorview.Marker
	for _, record := range a.pluginDiagnostics.All() {
		if record.FileKey != path {
			continue
		}
		end := record.Column + 1
		if record.EndLine == record.Line && record.EndColumn > record.Column {
			end = record.EndColumn
		}
		markers = append(markers, editorview.Marker{
			Line:     record.Line,
			Start:    record.Column,
			End:      end,
			Severity: markerSeverity(record.Severity),
		})
	}
	return markers
}

// markerSeverity maps a stored severity onto the colour the view draws.
func markerSeverity(severity plugindiag.Severity) editorview.MarkerSeverity {
	switch severity {
	case plugindiag.SeverityError:
		return editorview.MarkerError
	case plugindiag.SeverityWarning:
		return editorview.MarkerWarning
	default:
		return editorview.MarkerInfo
	}
}

// clearPluginDiagnostics drops everything a previous project's servers published.
func (a *App) clearPluginDiagnostics() {
	a.pluginDiagnostics = nil
}

// pluginDocumentResolver places a document identity inside the open project.
//
// Core resolves a document to its own spelling, and a server may report a URI or a
// path, so both shapes are accepted. A document outside the project is refused.
func (a *App) pluginDocumentResolver() pluginservice.Resolver {
	root := ""
	if a.project != nil {
		root = a.project.root
	}
	return func(uri string) (string, string, bool) {
		if root == "" || uri == "" {
			return "", "", false
		}
		path := strings.TrimPrefix(uri, "file://")
		if path == "" {
			return "", "", false
		}
		// A URI may spell the separator differently from the file system; Clean folds
		// a doubled leading slash that would otherwise name a different path.
		path = filepath.Clean(filepath.FromSlash(path))
		if path == "" {
			return "", "", false
		}
		if !filepath.IsAbs(path) {
			path = filepath.Join(root, path)
		}
		relative, err := filepath.Rel(root, path)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return "", "", false
		}
		return path, filepath.ToSlash(relative), true
	}
}

// pluginDiagnosticCounts reports how many problems the open project has.
func (a *App) pluginDiagnosticCounts() map[plugindiag.Severity]int {
	if a.pluginDiagnostics == nil {
		return nil
	}
	return a.pluginDiagnostics.Counts()
}

// pluginProblemCount reports how many problems the open project has in total.
func (a *App) pluginProblemCount() int {
	total := 0
	for _, count := range a.pluginDiagnosticCounts() {
		total += count
	}
	return total
}
