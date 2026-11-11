package workbench

import (
	"encoding/json"
	"strings"
)

// Agent activity is everything the Agent reports besides reply text: tool calls,
// reasoning, plan, context usage, model-call statistics, subscription quota,
// subagents and its slash commands. Core forwards the fixed ACP shapes of
// shared/fixtures/agent/acp-events-v1.json; this file decodes them into bounded,
// per-session state and never branches on Codex or Claude names.
const (
	// agentToolLimit bounds the tool calls that can still receive an update.
	agentToolLimit = 512
	// agentToolOutputLimit bounds the output kept for one tool row.
	agentToolOutputLimit = 8 << 10
	// agentSubagentLimit and agentSubagentTextLimit bound the monitored children.
	agentSubagentLimit     = 32
	agentSubagentTextLimit = 4 << 10
	agentSubagentToolLimit = 20
	// agentSessionActivityLimit bounds how many sessions keep their own plan and
	// usage; the oldest are dropped first.
	agentSessionActivityLimit = 32
	// agentCommandLimit bounds one session's cached slash commands.
	agentCommandLimit = 512
)

// agentToolCall is one tool row of the transcript. Its title, kind and output are
// the Agent's own words.
type agentToolCall struct {
	ID     string
	Title  string
	Kind   string
	Status string
	Output string
	// Card is the Claude Desktop card Core attached (agent_cards.go), shown once
	// the call completes.
	Card     *agentCard
	Expanded bool
}

type agentPlanEntry struct {
	Content  string
	Priority string
	Status   string
}

// agentSubagentTool is one tool call a child session made.
type agentSubagentTool struct {
	ID     string
	Title  string
	Status string
}

// agentSubagent is one child session the Agent announced. The state is the
// Agent's own word; only an explicit "completed" counts as success.
type agentSubagent struct {
	ID       string
	ParentID string
	Name     string
	Task     string
	State    string
	Thought  string
	Reply    string
	Tools    []agentSubagentTool
	Expanded bool
}

// agentCommand is one slash command the Agent declared for a session.
type agentCommand struct {
	Name        string
	Description string
	Hint        string
}

// agentModelStats merges the contribution of every modelCall event in order:
// counters add, and a present context replaces the previous one.
type agentModelStats struct {
	Requests, Steps, FailedSteps, NonStreamingSteps uint64
	DurationMs                                      uint64
	Input, CacheRead, CacheWrite, Output            uint64
	Reasoning                                       uint64
	CallsWithUsage                                  uint64
	FirstTokenMs, FirstTokenCount                   uint64
	GenerationMs, GeneratedTokens                   uint64
	Context                                         *agentPromptContext
}

type agentPromptContext struct {
	SystemPromptTokens, ToolTokens, MCPToolTokens, MessageTokens uint64
	ToolCount, MCPToolCount                                      uint64
	ScaledToUsage                                                bool
}

// agentTurnUsage is the usage the prompt response reported for a finished turn.
// The counters are Agent-owned; nothing is summed or inferred from them.
type agentTurnUsage struct {
	Total, Input, Output uint64
}

// agentSessionActivity is one session's own plan, usage and statistics, so
// switching conversations never shows another one's numbers.
type agentSessionActivity struct {
	plan        []agentPlanEntry
	usageKnown  bool
	used, size  uint64
	stats       agentModelStats
	statsKnown  bool
	turnUsage   *agentTurnUsage
	quiet       bool
	retrying    bool
	statsOpen   bool
	planOpen    bool
	subagents   []*agentSubagent
	subagentsOp bool
}

// agentQuotaWindow is one actual subscription window; unknown values are never
// invented.
type agentQuotaWindow struct {
	ID           string
	Name         string
	LimitSeconds int64
	UsedPercent  float64
	ResetsAt     int64
}

// agentActivityState is the connection's activity. It is dropped with the
// connection; the command cache is per session.
type agentActivityState struct {
	tools    map[string]*agentToolCall
	sessions map[string]*agentSessionActivity
	order    []string
	commands map[string][]agentCommand

	canSteer bool

	quota        []agentQuotaWindow
	quotaFetched int64
	quotaFailed  string
	quotaSeen    bool
	quotaPending bool
}

// session returns the activity of one session, creating it on first use.
func (s *agentActivityState) session(id string) *agentSessionActivity {
	if s.sessions == nil {
		s.sessions = map[string]*agentSessionActivity{}
	}
	if existing, ok := s.sessions[id]; ok {
		return existing
	}
	if len(s.order) >= agentSessionActivityLimit {
		delete(s.sessions, s.order[0])
		s.order = s.order[1:]
	}
	created := &agentSessionActivity{}
	s.sessions[id] = created
	s.order = append(s.order, id)
	return created
}

// current returns the open session's activity, or nil before a session exists.
func (s *agentActivityState) current(sessionID string) *agentSessionActivity {
	if sessionID == "" {
		return nil
	}
	return s.sessions[sessionID]
}

// forget drops one session's activity; a new conversation starts clean.
func (s *agentActivityState) forget(id string) {
	delete(s.sessions, id)
	for i, existing := range s.order {
		if existing == id {
			s.order = append(s.order[:i], s.order[i+1:]...)
			break
		}
	}
}

// commandsFor returns the commands cached for one session.
func (s *agentActivityState) commandsFor(sessionID string) []agentCommand {
	return s.commands[sessionID]
}

type agentUpdateWire struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       json.RawMessage `json:"content"`
	ToolCallID    string          `json:"toolCallId"`
	Title         string          `json:"title"`
	Severity      string          `json:"severity"`
	Description   string          `json:"description"`
	Kind          string          `json:"kind"`
	Status        string          `json:"status"`
	Meta          json.RawMessage `json:"_meta"`
	Entries       []struct {
		Content  string `json:"content"`
		Priority string `json:"priority"`
		Status   string `json:"status"`
	} `json:"entries"`
	Used              *float64 `json:"used"`
	Size              *float64 `json:"size"`
	AvailableCommands []struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Input       *struct {
			Hint string `json:"hint"`
		} `json:"input"`
	} `json:"availableCommands"`
	ConfigOptions     json.RawMessage `json:"configOptions"`
	SubagentSessionID string          `json:"subagentSessionId"`
	Name              string          `json:"name"`
	Task              string          `json:"task"`
	State             string          `json:"state"`
}

// agentTextContent reads the text of an ACP content block.
func agentTextContent(raw json.RawMessage) string {
	var block struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &block) != nil || block.Type != "text" {
		return ""
	}
	return block.Text
}

// agentToolContentText flattens a tool call's content array to the text and
// edited paths it shows. Diff bodies stay with the review surface.
func agentToolContentText(raw json.RawMessage) string {
	var items []struct {
		Type    string          `json:"type"`
		Content json.RawMessage `json:"content"`
		Path    string          `json:"path"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &items) != nil {
		return ""
	}
	var lines []string
	for _, item := range items {
		switch item.Type {
		case "content":
			if text := agentTextContent(item.Content); text != "" {
				lines = append(lines, text)
			}
		case "diff":
			if item.Path != "" {
				lines = append(lines, item.Path)
			}
		}
	}
	return strings.Join(lines, "\n")
}

// applyAgentToolCall adds or updates one tool row. A tool_call_update changes only
// the fields it carries.
func (a *App) applyAgentToolCall(p *project, update agentUpdateWire, messages *[]agentMessage, bytes *int) {
	if update.ToolCallID == "" {
		return
	}
	act := &p.agent.activity
	if act.tools == nil || len(act.tools) >= agentToolLimit {
		act.tools = map[string]*agentToolCall{}
	}
	card := decodeAgentCard(update.Meta)
	tool, known := act.tools[update.ToolCallID]
	if !known {
		if update.SessionUpdate == "tool_call_update" && update.Title == "" && update.Status == "" && len(update.Content) == 0 && card == nil {
			return
		}
		tool = &agentToolCall{ID: update.ToolCallID}
		act.tools[update.ToolCallID] = tool
		if n := len(*messages); n > 0 {
			(*messages)[n-1].Streaming = false
		}
		*messages = append(*messages, agentMessage{Role: agentRoleTool, Tool: tool})
	}
	if update.Title != "" {
		*bytes += len(update.Title) - len(tool.Title)
		tool.Title = update.Title
	}
	if update.Kind != "" {
		tool.Kind = update.Kind
	}
	if update.Status != "" {
		tool.Status = update.Status
	}
	if card != nil {
		*bytes += card.size() - tool.Card.size()
		tool.Card = card
	}
	if text := agentToolContentText(update.Content); text != "" {
		before := len(tool.Output)
		tool.Output = agentDisplayPrefix(text, agentToolOutputLimit)
		*bytes += len(tool.Output) - before
	}
	if tool.Status == "" {
		tool.Status = "pending"
	}
}

// appendAgentThought merges a reasoning chunk into the last reasoning row.
func appendAgentThought(messages *[]agentMessage, bytes *int, value string) {
	text := agentDisplayPrefix(value, agentMessageTextLimit)
	if n := len(*messages); n > 0 && (*messages)[n-1].Role == agentRoleThought && (*messages)[n-1].Streaming {
		last := &(*messages)[n-1]
		if room := agentMessageTextLimit - len(last.Text); room > 0 {
			text = agentDisplayPrefix(text, room)
			last.Text += text
			*bytes += len(text)
		}
		return
	}
	if n := len(*messages); n > 0 {
		(*messages)[n-1].Streaming = false
	}
	*messages = append(*messages, agentMessage{Role: agentRoleThought, Text: text, Streaming: true})
	*bytes += len(text)
}

// agentSessionScoped reports that a session-level update belongs to the open,
// restoring or replaying conversation.
func agentSessionScoped(p *project, sessionID string) bool {
	h := &p.agent.history
	return sessionID == "" || sessionID == p.agent.sessionID || sessionID == h.restoreSession || sessionID == h.replaySession
}

// applyAgentSessionUpdate handles the updates that are not transcript rows. It
// reports whether it consumed the update.
func (a *App) applyAgentSessionUpdate(p *project, sessionID string, update agentUpdateWire) bool {
	act := &p.agent.activity
	switch update.SessionUpdate {
	case "available_commands_update":
		// Commands can arrive before the session is confirmed, so they are cached
		// by the id the Agent reported rather than by the open session.
		id := sessionID
		if id == "" {
			id = p.agent.sessionID
		}
		if id == "" {
			return true
		}
		if act.commands == nil || (len(act.commands) >= agentSessionActivityLimit && act.commands[id] == nil) {
			act.commands = map[string][]agentCommand{}
		}
		list := make([]agentCommand, 0, len(update.AvailableCommands))
		for _, command := range update.AvailableCommands {
			if command.Name == "" || len(list) >= agentCommandLimit {
				continue
			}
			item := agentCommand{Name: command.Name, Description: command.Description}
			if command.Input != nil {
				item.Hint = command.Input.Hint
			}
			list = append(list, item)
		}
		act.commands[id] = list
		return true
	case "notice":
		// A live advisory, not a reply: kept apart from the transcript (agent_notice.go).
		if agentSessionScoped(p, sessionID) {
			a.applyAgentNotice(p, update)
		}
		return true
	case "config_option_update":
		// The Agent changed a session setting itself (for example its permission
		// mode). Its full list is authoritative, so the selectors follow it.
		if agentSessionScoped(p, sessionID) {
			a.replaceAgentConfigOptions(p, update.ConfigOptions)
		}
		return true
	case "usage_update":
		if !agentSessionScoped(p, sessionID) {
			return true
		}
		id := agentActivityID(p, sessionID)
		if id == "" {
			return true
		}
		s := act.session(id)
		if update.Used == nil || update.Size == nil || *update.Size <= 0 || *update.Used < 0 {
			s.usageKnown = false
			return true
		}
		s.used, s.size, s.usageKnown = uint64(*update.Used), uint64(*update.Size), true
		if limit := a.agentContextWindowLimit(); limit > 0 && s.size > limit {
			s.size = limit
		}
		return true
	case "plan":
		if !agentSessionScoped(p, sessionID) {
			return true
		}
		id := agentActivityID(p, sessionID)
		if id == "" {
			return true
		}
		s := act.session(id)
		s.plan = s.plan[:0:0]
		for _, entry := range update.Entries {
			s.plan = append(s.plan, agentPlanEntry{Content: entry.Content, Priority: entry.Priority, Status: entry.Status})
		}
		if len(s.plan) == 0 {
			s.planOpen = false
		}
		return true
	case "subagent_spawned":
		a.applyAgentSubagentSpawned(p, sessionID, update)
		return true
	case "subagent_state_update":
		if sub := p.agent.subagent(update.SubagentSessionID); sub != nil {
			sub.State = update.State
		}
		return true
	}
	return false
}

// agentActivityID is the session an activity update is stored under.
func agentActivityID(p *project, sessionID string) string {
	if sessionID != "" {
		return sessionID
	}
	return p.agent.sessionID
}

// agentContextWindowLimit is the configured context window the display caps at.
func (a *App) agentContextWindowLimit() uint64 {
	return a.agentContextLimits().WindowTokens
}

// subagent finds a monitored child in any session.
func (s *agentState) subagent(id string) *agentSubagent {
	if id == "" {
		return nil
	}
	for _, session := range s.activity.sessions {
		for _, sub := range session.subagents {
			if sub.ID == id {
				return sub
			}
		}
	}
	return nil
}

func (a *App) applyAgentSubagentSpawned(p *project, parentID string, update agentUpdateWire) {
	if update.SubagentSessionID == "" || p.agent.subagent(update.SubagentSessionID) != nil {
		return
	}
	root := parentID
	if parent := p.agent.subagent(parentID); parent != nil {
		root = rootAgentSession(p, parent)
	} else if !agentSessionScoped(p, parentID) {
		return
	}
	id := agentActivityID(p, root)
	if id == "" {
		return
	}
	s := p.agent.activity.session(id)
	if len(s.subagents) >= agentSubagentLimit {
		return
	}
	s.subagents = append(s.subagents, &agentSubagent{
		ID: update.SubagentSessionID, ParentID: parentID, Name: update.Name, Task: update.Task, State: "running",
	})
}

// rootAgentSession walks a child to the root session that owns it.
func rootAgentSession(p *project, sub *agentSubagent) string {
	root := sub.ParentID
	for depth := 0; depth < agentSubagentLimit; depth++ {
		parent := p.agent.subagent(root)
		if parent == nil {
			return root
		}
		root = parent.ParentID
	}
	return root
}

// applyAgentSubagentUpdate records a child session's own output. Child text and
// tools never enter the root transcript.
func (a *App) applyAgentSubagentUpdate(sub *agentSubagent, update agentUpdateWire) {
	switch update.SessionUpdate {
	case "agent_thought_chunk":
		sub.Thought = agentDisplayPrefix(sub.Thought+agentTextContent(update.Content), agentSubagentTextLimit)
	case "agent_message_chunk":
		sub.Reply = agentDisplayPrefix(sub.Reply+agentTextContent(update.Content), agentSubagentTextLimit)
	case "tool_call", "tool_call_update":
		for i := range sub.Tools {
			if sub.Tools[i].ID == update.ToolCallID {
				if update.Title != "" {
					sub.Tools[i].Title = update.Title
				}
				if update.Status != "" {
					sub.Tools[i].Status = update.Status
				}
				return
			}
		}
		if update.ToolCallID == "" || len(sub.Tools) >= agentSubagentToolLimit {
			return
		}
		status := update.Status
		if status == "" {
			status = "pending"
		}
		sub.Tools = append(sub.Tools, agentSubagentTool{ID: update.ToolCallID, Title: update.Title, Status: status})
	}
}

// mergeAgentModelStats adds one call's contribution in event order.
func mergeAgentModelStats(total *agentModelStats, c agentModelStatsWire) {
	total.Requests += c.Requests
	total.Steps += c.Steps
	total.FailedSteps += c.FailedSteps
	total.NonStreamingSteps += c.NonStreamingSteps
	total.DurationMs += c.DurationMs
	total.Input += c.InputTokens
	total.CacheRead += c.CacheReadTokens
	total.CacheWrite += c.CacheWriteTokens
	total.Output += c.OutputTokens
	total.Reasoning += c.ReasoningTokens
	total.CallsWithUsage += c.CallsWithUsage
	total.FirstTokenMs += c.FirstTokenMs
	total.FirstTokenCount += c.FirstTokenCount
	total.GenerationMs += c.GenerationMs
	total.GeneratedTokens += c.GeneratedTokens
	if c.Context != nil {
		total.Context = &agentPromptContext{
			SystemPromptTokens: c.Context.SystemPromptTokens, ToolTokens: c.Context.ToolTokens,
			MCPToolTokens: c.Context.MCPToolTokens, MessageTokens: c.Context.MessageTokens,
			ToolCount: c.Context.ToolCount, MCPToolCount: c.Context.MCPToolCount, ScaledToUsage: c.Context.ScaledToUsage,
		}
	}
}

type agentModelStatsWire struct {
	Requests          uint64 `json:"requests"`
	Steps             uint64 `json:"steps"`
	FailedSteps       uint64 `json:"failedSteps"`
	NonStreamingSteps uint64 `json:"nonStreamingSteps"`
	DurationMs        uint64 `json:"durationMs"`
	InputTokens       uint64 `json:"inputTokens"`
	CacheReadTokens   uint64 `json:"cacheReadTokens"`
	CacheWriteTokens  uint64 `json:"cacheWriteTokens"`
	OutputTokens      uint64 `json:"outputTokens"`
	ReasoningTokens   uint64 `json:"reasoningTokens"`
	CallsWithUsage    uint64 `json:"callsWithUsage"`
	FirstTokenMs      uint64 `json:"firstTokenMs"`
	FirstTokenCount   uint64 `json:"firstTokenCount"`
	GenerationMs      uint64 `json:"generationMs"`
	GeneratedTokens   uint64 `json:"generatedTokens"`
	Context           *struct {
		SystemPromptTokens uint64 `json:"systemPromptTokens"`
		ToolTokens         uint64 `json:"toolTokens"`
		MCPToolTokens      uint64 `json:"mcpToolTokens"`
		MessageTokens      uint64 `json:"messageTokens"`
		ToolCount          uint64 `json:"toolCount"`
		MCPToolCount       uint64 `json:"mcpToolCount"`
		ScaledToUsage      bool   `json:"scaledToUsage"`
	} `json:"context"`
}

// applyAgentModelCall merges a modelCall event. Unattributed calls carry no
// session and are dropped rather than guessed.
func (a *App) applyAgentModelCall(p *project, sessionID string, statistics json.RawMessage) {
	if sessionID == "" || len(statistics) == 0 {
		return
	}
	var wire agentModelStatsWire
	if err := json.Unmarshal(statistics, &wire); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_model_call", err))
		return
	}
	s := p.agent.activity.session(sessionID)
	mergeAgentModelStats(&s.stats, wire)
	s.statsKnown = true
}

// applyAgentTurnFinished records the usage the prompt response reported.
func (a *App) applyAgentTurnFinished(p *project, sessionID string, usage json.RawMessage) {
	id := agentActivityID(p, sessionID)
	if id == "" {
		return
	}
	s := p.agent.activity.session(id)
	s.quiet, s.retrying = false, false
	s.turnUsage = nil
	var wire struct {
		TotalTokens  *uint64 `json:"totalTokens"`
		InputTokens  *uint64 `json:"inputTokens"`
		OutputTokens *uint64 `json:"outputTokens"`
	}
	if len(usage) == 0 || string(usage) == "null" || json.Unmarshal(usage, &wire) != nil ||
		wire.TotalTokens == nil || wire.InputTokens == nil || wire.OutputTokens == nil {
		return
	}
	s.turnUsage = &agentTurnUsage{Total: *wire.TotalTokens, Input: *wire.InputTokens, Output: *wire.OutputTokens}
}

// applyAgentQuota stores Core's latest snapshot or failure. The control is shown
// only once Core has reported quota, which API-key connections never do.
func (a *App) applyAgentQuota(p *project, snapshot json.RawMessage, failure string) {
	act := &p.agent.activity
	act.quotaPending = false
	act.quotaSeen = true
	if failure != "" {
		act.quotaFailed = failure
		return
	}
	var wire struct {
		Windows []struct {
			ID           string   `json:"id"`
			Name         string   `json:"name"`
			LimitSeconds int64    `json:"limitSeconds"`
			UsedPercent  *float64 `json:"usedPercent"`
			ResetsAt     int64    `json:"resetsAt"`
		} `json:"windows"`
		FetchedAt int64 `json:"fetchedAt"`
	}
	if err := json.Unmarshal(snapshot, &wire); err != nil {
		act.quotaFailed = "invalid"
		return
	}
	act.quotaFailed = ""
	act.quota = act.quota[:0:0]
	for _, window := range wire.Windows {
		if window.UsedPercent == nil {
			continue
		}
		act.quota = append(act.quota, agentQuotaWindow{
			ID: window.ID, Name: window.Name, LimitSeconds: window.LimitSeconds,
			UsedPercent: *window.UsedPercent, ResetsAt: window.ResetsAt,
		})
	}
	act.quotaFetched = wire.FetchedAt
}

// refreshAgentQuota asks Core for a fresh snapshot. It is a read-only command and
// is only sent once Core has shown the connection has a quota.
func (a *App) refreshAgentQuota(p *project) {
	if p == nil || p.agent.conn == nil || p.agent.activity.quotaPending {
		return
	}
	act := &p.agent.activity
	if err := a.sendAgentCommand(p, map[string]any{"kind": "refreshQuota"}); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_quota", err))
		return
	}
	act.quotaPending = true
	a.performed("agent.quota.refresh", surfaceButton)
}
