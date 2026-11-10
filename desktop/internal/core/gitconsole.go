package core

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// The Git console keeps the Git commands the window ran and what they wrote. Core reports a
// request's commands as execution events (see the Rust contract's "Git execution events");
// the console stores them in the bounded journal the contract describes, and Core's
// git.consolePresentation turns the stored records into what the console draws. Core has
// already redacted every text it reports, so nothing here redacts again, and Core decides
// which commands are visible: an internal read-only query never reports a started command.
//
// The lengths of the retention budget are counted in bytes of UTF-8, which is never fewer
// than the characters the budget names, so the console keeps at most what it allows.

// Record states, as Core reports them.
const (
	// GitConsoleRunning is a command that has started and not yet finished.
	GitConsoleRunning = "running"
	// GitConsoleCompleted is a command whose exit Core observed.
	GitConsoleCompleted = "completed"
	// GitConsoleUnconfirmed is a command whose exit was never observed: it was cancelled,
	// or its request failed before it could report one.
	GitConsoleUnconfirmed = "unconfirmed"
)

// GitConsoleSearchLimit is the longest search, in bytes, git.consolePresentation accepts.
const GitConsoleSearchLimit = 1024

// gitConsoleRetention is the journal's budget, as requestStarted carries it.
type gitConsoleRetention struct {
	MaxRecords                int `json:"maxRecords"`
	MaxRecordOutputCharacters int `json:"maxRecordOutputCharacters"`
	MaxRecordOutputLines      int `json:"maxRecordOutputLines"`
	MaxTotalOutputCharacters  int `json:"maxTotalOutputCharacters"`
}

// defaultGitConsoleRetention is Core's budget, used until the first request reports it.
var defaultGitConsoleRetention = gitConsoleRetention{
	MaxRecords:                200,
	MaxRecordOutputCharacters: 32768,
	MaxRecordOutputLines:      2000,
	MaxTotalOutputCharacters:  1 << 20,
}

// GitConsoleLine is one line a command wrote, in the order it wrote them.
type GitConsoleLine struct {
	// Stream is "stdout" or "stderr". Output on stderr alone is not a failure.
	Stream string `json:"stream"`
	Text   string `json:"text"`
}

// GitConsoleRemoteResult is what a fetch or push reported about one remote.
type GitConsoleRemoteResult struct {
	Remote    string
	Succeeded bool
	// ReferencesAvailable says Core could read the changed references; nil when it did not
	// say.
	ReferencesAvailable *bool
	// UpdatedReferences and DeletedReferences are the numbers of changed references; they
	// are nil unless both counts are known, because a missing count must never read as no
	// change.
	UpdatedReferences, DeletedReferences *int
}

// GitConsoleRecord is one command of the console, or the failure of a request that ran
// none, as a snapshot has it. A snapshot's records are never changed afterwards: the journal
// copies a record before it changes it, except for Lines, which it only appends to past the
// snapshot's length or drops from the front of its own slice.
type GitConsoleRecord struct {
	// ID is unique within the window and never reused.
	ID string
	// Revision grows each time the record changes, so a view can tell which records it
	// must present again.
	Revision uint64
	// OperationID is the Core request the command belongs to.
	OperationID string
	// Started is when the console learned of the command.
	Started time.Time
	// Root is the directory the command ran in, or the repository of a failed request.
	Root string
	// Arguments are Git's arguments, without the executable; empty for a failed request
	// that started no command.
	Arguments []string
	// TemporaryConfig is the configuration the command was given on its command line.
	TemporaryConfig [][2]string
	Executable      string
	// Lines are the retained output, oldest first; Truncated says some of it was dropped.
	Lines     []GitConsoleLine
	Truncated bool
	// Progress is the transient progress line Git is rewriting, empty when there is none.
	Progress string
	// State is one of GitConsoleRunning, GitConsoleCompleted and GitConsoleUnconfirmed.
	State string
	// ExitCode is the command's exit status when Exited is set.
	ExitCode int
	Exited   bool
	// ExpectedExit says the workflow accepts a nonzero exit as a normal answer.
	ExpectedExit bool
	Duration     time.Duration
	// Error is the failure Core reported for the command or its request, message and
	// details on separate lines.
	Error        string
	RemoteResult *GitConsoleRemoteResult
}

// GitConsoleSnapshot is the console at one moment.
type GitConsoleSnapshot struct {
	// Records are oldest first.
	Records []GitConsoleRecord
	// Running says a request has started a command and not yet finished, so Stop has
	// something to cancel.
	Running bool
	// Omitted says older records were dropped to stay within the budget.
	Omitted bool
	// Revision grows each time the console changes.
	Revision uint64
}

// GitConsole is the window's Git console journal. It is safe for concurrent use: Core
// reports events on the goroutine of the request, and the window reads snapshots on its
// own thread.
type GitConsole struct {
	mu          sync.Mutex
	retention   gitConsoleRetention
	requests    map[string]*gitConsoleRequest
	records     []*gitConsoleEntry
	outputBytes int
	omitted     bool
	revision    uint64
	nextID      uint64
	now         func() time.Time
	// changed is called after the console changed, outside the lock.
	changed func()
}

// gitConsoleRequest is the bookkeeping of one Core request between requestStarted and
// requestFinished.
type gitConsoleRequest struct {
	// root is the repository the request names, for a failure that started no command.
	root string
	// running says the request started a command; it stays set until the request finishes,
	// even after Clear, so Stop can still cancel it.
	running bool
	// hidden says Clear removed the request's records; its later events are not recorded.
	hidden bool
	// recorded says a record of the request was ever kept.
	recorded bool
	// last is the request's most recent record, which a request failure is reported on.
	last        *gitConsoleEntry
	invocations map[uint64]*gitConsoleEntry
}

// gitConsoleEntry is a record as the journal keeps it.
type gitConsoleEntry struct {
	record GitConsoleRecord
	// outputBytes is what the record's lines count against the budget.
	outputBytes int
	// dropped says the record left the journal; later events for it are ignored.
	dropped bool
}

// NewGitConsole returns an empty console. changed, when not nil, is called after each
// change from the goroutine that made it; it must return promptly and must not call back
// into the console's caller's thread synchronously.
func NewGitConsole(changed func()) *GitConsole {
	return &GitConsole{
		retention: defaultGitConsoleRetention,
		requests:  map[string]*gitConsoleRequest{},
		now:       time.Now,
		changed:   changed,
	}
}

// Revision returns the console's revision, which grows each time it changes.
func (c *GitConsole) Revision() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.revision
}

// Snapshot returns the console's records and state.
func (c *GitConsole) Snapshot() GitConsoleSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	records := make([]GitConsoleRecord, len(c.records))
	for i, entry := range c.records {
		records[i] = entry.record
		lines := entry.record.Lines
		records[i].Lines = lines[:len(lines):len(lines)]
	}
	return GitConsoleSnapshot{Records: records, Running: c.runningLocked(), Omitted: c.omitted, Revision: c.revision}
}

// Clear removes every record. A request that is still running keeps running and Stop can
// still cancel it, but nothing more it reports is recorded.
func (c *GitConsole) Clear() {
	c.mu.Lock()
	for _, entry := range c.records {
		entry.dropped = true
	}
	clear(c.records)
	c.records = c.records[:0]
	c.outputBytes = 0
	c.omitted = false
	for _, request := range c.requests {
		request.hidden = true
		request.last = nil
		request.invocations = nil
	}
	c.revision++
	c.mu.Unlock()
	c.notify()
}

// Stop asks Core to cancel every request that has started a command and not yet finished.
// Cancellation is cooperative: each request ends, and its records show it, when Core stops
// it.
func (c *GitConsole) Stop() {
	c.mu.Lock()
	var operations []string
	for id, request := range c.requests {
		if request.running {
			operations = append(operations, id)
		}
	}
	c.mu.Unlock()
	for _, id := range operations {
		cancelOperation(id)
	}
}

func (c *GitConsole) runningLocked() bool {
	for _, request := range c.requests {
		if request.running {
			return true
		}
	}
	return false
}

// runningOperations returns the requests that have started a command and not yet finished,
// sorted, for tests.
func (c *GitConsole) runningOperations() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var operations []string
	for id, request := range c.requests {
		if request.running {
			operations = append(operations, id)
		}
	}
	slices.Sort(operations)
	return operations
}

func (c *GitConsole) notify() {
	if c.changed != nil {
		c.changed()
	}
}

// gitConsoleError is an error an event carries.
type gitConsoleError struct {
	Code    string  `json:"code"`
	Message string  `json:"message"`
	Details *string `json:"details"`
}

// text is the message and the details on separate lines.
func (e *gitConsoleError) text() string {
	if e.Details != nil && *e.Details != "" {
		return e.Message + "\n" + *e.Details
	}
	return e.Message
}

// gitConsoleEvent is every field of the execution events the console reads.
type gitConsoleEvent struct {
	OperationID string               `json:"operationId"`
	Type        string               `json:"type"`
	Retention   *gitConsoleRetention `json:"retention"`
	// WorkingDirectory is the started command's directory, or, on requestStarted, the
	// repository a host's fixture names.
	WorkingDirectory string      `json:"workingDirectory"`
	InvocationID     *uint64     `json:"invocationId"`
	Arguments        []string    `json:"arguments"`
	TemporaryConfig  [][2]string `json:"temporaryConfig"`
	Executable       *string     `json:"executable"`

	Stream    string `json:"stream"`
	Text      string `json:"text"`
	Progress  bool   `json:"progress"`
	Truncated bool   `json:"truncated"`

	State                string           `json:"state"`
	ExitCode             *int             `json:"exitCode"`
	ExpectedExit         bool             `json:"expectedExit"`
	DurationMilliseconds int64            `json:"durationMilliseconds"`
	Error                *gitConsoleError `json:"error"`

	UnconfirmedInvocations []uint64 `json:"unconfirmedInvocations"`
	FailureRecord          bool     `json:"failureRecord"`

	Remote                string            `json:"remote"`
	Succeeded             bool              `json:"succeeded"`
	ReferencesAvailable   *bool             `json:"referencesAvailable"`
	UpdatedReferences     []json.RawMessage `json:"updatedReferences"`
	DeletedReferences     []json.RawMessage `json:"deletedReferences"`
	UpdatedReferenceCount *int              `json:"updatedReferenceCount"`
	DeletedReferenceCount *int              `json:"deletedReferenceCount"`
}

// receive records one event of a request whose payload named root. An event the console
// cannot read is dropped: the request's own result decides what happened.
func (c *GitConsole) receive(root string, raw json.RawMessage) {
	var event gitConsoleEvent
	if json.Unmarshal(raw, &event) != nil {
		return
	}
	c.mu.Lock()
	changed := c.apply(root, &event)
	if changed {
		c.revision++
	}
	c.mu.Unlock()
	if changed {
		c.notify()
	}
}

// apply records event and says whether the console changed.
func (c *GitConsole) apply(root string, event *gitConsoleEvent) bool {
	id := event.OperationID
	switch event.Type {
	case "requestStarted":
		if event.Retention != nil && event.Retention.MaxRecords > 0 {
			c.retention = *event.Retention
		}
		if event.WorkingDirectory != "" {
			root = event.WorkingDirectory
		}
		c.requests[id] = &gitConsoleRequest{root: root}
		return false
	case "requestFinished":
		return c.finishRequest(root, event)
	}
	request := c.requests[id]
	if request == nil {
		if event.Type != "started" {
			return false
		}
		request = &gitConsoleRequest{root: root}
		c.requests[id] = request
	}
	switch event.Type {
	case "started":
		began := !request.running
		request.running = true
		if request.hidden {
			return began
		}
		c.start(request, event)
		return true
	case "output":
		entry := c.invocation(request, event.InvocationID)
		if entry == nil {
			return false
		}
		c.output(entry, event)
		return true
	case "finished":
		entry := c.invocation(request, event.InvocationID)
		if entry == nil {
			return false
		}
		record := &entry.record
		record.State = event.State
		if record.State == "" {
			record.State = GitConsoleCompleted
		}
		record.Exited = event.ExitCode != nil
		record.ExitCode = -1
		if event.ExitCode != nil {
			record.ExitCode = *event.ExitCode
		}
		record.ExpectedExit = event.ExpectedExit
		record.Duration = time.Duration(event.DurationMilliseconds) * time.Millisecond
		if event.Error != nil {
			record.Error = event.Error.text()
		}
		record.Progress = ""
		c.touch(entry)
		return true
	case "remoteResult":
		entry := c.invocation(request, event.InvocationID)
		if entry == nil {
			return false
		}
		result := &GitConsoleRemoteResult{Remote: event.Remote, Succeeded: event.Succeeded, ReferencesAvailable: event.ReferencesAvailable}
		updated, deleted := referenceCount(event.UpdatedReferenceCount, event.UpdatedReferences), referenceCount(event.DeletedReferenceCount, event.DeletedReferences)
		if updated != nil && deleted != nil {
			result.UpdatedReferences, result.DeletedReferences = updated, deleted
		}
		entry.record.RemoteResult = result
		if event.Error != nil {
			entry.record.Error = event.Error.Message
		}
		c.touch(entry)
		return true
	}
	return false
}

// referenceCount is the number of changed references a remote result reports, from its
// count or else from its list, nil when it reports neither.
func referenceCount(count *int, references []json.RawMessage) *int {
	if count != nil {
		value := *count
		return &value
	}
	if references != nil {
		value := len(references)
		return &value
	}
	return nil
}

// invocation is the live record of a request's command, or of its latest command when the
// event names none.
func (c *GitConsole) invocation(request *gitConsoleRequest, id *uint64) *gitConsoleEntry {
	if request.hidden {
		return nil
	}
	entry := request.last
	if id != nil {
		entry = request.invocations[*id]
	}
	if entry == nil || entry.dropped {
		return nil
	}
	return entry
}

// start keeps a record of a started command.
func (c *GitConsole) start(request *gitConsoleRequest, event *gitConsoleEvent) {
	root := event.WorkingDirectory
	if root == "" {
		root = request.root
	}
	record := GitConsoleRecord{
		OperationID:     event.OperationID,
		Root:            root,
		Arguments:       slices.Clone(event.Arguments),
		TemporaryConfig: slices.Clone(event.TemporaryConfig),
		State:           GitConsoleRunning,
		ExitCode:        -1,
	}
	if event.Executable != nil {
		record.Executable = *event.Executable
	}
	entry := c.append(record)
	request.recorded = true
	request.last = entry
	if event.InvocationID != nil {
		if request.invocations == nil {
			request.invocations = map[uint64]*gitConsoleEntry{}
		}
		request.invocations[*event.InvocationID] = entry
	}
}

// output keeps a line or a progress update of a command, then drops the oldest records
// while the console holds more output than the budget allows.
func (c *GitConsole) output(entry *gitConsoleEntry, event *gitConsoleEvent) {
	record := &entry.record
	if event.Progress {
		record.Progress = strings.Clone(event.Text)
	} else {
		c.appendLine(entry, event.Stream, event.Text)
		record.Progress = ""
	}
	record.Truncated = record.Truncated || event.Truncated
	c.touch(entry)
	for len(c.records) > 1 && c.outputBytes > c.retention.MaxTotalOutputCharacters {
		c.dropOldest()
	}
}

// appendLine keeps one output line within the record's budget: a line longer than the
// record may hold keeps its end, and the oldest lines go while the record holds too much.
func (c *GitConsole) appendLine(entry *gitConsoleEntry, stream, text string) {
	record := &entry.record
	if limit := max(c.retention.MaxRecordOutputCharacters-1, 0); len(text) > limit {
		text = suffix(text, limit)
		record.Truncated = true
	}
	record.Lines = append(record.Lines, GitConsoleLine{Stream: stream, Text: strings.Clone(text)})
	entry.outputBytes += len(text) + 1
	c.outputBytes += len(text) + 1
	for len(record.Lines) > 1 && (entry.outputBytes > c.retention.MaxRecordOutputCharacters || len(record.Lines) > c.retention.MaxRecordOutputLines) {
		size := len(record.Lines[0].Text) + 1
		entry.outputBytes -= size
		c.outputBytes -= size
		record.Lines = record.Lines[1:]
		record.Truncated = true
	}
}

// suffix is the last bytes of s, at most limit of them, starting on a character boundary.
func suffix(s string, limit int) string {
	start := len(s) - limit
	for start < len(s) && !utf8.RuneStart(s[start]) {
		start++
	}
	return s[start:]
}

// append keeps a new record, dropping the oldest while the console holds too many.
func (c *GitConsole) append(record GitConsoleRecord) *gitConsoleEntry {
	c.nextID++
	record.ID = "git-" + strconv.FormatUint(c.nextID, 10)
	record.Started = c.now()
	entry := &gitConsoleEntry{record: record}
	c.records = append(c.records, entry)
	c.touch(entry)
	for len(c.records) > max(c.retention.MaxRecords, 1) {
		c.dropOldest()
	}
	return entry
}

// dropOldest removes the oldest record.
func (c *GitConsole) dropOldest() {
	oldest := c.records[0]
	oldest.dropped = true
	c.outputBytes -= oldest.outputBytes
	c.records[0] = nil
	c.records = c.records[1:]
	c.omitted = true
}

// touch marks entry as changed in the revision being made.
func (c *GitConsole) touch(entry *gitConsoleEntry) {
	entry.record.Revision = c.revision + 1
}

// finishRequest ends a request: its commands that never confirmed an exit are marked so,
// and its failure is shown on its last command, or as a record of its own when it started
// none.
func (c *GitConsole) finishRequest(root string, event *gitConsoleEvent) bool {
	request := c.requests[event.OperationID]
	delete(c.requests, event.OperationID)
	if request == nil {
		request = &gitConsoleRequest{root: root}
	}
	if request.hidden {
		return request.running
	}
	changed := request.running
	if !request.recorded {
		if event.Error == nil || !event.FailureRecord {
			return changed
		}
		c.appendFailure(request, event)
		return true
	}
	for _, id := range event.UnconfirmedInvocations {
		if entry := request.invocations[id]; entry != nil && !entry.dropped {
			entry.record.State = GitConsoleUnconfirmed
			c.touch(entry)
			changed = true
		}
	}
	// A failure no command reported, such as a refusal after the queries that read the
	// state, is its own record; any other belongs to the last command.
	if event.Error != nil {
		if last := request.last; !event.FailureRecord && last != nil && !last.dropped {
			last.record.Error = event.Error.text()
			c.touch(last)
			changed = true
		} else if event.FailureRecord {
			c.appendFailure(request, event)
			changed = true
		}
	}
	return changed
}

// appendFailure keeps a record of a request that failed before a command could report it.
func (c *GitConsole) appendFailure(request *gitConsoleRequest, event *gitConsoleEvent) {
	c.append(GitConsoleRecord{
		OperationID: event.OperationID,
		Root:        request.root,
		Arguments:   []string{},
		State:       GitConsoleUnconfirmed,
		ExitCode:    -1,
		Error:       event.Error.text(),
	})
}

// The console's link to the requests: a context carries the console its Git requests are
// recorded in, and execute observes each recordable request's events.

type gitConsoleKey struct{}

// gitConsoleSink is the console a context's requests are recorded in, and the repository a
// request is recorded under when its payload names none.
type gitConsoleSink struct {
	console *GitConsole
	root    string
}

// WithGitConsole returns a context whose Git requests are recorded in console; root is the
// repository a request is recorded under when its payload names none. A nil console makes
// the context's requests unrecorded, for reads the user did not ask for, such as the
// branches of recent projects.
func WithGitConsole(ctx context.Context, console *GitConsole, root string) context.Context {
	if console == nil {
		return context.WithValue(ctx, gitConsoleKey{}, (*gitConsoleSink)(nil))
	}
	return context.WithValue(ctx, gitConsoleKey{}, &gitConsoleSink{console: console, root: root})
}

type gitRefreshKey struct{}

// AutomaticRefresh returns a context whose Git requests are automatic refreshes, which run
// on every file or repository change: their internal queries stay out of the console, which
// records every other Git command a request runs. The commands the user started still
// appear.
func AutomaticRefresh(ctx context.Context) context.Context {
	return context.WithValue(ctx, gitRefreshKey{}, true)
}

// gitExecutionOf is the Git policy of a request: a Git request of a context with a console
// asks Core to report its internal queries, unless the context is an automatic refresh.
// Other requests keep Core's defaults.
func gitExecutionOf(ctx context.Context, command string) *gitExecution {
	if !strings.HasPrefix(command, "git.") || gitConsoleUnrecorded[command] {
		return nil
	}
	if sink, _ := ctx.Value(gitConsoleKey{}).(*gitConsoleSink); sink == nil {
		return nil
	}
	if refresh, _ := ctx.Value(gitRefreshKey{}).(bool); refresh {
		return &gitExecution{Source: "background"}
	}
	return &gitExecution{ReportQueries: true}
}

// gitConsoleUnrecorded are the git commands that never run Git: they parse, plan or present
// what the host gives them, or answer a prompt of a running request, so a failure of theirs
// is not a Git command the user would look for in the console.
var gitConsoleUnrecorded = map[string]bool{
	"git.consolePresentation":        true,
	"git.authRespond":                true,
	"git.changelists":                true,
	"git.classifyMetadataChanges":    true,
	"git.branchNamePreview":          true,
	"git.parseCheckoutMetadata":      true,
	"git.parseGitdirPointer":         true,
	"git.graphProjection":            true,
	"git.repositoryColorAssignments": true,
	"git.executionInspect":           true,
	"git.historyCursorClose":         true,
}

// gitConsoleObserver returns the observer of a request: next, preceded by the console of
// ctx when command runs Git. It returns next unchanged when there is nothing to record.
func gitConsoleObserver(ctx context.Context, command string, request []byte, next func(json.RawMessage)) func(json.RawMessage) {
	if !strings.HasPrefix(command, "git.") || gitConsoleUnrecorded[command] {
		return next
	}
	sink, _ := ctx.Value(gitConsoleKey{}).(*gitConsoleSink)
	if sink == nil {
		return next
	}
	root := sink.root
	var envelope struct {
		Payload struct {
			Root string `json:"root"`
		} `json:"payload"`
	}
	if json.Unmarshal(request, &envelope) == nil && envelope.Payload.Root != "" {
		root = envelope.Payload.Root
	}
	console := sink.console
	return func(event json.RawMessage) {
		console.receive(root, event)
		if next != nil {
			next(event)
		}
	}
}

// Presentation: git.consolePresentation folds and searches the records the console keeps.

// GitConsoleCommandFragment is a run of a command's text: plain text, or a fold of the
// temporary configuration that shows Preview until it is opened.
type GitConsoleCommandFragment struct {
	ID string `json:"id"`
	// Kind is "text" or "configuration".
	Kind    string `json:"kind"`
	Text    string `json:"text"`
	Preview string `json:"preview"`
	// Count is the number of settings a configuration fold holds.
	Count int `json:"count"`
	// Matches is the number of search matches in Text.
	Matches int `json:"matches"`
}

// GitConsoleOutputFragment is a half-open range [Start, End) of a record's Lines: plain
// lines, or a fold of progress lines labelled by its last line.
type GitConsoleOutputFragment struct {
	ID    string `json:"id"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	// Kind is "text" or "progress".
	Kind  string `json:"kind"`
	Count int    `json:"count"`
	// Added, Updated and Deleted are the reference changes a fold reports.
	Added   int `json:"added"`
	Updated int `json:"updated"`
	Deleted int `json:"deleted"`
	Matches int `json:"matches"`
}

// Console notices, which the host translates.
const (
	GitConsoleNoticeWaiting   = "waitingForOutput"
	GitConsoleNoticeNoOutput  = "completedWithoutOutput"
	GitConsoleNoticeUnchanged = "fetchUnchanged"
)

// GitConsoleEntry is how the console draws one record.
type GitConsoleEntry struct {
	// ID is the record's ID.
	ID string `json:"id"`
	// RepositoryLabel is the repository the record ran in.
	RepositoryLabel string                      `json:"repositoryLabel"`
	Command         []GitConsoleCommandFragment `json:"command"`
	Output          []GitConsoleOutputFragment  `json:"output"`
	// Failed says the record is a failure: an error, an unconfirmed exit, or an exit the
	// workflow did not expect.
	Failed bool `json:"failed"`
	// Notice is one of the GitConsoleNotice values, empty for none.
	Notice string `json:"notice"`
	// Matches is the exact number of search matches in the record.
	Matches int `json:"-"`
}

// GitConsoleHit is one search match: in the repository label ("repository"), in a command
// or output fragment, in the error ("error") or in the progress line ("progress").
// LineIndex is the index into the record's Lines of a match in output.
type GitConsoleHit struct {
	RecordID   string `json:"recordId"`
	FragmentID string `json:"fragmentId"`
	LineIndex  *int   `json:"lineIndex"`
}

// GitConsolePresentation is how the console draws records.
type GitConsolePresentation struct {
	// Entries are in the order of the records asked for.
	Entries []GitConsoleEntry
	// Hits are the first of the matches Core locates, at most 1000 per request; the exact
	// numbers are in TotalMatches and each entry's Matches.
	Hits         []GitConsoleHit
	TotalMatches int
}

type gitConsoleWireRemote struct {
	Succeeded             bool  `json:"succeeded"`
	ReferencesAvailable   *bool `json:"referencesAvailable,omitempty"`
	UpdatedReferenceCount *int  `json:"updatedReferenceCount,omitempty"`
	DeletedReferenceCount *int  `json:"deletedReferenceCount,omitempty"`
}

type gitConsoleWireRecord struct {
	ID              string                `json:"id"`
	Root            string                `json:"root"`
	Arguments       []string              `json:"arguments"`
	TemporaryConfig [][2]string           `json:"temporaryConfig"`
	Lines           []GitConsoleLine      `json:"lines"`
	State           string                `json:"state"`
	ExitCode        *int                  `json:"exitCode,omitempty"`
	ExpectedExit    bool                  `json:"expectedExit"`
	Error           *string               `json:"error,omitempty"`
	Executable      *string               `json:"executable,omitempty"`
	Progress        *string               `json:"progress,omitempty"`
	RemoteResult    *gitConsoleWireRemote `json:"remoteResult,omitempty"`
	Truncated       bool                  `json:"truncated"`
}

type gitConsolePresentationRequest struct {
	Records []gitConsoleWireRecord `json:"records"`
	Search  string                 `json:"search"`
}

type gitConsoleGroup struct {
	Matches   int      `json:"matches"`
	RecordIDs []string `json:"recordIds"`
}

type gitConsolePresentationResponse struct {
	Entries      []GitConsoleEntry `json:"entries"`
	Groups       []gitConsoleGroup `json:"groups"`
	Matches      []GitConsoleHit   `json:"matches"`
	TotalMatches int               `json:"totalMatches"`
}

// The limits of one git.consolePresentation request. A request's size is measured the way
// Core measures it, and kept under Core's 4 MiB with room to spare.
const (
	gitConsolePresentRecords = 200
	gitConsolePresentBytes   = 3 << 20
)

// wire is the record as git.consolePresentation reads it, and the size Core counts it as.
func (r *GitConsoleRecord) wire() (gitConsoleWireRecord, int) {
	wire := gitConsoleWireRecord{
		ID:              r.ID,
		Root:            r.Root,
		Arguments:       nonNil(r.Arguments),
		TemporaryConfig: nonNil(r.TemporaryConfig),
		Lines:           nonNil(r.Lines),
		State:           r.State,
		ExpectedExit:    r.ExpectedExit,
		Truncated:       r.Truncated,
	}
	size := len(r.ID) + len(r.Root) + len(r.State) + len(r.Error) + len(r.Progress) + len(r.Executable) + 32*len(r.Lines) + 8*len(r.Arguments)
	for _, line := range r.Lines {
		size += len(line.Text)
	}
	for _, argument := range r.Arguments {
		size += len(argument)
	}
	for _, setting := range r.TemporaryConfig {
		size += len(setting[0]) + len(setting[1]) + 16
	}
	if r.Exited {
		code := r.ExitCode
		wire.ExitCode = &code
	}
	if r.Error != "" {
		wire.Error = &r.Error
	}
	if r.Executable != "" {
		wire.Executable = &r.Executable
	}
	if r.Progress != "" {
		wire.Progress = &r.Progress
	}
	if result := r.RemoteResult; result != nil {
		wire.RemoteResult = &gitConsoleWireRemote{
			Succeeded:             result.Succeeded,
			ReferencesAvailable:   result.ReferencesAvailable,
			UpdatedReferenceCount: result.UpdatedReferences,
			DeletedReferenceCount: result.DeletedReferences,
		}
	}
	return wire, size
}

// GitConsolePresentation asks Core how to draw records, matching search case-insensitively
// when it is not empty. Records are sent in as many requests as Core's limits need, so any
// number may be asked for; search must be at most GitConsoleSearchLimit bytes.
//
// GitConsolePresentation blocks; call it from a background goroutine.
func (c *Client) GitConsolePresentation(ctx context.Context, records []GitConsoleRecord, search string) (GitConsolePresentation, error) {
	var presentation GitConsolePresentation
	request := gitConsolePresentationRequest{Search: search, Records: []gitConsoleWireRecord{}}
	size := 0
	send := func() error {
		var response gitConsolePresentationResponse
		if err := c.Execute(ctx, "git.consolePresentation", request, &response); err != nil {
			return err
		}
		matches := make(map[string]int, len(response.Groups))
		for _, group := range response.Groups {
			for _, id := range group.RecordIDs {
				matches[id] += group.Matches
			}
		}
		for _, entry := range response.Entries {
			entry.Matches = matches[entry.ID]
			presentation.Entries = append(presentation.Entries, entry)
		}
		presentation.Hits = append(presentation.Hits, response.Matches...)
		presentation.TotalMatches += response.TotalMatches
		request.Records, size = request.Records[:0], 0
		return nil
	}
	for i := range records {
		wire, n := records[i].wire()
		if len(request.Records) > 0 && (len(request.Records) == gitConsolePresentRecords || size+n > gitConsolePresentBytes) {
			if err := send(); err != nil {
				return GitConsolePresentation{}, err
			}
		}
		request.Records = append(request.Records, wire)
		size += n
	}
	if len(request.Records) > 0 {
		if err := send(); err != nil {
			return GitConsolePresentation{}, err
		}
	}
	return presentation, nil
}
