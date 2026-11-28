package workbench

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// This file serves the IDE API's two session tools, which let the MCP clients of a project's
// connection search and read the local session records of the user's agents (API-45). A
// connection declares them only while the user turned on "Allow MCP clients to search local
// sessions" and allowed Lithe to read at least one agent's sessions; every call checks both
// again on the window thread. Answers carry no file path, working directory or account, and
// the log records only the tool, the number of results and the duration.

const (
	// ideAPISessionHits bounds the hits one search answers.
	ideAPISessionHits = 20
	// ideAPIExcerptBytes bounds one hit's excerpt; twenty of them stay within the 32 KiB the
	// contract promises for one answer.
	ideAPIExcerptBytes = 1 << 10
	// ideAPIExcerptLead is how much text an excerpt keeps before the first query word.
	ideAPIExcerptLead = 160
	// ideAPISessionChunk is how many bytes of a session file one read of a page asks for; a
	// read this size holds about this much text at most, so the page bound is met only by a read made
	// larger for one long line.
	ideAPISessionChunk = 32 << 10
	// ideAPIMessageBytes bounds the text of one message a page answers.
	ideAPIMessageBytes = 4 << 10
	// ideAPIPageText bounds the message text of one page; a page stops reading once it holds
	// half of it, so the last read rarely meets the bound.
	ideAPIPageText = 64 << 10
	// ideAPIToolNameBytes bounds the tool name a message carries.
	ideAPIToolNameBytes = 128
	// ideAPIPageMessages bounds the messages of one page; a page stops reading once it holds
	// half of them, which one ideAPISessionChunk read cannot fill again.
	ideAPIPageMessages = 2000
)

// ideAPISessionTools are the session tools, served only while ideAPISessionsOffered holds.
var ideAPISessionTools = []string{"lithe_sessions_search", "lithe_sessions_read"}

// ideAPIServesSessions reports whether a connection's selection holds the session tools.
func ideAPIServesSessions(exposure []core.IDEToolExposure) bool {
	for _, tool := range exposure {
		if tool.Name == ideAPISessionTools[0] {
			return true
		}
	}
	return false
}

// ideAPIReadableAgents are the configured agents whose sessions the user lets Lithe read now.
// The saved consent is checked as well as the catalog, so taking a consent back refuses the
// next call before the agents are configured again. It runs on the window thread.
func (a *App) ideAPIReadableAgents() []agents.CatalogAgent {
	consent := agents.Consent(a.settings.AgentSessionConsent)
	var readable []agents.CatalogAgent
	for _, agent := range a.agentsView.catalog {
		if agent.ReadsSessions && agent.MayReadSessions && consent.Plugin(agent.PluginID) {
			readable = append(readable, agent)
		}
	}
	return readable
}

// ideAPISessionsOffered reports whether a connection should declare the session tools: the
// user turned the switch on and lets Lithe read at least one agent's sessions. It runs on the
// window thread.
func (a *App) ideAPISessionsOffered() bool {
	return a.settings.AgentSessionsMCPSearch && a.agentKernel != nil && len(a.ideAPIReadableAgents()) > 0
}

// refreshIDEAPISessionTools records whether connections declare the session tools and
// reconnects the open project's connection when what it declares is no longer right. The
// window thread calls it whenever the switch, a consent or the agent catalog changes.
func (a *App) refreshIDEAPISessionTools() {
	a.ideAPISessionsDeclared.Store(a.ideAPISessionsOffered())
	a.ideAPIReconnect(a.project)
}

// ideAPIReconnect closes the project's connection and opens it again with the same grants when
// the session tools it declares differ from what the window offers now. The descriptor path
// and the client configuration stay the same, so a client keeps its configuration and
// reconnects. A disable or enable in the meantime wins: the connection is not reopened.
func (a *App) ideAPIReconnect(p *project) {
	if p == nil {
		return
	}
	sessions := a.ideAPISessionsDeclared.Load()
	p.ideAPI.mu.Lock()
	conn := p.ideAPI.conn
	if conn == nil || ideAPIServesSessions(conn.exposure) == sessions {
		p.ideAPI.mu.Unlock()
		return
	}
	p.ideAPI.conn = nil
	p.ideAPI.closes++
	closes := p.ideAPI.closes
	p.ideAPI.mu.Unlock()
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		a.ideAPIStop(conn)
		p.ideAPI.mu.Lock()
		replaced := p.ideAPI.closes != closes || p.ideAPI.conn != nil
		p.ideAPI.mu.Unlock()
		if replaced || p.ctx.Err() != nil {
			return
		}
		helper, err := a.ideAPIHelperPath()
		if err == nil {
			_, err = a.ideAPIEnable(p, conn.permissions, helper)
		}
		// A disable that came while the connection was opening found none to close.
		p.ideAPI.mu.Lock()
		disabled := p.ideAPI.closes != closes
		p.ideAPI.mu.Unlock()
		if err == nil && disabled {
			a.ideAPIDisable(p)
		}
		ideAPISettings{a: a}.setError(err)
		a.invalidateSettingsWindow()
	}()
}

// ideAPISessionScope is what one session tool call may read, taken on the window thread.
type ideAPISessionScope struct {
	kernel  *agents.Client
	service *pluginservice.Service
	agents  []agents.CatalogAgent
}

// keys are the record keys of the agents the call may read.
func (s ideAPISessionScope) keys() []string {
	keys := make([]string, len(s.agents))
	for index, agent := range s.agents {
		keys[index] = agent.Key()
	}
	return keys
}

// agent returns the readable agent with the record key.
func (s ideAPISessionScope) agent(key string) (agents.CatalogAgent, bool) {
	for _, agent := range s.agents {
		if agent.Key() == key {
			return agent, true
		}
	}
	return agents.CatalogAgent{}, false
}

// ideAPISessionAccess checks on the window thread that the call may read sessions, and of
// which agents: agent, when not empty, narrows them to that one.
func (a *App) ideAPISessionAccess(ctx context.Context, conn *ideAPIConnection, agent string) (ideAPISessionScope, map[string]any) {
	answer := a.ideAPIOnProject(ctx, conn, func(p *project) any { return a.ideAPISessionGate(p, agent) })
	if scope, ok := answer.(ideAPISessionScope); ok {
		return scope, nil
	}
	failure, _ := answer.(map[string]any)
	return ideAPISessionScope{}, failure
}

// ideAPISessionGate is the scope a session tool call in p may read, or the failure that refuses
// it: the switch is off, the workspace is remote, the window has no records, or the user lets
// Lithe read no agent's sessions (or not agent's, when it names one). It runs on the window
// thread.
func (a *App) ideAPISessionGate(p *project, agent string) any {
	switch {
	case !a.settings.AgentSessionsMCPSearch:
		return ideAPIFailure("NOT_SUPPORTED", "Session search is turned off in Lithe's Agents settings")
	case p.remote != nil:
		return ideAPIFailure("NOT_AVAILABLE", "Agent sessions are not available in a remote workspace")
	case a.agentKernel == nil:
		return ideAPIFailure("NOT_AVAILABLE", "Agent sessions are not available in this window")
	}
	scope := ideAPISessionScope{kernel: a.agentKernel, service: a.plugins}
	for _, candidate := range a.ideAPIReadableAgents() {
		if agent == "" || candidate.Key() == agent {
			scope.agents = append(scope.agents, candidate)
		}
	}
	if len(scope.agents) > 0 {
		return scope
	}
	if agent != "" {
		return ideAPIFailure("PERMISSION_DENIED", "The user has not allowed Lithe to read this agent's sessions")
	}
	return ideAPIFailure("NOT_AVAILABLE", "The user has not allowed Lithe to read any agent's sessions")
}

// ensureBackend starts the plugin backend that parses an agent's session files, once per call.
func (s ideAPISessionScope) ensureBackend(ctx context.Context, started map[string]error, agent agents.CatalogAgent) error {
	key := agent.Key()
	if err, done := started[key]; done {
		return err
	}
	var err error
	if s.service != nil {
		err = s.service.EnsureAgentBackend(ctx, agent.PluginID, agent.AgentID)
	}
	started[key] = err
	return err
}

// ideAPISessionFailure is the failure of a records call that did not answer: a timeout when the
// call ran out of time, otherwise a fixed message, since a Core or plugin error may name a file.
func ideAPISessionFailure(ctx context.Context, message string) map[string]any {
	if ctx.Err() != nil {
		return ideAPITimeout()
	}
	return ideAPIFailure("OPERATION_FAILED", message)
}

// ideAPISessionsSearch answers lithe_sessions_search: the hits of the query in the readable
// agents' indexed sessions, each with an excerpt re-read from the session file.
func (a *App) ideAPISessionsSearch(ctx context.Context, conn *ideAPIConnection, query, agent string) (any, int) {
	scope, failure := a.ideAPISessionAccess(ctx, conn, agent)
	if failure != nil {
		return failure, 0
	}
	hits, err := scope.kernel.Search(ctx, agents.SearchQuery{Text: query, Agents: scope.keys(), Limit: ideAPISessionHits + 1})
	if err != nil {
		return ideAPISessionFailure(ctx, "Lithe could not search the session records"), 0
	}
	truncated := len(hits) > ideAPISessionHits
	hits = hits[:min(len(hits), ideAPISessionHits)]
	started := map[string]error{}
	answered := make([]map[string]any, 0, len(hits))
	for _, hit := range hits {
		if ctx.Err() != nil {
			truncated = true
			break
		}
		owner, ok := scope.agent(hit.Agent)
		if !ok {
			continue
		}
		entry := map[string]any{"agent": hit.Agent, "agentName": owner.DisplayName, "sessionID": hit.SessionID}
		if hit.AtMs > 0 {
			entry["atMs"] = hit.AtMs
		}
		if scope.ensureBackend(ctx, started, owner) == nil {
			result, err := scope.kernel.Read(ctx, hit.Agent, hit.Path, hit.Range)
			switch {
			case err != nil:
			case result.Changed:
				entry["changed"] = true
			default:
				excerpt, cut := ideAPIExcerpt(result.Messages, query)
				entry["excerpt"] = excerpt
				if cut {
					entry["excerptTruncated"] = true
				}
			}
		}
		answered = append(answered, entry)
	}
	return map[string]any{"hits": answered, "truncated": truncated}, len(answered)
}

// ideAPIExcerpt is at most ideAPIExcerptBytes of the hit's message text, starting a little
// before the first query word it finds, cut on character boundaries. cut reports that text
// was left out on either side.
func ideAPIExcerpt(messages []agents.RecordedMessage, query string) (string, bool) {
	var parts []string
	for _, message := range messages {
		if text := strings.TrimSpace(message.Text); text != "" {
			parts = append(parts, text)
		}
	}
	text := strings.Join(parts, "\n")
	start := 0
	// Lowering keeps byte offsets only when it keeps the length; otherwise the excerpt starts
	// at the beginning, which still holds the hit's message.
	if lower := strings.ToLower(text); len(lower) == len(text) {
		for _, word := range strings.Fields(strings.ToLower(query)) {
			if index := strings.Index(lower, word); index >= 0 {
				start = max(0, index-ideAPIExcerptLead)
				break
			}
		}
	}
	for start > 0 && start < len(text) && !utf8.RuneStart(text[start]) {
		start--
	}
	excerpt := agents.Clip(text[start:], ideAPIExcerptBytes)
	return excerpt, start > 0 || len(excerpt) < len(text)-start
}

// ideAPISessionsRead answers lithe_sessions_read: one bounded page of a session's recorded
// messages, from the start or from a cursor an earlier page of this connection answered.
func (a *App) ideAPISessionsRead(ctx context.Context, conn *ideAPIConnection, sessionID, agent, cursor string) (any, int) {
	scope, failure := a.ideAPISessionAccess(ctx, conn, agent)
	if failure != nil {
		return failure, 0
	}
	sessions, err := scope.kernel.List(ctx, agents.ListQuery{Agents: scope.keys(), SessionID: sessionID, Limit: 2, Titles: true})
	if err != nil {
		return ideAPISessionFailure(ctx, "Lithe could not list the session records"), 0
	}
	switch {
	case len(sessions) == 0 || sessions[0].SessionID != sessionID:
		return ideAPIFailure("NOT_FOUND", "No allowed agent has a recorded session with this ID"), 0
	case len(sessions) > 1:
		return ideAPIFailure("INVALID_ARGUMENTS", "Two agents have a session with this ID; pass agent"), 0
	}
	session := sessions[0]
	owner, ok := scope.agent(session.Agent)
	if !ok {
		return ideAPIFailure("NOT_FOUND", "No allowed agent has a recorded session with this ID"), 0
	}
	start := uint64(0)
	if cursor != "" {
		offset, valid := conn.sessionOffset(session.Agent, sessionID, cursor)
		if !valid || offset > session.ReadBytes {
			return ideAPIFailure("INVALID_ARGUMENTS", "cursor is not a nextCursor this connection answered for this session"), 0
		}
		start = offset
	}
	if err := scope.ensureBackend(ctx, map[string]error{}, owner); err != nil {
		return ideAPISessionFailure(ctx, "The agent's plugin could not read its sessions"), 0
	}
	page := readSessionPage(ctx, scope.kernel, session.Agent, session.Path, start, session.ReadBytes)
	if page.err != nil {
		return ideAPISessionFailure(ctx, "Lithe could not read the session"), 0
	}
	hasMore := !page.changed && !page.tooLong && page.next < session.ReadBytes
	result := map[string]any{
		"agent": session.Agent, "agentName": owner.DisplayName, "sessionID": session.SessionID,
		"title": session.Title, "messages": page.messages, "hasMore": hasMore, "changed": page.changed,
	}
	if page.tooLong {
		result["tooLong"] = true
	}
	if page.omitted > 0 {
		result["omitted"] = page.omitted
	}
	if hasMore {
		result["nextCursor"] = conn.sessionCursor(session.Agent, sessionID, page.next)
	}
	return result, len(page.messages)
}

// ideAPISessionPage is one page of a session: its messages as answered, where the next page
// starts and why reading stopped. omitted counts the messages of the last read the page had
// no room for; the next page starts after them.
type ideAPISessionPage struct {
	messages []map[string]any
	next     uint64
	changed  bool
	tooLong  bool
	omitted  int
	err      error
}

// readSessionPage reads a session file from next on with readRecordSpans, ideAPISessionChunk
// bytes at a time, until the page holds half of ideAPIPageText or of ideAPIPageMessages, the
// reads reach size or agentRecordReadsPerLoad spans were read. Each message keeps at most
// ideAPIMessageBytes of text and the page at most ideAPIPageText; a message cut by either bound
// says so. Only a read made larger for a long line can bring more than the page has room for:
// the page answers what fits, counts the rest in omitted and ends there, since a read cannot be
// resumed inside its range.
func readSessionPage(ctx context.Context, kernel *agents.Client, agent, path string, next, size uint64) ideAPISessionPage {
	page := ideAPISessionPage{next: next, messages: []map[string]any{}}
	text := 0
	for range agentRecordReadsPerLoad {
		if page.next >= size || text >= ideAPIPageText/2 || len(page.messages) >= ideAPIPageMessages/2 {
			break
		}
		read := readRecordSpans(ctx, kernel, agent, path, page.next, size, ideAPISessionChunk)
		page.changed, page.tooLong, page.err = read.changed, read.tooLong, read.err
		if read.err != nil || read.changed || read.tooLong {
			return page
		}
		page.next = read.next
		for _, message := range read.messages {
			if text >= ideAPIPageText || len(page.messages) >= ideAPIPageMessages {
				page.omitted++
				continue
			}
			clipped := agents.Clip(message.Text, min(ideAPIMessageBytes, ideAPIPageText-text))
			entry := map[string]any{"role": message.Role, "text": clipped}
			if message.AtMs > 0 {
				entry["atMs"] = message.AtMs
			}
			if message.ToolName != "" {
				entry["toolName"] = agents.Clip(message.ToolName, ideAPIToolNameBytes)
			}
			if len(clipped) < len(message.Text) {
				entry["truncated"] = true
			}
			text += len(clipped)
			page.messages = append(page.messages, entry)
		}
		if page.omitted > 0 {
			return page
		}
	}
	return page
}

// sessionCursor is the opaque cursor of a page of one session starting at offset. It is signed
// with the connection's key, so only cursors this connection answered are accepted back.
func (conn *ideAPIConnection) sessionCursor(agent, sessionID string, offset uint64) string {
	return strconv.FormatUint(offset, 10) + "." + conn.cursorMAC(agent, sessionID, offset)
}

// sessionOffset returns the offset of a cursor sessionCursor made for the session.
func (conn *ideAPIConnection) sessionOffset(agent, sessionID, cursor string) (uint64, bool) {
	number, mac, found := strings.Cut(cursor, ".")
	if !found {
		return 0, false
	}
	offset, err := strconv.ParseUint(number, 10, 64)
	if err != nil || strconv.FormatUint(offset, 10) != number {
		return 0, false
	}
	return offset, hmac.Equal([]byte(mac), []byte(conn.cursorMAC(agent, sessionID, offset)))
}

// cursorMAC signs a session cursor with the connection's key.
func (conn *ideAPIConnection) cursorMAC(agent, sessionID string, offset uint64) string {
	mac := hmac.New(sha256.New, conn.cursorKey[:])
	mac.Write([]byte(agent))
	mac.Write([]byte{0})
	mac.Write([]byte(sessionID))
	mac.Write([]byte{0})
	mac.Write([]byte(strconv.FormatUint(offset, 10)))
	return hex.EncodeToString(mac.Sum(nil)[:12])
}

// ideAPISessionsLogged records a session tool call: the tool, how many hits or messages it
// answered and how long it took. Never the query, a session ID or content.
func (a *App) ideAPISessionsLogged(ctx context.Context, tool string, results int, started time.Time) {
	a.emitIn(ctx, core.LevelInfo, "agent.records.inspected", map[string]any{
		"tool":        tool,
		"results":     int64(results),
		"duration_ms": uint64(max(0, time.Since(started).Milliseconds())),
	})
}
