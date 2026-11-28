package agents

import "encoding/json"

// ConfiguredPlugin is one enabled plugin as agents.configure takes it: its installed manifest
// and the permissions the user granted it.
type ConfiguredPlugin struct {
	Manifest           json.RawMessage `json:"manifest"`
	GrantedPermissions []string        `json:"grantedPermissions"`
}

// Configured is Core's answer to agents.configure.
type Configured struct {
	Agents   []CatalogAgent `json:"agents"`
	Rejected []Rejected     `json:"rejected"`
}

// Rejected is a plugin Core could not load agents from.
type Rejected struct {
	PluginID string `json:"pluginID"`
	Code     string `json:"code"`
	Message  string `json:"message"`
}

// AgentIcon is the icon a manifest gives an agent: a host icon ID, or package image resources
// (Path, DarkPath) relative to the plugin directory, painted tinted (template) or with its own
// colors (original).
type AgentIcon struct {
	Host     string `json:"host,omitempty"`
	Path     string `json:"path,omitempty"`
	DarkPath string `json:"darkPath,omitempty"`
	Mode     string `json:"mode,omitempty"`
}

// CatalogAgent is one configured agent.
type CatalogAgent struct {
	PluginID          string     `json:"pluginID"`
	AgentID           string     `json:"agentID"`
	DisplayName       string     `json:"displayName"`
	Tool              string     `json:"tool"`
	Icon              *AgentIcon `json:"icon,omitempty"`
	Modes             []string   `json:"modes"`
	Forms             []string   `json:"forms"`
	ReadsSessions     bool       `json:"readsSessions"`
	MayRun            bool       `json:"mayRun"`
	MayReadSessions   bool       `json:"mayReadSessions"`
	TerminalArguments []string   `json:"terminalArguments,omitempty"`
	Update            *Update    `json:"update,omitempty"`
	// SessionRootVariables names the environment variables the agent's session directories
	// read; agentSessions.configure passes their values.
	SessionRootVariables []string `json:"sessionRootVariables,omitempty"`
}

// Update is how the agent's CLI updates itself: the host runs the tool with these arguments in
// a terminal after the user confirms.
type Update struct {
	Arguments []string `json:"arguments"`
}

// Key is the agent's record key, "<pluginID>/<agentID>".
func (a CatalogAgent) Key() string { return a.PluginID + "/" + a.AgentID }

// HasMode reports whether the agent runs in the given mode ("native" or "acp").
func (a CatalogAgent) HasMode(mode string) bool { return contains(a.Modes, mode) }

// HasForm reports whether the agent offers the given form ("conversation" or "terminal").
func (a CatalogAgent) HasForm(form string) bool { return contains(a.Forms, form) }

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

// LiveSession is one session Core runs.
type LiveSession struct {
	Session            string   `json:"session"`
	PluginID           string   `json:"pluginID"`
	AgentID            string   `json:"agentID"`
	ActiveTurn         uint64   `json:"activeTurn,omitempty"`
	AgentSessionID     string   `json:"agentSessionID,omitempty"`
	PendingPermissions []string `json:"pendingPermissions"`
}

// StartRequest is agents.start's payload.
type StartRequest struct {
	PluginID string `json:"pluginID"`
	AgentID  string `json:"agentID"`
	// Cwd is the absolute directory the CLI starts in.
	Cwd string `json:"cwd"`
	// ToolPath is the CLI the host resolved for the agent's tool.
	ToolPath string `json:"toolPath"`
	RootURI  string `json:"rootURI,omitempty"`
	// Resume is the agent's own session ID to continue.
	Resume           string `json:"resume,omitempty"`
	WorkspaceTrusted bool   `json:"workspaceTrusted"`
	// Environment is the CLI's whole environment.
	Environment map[string]string `json:"environment"`
}

// EventBatch is agents.waitEvents' answer.
type EventBatch struct {
	Events []SessionEvent `json:"events"`
	// Next is the sequence to pass as after to the next wait.
	Next   uint64 `json:"next"`
	Missed bool   `json:"missed"`
}

// SessionEvent is one event of one session.
type SessionEvent struct {
	Sequence uint64 `json:"sequence"`
	Session  string `json:"session"`
	Event    Event  `json:"event"`
}

// Event is any event a session reports; Kind says which fields are set. Backends report
// session, message, toolCall, plan, permissionRequested, usage, rateLimits, turnEnded, notice
// and configOptions; Core adds started, turnStarted, permissionDecided, outputLineDropped and
// exited.
type Event struct {
	Kind string `json:"kind"`

	AgentSessionID string `json:"agentSessionID,omitempty"`
	Model          string `json:"model,omitempty"`
	Effort         string `json:"effort,omitempty"`
	AgentVersion   string `json:"agentVersion,omitempty"`

	Turn      uint64 `json:"turn,omitempty"`
	Role      string `json:"role,omitempty"`
	MessageID string `json:"messageID,omitempty"`
	Text      string `json:"text,omitempty"`
	Delta     bool   `json:"delta,omitempty"`

	ToolCallID string         `json:"toolCallID,omitempty"`
	Status     string         `json:"status,omitempty"`
	ToolKind   string         `json:"toolKind,omitempty"`
	Title      string         `json:"title,omitempty"`
	Locations  []ToolLocation `json:"locations,omitempty"`
	Diff       *ToolDiff      `json:"diff,omitempty"`
	Output     string         `json:"output,omitempty"`

	Entries []PlanEntry `json:"entries,omitempty"`

	Permission string             `json:"permission,omitempty"`
	Options    []PermissionOption `json:"options,omitempty"`
	Option     string             `json:"option,omitempty"`

	Tokens        Tokens   `json:"tokens"`
	ContextUsed   uint64   `json:"contextUsed,omitempty"`
	ContextWindow uint64   `json:"contextWindow,omitempty"`
	CostUSD       *float64 `json:"costUsd,omitempty"`

	Windows []RateWindow `json:"windows,omitempty"`
	Plan    string       `json:"plan,omitempty"`

	Reason     string `json:"reason,omitempty"`
	Message    string `json:"message,omitempty"`
	ExitCode   *int   `json:"exitCode,omitempty"`
	StderrTail string `json:"stderrTail,omitempty"`

	Level string `json:"level,omitempty"`
	Code  string `json:"code,omitempty"`

	ConfigOptions []ConfigOption `json:"configOptions,omitempty"`

	PluginID string `json:"pluginID,omitempty"`
	AgentID  string `json:"agentID,omitempty"`
	Mode     string `json:"mode,omitempty"`
	Resume   string `json:"resume,omitempty"`
}

// ConfigOption is a setting of a session the user may change, as its backend last reported it.
// Category is model, thoughtLevel (the reasoning effort, its values from least to most), mode,
// or empty for any other; CurrentValue is one of Options' values.
type ConfigOption struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Description  string        `json:"description,omitempty"`
	Category     string        `json:"category,omitempty"`
	CurrentValue string        `json:"currentValue"`
	Options      []ConfigValue `json:"options"`
}

// ConfigValue is one value a setting offers.
type ConfigValue struct {
	Value       string `json:"value"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// Current is the index of the setting's current value among its values, -1 when it lists none
// such.
func (o ConfigOption) Current() int {
	for i, value := range o.Options {
		if value.Value == o.CurrentValue {
			return i
		}
	}
	return -1
}

// ToolLocation is a file a tool call touches.
type ToolLocation struct {
	Path string `json:"path"`
	Line uint64 `json:"line,omitempty"`
}

// ToolDiff is the change a tool call makes to one file.
type ToolDiff struct {
	Path    string  `json:"path"`
	OldText *string `json:"oldText,omitempty"`
	NewText string  `json:"newText"`
}

// PlanEntry is one step of the agent's plan.
type PlanEntry struct {
	Content string `json:"content"`
	Status  string `json:"status"`
}

// PermissionOption is one answer the backend offers to a permission request.
type PermissionOption struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	OptionKind string `json:"optionKind"`
}

// Tokens counts the tokens of a call or a turn.
type Tokens struct {
	Input        uint64 `json:"input,omitempty"`
	Output       uint64 `json:"output,omitempty"`
	CacheRead    uint64 `json:"cacheRead,omitempty"`
	CacheWrite5m uint64 `json:"cacheWrite5m,omitempty"`
	CacheWrite1h uint64 `json:"cacheWrite1h,omitempty"`
	Reasoning    uint64 `json:"reasoning,omitempty"`
}

// Total is every token counted once.
func (t Tokens) Total() uint64 {
	return t.Input + t.Output + t.CacheRead + t.CacheWrite5m + t.CacheWrite1h + t.Reasoning
}

// RateWindow is the share of one rate-limit window the account has used.
type RateWindow struct {
	ID            string  `json:"id"`
	Label         string  `json:"label,omitempty"`
	UsedPercent   float64 `json:"usedPercent"`
	WindowMinutes uint64  `json:"windowMinutes,omitempty"`
	ResetsAtMs    int64   `json:"resetsAtMs,omitempty"`
}

// RecordsConfig is agentSessions.configure's payload.
type RecordsConfig struct {
	// CacheDirectory is an absolute directory under the platform's Caches directory.
	CacheDirectory string `json:"cacheDirectory"`
	UserHome       string `json:"userHome"`
	// Environment holds the values of the catalog's sessionRootVariables.
	Environment map[string]string `json:"environment"`
	PricesFile  string            `json:"pricesFile,omitempty"`
}

// RecordsConfigured is agentSessions.configure's answer.
type RecordsConfigured struct {
	PricedModels int    `json:"pricedModels,omitempty"`
	PricesError  string `json:"pricesError,omitempty"`
}

// SyncReport is agentSessions.sync's answer: counts only.
type SyncReport struct {
	FilesListed       int   `json:"filesListed"`
	FilesUnchanged    int   `json:"filesUnchanged"`
	FilesRead         int   `json:"filesRead"`
	FilesRestarted    int   `json:"filesRestarted"`
	FilesRemoved      int   `json:"filesRemoved"`
	FilesFailed       int   `json:"filesFailed"`
	BytesRead         int64 `json:"bytesRead"`
	SkippedLines      int   `json:"skippedLines"`
	Sessions          int   `json:"sessions"`
	Calls             int   `json:"calls"`
	Spans             int   `json:"spans"`
	TruncatedSources  int   `json:"truncatedSources"`
	UnreadableEntries int   `json:"unreadableEntries"`
}

// ByteRange is a range of bytes of a session file.
type ByteRange struct {
	Start uint64 `json:"start"`
	End   uint64 `json:"end"`
}

// ListQuery is agentSessions.list's payload.
type ListQuery struct {
	Agents    []string `json:"agents,omitempty"`
	Cwd       string   `json:"cwd,omitempty"`
	SessionID string   `json:"sessionID,omitempty"`
	// CwdUnder keeps only sessions whose directory is one of these or lies under one of them.
	CwdUnder      []string `json:"cwdUnder,omitempty"`
	ActiveSinceMs int64    `json:"activeSinceMs,omitempty"`
	// Order is "updated" (latest activity first, the default) or "started" (latest start first).
	Order  string `json:"order,omitempty"`
	Offset int    `json:"offset"`
	Limit  int    `json:"limit,omitempty"`
	Titles bool   `json:"titles"`
	// Counts asks for the whole filtered list's total and per-directory groups.
	Counts bool `json:"counts,omitempty"`
}

// SessionList is one page of agentSessions.list with the counts Counts asks for.
type SessionList struct {
	Sessions []RecordedSession `json:"sessions"`
	// Total is how many sessions the filters keep, whatever the page.
	Total           uint64         `json:"total"`
	Groups          []SessionGroup `json:"groups,omitempty"`
	GroupsTruncated bool           `json:"groupsTruncated,omitempty"`
}

// SessionGroup counts the filtered sessions of one directory; Cwd is empty for sessions that
// record none.
type SessionGroup struct {
	Cwd         string `json:"cwd,omitempty"`
	Count       uint64 `json:"count"`
	UpdatedAtMs int64  `json:"updatedAtMs,omitempty"`
}

// RecordedSession is one recorded session.
type RecordedSession struct {
	Agent     string `json:"agent"`
	SessionID string `json:"sessionID"`
	Path      string `json:"path"`
	// ReadBytes is how many bytes of Path the cache has read, where a read of the whole record
	// ends.
	ReadBytes       uint64 `json:"readBytes"`
	FileCount       int    `json:"fileCount"`
	ParentSessionID string `json:"parentSessionID,omitempty"`
	Cwd             string `json:"cwd,omitempty"`
	StartedAtMs     int64  `json:"startedAtMs,omitempty"`
	UpdatedAtMs     int64  `json:"updatedAtMs,omitempty"`
	AgentVersion    string `json:"agentVersion,omitempty"`
	PluginID        string `json:"pluginID"`
	AgentID         string `json:"agentID"`
	Title           string `json:"title,omitempty"`
	// MessageCount is how many searchable messages the session's own file holds; subagent files
	// are not counted.
	MessageCount uint64 `json:"messageCount,omitempty"`
	// SubagentCount is how many distinct subagent threads the session's calls name.
	SubagentCount uint64 `json:"subagentCount,omitempty"`
	// Model is the latest main-thread model the session called.
	Model string `json:"model,omitempty"`
	// LastMessageRange is where the last message lies in Path; Read reads it for a preview.
	LastMessageRange *ByteRange `json:"lastMessageRange,omitempty"`
}

// SearchQuery is agentSessions.search's payload.
type SearchQuery struct {
	Text      string   `json:"text"`
	Agents    []string `json:"agents,omitempty"`
	SessionID string   `json:"sessionID,omitempty"`
	Limit     int      `json:"limit,omitempty"`
}

// SearchHit is where a search found its words.
type SearchHit struct {
	Agent     string    `json:"agent"`
	Path      string    `json:"path"`
	SessionID string    `json:"sessionID"`
	AtMs      int64     `json:"atMs,omitempty"`
	Range     ByteRange `json:"range"`
	PluginID  string    `json:"pluginID"`
	AgentID   string    `json:"agentID"`
}

// ReadResult is agentSessions.read's answer. Changed reports that the file no longer holds the
// range as recorded. End is where the next page starts: the range's end, or the start of the line
// the range cut; it equals the range's start when the range lies inside one line.
type ReadResult struct {
	Changed  bool              `json:"changed"`
	Messages []RecordedMessage `json:"messages"`
	End      uint64            `json:"end"`
}

// RecordedMessage is one message of a recorded session.
type RecordedMessage struct {
	Role     string `json:"role"`
	Text     string `json:"text"`
	AtMs     int64  `json:"atMs,omitempty"`
	ToolName string `json:"toolName,omitempty"`
}

// StatsQuery is agentSessions.stats' payload. GroupBy is day, agent, model, session or cwd.
type StatsQuery struct {
	Agents           []string `json:"agents,omitempty"`
	SessionID        string   `json:"sessionID,omitempty"`
	SinceMs          int64    `json:"sinceMs,omitempty"`
	UntilMs          int64    `json:"untilMs,omitempty"`
	GroupBy          string   `json:"groupBy"`
	UTCOffsetSeconds int      `json:"utcOffsetSeconds"`
}

// Stats is agentSessions.stats' answer.
type Stats struct {
	Summaries  []Summary      `json:"summaries"`
	RateLimits []RateSnapshot `json:"rateLimits"`
}

// Summary is the usage of one group of calls.
type Summary struct {
	Key             GroupKey   `json:"key"`
	Calls           uint64     `json:"calls"`
	FailedCalls     uint64     `json:"failedCalls"`
	CompactionCalls uint64     `json:"compactionCalls"`
	Tokens          Tokens     `json:"tokens"`
	CacheHitRate    *float64   `json:"cacheHitRate,omitempty"`
	Cost            *CostTotal `json:"cost,omitempty"`
	FirstStartedAt  int64      `json:"firstStartedAtMs"`
	LastStartedAt   int64      `json:"lastStartedAtMs"`
}

// GroupKey names the group a summary covers; Kind is day, agent, model, session or cwd.
type GroupKey struct {
	Kind      string `json:"kind"`
	Date      string `json:"date,omitempty"`
	Agent     string `json:"agent,omitempty"`
	Model     string `json:"model,omitempty"`
	SessionID string `json:"sessionID,omitempty"`
	Cwd       string `json:"cwd,omitempty"`
}

// CostTotal is the API-price equivalent of a group's priced calls.
type CostTotal struct {
	USD              float64 `json:"usd"`
	Basis            string  `json:"basis"`
	PricedCalls      uint64  `json:"pricedCalls"`
	UnpricedCalls    uint64  `json:"unpricedCalls"`
	ApproximateCalls uint64  `json:"approximateCalls"`
}

// RateSnapshot is an agent's latest rate-limit state.
type RateSnapshot struct {
	AtMs     int64        `json:"atMs"`
	Windows  []RateWindow `json:"windows"`
	Plan     string       `json:"plan,omitempty"`
	PluginID string       `json:"pluginID"`
	AgentID  string       `json:"agentID"`
}
