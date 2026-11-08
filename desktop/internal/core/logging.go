package core

import (
	"context"
	"fmt"
)

// LogLevel is the severity of a log record, in the kernel's canonical disk spelling.
type LogLevel string

// The four severities, from least to most severe.
const (
	LevelDebug LogLevel = "DEBUG"
	LevelInfo  LogLevel = "INFO"
	LevelWarn  LogLevel = "WARN"
	LevelError LogLevel = "ERROR"
)

// LogLevels lists every severity, from most to least severe, the order the log window shows
// its level toggles in.
var LogLevels = []LogLevel{LevelError, LevelWarn, LevelInfo, LevelDebug}

// LogError is a structured logging failure. Code is the stable logging v2 code; Reason is a
// safe explanation that never echoes the rejected input.
type LogError struct {
	Code   int    `json:"code"`
	Reason string `json:"reason"`
}

func (e *LogError) Error() string {
	return fmt.Sprintf("log error %d: %s", e.Code, e.Reason)
}

// logResult is how the logging commands that can fail in their own domain answer: either the
// result or a LogError, inside a successful kernel response.
type logResult[T any] struct {
	Result *T        `json:"result"`
	Error  *LogError `json:"error"`
}

// executeLog runs a logging command that answers with a logResult and unwraps it.
func executeLog[T any](ctx context.Context, c *Client, command string, payload any) (T, error) {
	var answer logResult[T]
	var zero T
	if err := c.Execute(ctx, command, payload, &answer); err != nil {
		return zero, err
	}
	if answer.Error != nil {
		return zero, answer.Error
	}
	if answer.Result == nil {
		return zero, newParseError(command, "core answered without a result or an error", "")
	}
	return *answer.Result, nil
}

// LogEvent is one fact to encode. With catalog validation the kernel checks the event id,
// level and fields against the event catalog, derives the channel and replaces Msg with the
// catalog message, so Msg may be empty.
type LogEvent struct {
	// Ts is the RFC 3339 instant the fact was observed.
	Ts string `json:"ts"`
	// Level must equal the catalog level of Event.
	Level LogLevel `json:"level"`
	// Seq is the session's monotonic sequence number.
	Seq uint64 `json:"seq"`
	// Event is the catalog id, for example app.session.started.
	Event string `json:"event"`
	// Op correlates the records of one operation; empty means none.
	Op string `json:"op,omitempty"`
	// Msg is the human-readable fact.
	Msg string `json:"msg"`
	// Fields are the catalog fields, each a JSON scalar. Durations use the "_ms" suffix.
	Fields map[string]any `json:"fields"`
	// Channel is read only for the log.dropped and log.repeated system events, whose channel
	// the host chooses; the catalog decides it for every other event.
	Channel string `json:"channel,omitempty"`
}

// LogHeader is the metadata line that starts every log file.
type LogHeader struct {
	// Session is the full UUID of the process session.
	Session string `json:"session"`
	// Pid is the process id.
	Pid uint32 `json:"pid"`
	// App is the application version, a bare token.
	App string `json:"app"`
	// Channel is the logical channel the file holds.
	Channel string `json:"channel"`
	// Started is the RFC 3339 instant the session started.
	Started string `json:"started"`
}

// LogBatch is one call to the encoder.
type LogBatch struct {
	// Events are encoded in order; a malformed event fails alone.
	Events []LogEvent
	// ValidateCatalog checks every event against the catalog, as the writer always should.
	ValidateCatalog bool
	// Deduplicate merges adjacent equal facts into log.repeated.
	Deduplicate bool
	// Previous is the last event of the previous batch, compared with the first event when
	// deduplicating.
	Previous *LogEvent
	// Headers are encoded as file header lines; the first one also yields the session path.
	Headers []LogHeader
}

type logBatchWire struct {
	PreviousEvent   *LogEvent   `json:"previousEvent,omitempty"`
	Deduplicate     bool        `json:"deduplicate"`
	ValidateCatalog bool        `json:"validateCatalog"`
	Headers         []LogHeader `json:"headers"`
	Events          []LogEvent  `json:"events"`
}

// EncodedLog is the outcome for one event or header: a line or an error.
type EncodedLog struct {
	// Channel is the channel the line belongs to.
	Channel string `json:"channel"`
	// Line is the disk line without its newline; empty on error.
	Line string `json:"line"`
	// Error explains why the item was rejected; nil on success.
	Error *LogError `json:"error"`
}

// EncodedLogBatch is the encoder's answer, one entry per input in order.
type EncodedLogBatch struct {
	Headers []EncodedLog `json:"headers"`
	// SessionPath is the session directory relative to the log root, derived from the first
	// header; empty without headers.
	SessionPath string       `json:"sessionPath"`
	Results     []EncodedLog `json:"results"`
}

// EncodeLogBatch encodes events and headers into disk lines. The batch is not modified.
func (c *Client) EncodeLogBatch(ctx context.Context, batch LogBatch) (EncodedLogBatch, error) {
	var answer EncodedLogBatch
	events := make([]LogEvent, len(batch.Events))
	for i, event := range batch.Events {
		events[i] = withFields(event)
	}
	var previous *LogEvent
	if batch.Previous != nil {
		event := withFields(*batch.Previous)
		previous = &event
	}
	err := c.Execute(ctx, "diagnostics.encodeLogBatch", logBatchWire{
		PreviousEvent:   previous,
		Deduplicate:     batch.Deduplicate,
		ValidateCatalog: batch.ValidateCatalog,
		Headers:         nonNil(batch.Headers),
		Events:          events,
	}, &answer)
	return answer, err
}

// withFields gives an event without fields an empty map of them. The kernel takes a null
// fields value for a malformed event, and ignores a previous event whose fields are null.
func withFields(event LogEvent) LogEvent {
	if event.Fields == nil {
		event.Fields = map[string]any{}
	}
	return event
}

// LogChannelPath is where a channel's file lives inside the session directory.
type LogChannelPath struct {
	// Category is the retention category of the file, for example application or language.
	Category string `json:"category"`
	// PluginFilesPath is the plugin's private file directory, for plugin channels only.
	PluginFilesPath string `json:"pluginFilesPath"`
	// RelativePath is the file path relative to the session directory.
	RelativePath string `json:"relativePath"`
}

// ResolveLogChannel returns the file a channel writes to. rotation is 0 for the active file and
// counts up for rotated files; existing lists the channels the session already has files for.
func (c *Client) ResolveLogChannel(ctx context.Context, channel string, rotation int, existing []string) (LogChannelPath, error) {
	return executeLog[LogChannelPath](ctx, c, "diagnostics.resolveLogChannel", struct {
		Channel          string   `json:"channel"`
		RotationIndex    int      `json:"rotationIndex"`
		ExistingChannels []string `json:"existingChannels"`
	}{channel, rotation, nonNil(existing)})
}

// LogFile is one file of the log inventory.
type LogFile struct {
	// RelativePath is relative to the log root, for example sessions/<name>/app.log.
	RelativePath string `json:"relativePath"`
	SizeBytes    uint64 `json:"sizeBytes"`
	// ModifiedAt is an RFC 3339 instant.
	ModifiedAt string `json:"modifiedAt"`
}

// LogCollectionRequest asks which byte ranges of the inventory a query should read.
type LogCollectionRequest struct {
	Files []LogFile `json:"files"`
	// CurrentSession is the directory name of this process's session.
	CurrentSession string `json:"currentSession"`
	// Session selects current, previous or all.
	Session string `json:"session"`
	// Category limits the plan to one retention category; empty means all.
	Category string `json:"category,omitempty"`
	// RecentSessions limits all to the newest sessions; zero means the kernel's default.
	RecentSessions int `json:"recentSessions,omitempty"`
	// Since skips files last modified before this RFC 3339 instant.
	Since string `json:"since,omitempty"`
}

// LogRead is one bounded tail to read.
type LogRead struct {
	RelativePath string `json:"relativePath"`
	Offset       uint64 `json:"offset"`
	MaxBytes     uint64 `json:"maxBytes"`
}

// LogCollectionPlan is the kernel's read plan.
type LogCollectionPlan struct {
	Reads          []LogRead `json:"reads"`
	Truncated      bool      `json:"truncated"`
	EstimatedBytes uint64    `json:"estimatedBytes"`
	Sessions       []string  `json:"sessions"`
}

// PlanLogCollection plans the reads for a query over the inventory.
func (c *Client) PlanLogCollection(ctx context.Context, request LogCollectionRequest) (LogCollectionPlan, error) {
	request.Files = nonNil(request.Files)
	return executeLog[LogCollectionPlan](ctx, c, "diagnostics.planLogCollection", request)
}

// LogSource is one tail of a log file handed to a query.
type LogSource struct {
	// RelativePath is relative to the log root or, for live lines, to the session directory.
	RelativePath string `json:"relativePath"`
	Text         string `json:"text"`
	// StartsMidLine discards the first, incomplete line.
	StartsMidLine bool `json:"startsMidLine"`
	// FirstLineNumber is the one-based line number the text starts at; zero means 1.
	FirstLineNumber int `json:"firstLineNumber,omitempty"`
}

// LogQuery filters and merges sources. Zero fields filter nothing.
type LogQuery struct {
	Sources         []LogSource `json:"sources"`
	ChannelPrefixes []string    `json:"channelPrefixes"`
	// Levels is the exact set of severities to keep. Nil keeps every severity; an empty,
	// non-nil set keeps none.
	Levels *[]LogLevel `json:"levels,omitempty"`
	// Since and Until are inclusive RFC 3339 bounds.
	Since string `json:"since,omitempty"`
	Until string `json:"until,omitempty"`
	// FilterSince and FilterUntil are a second pair of inclusive RFC 3339 bounds the kernel
	// intersects with Since and Until: an export of a time range keeps the window's own range
	// on top of it.
	FilterSince string `json:"filterSince,omitempty"`
	FilterUntil string `json:"filterUntil,omitempty"`
	// AfterSequences hides records at or below a session's watermark; session-relative
	// sources use the empty key.
	AfterSequences map[string]uint64 `json:"afterSequences,omitempty"`
	Search         string            `json:"search,omitempty"`
	Op             string            `json:"op,omitempty"`
	// Limit keeps the newest matches, 1 to 10000; zero means the kernel's default.
	Limit int `json:"limit,omitempty"`
	// Expression is a filter in the log filter language, at most 1024 bytes.
	Expression string `json:"expression,omitempty"`
	// HistogramBuckets asks for an event histogram with 1 to 240 buckets.
	HistogramBuckets int `json:"histogramBuckets,omitempty"`
}

// LogRecord is one matching record.
type LogRecord struct {
	// Line is the redacted disk line.
	Line         string `json:"line"`
	Channel      string `json:"channel"`
	RelativePath string `json:"relativePath"`
	LineNumber   int    `json:"lineNumber"`
	// FoldKey is equal for records the window may fold together.
	FoldKey string `json:"foldKey"`
	EpochMs int64  `json:"epochMs"`
	// OpOffsetMs is the time since the first match of the queried operation.
	OpOffsetMs *int64            `json:"opOffsetMs"`
	Ts         string            `json:"ts"`
	Level      LogLevel          `json:"level"`
	Seq        uint64            `json:"seq"`
	Event      string            `json:"event"`
	Op         string            `json:"op"`
	Msg        string            `json:"msg"`
	Fields     map[string]string `json:"fields"`
}

// LogChannelCount counts the records of one channel.
type LogChannelCount struct {
	Total int `json:"total"`
	Warn  int `json:"warn"`
	Error int `json:"error"`
}

// LogBucket is one histogram bucket.
type LogBucket struct {
	Debug int `json:"debug"`
	Info  int `json:"info"`
	Warn  int `json:"warn"`
	Error int `json:"error"`
}

// LogHistogram is the event distribution over time; the end is exclusive.
type LogHistogram struct {
	StartEpochMs int64       `json:"startEpochMs"`
	EndEpochMs   int64       `json:"endEpochMs"`
	BucketMs     int64       `json:"bucketMs"`
	Buckets      []LogBucket `json:"buckets"`
}

// LogOpSummary summarizes the records of the queried operation.
type LogOpSummary struct {
	Op           string `json:"op"`
	Count        int    `json:"count"`
	FirstEpochMs int64  `json:"firstEpochMs"`
	LastEpochMs  int64  `json:"lastEpochMs"`
	DurationMs   int64  `json:"durationMs"`
}

// LogQueryResult is the answer to a query.
type LogQueryResult struct {
	// SessionSequences is the highest sequence per session, before filtering.
	SessionSequences map[string]uint64 `json:"sessionSequences"`
	// Records are the newest matches in ascending order.
	Records []LogRecord `json:"records"`
	// Truncated reports that evidence was left out.
	Truncated           bool `json:"truncated"`
	SkippedInvalidLines int  `json:"skippedInvalidLines"`
	// FoldMinimumRun is how many equal adjacent records make a foldable run.
	FoldMinimumRun int `json:"foldMinimumRun"`
	// Channels counts every decoded record per channel, before filtering.
	Channels  map[string]LogChannelCount `json:"channels"`
	Histogram *LogHistogram              `json:"histogram"`
	OpSummary *LogOpSummary              `json:"opSummary"`
}

// QueryLogs filters and merges log tails.
func (c *Client) QueryLogs(ctx context.Context, query LogQuery) (LogQueryResult, error) {
	query.Sources = nonNil(query.Sources)
	query.ChannelPrefixes = nonNil(query.ChannelPrefixes)
	return executeLog[LogQueryResult](ctx, c, "diagnostics.queryLogsV2", query)
}

// LogFilterTerm is one term of a filter expression.
type LogFilterTerm struct {
	// Kind is level_at_least, level, op, event, channel, regex, field or text.
	Kind string `json:"kind"`
	// Key is the field name for field terms.
	Key    string `json:"key,omitempty"`
	Value  string `json:"value"`
	Negate bool   `json:"negate"`
}

// LogParsedTerm is a term with the byte range it was parsed from.
type LogParsedTerm struct {
	LogFilterTerm
	Start int `json:"start"`
	End   int `json:"end"`
}

// LogFilterDiagnostic is a syntax error in a filter expression, over a byte range.
type LogFilterDiagnostic struct {
	Start   int    `json:"start"`
	End     int    `json:"end"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// LogFilter is a parsed filter expression.
type LogFilter struct {
	Terms  []LogParsedTerm       `json:"terms"`
	Errors []LogFilterDiagnostic `json:"errors"`
}

// ParseLogFilter parses a filter expression.
func (c *Client) ParseLogFilter(ctx context.Context, expression string) (LogFilter, error) {
	var answer LogFilter
	err := c.Execute(ctx, "diagnostics.parseLogFilter", struct {
		Expression string `json:"expression"`
	}{expression}, &answer)
	return answer, err
}

// ComposeLogFilter adds term to expression, replacing a term it contradicts.
func (c *Client) ComposeLogFilter(ctx context.Context, expression string, term LogFilterTerm) (string, error) {
	answer, err := executeLog[struct {
		Expression string `json:"expression"`
	}](ctx, c, "diagnostics.composeLogFilter", struct {
		Expression string        `json:"expression"`
		Term       LogFilterTerm `json:"term"`
	}{expression, term})
	return answer.Expression, err
}

// LogEnvironment describes the application for exported records.
type LogEnvironment struct {
	AppVersion   string   `json:"appVersion"`
	OsVersion    string   `json:"osVersion"`
	Architecture string   `json:"architecture"`
	Plugins      []string `json:"plugins"`
}

// FormatLogRecords formats disk lines as "json" or "markdown". A nil environment formats the
// bare records.
func (c *Client) FormatLogRecords(ctx context.Context, lines []string, format string, environment *LogEnvironment) (string, error) {
	if environment != nil {
		environment.Plugins = nonNil(environment.Plugins)
	}
	answer, err := executeLog[struct {
		Text string `json:"text"`
	}](ctx, c, "diagnostics.formatLogRecords", struct {
		Lines       []string        `json:"lines"`
		Format      string          `json:"format"`
		Environment *LogEnvironment `json:"environment,omitempty"`
	}{nonNil(lines), format, environment})
	return answer.Text, err
}

// LogSession is one session directory of the inventory.
type LogSession struct {
	Name  string    `json:"name"`
	Files []LogFile `json:"files"`
}

// LogRetentionLimits bounds the log directory; zero fields use the kernel's defaults.
type LogRetentionLimits struct {
	MaxAgeMs         int64  `json:"maxAgeMs,omitempty"`
	TotalBytes       uint64 `json:"totalBytes,omitempty"`
	PerfBytes        uint64 `json:"perfBytes,omitempty"`
	PluginFilesBytes uint64 `json:"pluginFilesBytes,omitempty"`
}

// LogRetentionRequest asks what to delete from the log directory.
type LogRetentionRequest struct {
	Sessions       []LogSession       `json:"sessions"`
	LegacyFiles    []LogFile          `json:"legacyFiles"`
	CurrentSession string             `json:"currentSession"`
	Now            string             `json:"now"`
	Limits         LogRetentionLimits `json:"limits"`
	StartupCleanup bool               `json:"startupCleanup"`
}

// LogDeletion is one file or directory to delete, relative to the log root.
type LogDeletion struct {
	RelativePath string `json:"relativePath"`
	Directory    bool   `json:"directory"`
	Reason       string `json:"reason"`
}

// LogRetentionPlan lists what to delete.
type LogRetentionPlan struct {
	Deletions []LogDeletion `json:"deletions"`
}

// PlanLogRetention plans the deletions that keep the log directory within its limits.
func (c *Client) PlanLogRetention(ctx context.Context, request LogRetentionRequest) (LogRetentionPlan, error) {
	request.Sessions = nonNil(request.Sessions)
	for i := range request.Sessions {
		request.Sessions[i].Files = nonNil(request.Sessions[i].Files)
	}
	request.LegacyFiles = nonNil(request.LegacyFiles)
	return executeLog[LogRetentionPlan](ctx, c, "diagnostics.planLogRetention", request)
}

// CoreEvent is a fact the kernel recorded for the host's writer, which assigns the sequence.
type CoreEvent struct {
	Ts      string         `json:"ts"`
	Level   LogLevel       `json:"level"`
	Event   string         `json:"event"`
	Channel string         `json:"channel"`
	Op      string         `json:"op"`
	Fields  map[string]any `json:"fields"`
}

// CoreEvents is one drain of the kernel's fact queue.
type CoreEvents struct {
	Events []CoreEvent `json:"events"`
	// Dropped counts facts the queue suppressed since the previous drain.
	Dropped uint64 `json:"dropped"`
}

// DrainCoreEvents takes the facts the kernel recorded since the previous drain.
func (c *Client) DrainCoreEvents(ctx context.Context) (CoreEvents, error) {
	var answer CoreEvents
	err := c.Execute(ctx, "diagnostics.drainCoreEvents", nil, &answer)
	return answer, err
}

// ConfigureCoreEvents turns detailed diagnostics on or off. With debug on, roots limits DEBUG
// facts to those channel roots; nil enables every root.
func (c *Client) ConfigureCoreEvents(ctx context.Context, debug bool, roots []string) error {
	payload := struct {
		Debug bool      `json:"debug"`
		Roots *[]string `json:"roots"`
	}{Debug: debug}
	if roots != nil {
		payload.Roots = &roots
	}
	return c.Execute(ctx, "diagnostics.configureCoreEvents", payload, nil)
}
