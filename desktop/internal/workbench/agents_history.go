package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/vivaui/viva/ui"
)

// This file is the History tab's state (agents_history_view.go draws it): the recorded sessions
// of the agents the user lets Lithe read, listed page by page through Core in the scope, order
// and filters the user chose, or the sessions a search found; the refresh that reads the
// changed session files first; and a preview of each row's last message, read on demand.
// Titles, previews and directories stay in this window's memory and are never logged; the tab
// logs only its actions and, when one fails, Core's error code.

const (
	// agentHistoryPage is how many sessions one page of the list asks Core for.
	agentHistoryPage = 100
	// agentSearchLimit is the most search hits one search asks for; each distinct session among
	// them is one row.
	agentSearchLimit = 100
	// agentScopeDirectories is the most directories a scope names; Core takes up to 64.
	agentScopeDirectories = 64
	// agentPreviewBatch is how many previews one background read takes.
	agentPreviewBatch = 24
	// agentPreviewQueue bounds the previews waiting to be read; rows that scrolled away drop out.
	agentPreviewQueue = 2 * agentPreviewBatch
	// agentPreviewCache bounds the previews kept, the oldest dropped first.
	agentPreviewCache = 600
	// agentPreviewChars is the most characters a preview keeps; a row shows two lines.
	agentPreviewChars = 400
	// agentPreviewMaxBytes is the largest message a preview reads; a longer one shows none.
	agentPreviewMaxBytes = 1 << 20
)

// agentHistoryScope is which directories the History tab lists sessions of.
type agentHistoryScope int

const (
	// agentScopeWorkspace lists the sessions run in the open folder or below it.
	agentScopeWorkspace agentHistoryScope = iota
	// agentScopeProject lists the sessions of the folder's repository and all its worktrees.
	agentScopeProject
	// agentScopeAll lists the sessions of every directory.
	agentScopeAll
)

// agentHistoryOrder is how the History tab orders its rows.
type agentHistoryOrder int

const (
	// agentOrderLatest puts the latest first: in the list the latest activity, as Core orders it;
	// in search results the newest match, as Core's search does.
	agentOrderLatest agentHistoryOrder = iota
	// agentOrderUpdated puts the latest activity first; search results only offer it, since it
	// is the list's latest already.
	agentOrderUpdated
	// agentOrderStarted puts the latest start first.
	agentOrderStarted
)

// agentHistorySince is how recent a session's last activity must be to be listed.
type agentHistorySince int

const (
	agentSinceAny agentHistorySince = iota
	agentSinceToday
	agentSinceWeek
	agentSinceMonth
)

// agentHistoryPopup is the header menu or popover of the History tab that is open.
type agentHistoryPopup int

const (
	agentPopupNone agentHistoryPopup = iota
	agentPopupHost
	agentPopupFilter
	agentPopupOrder
)

// agentHistory is the History tab: the recorded sessions of the agents the user lets Lithe
// read, or the sessions a search found, grouped by directory.
type agentHistory struct {
	query string
	// searched is the query the shown rows answer, empty when they list sessions.
	searched string
	scope    agentHistoryScope
	// order orders the list, by Core; searchOrder orders search results, here.
	order       agentHistoryOrder
	searchOrder agentHistoryOrder
	// hidden are the agent keys the filter leaves out.
	hidden map[string]bool
	since  agentHistorySince
	// compact hides the previews.
	compact bool

	loading bool
	loaded  bool
	// more is set while the next page is on its way; moreFailed stops loading pages on scroll
	// until the user asks again.
	more       bool
	moreFailed bool
	// wantsList and wantsMore are set by a paint that declares the tab before its list was read,
	// or with the row after the loaded sessions in view; the paint's end starts the read
	// (endAgentHistoryFrame).
	wantsList bool
	wantsMore bool
	// generation discards the answer of a load a newer one replaced.
	generation uint64
	sessions   []agents.RecordedSession
	// total is how many sessions the list's filters keep; groupCounts counts them by directory.
	total       uint64
	groupCounts map[string]uint64
	// hits is the best hit of each session a search found, by agentSessionKey.
	hits    map[string]agents.SearchHit
	failure string

	refreshing  bool
	refreshedAt time.Time
	syncs       []agentSyncResult
	// statusOpen shows what the last refresh read of each agent.
	statusOpen bool

	collapsed map[string]bool
	expanded  map[string]bool
	// menu is the agentSessionKey of the row whose menu is open.
	menu  string
	popup agentHistoryPopup

	rows     []agentHistoryRow
	list     ui.ListState
	previews agentPreviews
	// record is the recorded session shown in place of the list, nil when the list shows.
	record *agentRecord
}

// agentSyncResult is what a refresh read of one agent's session files.
type agentSyncResult struct {
	agent  string
	report agents.SyncReport
	// failure is why the agent could not be read, empty when it was.
	failure string
}

// agentHistoryRowKind is what a row of the History tab's list is.
type agentHistoryRowKind int

const (
	agentRowGroup agentHistoryRowKind = iota
	agentRowSession
	agentRowMore
)

// agentHistoryRow is one row of the list: a directory's heading, a session (index into
// sessions) or the row that loads the next page.
type agentHistoryRow struct {
	kind    agentHistoryRowKind
	cwd     string
	session int
	// count is how many loaded sessions a heading's directory has.
	count int
}

// agentSessionKey names a session among every agent's sessions.
func agentSessionKey(agent, sessionID string) string {
	return agent + "\x00" + sessionID
}

// searching reports whether the rows are search results.
func (h *agentHistory) searching() bool { return h.searched != "" }

// shownOrder is the order the rows are in.
func (h *agentHistory) shownOrder() agentHistoryOrder {
	if h.searching() {
		return h.searchOrder
	}
	return h.order
}

// filtersActive is how many of the filter's choices narrow the list, for the badge on its button.
func (h *agentHistory) filtersActive() int {
	n := 0
	if len(h.hidden) > 0 {
		n++
	}
	if h.since != agentSinceAny {
		n++
	}
	return n
}

// rebuildRows lays the sessions out under their directories, in the order each directory first
// appears, leaving out the rows of collapsed directories; a list with more pages ends in the row
// that loads the next one.
func (h *agentHistory) rebuildRows() {
	var order []string
	members := map[string][]int{}
	for i, session := range h.sessions {
		if _, seen := members[session.Cwd]; !seen {
			order = append(order, session.Cwd)
		}
		members[session.Cwd] = append(members[session.Cwd], i)
	}
	rows := make([]agentHistoryRow, 0, len(order)+len(h.sessions)+1)
	for _, cwd := range order {
		rows = append(rows, agentHistoryRow{kind: agentRowGroup, cwd: cwd, count: len(members[cwd])})
		if h.collapsed[cwd] {
			continue
		}
		for _, index := range members[cwd] {
			rows = append(rows, agentHistoryRow{kind: agentRowSession, cwd: cwd, session: index})
		}
	}
	if h.hasMore() {
		rows = append(rows, agentHistoryRow{kind: agentRowMore})
	}
	h.rows = rows
}

// isEndSpace reports whether a row of the list is the blank space after its last row; the list
// treats it as a heading, so it is never chosen, focused or typed to.
func (h *agentHistory) isEndSpace(row int) bool { return row >= len(h.rows) }

// hasMore reports whether the list has pages not loaded yet.
func (h *agentHistory) hasMore() bool {
	return !h.searching() && uint64(len(h.sessions)) < h.total
}

// groupCount is how many sessions a directory's heading counts: Core's count over the whole
// list, or the loaded rows when Core gave none (search results, or a group past Core's bound).
func (h *agentHistory) groupCount(row agentHistoryRow) uint64 {
	if count, ok := h.groupCounts[row.cwd]; ok && !h.searching() {
		return count
	}
	return uint64(row.count)
}

// toggleGroup collapses or expands a directory's rows.
func (h *agentHistory) toggleGroup(cwd string) {
	if h.collapsed == nil {
		h.collapsed = map[string]bool{}
	}
	if h.collapsed[cwd] {
		delete(h.collapsed, cwd)
	} else {
		h.collapsed[cwd] = true
	}
	h.rebuildRows()
}

// toggleExpanded opens or closes a session's details.
func (h *agentHistory) toggleExpanded(key string) {
	if h.expanded == nil {
		h.expanded = map[string]bool{}
	}
	if h.expanded[key] {
		delete(h.expanded, key)
	} else {
		h.expanded[key] = true
	}
}

// agentHistoryRequest is what one load asks Core for, taken on the window thread.
type agentHistoryRequest struct {
	keys  []string
	query string
	scope agentHistoryScope
	// root is the open folder; repository is its repository's top level, empty outside Git.
	root       string
	repository string
	order      agentHistoryOrder
	sinceMs    int64
	offset     int
}

// agentHistoryAnswer is what one load found, handed to the window thread.
type agentHistoryAnswer struct {
	sessions    []agents.RecordedSession
	total       uint64
	groupCounts map[string]uint64
	hits        map[string]agents.SearchHit
	err         error
}

// historyRequest is the request for the tab's current choices, from offset on.
func (a *App) historyRequest(p *project, offset int) agentHistoryRequest {
	h := &a.agentsView.history
	var keys []string
	for _, key := range a.agentsView.readableAgents() {
		if !h.hidden[key] {
			keys = append(keys, key)
		}
	}
	request := agentHistoryRequest{
		keys: keys, query: strings.TrimSpace(h.query), scope: h.scope, root: p.root,
		order: h.order, sinceMs: agentSinceMs(h.since, time.Now()), offset: offset,
	}
	if p.git.status.RepositoryRoot != "" {
		request.repository = p.git.repositoryRoot(p.root)
	}
	return request
}

// agentSinceMs is the earliest last activity a choice lists, 0 for any.
func agentSinceMs(since agentHistorySince, now time.Time) int64 {
	switch since {
	case agentSinceToday:
		year, month, day := now.Date()
		return time.Date(year, month, day, 0, 0, 0, 0, now.Location()).UnixMilli()
	case agentSinceWeek:
		return now.AddDate(0, 0, -7).UnixMilli()
	case agentSinceMonth:
		return now.AddDate(0, 0, -30).UnixMilli()
	}
	return 0
}

// loadAgentHistory lists the sessions, or the hits of the search field's query, from the start.
func (a *App) loadAgentHistory(p *project) {
	v := &a.agentsView
	h := &v.history
	if p == nil || a.agentKernel == nil || p.remote != nil || len(v.readableAgents()) == 0 {
		return
	}
	request := a.historyRequest(p, 0)
	h.generation++
	generation := h.generation
	h.loading, h.more, h.moreFailed, h.failure, h.menu = true, false, false, "", ""
	if len(request.keys) == 0 {
		// The filter leaves out every agent; Core would read an empty list as every agent.
		a.applyAgentHistory(request, agentHistoryAnswer{})
		return
	}
	agentsKernel, kernel := a.agentKernel, a.kernel
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		answer := runAgentHistory(ctx, agentsKernel, kernel, request)
		return func(a *App) {
			if a.agentsView.history.generation != generation {
				return
			}
			a.applyAgentHistory(request, answer)
		}
	})
}

// applyAgentHistory shows what a load from the start found.
func (a *App) applyAgentHistory(request agentHistoryRequest, answer agentHistoryAnswer) {
	h := &a.agentsView.history
	h.loading, h.loaded = false, true
	h.searched = request.query
	h.sessions, h.total, h.groupCounts, h.hits = answer.sessions, answer.total, answer.groupCounts, answer.hits
	h.list = ui.ListState{}
	if answer.err != nil {
		a.backgroundFailed("agents_history", answer.err)
		h.failure = a.agentFailure(answer.err)
	}
	h.sortSearch()
	h.rebuildRows()
}

// sortSearch puts search results in the order chosen for them: by their newest match, as Core
// found them, or by their sessions' latest activity or start.
func (h *agentHistory) sortSearch() {
	if !h.searching() {
		return
	}
	at := func(session agents.RecordedSession) int64 {
		switch h.searchOrder {
		case agentOrderUpdated:
			return session.UpdatedAtMs
		case agentOrderStarted:
			return session.StartedAtMs
		}
		return h.hits[agentSessionKey(session.Agent, session.SessionID)].AtMs
	}
	slices.SortStableFunc(h.sessions, func(left, right agents.RecordedSession) int {
		switch l, r := at(left), at(right); {
		case l > r:
			return -1
		case l < r:
			return 1
		}
		return 0
	})
}

// chooseAgentHistoryOrder orders the rows: search results here, the list by asking Core for it
// again.
func (a *App) chooseAgentHistoryOrder(p *project, order agentHistoryOrder) {
	h := &a.agentsView.history
	if h.searching() {
		if h.searchOrder != order {
			h.searchOrder = order
			h.sortSearch()
			h.rebuildRows()
		}
		return
	}
	if h.order != order {
		h.order = order
		a.loadAgentHistory(p)
	}
}

// loadMoreAgentHistory lists the next page of sessions after the loaded ones.
func (a *App) loadMoreAgentHistory(p *project) {
	v := &a.agentsView
	h := &v.history
	if p == nil || a.agentKernel == nil || h.loading || h.more || !h.hasMore() {
		return
	}
	request := a.historyRequest(p, len(h.sessions))
	request.query = ""
	if len(request.keys) == 0 {
		return
	}
	h.more, h.moreFailed = true, false
	generation := h.generation
	agentsKernel, kernel := a.agentKernel, a.kernel
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		answer := runAgentHistory(ctx, agentsKernel, kernel, request)
		return func(a *App) {
			h := &a.agentsView.history
			if h.generation != generation {
				return
			}
			h.more = false
			if answer.err != nil {
				h.moreFailed = true
				a.backgroundFailed("agents_history", answer.err)
				return
			}
			h.sessions = appendNewSessions(h.sessions, answer.sessions)
			h.total, h.groupCounts = answer.total, answer.groupCounts
			if len(answer.sessions) == 0 {
				// The list shrank while it was read; stop asking for pages that are not there.
				h.total = uint64(len(h.sessions))
			}
			h.rebuildRows()
		}
	})
}

// appendNewSessions appends the sessions of a further page that the loaded ones lack: a session
// that moved up the list since the earlier page was read would otherwise show twice.
func appendNewSessions(loaded, page []agents.RecordedSession) []agents.RecordedSession {
	seen := make(map[string]bool, len(loaded))
	for _, session := range loaded {
		seen[agentSessionKey(session.Agent, session.SessionID)] = true
	}
	for _, session := range page {
		if key := agentSessionKey(session.Agent, session.SessionID); !seen[key] {
			seen[key] = true
			loaded = append(loaded, session)
		}
	}
	return loaded
}

// runAgentHistory answers a request off the window thread: a page of the list, or the sessions
// of a search's hits in the scope and time the request keeps.
func runAgentHistory(ctx context.Context, agentsKernel *agents.Client, kernel Kernel, request agentHistoryRequest) agentHistoryAnswer {
	directories := agentScopeDirectoryList(ctx, kernel, request)
	if request.query == "" {
		order := "updated"
		if request.order == agentOrderStarted {
			order = "started"
		}
		page, err := agentsKernel.ListPage(ctx, agents.ListQuery{
			Agents: request.keys, CwdUnder: directories, ActiveSinceMs: request.sinceMs,
			Order: order, Offset: request.offset, Limit: agentHistoryPage, Titles: true,
		})
		if err != nil {
			return agentHistoryAnswer{err: err}
		}
		counts := make(map[string]uint64, len(page.Groups))
		if !page.GroupsTruncated {
			for _, group := range page.Groups {
				counts[group.Cwd] = group.Count
			}
		}
		return agentHistoryAnswer{sessions: page.Sessions, total: page.Total, groupCounts: counts}
	}
	hits, err := agentsKernel.Search(ctx, agents.SearchQuery{Text: request.query, Agents: request.keys, Limit: agentSearchLimit})
	if err != nil {
		return agentHistoryAnswer{err: err}
	}
	best := map[string]agents.SearchHit{}
	var sessions []agents.RecordedSession
	for _, hit := range hits {
		key := agentSessionKey(hit.Agent, hit.SessionID)
		if _, seen := best[key]; seen {
			continue
		}
		best[key] = hit
		found, err := agentsKernel.List(ctx, agents.ListQuery{Agents: []string{hit.Agent}, SessionID: hit.SessionID, Limit: 1, Titles: true})
		if err != nil {
			return agentHistoryAnswer{err: err}
		}
		session := agents.RecordedSession{
			Agent: hit.Agent, SessionID: hit.SessionID, Path: hit.Path, PluginID: hit.PluginID,
			AgentID: hit.AgentID, UpdatedAtMs: hit.AtMs,
		}
		if len(found) > 0 {
			session = found[0]
		}
		if directories != nil && !underAny(session.Cwd, directories) {
			continue
		}
		if request.sinceMs > 0 && session.UpdatedAtMs < request.sinceMs {
			continue
		}
		sessions = append(sessions, session)
	}
	return agentHistoryAnswer{sessions: sessions, total: uint64(len(sessions)), hits: best}
}

// agentScopeDirectoryList is the directories a scope lists the sessions of, nil for every
// directory: the open folder, or its repository's top level and every worktree of it (the open
// folder alone when it is not in a repository, with the top level when the worktrees cannot be
// read).
func agentScopeDirectoryList(ctx context.Context, kernel Kernel, request agentHistoryRequest) []string {
	switch request.scope {
	case agentScopeAll:
		return nil
	case agentScopeProject:
		if request.repository == "" || kernel == nil {
			return []string{request.root}
		}
		directories := []string{request.repository, request.root}
		worktrees, err := kernel.GitWorktrees(ctx, request.repository)
		if err == nil {
			for _, worktree := range worktrees {
				if !worktree.IsBare && worktree.Path != "" {
					directories = append(directories, worktree.Path)
				}
			}
		}
		return scopeDirectories(directories)
	}
	return []string{request.root}
}

// scopeDirectories drops empty and repeated directories, and any that lie under another one
// (they add nothing), keeping at most agentScopeDirectories.
func scopeDirectories(directories []string) []string {
	var kept []string
	for _, directory := range directories {
		directory = filepath.Clean(directory)
		if directory == "." || slices.Contains(kept, directory) {
			continue
		}
		kept = append(kept, directory)
	}
	var out []string
	for _, directory := range kept {
		others := slices.DeleteFunc(slices.Clone(kept), func(other string) bool { return other == directory })
		if !underAny(directory, others) {
			out = append(out, directory)
		}
	}
	if len(out) > agentScopeDirectories {
		out = out[:agentScopeDirectories]
	}
	return out
}

// underAny reports whether cwd is one of directories or lies under one of them, as Core's
// cwdUnder matches it: by whole path components.
func underAny(cwd string, directories []string) bool {
	if cwd == "" {
		return false
	}
	for _, directory := range directories {
		directory = strings.TrimRight(directory, `/\`)
		if directory == "" {
			// The file system's root holds every directory.
			return true
		}
		if cwd == directory || strings.HasPrefix(cwd, directory) && strings.ContainsRune(`/\`, rune(cwd[len(directory)])) {
			return true
		}
	}
	return false
}

// refreshAgentHistory reads the changed session files of every agent the user lets Lithe read,
// starting each agent's backend first, then lists the sessions again.
func (a *App) refreshAgentHistory(p *project) {
	v := &a.agentsView
	h := &v.history
	keys := v.readableAgents()
	if p == nil || a.agentKernel == nil || p.remote != nil || len(keys) == 0 || h.refreshing {
		return
	}
	h.refreshing, h.failure = true, ""
	kernel, service := a.agentKernel, a.plugins
	var catalog []agents.CatalogAgent
	for _, agent := range v.catalog {
		if slices.Contains(keys, agent.Key()) {
			catalog = append(catalog, agent)
		}
	}
	a.background(p, agentSyncTimeout, func(ctx context.Context) func(*App) {
		reports := make([]agents.SyncReport, len(catalog))
		failures := make([]error, len(catalog))
		for i, agent := range catalog {
			if service != nil {
				if err := service.EnsureAgentBackend(ctx, agent.PluginID, agent.AgentID); err != nil {
					failures[i] = err
					continue
				}
			}
			reports[i], failures[i] = kernel.Sync(ctx, agent.PluginID, agent.AgentID)
		}
		return func(a *App) {
			h := &a.agentsView.history
			h.refreshing, h.refreshedAt = false, time.Now()
			h.syncs = h.syncs[:0]
			for i, agent := range catalog {
				result := agentSyncResult{agent: agent.DisplayName, report: reports[i]}
				if failures[i] != nil {
					result.failure = a.agentFailure(failures[i])
				}
				h.syncs = append(h.syncs, result)
			}
			if failure := errors.Join(failures...); failure != nil {
				a.backgroundFailed("agents_history_sync", failure)
			}
			a.loadAgentHistory(p)
		}
	})
}

// refreshFailed reports whether the last refresh could not read some agent.
func (h *agentHistory) refreshFailed() bool {
	return slices.ContainsFunc(h.syncs, func(result agentSyncResult) bool { return result.failure != "" })
}

// forgetUnreadable drops what the tab holds of agents the user no longer lets Lithe read, and
// asks for a new list.
func (h *agentHistory) forgetUnreadable(readable []string) {
	h.sessions = slices.DeleteFunc(h.sessions, func(session agents.RecordedSession) bool {
		return !slices.Contains(readable, session.Agent)
	})
	for key, hit := range h.hits {
		if !slices.Contains(readable, hit.Agent) {
			delete(h.hits, key)
		}
	}
	h.previews.forget(func(key agentPreviewKey) bool { return !slices.Contains(readable, key.agent) })
	h.rebuildRows()
	h.loaded = false
}

// agentPreviewKey names the span of a session file a preview is read from: the session's last
// message, or a search hit.
type agentPreviewKey struct {
	agent, path string
	start, end  uint64
}

// agentPreview is a row's preview: who spoke ("user", "assistant", "thought", "tool") and the
// start of what they said, on one line. A failed or empty read keeps an empty preview, so it is
// not read again until the span changes.
type agentPreview struct {
	role     string
	toolName string
	text     string
}

// agentPreviews holds the previews read so far and those waiting to be read. They live in this
// window's memory only; Core keeps no message text for them.
type agentPreviews struct {
	done    map[agentPreviewKey]agentPreview
	order   []agentPreviewKey
	queue   []agentPreviewKey
	loading bool
}

// lookup is a preview read so far.
func (previews *agentPreviews) lookup(key agentPreviewKey) (agentPreview, bool) {
	preview, ok := previews.done[key]
	return preview, ok
}

// want queues a preview that has not been read, keeping the latest wanted (the rows on screen).
func (previews *agentPreviews) want(key agentPreviewKey) {
	if _, ok := previews.done[key]; ok || slices.Contains(previews.queue, key) {
		return
	}
	previews.queue = append(previews.queue, key)
	if extra := len(previews.queue) - agentPreviewQueue; extra > 0 {
		previews.queue = slices.Delete(previews.queue, 0, extra)
	}
}

// take removes the next batch to read, the latest wanted first.
func (previews *agentPreviews) take() []agentPreviewKey {
	n := min(len(previews.queue), agentPreviewBatch)
	batch := slices.Clone(previews.queue[len(previews.queue)-n:])
	previews.queue = previews.queue[:len(previews.queue)-n]
	slices.Reverse(batch)
	return batch
}

// store keeps a preview, dropping the oldest beyond agentPreviewCache.
func (previews *agentPreviews) store(key agentPreviewKey, preview agentPreview) {
	if previews.done == nil {
		previews.done = map[agentPreviewKey]agentPreview{}
	}
	if _, ok := previews.done[key]; !ok {
		previews.order = append(previews.order, key)
	}
	previews.done[key] = preview
	for len(previews.order) > agentPreviewCache {
		delete(previews.done, previews.order[0])
		previews.order = previews.order[1:]
	}
}

// forget drops the previews, read or waiting, that drop reports.
func (previews *agentPreviews) forget(drop func(agentPreviewKey) bool) {
	for key := range previews.done {
		if drop(key) {
			delete(previews.done, key)
		}
	}
	previews.order = slices.DeleteFunc(previews.order, drop)
	previews.queue = slices.DeleteFunc(previews.queue, drop)
}

// previewKeyOf is the span a session row previews: the hit a search found in it, or its last
// message. It reports false when the session records no message.
func (h *agentHistory) previewKeyOf(session agents.RecordedSession) (agentPreviewKey, bool) {
	if hit, ok := h.hits[agentSessionKey(session.Agent, session.SessionID)]; ok && h.searching() {
		return agentPreviewKey{agent: hit.Agent, path: hit.Path, start: hit.Range.Start, end: hit.Range.End}, true
	}
	if span := session.LastMessageRange; span != nil && span.End > span.Start {
		return agentPreviewKey{agent: session.Agent, path: session.Path, start: span.Start, end: span.End}, true
	}
	return agentPreviewKey{}, false
}

// endAgentHistoryFrame starts the reads the History tab's paint asked for: the list, its next
// page, and the previews of the rows it declared. The paint only notes them, as an After runs
// only after a paint that delivers an event, and a row that scrolls into view or a list that
// first shows comes with none.
func (a *App) endAgentHistoryFrame() {
	h := &a.agentsView.history
	wantsList, wantsMore := h.wantsList, h.wantsMore
	h.wantsList, h.wantsMore = false, false
	p := a.project
	if p == nil {
		return
	}
	if wantsList && !h.loaded && !h.loading && !h.refreshing {
		a.loadAgentHistory(p)
	}
	if wantsMore && h.loaded && !h.more && !h.moreFailed {
		a.loadMoreAgentHistory(p)
	}
	a.loadAgentPreviews(p)
}

// loadAgentPreviews reads the next batch of previews through Core, off the window thread.
func (a *App) loadAgentPreviews(p *project) {
	previews := &a.agentsView.history.previews
	kernel := a.agentKernel
	if p == nil || kernel == nil || previews.loading || len(previews.queue) == 0 {
		return
	}
	batch := previews.take()
	previews.loading = true
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		read := make([]agentPreview, len(batch))
		var failure error
		for i, key := range batch {
			if key.end-key.start > agentPreviewMaxBytes {
				continue
			}
			result, err := kernel.Read(ctx, key.agent, key.path, agents.ByteRange{Start: key.start, End: key.end})
			if err != nil {
				failure = err
				continue
			}
			if !result.Changed {
				read[i] = previewOf(result.Messages)
			}
		}
		return func(a *App) {
			previews := &a.agentsView.history.previews
			previews.loading = false
			readable := a.agentsView.readableAgents()
			for i, key := range batch {
				if slices.Contains(readable, key.agent) {
					previews.store(key, read[i])
				}
			}
			if failure != nil {
				a.backgroundFailed("agents_preview", failure)
			}
			a.loadAgentPreviews(p)
		}
	})
}

// previewOf is the preview of the last message with words among messages.
func previewOf(messages []agents.RecordedMessage) agentPreview {
	for i := len(messages) - 1; i >= 0; i-- {
		if text := previewText(messages[i].Text); text != "" {
			return agentPreview{role: messages[i].Role, toolName: messages[i].ToolName, text: text}
		}
	}
	return agentPreview{}
}

// previewText is text on one line: every run of white space one space, cut to agentPreviewChars
// characters. Markdown stays as it is.
func previewText(text string) string {
	var b strings.Builder
	space, count := false, 0
	for _, r := range text {
		if r == utf8.RuneError || unicode.IsControl(r) && !unicode.IsSpace(r) {
			continue
		}
		if unicode.IsSpace(r) {
			space = b.Len() > 0
			continue
		}
		if count == agentPreviewChars {
			break
		}
		if space {
			b.WriteByte(' ')
			count++
			space = false
		}
		b.WriteRune(r)
		count++
	}
	return b.String()
}
