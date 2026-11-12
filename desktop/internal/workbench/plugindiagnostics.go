package workbench

import (
	"context"
	"errors"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// pluginDiagnosticSet returns the storage of one plugin, making it on first use.
//
// Diagnostics are kept per plugin rather than per workspace so that stopping or
// disabling one server withdraws only what that server published. Core's query
// receives the union of the sets; the owner never appears in its request or
// result.
func (a *App) pluginDiagnosticSet(pluginID string) *plugindiag.Set {
	if a.pluginDiagnostics == nil {
		a.pluginDiagnostics = make(map[string]*plugindiag.Set)
	}
	set := a.pluginDiagnostics[pluginID]
	if set == nil {
		set = plugindiag.NewSet()
		a.pluginDiagnostics[pluginID] = set
	}
	return set
}

// pluginDiagnosticSets returns the stores to read, without allocating when there
// are none.
func (a *App) pluginDiagnosticSets() []*plugindiag.Set {
	if len(a.pluginDiagnostics) == 0 {
		return nil
	}
	owners := make([]string, 0, len(a.pluginDiagnostics))
	for owner := range a.pluginDiagnostics {
		owners = append(owners, owner)
	}
	// The union is what Core sees, and Core keeps submission order for ties. A Go
	// map's order is random, so the owners are sorted to make equal diagnostics
	// from two plugins reach the list in the same order on every query.
	sort.Strings(owners)
	sets := make([]*plugindiag.Set, 0, len(owners))
	for _, owner := range owners {
		sets = append(sets, a.pluginDiagnostics[owner])
	}
	return sets
}

// applyPluginDiagnostics stores the diagnostics one language server published for
// one document.
//
// An empty set clears the document, which is how a server withdraws a problem it
// fixed. A document this window cannot place in the workspace is dropped: storing
// it under a path the user cannot open would only add a marker nobody can reach.
func (a *App) applyPluginDiagnostics(pluginID string, event core.PluginDiagnosticsEvent) {
	if a.plugins == nil || pluginID == "" {
		return
	}
	resolve := a.pluginDocumentResolver()
	fileKey, ok := pluginservice.FileKeyFor(event.URI, resolve)
	if !ok {
		return
	}
	records := pluginservice.DiagnosticsFromEvent(event, resolve)
	set := a.pluginDiagnosticSet(pluginID)
	if err := set.Replace(fileKey, records); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_diagnostics", err))
		return
	}
	a.refreshDocumentMarkers(fileKey)
	a.markProblemsChanged()
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

// documentMarkers turns every server's stored diagnostics of one file into view
// markers.
//
// A diagnostic that spans lines underlines only its first cell: the view draws one
// row at a time, and an underline that crossed rows would need the range of every
// row it covers.
func (a *App) documentMarkers(path string) []editorview.Marker {
	if len(a.pluginDiagnostics) == 0 {
		return nil
	}
	var markers []editorview.Marker
	for _, set := range a.pluginDiagnosticSets() {
		for _, record := range set.All() {
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

// clearPluginDiagnostics withdraws everything one plugin's server published.
// Other plugins' diagnostics for the same files stay.
func (a *App) clearPluginDiagnostics(pluginID string) {
	if a.pluginDiagnostics == nil {
		return
	}
	if _, present := a.pluginDiagnostics[pluginID]; !present {
		return
	}
	delete(a.pluginDiagnostics, pluginID)
	if len(a.pluginDiagnostics) == 0 {
		a.pluginDiagnostics = nil
	}
	a.refreshOpenDocumentMarkers()
	a.markProblemsChanged()
}

// clearPluginFileDiagnostics withdraws one plugin's diagnostics for one file,
// which is what closing the document in its session means for the Problems list.
func (a *App) clearPluginFileDiagnostics(pluginID, fileKey string) {
	if a.pluginDiagnostics == nil || fileKey == "" {
		return
	}
	set := a.pluginDiagnostics[pluginID]
	if set == nil {
		return
	}
	set.Clear(fileKey)
	a.refreshDocumentMarkers(fileKey)
	a.markProblemsChanged()
}

// clearAllPluginDiagnostics drops every server's diagnostics, for a project
// switch or close.
func (a *App) clearAllPluginDiagnostics() {
	if a.pluginDiagnostics == nil {
		return
	}
	a.pluginDiagnostics = nil
	a.refreshOpenDocumentMarkers()
	a.markProblemsChanged()
}

// refreshOpenDocumentMarkers redraws the files that are open after a store was
// replaced whole.
func (a *App) refreshOpenDocumentMarkers() {
	if a.project == nil {
		return
	}
	for _, document := range a.project.docs.list {
		document.view.SetMarkers(a.documentMarkers(document.path))
	}
}

// pluginDocumentResolver places a document identity inside the open project.
//
// Core resolves a document to its own spelling, and a server may report a URI or a
// path, so both shapes are accepted. A document outside the project is refused.
func (a *App) pluginDocumentResolver() pluginservice.Resolver {
	root := ""
	owner := context.Background()
	if a.project != nil {
		root = a.project.root
		if a.project.ctx != nil {
			owner = a.project.ctx
		}
	}
	// The two diagnostics projections ask for the same URI. Cache only the last
	// result within this event, avoiding a second C ABI call without retaining a
	// workspace-wide identity cache that could outlive its source.
	var last string
	var identity *core.PluginDocumentIdentity
	loaded := false
	return func(uri string) (string, string, bool) {
		if root == "" || uri == "" {
			return "", "", false
		}
		if !loaded || last != uri {
			ctx, cancel := context.WithTimeout(owner, kernelCallTimeout)
			result, err := a.kernel.ResolvePluginDocumentIdentity(ctx, root, uri, "auto")
			cancel()
			identity, last, loaded = result, uri, true
			if err != nil {
				// log-exempt: 用户取消：关闭工作区后迟到的诊断不再需要归属。
				if !errors.Is(err, context.Canceled) {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_diagnostic_identity", err))
				}
				identity = nil
			}
		}
		if identity == nil {
			return "", "", false
		}
		return identity.Path, identity.RelativePath, true
	}
}

// pluginDiagnosticCounts reports how many problems every plugin published for the
// open project has, summed by severity.
func (a *App) pluginDiagnosticCounts() map[plugindiag.Severity]int {
	if len(a.pluginDiagnostics) == 0 {
		return nil
	}
	counts := make(map[plugindiag.Severity]int, 4)
	for _, set := range a.pluginDiagnosticSets() {
		for severity, count := range set.Counts() {
			counts[severity] += count
		}
	}
	return counts
}

// pluginProblemCount reports how many problems the open project has in total.
func (a *App) pluginProblemCount() int {
	total := 0
	for _, count := range a.pluginDiagnosticCounts() {
		total += count
	}
	return total
}
