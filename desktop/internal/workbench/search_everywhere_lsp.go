package workbench

import (
	"context"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Search Everywhere also lists the symbols the project's language servers report through
// workspace/symbol. Each server that declares workspaceSymbols is asked with the query, after the
// query has settled; the answers are ranked by Core's workspace.rankNames and joined to the Core
// index's results on the Classes, Symbols and All tabs. A kind that is a class (LSP 5, 10, 11, 23)
// is listed as a class; the others as symbols. A match is removed again when the query changes.

const (
	// pluginSemanticWorkspaceSymbols is the operation, featureWorkspaceSymbols the feature a server
	// declares for it, and pluginMethodWorkspaceSymbols the method Core reports the answer under.
	pluginSemanticWorkspaceSymbols = "workspaceSymbols"
	featureWorkspaceSymbols        = "workspaceSymbols"
	pluginMethodWorkspaceSymbols   = "workspace/symbol"
	// everywhereSymbolDelay is how long the query must stay unchanged before the servers are asked.
	everywhereSymbolDelay = 200 * time.Millisecond
	// everywhereSymbolLimit bounds the symbols kept from all servers together.
	everywhereSymbolLimit = 1000
)

// everywhereClassKinds are the LSP SymbolKind numbers listed on the Classes tab: Class, Enum,
// Interface and Struct.
var everywhereClassKinds = map[int]bool{5: true, 10: true, 11: true, 23: true}

// everywhereSymbolState is the project's workspace/symbol query: its generation, the requests in
// flight, the symbols answered so far and the ranked matches shown.
type everywhereSymbolState struct {
	generation uint64
	query      string
	cancel     context.CancelFunc
	pending    []*semanticPending
	items      []core.WorkspaceSymbol
	itemKeys   map[string]bool
	servers    []string
	ranked     []core.WorkspaceSearchMatch
	// lspKeys are the keys of the matches this state added to the Search Everywhere list, so
	// they can be taken out again before the list is rebuilt.
	lspKeys map[string]bool
}

// everywhereMatchKey is the identity of a match for de-duplication: path, line and name.
func everywhereMatchKey(path string, line int, name string) string {
	return path + "\x00" + strconv.Itoa(line) + "\x00" + name
}

// startEverywhereSymbols begins a new workspace/symbol query for the project: the previous one is
// cancelled and its answers dropped, and the servers are asked after the debounce if the tab shows
// symbols at all.
func (a *App) startEverywhereSymbols(p *project, query string, scope int) {
	if p == nil {
		return
	}
	st := &p.everywhereSymbols
	a.cancelEverywhereSymbols(p)
	st.generation++
	st.query = query
	st.items, st.itemKeys, st.ranked = nil, nil, nil
	if strings.TrimSpace(query) == "" || !everywhereShowsSymbols(scope) || a.plugins == nil {
		return
	}
	servers := a.workspaceSymbolServers(p)
	if len(servers) == 0 {
		return
	}
	ctx, cancel := context.WithCancel(p.ctx)
	st.cancel = cancel
	generation := st.generation
	st.pending = nil
	for _, server := range servers {
		pending := &semanticPending{kind: pluginSemanticWorkspaceSymbols, generation: generation, project: p, server: server}
		st.pending = append(st.pending, pending)
		a.semantics.pending = append(a.semantics.pending, pending)
	}
	// The goroutine reads its own copy: the window thread keeps the list as answers arrive.
	pendings := append([]*semanticPending(nil), st.pending...)
	plugins := a.plugins
	request := core.PluginSemanticRequest{Operation: pluginSemanticWorkspaceSymbols, Query: query}
	a.background(p, 0, func(context.Context) func(*App) {
		timer := time.NewTimer(everywhereSymbolDelay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			return func(*App) {}
		}
		type started struct {
			pending   *semanticPending
			operation string
			err       error
		}
		results := make([]started, 0, len(pendings))
		for _, pending := range pendings {
			if pending.server == nil || pending.server.session == nil {
				continue
			}
			operation, err := plugins.RequestLanguageSession(ctx, pending.server.session, request)
			results = append(results, started{pending: pending, operation: operation, err: err})
		}
		ctxErr := ctx.Err()
		return func(a *App) {
			defer cancel()
			if st.generation != generation {
				return
			}
			for _, result := range results {
				a.semanticRequestStarted(result.pending, result.operation, result.err, ctxErr)
			}
		}
	})
}

// everywhereShowsSymbols reports whether a tab lists symbols: All, Classes and Symbols do.
func everywhereShowsSymbols(scope int) bool {
	return scope == 0 || scope == 1 || scope == 3
}

// cancelEverywhereSymbols drops the project's symbol query: its requests are cancelled, and an
// answer that arrives later is ignored because its pending entry is gone.
func (a *App) cancelEverywhereSymbols(p *project) {
	st := &p.everywhereSymbols
	if st.cancel != nil {
		st.cancel()
		st.cancel = nil
	}
	for _, pending := range st.pending {
		a.removePending(pending)
	}
	st.pending = nil
}

// workspaceSymbolServers are the ready language servers of the project that declare workspaceSymbols.
func (a *App) workspaceSymbolServers(p *project) []*pluginServer {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	var servers []*pluginServer
	for _, server := range a.pluginServers {
		if server != nil && server.project == p && server.isReady() && server.features[featureWorkspaceSymbols] {
			servers = append(servers, server)
		}
	}
	return servers
}

// applyWorkspaceSymbols takes one server's workspace/symbol answer, adds its symbols to the query
// and ranks them all in the background. An answer for a replaced query is dropped.
func (a *App) applyWorkspaceSymbols(pending *semanticPending, event core.BackendEvent, failed bool) {
	p := pending.project
	if p == nil || p != a.project {
		return
	}
	st := &p.everywhereSymbols
	if st.generation != pending.generation {
		return
	}
	st.pending = removePendingEntry(st.pending, pending)
	if failed {
		return
	}
	symbols, err := core.PluginWorkspaceSymbols(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_symbols", err))
		return
	}
	if st.itemKeys == nil {
		st.itemKeys = map[string]bool{}
	}
	added := false
	for _, symbol := range symbols {
		if len(st.items) >= everywhereSymbolLimit {
			break
		}
		path, ok := everywhereSymbolPath(p, symbol.URI)
		if !ok || symbol.Name == "" {
			continue
		}
		line := -1
		if symbol.Range != nil {
			line = symbol.Range.Start.Line
		}
		key := everywhereMatchKey(path, line, symbol.Name)
		if st.itemKeys[key] {
			continue
		}
		st.itemKeys[key] = true
		st.items = append(st.items, symbol)
		added = true
	}
	if !added {
		return
	}
	candidates := make([]core.RankCandidate, 0, len(st.items))
	for _, item := range st.items {
		path, _ := everywhereSymbolPath(p, item.URI)
		candidates = append(candidates, core.RankCandidate{Name: item.Name, Path: path})
	}
	items := append([]core.WorkspaceSymbol(nil), st.items...)
	query, generation, kernel := st.query, st.generation, a.kernel
	a.background(p, searchTimeout, func(ctx context.Context) func(*App) {
		order, err := kernel.RankNames(ctx, query, candidates)
		return func(a *App) {
			if st.generation != generation {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_symbols_rank", err))
				return
			}
			st.ranked = everywhereRankedMatches(p, items, order)
			a.everywhereSymbolsMerge(p)
		}
	})
}

// removePendingEntry drops one pending request from a list, keeping the order of the rest.
func removePendingEntry(list []*semanticPending, pending *semanticPending) []*semanticPending {
	for i, candidate := range list {
		if candidate == pending {
			return append(list[:i], list[i+1:]...)
		}
	}
	return list
}

// everywhereSymbolPath is the project-relative slash path of a symbol's file URI, or false when the
// file is not in the project.
func everywhereSymbolPath(p *project, uri string) (string, bool) {
	target, err := url.Parse(uri)
	if err != nil || strings.ToLower(target.Scheme) != "file" {
		return "", false
	}
	abs := fileURIPath(target)
	relative, ok := projectRelative(p.root, abs)
	if !ok {
		return "", false
	}
	return filepath.ToSlash(relative), true
}

// everywhereRankedMatches turns the symbols in Core's ranking order into search matches. A symbol
// without a range opens its file without moving the caret, so its line is left empty.
func everywhereRankedMatches(p *project, items []core.WorkspaceSymbol, order []int) []core.WorkspaceSearchMatch {
	matches := make([]core.WorkspaceSearchMatch, 0, len(order))
	for _, index := range order {
		if index < 0 || index >= len(items) {
			continue
		}
		item := items[index]
		path, ok := everywhereSymbolPath(p, item.URI)
		if !ok {
			continue
		}
		kind := "symbol"
		if everywhereClassKinds[item.Kind] {
			kind = "type"
		}
		name := item.Name
		match := core.WorkspaceSearchMatch{Kind: kind, Path: path, Preview: name, SymbolName: &name}
		if item.ContainerName != "" {
			match.Preview = item.ContainerName + "." + name
		}
		if item.Range != nil {
			line := item.Range.Start.Line + 1
			match.Line = &line
		}
		matches = append(matches, match)
	}
	return matches
}

// everywhereStripSymbols takes the symbol matches out of the list, before a Core answer rebuilds it.
func (a *App) everywhereStripSymbols(p *project) {
	st := &p.everywhereSymbols
	if len(st.lspKeys) == 0 {
		return
	}
	s := &p.everywhere
	kept := s.matches[:0:0]
	for _, match := range s.matches {
		if !st.lspKeys[everywhereMatchOf(match)] {
			kept = append(kept, match)
		}
	}
	s.matches = kept
	st.lspKeys = nil
}

// everywhereSymbolsMerge appends the ranked symbols of the tab to the list, skipping any the Core
// index already lists, and keeps the list within its limit.
func (a *App) everywhereSymbolsMerge(p *project) {
	if p == nil {
		return
	}
	st := &p.everywhereSymbols
	s := &p.everywhere
	a.everywhereStripSymbols(p)
	if st.generation == 0 || strings.TrimSpace(st.query) == "" || strings.TrimSpace(s.query) != strings.TrimSpace(st.query) {
		return
	}
	seen := make(map[string]bool, len(s.matches))
	for _, match := range s.matches {
		seen[everywhereMatchOf(match)] = true
	}
	for _, match := range st.ranked {
		// The tab's kinds, which on All leave out what its filter unticked.
		if !slices.Contains(strings.Split(s.options.kinds, ","), match.Kind) {
			continue
		}
		key := everywhereMatchOf(match)
		if seen[key] {
			continue
		}
		seen[key] = true
		if st.lspKeys == nil {
			st.lspKeys = map[string]bool{}
		}
		st.lspKeys[key] = true
		s.matches = append(s.matches, match)
	}
	if len(s.matches) > everywhereMaxResults {
		s.matches = s.matches[:everywhereMaxResults]
	}
}

// everywhereMatchOf is the de-duplication key of a match: its path, line and name.
func everywhereMatchOf(match core.WorkspaceSearchMatch) string {
	line := -1
	if match.Line != nil {
		line = *match.Line - 1
	}
	name := ""
	if match.SymbolName != nil {
		name = *match.SymbolName
	}
	return everywhereMatchKey(match.Path, line, name)
}
