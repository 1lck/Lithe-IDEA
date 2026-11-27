package agents

import "unicode/utf8"

// EntryKind says what a transcript entry shows.
type EntryKind int

const (
	// EntryUser is a prompt the user sent.
	EntryUser EntryKind = iota
	// EntryAssistant is the agent's reply text.
	EntryAssistant
	// EntryThought is the agent's reasoning text.
	EntryThought
	// EntryTool is a tool call and its latest state.
	EntryTool
	// EntryNotice is a notice the backend reported, or a turn that did not complete.
	EntryNotice
)

// Bounds of one transcript. A long session keeps its latest entries; the oldest quarter is
// dropped at once so dropping is rare.
const (
	MaxEntries     = 2000
	MaxEntryBytes  = 256 << 10
	MaxOutputBytes = 16 << 10
	MaxTotalBytes  = 4 << 20
)

// Entry is one row of a transcript.
type Entry struct {
	Kind EntryKind
	Turn uint64
	// ID is the message or tool call ID the backend gave, empty for user prompts and notices.
	ID   string
	Text string
	// Tool calls.
	Status    string
	ToolKind  string
	Title     string
	Locations []ToolLocation
	Output    string
	// Notices: info, warning or error, and the backend's code or, for a turn that did not
	// complete, its reason (cancelled, maxTokens, maxTurns, refused or failed).
	Level string
	Code  string
}

// Permission is a permission request waiting for the user.
type Permission struct {
	Turn       uint64
	Permission string
	Title      string
	ToolCallID string
	Options    []PermissionOption
}

// Usage is the latest usage the session reported.
type Usage struct {
	Model         string
	Tokens        Tokens
	ContextUsed   uint64
	ContextWindow uint64
	CostUSD       *float64
}

// Exit is how the session ended.
type Exit struct {
	Reason   string
	ExitCode *int
}

// Transcript is one live session as the window shows it, folded from the session's events. It
// lives in memory only and is never logged.
type Transcript struct {
	Session        string
	PluginID       string
	AgentID        string
	AgentSessionID string
	Model          string
	Effort         string
	AgentVersion   string

	Entries []Entry
	// ActiveTurn is the turn in progress, zero when none.
	ActiveTurn uint64
	Pending    []Permission
	Plan       []PlanEntry
	Usage      *Usage
	RateLimits []RateWindow
	RatePlan   string
	Exit       *Exit
	// Dropped counts entries dropped to keep the bounds, and output lines Core dropped.
	Dropped int
	// Missed reports that Core's event buffer lost events of this session.
	Missed bool

	index map[string]int
	bytes int
}

// NewTranscript is an empty transcript of a session.
func NewTranscript(session, pluginID, agentID string) *Transcript {
	return &Transcript{Session: session, PluginID: pluginID, AgentID: agentID, index: map[string]int{}}
}

// Live reports whether the session has not ended.
func (t *Transcript) Live() bool { return t.Exit == nil }

// AddPrompt records a prompt the user is sending. It shows at once, before the turn's replies,
// which can arrive before Core's answer to the prompt; its turn is zero until PromptAccepted.
func (t *Transcript) AddPrompt(text string) {
	t.push(Entry{Kind: EntryUser, Text: clip(text, MaxEntryBytes)})
}

// PromptAccepted gives the oldest prompt still waiting for a turn the turn Core assigned it.
func (t *Transcript) PromptAccepted(turn uint64) {
	if at := t.waitingPrompt(); at >= 0 {
		t.Entries[at].Turn = turn
	}
	if turn > t.ActiveTurn {
		t.ActiveTurn = turn
	}
}

// PromptRefused takes back the oldest prompt still waiting for a turn, which Core refused, and
// answers its text so the window can put it back in the prompt field.
func (t *Transcript) PromptRefused() string {
	at := t.waitingPrompt()
	if at < 0 {
		return ""
	}
	text := t.Entries[at].Text
	t.bytes -= entrySize(t.Entries[at])
	t.Entries = append(t.Entries[:at], t.Entries[at+1:]...)
	t.reindex()
	return text
}

func (t *Transcript) waitingPrompt() int {
	for at, entry := range t.Entries {
		if entry.Kind == EntryUser && entry.Turn == 0 {
			return at
		}
	}
	return -1
}

// Apply folds one event into the transcript.
func (t *Transcript) Apply(event Event) {
	switch event.Kind {
	case "started":
		if event.PluginID != "" {
			t.PluginID, t.AgentID = event.PluginID, event.AgentID
		}
	case "session":
		t.AgentSessionID = event.AgentSessionID
		t.Model = firstNonEmpty(event.Model, t.Model)
		t.Effort = firstNonEmpty(event.Effort, t.Effort)
		t.AgentVersion = firstNonEmpty(event.AgentVersion, t.AgentVersion)
	case "turnStarted":
		t.ActiveTurn = event.Turn
	case "message":
		kind := EntryAssistant
		if event.Role == "thought" {
			kind = EntryThought
		}
		t.message(kind, event)
	case "toolCall":
		t.toolCall(event)
	case "plan":
		t.Plan = append(t.Plan[:0], event.Entries...)
	case "permissionRequested":
		t.removePending(event.Permission)
		t.Pending = append(t.Pending, Permission{
			Turn: event.Turn, Permission: event.Permission, Title: event.Title,
			ToolCallID: event.ToolCallID, Options: event.Options,
		})
	case "permissionDecided":
		t.removePending(event.Permission)
	case "usage":
		t.Usage = &Usage{
			Model: firstNonEmpty(event.Model, t.Model), Tokens: event.Tokens,
			ContextUsed: event.ContextUsed, ContextWindow: event.ContextWindow, CostUSD: event.CostUSD,
		}
	case "rateLimits":
		t.RateLimits = append(t.RateLimits[:0], event.Windows...)
		t.RatePlan = event.Plan
	case "turnEnded":
		if event.Turn == t.ActiveTurn {
			t.ActiveTurn = 0
		}
		t.dropPendingOf(event.Turn)
		if event.Reason != "" && event.Reason != "completed" {
			t.push(Entry{Kind: EntryNotice, Turn: event.Turn, Level: "warning", Code: clip(event.Reason, 64), Text: clip(event.Message, MaxEntryBytes)})
		}
	case "notice":
		t.push(Entry{Kind: EntryNotice, Turn: t.ActiveTurn, Level: event.Level, Code: clip(event.Code, 128), Text: clip(event.Text, MaxEntryBytes)})
	case "outputLineDropped":
		t.Dropped++
	case "exited":
		t.Exit = &Exit{Reason: event.Reason, ExitCode: event.ExitCode}
		t.ActiveTurn = 0
		t.Pending = nil
	}
}

func (t *Transcript) message(kind EntryKind, event Event) {
	key := "m:" + event.MessageID
	if at, ok := t.index[key]; ok && event.MessageID != "" {
		entry := &t.Entries[at]
		before := len(entry.Text)
		if event.Delta {
			entry.Text = clip(entry.Text+event.Text, MaxEntryBytes)
		} else {
			entry.Text = clip(event.Text, MaxEntryBytes)
		}
		t.bytes += len(entry.Text) - before
		t.trim()
		return
	}
	t.push(Entry{Kind: kind, Turn: event.Turn, ID: event.MessageID, Text: clip(event.Text, MaxEntryBytes)})
	if event.MessageID != "" {
		t.index[key] = len(t.Entries) - 1
	}
}

func (t *Transcript) toolCall(event Event) {
	key := "t:" + event.ToolCallID
	if at, ok := t.index[key]; ok {
		entry := &t.Entries[at]
		before := entrySize(*entry)
		entry.Status = event.Status
		entry.ToolKind = firstNonEmpty(event.ToolKind, entry.ToolKind)
		entry.Title = firstNonEmpty(clip(event.Title, 1024), entry.Title)
		if len(event.Locations) > 0 {
			entry.Locations = event.Locations
		}
		if event.Output != "" {
			entry.Output = tail(event.Output, MaxOutputBytes)
		}
		t.bytes += entrySize(*entry) - before
		t.trim()
		return
	}
	t.push(Entry{
		Kind: EntryTool, Turn: event.Turn, ID: event.ToolCallID, Status: event.Status,
		ToolKind: event.ToolKind, Title: clip(event.Title, 1024), Locations: event.Locations,
		Output: tail(event.Output, MaxOutputBytes),
	})
	t.index[key] = len(t.Entries) - 1
}

func (t *Transcript) removePending(permission string) {
	kept := t.Pending[:0]
	for _, pending := range t.Pending {
		if pending.Permission != permission {
			kept = append(kept, pending)
		}
	}
	t.Pending = kept
}

func (t *Transcript) dropPendingOf(turn uint64) {
	kept := t.Pending[:0]
	for _, pending := range t.Pending {
		if pending.Turn != turn {
			kept = append(kept, pending)
		}
	}
	t.Pending = kept
}

func (t *Transcript) push(entry Entry) {
	t.Entries = append(t.Entries, entry)
	t.bytes += entrySize(entry)
	t.trim()
}

// trim drops the oldest quarter of the entries while the transcript is over a bound.
func (t *Transcript) trim() {
	for len(t.Entries) > 1 && (len(t.Entries) > MaxEntries || t.bytes > MaxTotalBytes) {
		drop := max(len(t.Entries)/4, 1)
		for _, entry := range t.Entries[:drop] {
			t.bytes -= entrySize(entry)
		}
		t.Entries = append(t.Entries[:0:0], t.Entries[drop:]...)
		t.Dropped += drop
		t.reindex()
	}
}

func (t *Transcript) reindex() {
	clear(t.index)
	for at, entry := range t.Entries {
		switch entry.Kind {
		case EntryAssistant, EntryThought:
			if entry.ID != "" {
				t.index["m:"+entry.ID] = at
			}
		case EntryTool:
			t.index["t:"+entry.ID] = at
		}
	}
}

func entrySize(entry Entry) int {
	return len(entry.Text) + len(entry.Title) + len(entry.Output) + 64
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

// clip keeps at most limit bytes of text, cut on a character boundary.
func clip(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	cut := limit
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut]
}

// tail keeps at most the last limit bytes of text, cut on a character boundary.
func tail(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	start := len(text) - limit
	for start < len(text) && !utf8.RuneStart(text[start]) {
		start++
	}
	return text[start:]
}
