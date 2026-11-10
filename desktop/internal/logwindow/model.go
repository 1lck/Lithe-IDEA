// Package logwindow is the application log window: a live, filterable view of the
// structured logs that package logstore writes.
//
// The kernel decides everything a log means. It parses and composes filter expressions,
// selects, merges and folds records, counts channels, builds the histogram and formats
// records for copying; the window only asks and paints the answers. The macOS client's log
// window is the reference for the layout, and both use the same kernel calls, so a log reads
// the same in either client.
//
// Everything in the model runs on the window thread. The query of the logs is a ui.Effect of
// the window's page, keyed by the query; the other kernel and disk calls run on their own
// goroutines and hand their result back through the model's mailbox, which the window drains
// in OnWake before it paints.
package logwindow

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"maps"
	"math"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/ui"
)

// Source is the log store the window reads. *logstore.Store implements it.
type Source interface {
	QueryWindow(ctx context.Context, q logstore.Query) (logstore.Collection, error)
	QueryWindowBatch(ctx context.Context, batch []logstore.Batch, q logstore.Query) (core.LogQueryResult, error)
	LiveSummary(ctx context.Context, records []core.LogRecord) (logstore.LiveSummary, error)
	Subscribe(fn func([]logstore.Batch)) (cancel func())
	Emit(level core.LogLevel, event, op string, fields map[string]any)
	UsedBytes() int64
	ChangeDirectory(dir string) error
	RestoreDefaultDirectory() error
	DefaultDirectory() string
	ClearLogs() error
	ConfigureDiagnostics(enabled bool)
	Collect(ctx context.Context, q logstore.ExportQuery) (logstore.Export, error)
}

// Kernel is what the window asks the kernel directly. *core.Client implements it.
type Kernel interface {
	ParseLogFilter(ctx context.Context, expression string) (core.LogFilter, error)
	ComposeLogFilter(ctx context.Context, expression string, term core.LogFilterTerm) (string, error)
	FormatLogRecords(ctx context.Context, lines []string, format string, environment *core.LogEnvironment) (string, error)
	RedactText(ctx context.Context, text string) (string, error)
	BuildDiagnosticsManifest(ctx context.Context, environment core.DiagnosticsEnvironment, files []core.DiagnosticsFile, generatedAt int64) (core.DiagnosticsManifest, error)
}

const (
	// maxRecords is how many records the window holds; older ones are discarded as new
	// ones arrive.
	maxRecords = 20_000
	// maxBookmarks, maxChannels, maxExpressionBytes and maxBookmarkName bound what the
	// preferences file may hold.
	maxBookmarks       = 50
	maxChannels        = 64
	maxExpressionBytes = 1024
	maxBookmarkName    = 128
	// minColumnWidth and maxColumnWidth bound a column's width.
	minColumnWidth = 40
	maxColumnWidth = 2000
	// prefsFile keeps the window's preferences in the client's store.
	prefsFile = "log-window.json"
	// defaultDebounce is how long typing in the filter waits before it queries.
	defaultDebounce = 150 * time.Millisecond
	// diagnosticsFailed is the event the window records when it cannot read the logs.
	diagnosticsFailed = "app.logging.diagnostics_failed"
)

// Sessions the session menu offers, in its order.
const (
	sessionCurrent  = "current"
	sessionPrevious = "previous"
	sessionAll      = "all"
)

var sessions = []string{sessionCurrent, sessionPrevious, sessionAll}

// columns are the table's columns, in their default order.
var columns = []string{"seq", "time", "level", "channel", "event", "message", "fields"}

// allLevels is the level set of a new query: every level, in the order the macOS client
// stores it.
var allLevels = []core.LogLevel{core.LevelDebug, core.LevelInfo, core.LevelWarn, core.LevelError}

// windowQuery is the query the user builds in the toolbar and the channel list. It is what
// the preferences keep; the clear watermarks are not part of it.
type windowQuery struct {
	Session         string          `json:"session"`
	Expression      string          `json:"expression"`
	ChannelPrefixes []string        `json:"channelPrefixes"`
	Levels          []core.LogLevel `json:"levels"`
	Since           string          `json:"since,omitempty"`
	Until           string          `json:"until,omitempty"`
	Op              string          `json:"op,omitempty"`
}

func defaultQuery() windowQuery {
	return windowQuery{Session: sessionCurrent, ChannelPrefixes: []string{}, Levels: slices.Clone(allLevels)}
}

// clone is a copy of q that shares no slice with it.
func (q windowQuery) clone() windowQuery {
	q.ChannelPrefixes = slices.Clone(q.ChannelPrefixes)
	q.Levels = slices.Clone(q.Levels)
	return q
}

// bookmark is a saved filter.
type bookmark struct {
	ID    string      `json:"id"`
	Name  string      `json:"name"`
	Query windowQuery `json:"query"`
}

// preferences are the window's choices, kept in prefsFile.
type preferences struct {
	Query    windowQuery `json:"query"`
	Collapse bool        `json:"collapse"`
	// TimeMode is 0 for absolute time, 1 for the time since the previous row and 2 for the
	// time since the selected row.
	TimeMode  int                `json:"timeMode"`
	Widths    map[string]float64 `json:"widths"`
	Hidden    []string           `json:"hidden"`
	Bookmarks []bookmark         `json:"bookmarks"`
}

func defaultPreferences() preferences {
	return preferences{Query: defaultQuery(), Collapse: true, Widths: map[string]float64{}}
}

// sanitize bounds a query read from disk or built by the user.
func (q *windowQuery) sanitize() {
	if !slices.Contains(sessions, q.Session) {
		q.Session = sessionCurrent
	}
	q.Expression = boundExpression(q.Expression)
	if q.ChannelPrefixes == nil {
		q.ChannelPrefixes = []string{}
	}
	if len(q.ChannelPrefixes) > maxChannels {
		q.ChannelPrefixes = q.ChannelPrefixes[:maxChannels]
	}
	// A missing level set means every level; an empty one is the user's choice of none.
	if q.Levels == nil {
		q.Levels = slices.Clone(allLevels)
	}
	q.Levels = slices.DeleteFunc(q.Levels, func(level core.LogLevel) bool { return !slices.Contains(core.LogLevels, level) })
}

// sanitize bounds the preferences read from disk.
func (p *preferences) sanitize() {
	p.Query.sanitize()
	p.Hidden = slices.DeleteFunc(p.Hidden, func(column string) bool { return !slices.Contains(columns, column) })
	widths := make(map[string]float64, len(p.Widths))
	for column, width := range p.Widths {
		if slices.Contains(columns, column) && !math.IsNaN(width) && width < 1e9 && width > -1e9 {
			widths[column] = columnWidth(width)
		}
	}
	p.Widths = widths
	p.TimeMode = min(2, max(0, p.TimeMode))
	if len(p.Bookmarks) > maxBookmarks {
		p.Bookmarks = p.Bookmarks[:maxBookmarks]
	}
	for i := range p.Bookmarks {
		p.Bookmarks[i].Name = truncateRunes(p.Bookmarks[i].Name, maxBookmarkName)
		p.Bookmarks[i].Query.sanitize()
		if p.Bookmarks[i].ID == "" {
			p.Bookmarks[i].ID = newID()
		}
	}
}

func columnWidth(width float64) float64 { return min(maxColumnWidth, max(minColumnWidth, width)) }

// boundExpression cuts an expression to maxExpressionBytes on a character boundary.
func boundExpression(value string) string {
	if len(value) <= maxExpressionBytes {
		return value
	}
	cut := maxExpressionBytes
	for cut > 0 && !utf8.RuneStart(value[cut]) {
		cut--
	}
	return value[:cut]
}

func truncateRunes(value string, limit int) string {
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	return string([]rune(value)[:limit])
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// recordID identifies a record across queries. seq is local to a session, and the source
// path tells historical sessions apart.
func recordID(record core.LogRecord) string {
	return record.RelativePath + ":" + strconv.FormatUint(record.Seq, 10) + ":" + record.Ts
}

// displayRow is one row of the table. A run head carries the run's length and the time of
// its last record; an expanded or unfolded member counts 1.
type displayRow struct {
	// index is the record's index in Model.records.
	index int
	id    string
	count int
	last  string
	isRun bool
}

// Options configure a model.
type Options struct {
	Source Source
	Kernel Kernel
	// Store keeps the window's preferences; nil keeps them in memory only.
	Store *store.Store
	// Now is the clock; nil is time.Now.
	Now func() time.Time
	// Debounce is how long typing in the filter waits; zero is defaultDebounce, a negative
	// value does not wait.
	Debounce time.Duration
	// Environment describes the client for copied records; nil copies them without it.
	Environment func() core.LogEnvironment
	// Clipboard, Reveal and ChooseDirectory reach the system. Nil does nothing.
	Clipboard       func(text string) error
	Reveal          func(path string) error
	ChooseDirectory func(current string) (string, error)
	// SaveFile asks where to save a diagnostic bundle, suggesting a file name; an empty
	// path is a cancelled choice. Nil cannot export.
	SaveFile func(suggested string) (string, error)
	// CacheDirectory is the platform's cache directory, where an export stages its
	// evidence. Nil cannot export.
	CacheDirectory func() (string, error)
	// System describes the machine for a bundle's manifest, measuring the free space of
	// volume; nil records nothing about it.
	System func(volume string) sysinfo.Snapshot
	// Wake asks the window to drain the mailbox; nil is for tests, which drain themselves.
	Wake func()
}

// Model is the state of the log window. Its methods run on the window thread.
//
// The records slice is only ever appended to, resliced or replaced; an element is never
// written in place. That is what lets a background task read the slice it was given while
// the window thread moves on.
type Model struct {
	opts Options
	now  func() time.Time

	// The mailbox: results of background work, applied by drain.
	mu      sync.Mutex
	pending []func()
	running sync.WaitGroup
	ctx     context.Context
	stopAll context.CancelFunc
	closed  bool

	prefs preferences
	// expressionRevision counts changes of the expression the window did not type itself
	// (a composed term, an applied bookmark), so the filter field can follow them.
	expressionRevision int

	records []core.LogRecord
	ids     []string
	// keyBase is the key of records[0]: a record's key is keyBase plus its index. Keys are
	// handed out once and never reused, so a list can hold a record's selection by its key
	// while the records before it are trimmed or the whole answer is replaced. keyNext is
	// the key the next record gets.
	keyBase, keyNext int
	// selectionRevision counts the changes of the selection, so the table can tell the
	// list's own choice from one the model made.
	selectionRevision int
	channels          map[string]core.LogChannelCount
	histogram         *core.LogHistogram
	foldMinimumRun    int
	selection         map[string]bool
	expandedRuns      map[string]bool

	follows, scrolledUp bool
	newCount, discarded int
	// scrollTarget is the row the table scrolls to when scrollRevision changes; empty
	// scrolls to the end.
	scrollTarget   string
	scrollRevision int

	directory, currentSessionPath string
	defaultDirectory              string
	dropped, writeFailures        int
	diagnosticRemaining           time.Duration
	diagnosticCategory            string
	diagnosticSince               time.Time
	cleared                       bool
	unreadErrors                  map[string]bool
	trace                         *core.LogQueryResult
	diagnostics                   []core.LogFilterDiagnostic
	terms                         []core.LogParsedTerm
	failed                        bool

	// generation tells the answer to the latest query from one that a clear or a newer query
	// replaced. queryKey is the generation of the latest refresh and the key of the page's
	// query effect: a clear invalidates the answer in flight without asking again.
	generation      int
	queryKey        int
	job             atomic.Pointer[queryJob]
	queryFx         *ui.EffectState[queryResult, int]
	traceCancel     context.CancelFunc
	traceOp         string
	watermarks      map[string]uint64
	latestSequences map[string]uint64
	activeQuery     logstore.Query
	queryPending    bool
	needsRefresh    bool
	started         bool
	liveFailed      bool
	liveRevision    int
	unsubscribe     func()
	liveQueue       []logstore.Batch
	liveBusy        bool

	detailID   string
	detailText string

	usedBytes int64
	busy      bool

	export exportState
	// staging maps the export's staging directories to whether a task holds one; guarded by
	// mu, as closing the window removes those no task holds.
	staging map[string]bool

	dirty      bool
	rows       []displayRow
	selected   int
	totalCount int
}

// NewModel reads the preferences and returns a model that has not started reading logs.
func NewModel(opts Options) *Model {
	m := &Model{
		opts:             opts,
		now:              opts.Now,
		prefs:            defaultPreferences(),
		channels:         map[string]core.LogChannelCount{},
		foldMinimumRun:   3,
		selection:        map[string]bool{},
		expandedRuns:     map[string]bool{},
		unreadErrors:     map[string]bool{},
		follows:          true,
		latestSequences:  map[string]uint64{},
		dirty:            true,
		selected:         -1,
		defaultDirectory: opts.Source.DefaultDirectory(),
	}
	if m.now == nil {
		m.now = time.Now
	}
	if m.opts.Debounce == 0 {
		m.opts.Debounce = defaultDebounce
	}
	m.ctx, m.stopAll = context.WithCancel(context.Background())
	m.queryFx = ui.NewEffect[queryResult, int](m.runQuery)
	if opts.Store != nil {
		loaded := defaultPreferences()
		if _, err := opts.Store.Load(prefsFile, &loaded); err == nil {
			m.prefs = loaded
		}
	}
	m.prefs.sanitize()
	m.activeQuery = m.query()
	return m
}

// post queues fn for the window thread and wakes the window.
func (m *Model) post(fn func()) {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.pending = append(m.pending, fn)
	m.mu.Unlock()
	m.wake()
}

// wake asks the window to paint, which drains the mailbox and starts the query a refresh
// asked for.
func (m *Model) wake() {
	if m.opts.Wake != nil {
		m.opts.Wake()
	}
}

// drain applies what background work posted. It is part of the window's OnWake.
func (m *Model) drain() {
	m.mu.Lock()
	pending := m.pending
	m.pending = nil
	m.mu.Unlock()
	for _, fn := range pending {
		fn()
	}
}

// spawn runs work on its own goroutine.
func (m *Model) spawn(work func()) {
	m.running.Add(1)
	go func() {
		defer m.running.Done()
		work()
	}()
}

// wait blocks until every background task has returned and applies their results, for
// tests and shutdown.
func (m *Model) wait() {
	for {
		m.running.Wait()
		m.mu.Lock()
		quiet := len(m.pending) == 0
		m.mu.Unlock()
		if quiet {
			return
		}
		m.drain()
	}
}

// start reads the logs and follows new ones. Calling it again does nothing.
func (m *Model) start() {
	if m.started {
		return
	}
	m.started = true
	m.refresh(false)
	m.subscribe()
}

// close stops every task and drops what they would still deliver.
func (m *Model) close() {
	m.started = false
	m.generation++
	m.liveRevision++
	if m.unsubscribe != nil {
		m.unsubscribe()
		m.unsubscribe = nil
	}
	m.stopAll()
	m.mu.Lock()
	m.closed = true
	m.pending = nil
	m.mu.Unlock()
	m.removeUnheldStaging()
}

// query is the user's query with the clear watermarks.
func (m *Model) query() logstore.Query {
	q := m.prefs.Query
	result := logstore.Query{
		Session:         q.Session,
		Expression:      q.Expression,
		ChannelPrefixes: slices.Clone(q.ChannelPrefixes),
		Levels:          append([]core.LogLevel{}, q.Levels...),
		Since:           q.Since,
		Until:           q.Until,
		Op:              q.Op,
	}
	if len(m.watermarks) > 0 {
		result.AfterSequences = maps.Clone(m.watermarks)
	}
	return result
}

func (m *Model) persist() {
	if m.opts.Store == nil {
		return
	}
	if err := m.opts.Store.Save(prefsFile, m.prefs); err != nil {
		m.report(err)
	}
}

// queryJob is what a refresh asks of the query effect: the query, and how long to wait
// before it for typing to settle.
type queryJob struct {
	generation int
	q          logstore.Query
	delay      time.Duration
}

// queryResult is the answer to a queryJob: the filter the kernel parsed and, when it has no
// syntax error, the records.
type queryResult struct {
	generation int
	q          logstore.Query
	parsed     core.LogFilter
	collection logstore.Collection
}

// refresh queries the logs again. debounce waits first, for typing. The page's query effect
// is keyed by queryKey, so it cancels the query in flight and starts this one at the next
// paint, which wake asks for.
func (m *Model) refresh(debounce bool) {
	m.generation++
	m.queryKey = m.generation
	m.queryPending = true
	delay := time.Duration(0)
	if debounce && m.opts.Debounce > 0 {
		delay = m.opts.Debounce
	}
	m.job.Store(&queryJob{generation: m.generation, q: m.query(), delay: delay})
	m.wake()
}

// declareQuery declares the query effect in the window's page and applies the answer it
// finished with. It is called once in each paint, before anything reads the records.
func (m *Model) declareQuery(c ui.C) {
	if m.job.Load() == nil {
		return
	}
	ui.Effect(c, m.queryFx, m.queryKey)
	if result, err, ok := m.queryFx.Take(); ok {
		m.finishQuery(result, err)
	}
}

// runQuery is the effect's work, off the window thread: it waits out the debounce, has the
// kernel parse the expression and, when it parses, reads the records.
func (m *Model) runQuery(ctx context.Context) (queryResult, error) {
	job := m.job.Load()
	result := queryResult{generation: job.generation, q: job.q}
	if job.delay > 0 {
		timer := time.NewTimer(job.delay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return result, ctx.Err()
		}
	}
	parsed, err := m.opts.Kernel.ParseLogFilter(ctx, job.q.Expression)
	if err != nil {
		return result, err
	}
	result.parsed = parsed
	if len(parsed.Errors) > 0 {
		return result, nil
	}
	result.collection, err = m.opts.Source.QueryWindow(ctx, job.q)
	return result, err
}

// finishQuery applies the answer of the query effect unless a clear or a newer refresh made
// it stale.
func (m *Model) finishQuery(result queryResult, err error) {
	if err != nil {
		m.queryFailed(m.queryKey, err)
		return
	}
	if result.generation != m.generation {
		return
	}
	if len(result.parsed.Errors) > 0 {
		m.diagnostics = result.parsed.Errors
		m.queryPending = false
		m.needsRefresh = false
		return
	}
	m.diagnostics = nil
	m.terms = result.parsed.Terms
	m.applyCollection(result.q, result.collection)
}

func (m *Model) queryFailed(token int, err error) {
	if token != m.generation {
		return
	}
	m.queryPending = false
	m.report(err)
}

// applyCollection replaces the records with the answer to a query.
func (m *Model) applyCollection(q logstore.Query, c logstore.Collection) {
	m.activeQuery = q
	m.activeQuery.AfterSequences = maps.Clone(m.watermarks)
	m.directory = c.Directory
	m.currentSessionPath = c.CurrentSessionPath
	m.dropped, m.writeFailures = c.Dropped, c.WriteFailures
	m.setDiagnostics(c.DiagnosticCategory, c.DiagnosticRemaining)
	m.latestSequences = maps.Clone(c.Result.SessionSequences)
	if m.latestSequences == nil {
		m.latestSequences = map[string]uint64{}
	}
	m.records = c.Result.Records
	m.keyBase = m.keyNext
	m.keyNext += len(m.records)
	m.ids = make([]string, len(m.records))
	present := make(map[string]bool, len(m.records))
	for i, record := range m.records {
		m.ids[i] = recordID(record)
		present[m.ids[i]] = true
	}
	m.channels = c.Result.Channels
	if m.channels == nil {
		m.channels = map[string]core.LogChannelCount{}
	}
	m.histogram = c.Result.Histogram
	if c.Result.FoldMinimumRun > 0 {
		m.foldMinimumRun = c.Result.FoldMinimumRun
	}
	maps.DeleteFunc(m.selection, func(id string, _ bool) bool { return !present[id] })
	m.selectionRevision++
	maps.DeleteFunc(m.expandedRuns, func(id string, _ bool) bool { return !present[id] })
	m.dirty = true
	if !m.liveFailed {
		m.failed = false
	}
	m.queryPending = false
	if m.needsRefresh {
		m.needsRefresh = false
		m.refresh(false)
		return
	}
	m.selectIDs(m.selection)
}

func (m *Model) setDiagnostics(category string, remaining time.Duration) {
	m.diagnosticCategory = category
	m.diagnosticRemaining = remaining
	m.diagnosticSince = m.now()
}

// diagnosticsLeft is how long detailed diagnostics stay on; zero when they are off.
func (m *Model) diagnosticsLeft() time.Duration {
	left := m.diagnosticRemaining - m.now().Sub(m.diagnosticSince)
	return max(0, left)
}

// subscribe follows the lines the store writes from now on.
func (m *Model) subscribe() {
	if m.unsubscribe != nil {
		m.unsubscribe()
		m.unsubscribe = nil
	}
	m.liveRevision++
	revision := m.liveRevision
	m.liveFailed = false
	m.liveQueue = nil
	m.liveBusy = false
	m.spawn(func() {
		cancel := m.opts.Source.Subscribe(func(batch []logstore.Batch) {
			lines := slices.Clone(batch)
			m.post(func() { m.enqueueLive(revision, lines) })
		})
		m.post(func() {
			if revision != m.liveRevision {
				cancel()
				return
			}
			m.unsubscribe = cancel
		})
	})
}

func (m *Model) enqueueLive(revision int, batch []logstore.Batch) {
	if revision != m.liveRevision || !m.started {
		return
	}
	m.liveQueue = append(m.liveQueue, batch...)
	m.processLive()
}

// processLive runs the queued live lines through the kernel, one batch at a time, so the
// records keep the order they were written in.
func (m *Model) processLive() {
	if m.liveBusy || len(m.liveQueue) == 0 {
		return
	}
	batch := m.liveQueue
	m.liveQueue = nil
	// Only the current session receives this process's lines.
	if m.activeQuery.Session == sessionPrevious || len(m.activeQuery.Levels) == 0 {
		return
	}
	if m.queryPending {
		m.needsRefresh = true
		return
	}
	m.liveBusy = true
	revision, generation := m.liveRevision, m.generation
	q := m.activeQuery
	q.AfterSequences = maps.Clone(q.AfterSequences)
	q.ChannelPrefixes = slices.Clone(q.ChannelPrefixes)
	q.Levels = slices.Clone(q.Levels)
	held := m.records
	m.spawn(func() {
		result, err := m.opts.Source.QueryWindowBatch(m.ctx, batch, q)
		if err != nil {
			m.post(func() { m.liveError(revision, err) })
			return
		}
		window := retainedWindow(held, result.Records)
		summary, err := m.opts.Source.LiveSummary(m.ctx, window)
		if err != nil {
			m.post(func() { m.liveError(revision, err) })
			return
		}
		m.post(func() {
			if revision != m.liveRevision {
				return
			}
			m.liveBusy = false
			if generation == m.generation {
				m.append(result, &summary)
			}
			m.processLive()
		})
	})
}

// retainedWindow is what the window holds after held gains added: the last maxRecords of
// both.
func retainedWindow(held, added []core.LogRecord) []core.LogRecord {
	keep := max(0, maxRecords-len(added))
	if len(held) > keep {
		held = held[len(held)-keep:]
	}
	window := make([]core.LogRecord, 0, len(held)+len(added))
	window = append(window, held...)
	window = append(window, added...)
	if len(window) > maxRecords {
		window = window[len(window)-maxRecords:]
	}
	return window
}

func (m *Model) liveError(revision int, err error) {
	if revision != m.liveRevision {
		return
	}
	m.liveBusy = false
	m.liveFailed = true
	m.follows = false
	if m.unsubscribe != nil {
		m.unsubscribe()
		m.unsubscribe = nil
	}
	m.report(err)
}

// liveKey identifies a live record against one read back from disk, whose path differs.
type liveKey struct {
	ts      string
	seq     uint64
	channel string
}

// append adds the records of a live batch.
func (m *Model) append(result core.LogQueryResult, summary *logstore.LiveSummary) {
	// A subscription first replays its recent lines; drop the ones the window holds.
	var additions []core.LogRecord
	if len(result.Records) > 0 {
		retained := make(map[liveKey]struct{}, len(m.records))
		for _, record := range m.records {
			retained[liveKey{record.Ts, record.Seq, record.Channel}] = struct{}{}
		}
		for _, record := range result.Records {
			if _, ok := retained[liveKey{record.Ts, record.Seq, record.Channel}]; ok {
				continue
			}
			// Live records are located relative to the session; disk records relative to the
			// directory. Normalize once so selection and scrolling agree.
			if !strings.HasPrefix(record.RelativePath, "sessions/") && m.currentSessionPath != "" {
				record.RelativePath = m.currentSessionPath + "/" + record.RelativePath
			}
			additions = append(additions, record)
		}
	}
	for session, sequence := range result.SessionSequences {
		if sequence > m.latestSequences[session] {
			m.latestSequences[session] = sequence
		}
	}
	for _, record := range additions {
		m.records = append(m.records, record)
		m.ids = append(m.ids, recordID(record))
	}
	m.keyNext += len(additions)
	if removed := len(m.records) - maxRecords; removed > 0 {
		for _, id := range m.ids[:removed] {
			if m.selection[id] {
				m.selectionRevision++
			}
			delete(m.selection, id)
			delete(m.expandedRuns, id)
		}
		m.records = m.records[removed:]
		m.ids = m.ids[removed:]
		m.keyBase += removed
		m.discarded += removed
	}
	if !m.follows {
		m.newCount += len(additions)
	}
	prefixes := m.prefs.Query.ChannelPrefixes
	for channel, count := range result.Channels {
		if count.Error > 0 && len(prefixes) > 0 && !slices.Contains(prefixes, channel) && len(m.unreadErrors) < maxChannels {
			m.unreadErrors[channel] = true
		}
	}
	// The kernel counts the whole batch, filtered or not. A replay that is entirely held
	// already must not count its channels twice.
	if len(result.Records) == 0 || len(additions) > 0 {
		for channel, count := range result.Channels {
			old := m.channels[channel]
			m.channels[channel] = core.LogChannelCount{Total: old.Total + count.Total, Warn: old.Warn + count.Warn, Error: old.Error + count.Error}
		}
	}
	if summary != nil {
		m.histogram = summary.Histogram
		m.dropped, m.writeFailures = summary.Dropped, summary.WriteFailures
		m.setDiagnostics(summary.DiagnosticCategory, summary.DiagnosticRemaining)
	}
	if result.FoldMinimumRun > 0 {
		m.foldMinimumRun = result.FoldMinimumRun
	}
	if len(additions) > 0 {
		m.cleared = m.cleared && len(m.records) == 0
	}
	m.dirty = true
	m.syncDetail()
}

// ensure recomputes the rows and the selected record after a change.
func (m *Model) ensure() {
	if !m.dirty {
		return
	}
	m.dirty = false
	m.rows = m.rows[:0]
	for index := 0; index < len(m.records); {
		end := index + 1
		for end < len(m.records) && m.records[end].FoldKey == m.records[index].FoldKey {
			end++
		}
		count := end - index
		id := m.ids[index]
		isRun := m.prefs.Collapse && count >= m.foldMinimumRun
		m.rows = append(m.rows, displayRow{index: index, id: id, count: count, last: m.records[end-1].Ts, isRun: isRun})
		if !isRun || m.expandedRuns[id] {
			for child := index + 1; child < end; child++ {
				m.rows = append(m.rows, displayRow{index: child, id: m.ids[child], count: 1})
			}
		}
		index = end
	}
	m.selected = -1
	if len(m.selection) > 0 {
		for i := len(m.ids) - 1; i >= 0; i-- {
			if m.selection[m.ids[i]] {
				m.selected = i
				break
			}
		}
	}
	m.totalCount = 0
	for _, count := range m.channels {
		m.totalCount += count.Total
	}
}

// displayRows are the rows the table shows.
func (m *Model) displayRows() []displayRow {
	m.ensure()
	return m.rows
}

// selectedRecord is the last selected record, the one the details pane shows.
func (m *Model) selectedRecord() (core.LogRecord, bool) {
	m.ensure()
	if m.selected < 0 {
		return core.LogRecord{}, false
	}
	return m.records[m.selected], true
}

// selectedRecords are the selected records in table order.
func (m *Model) selectedRecords() []core.LogRecord {
	var selected []core.LogRecord
	for i, id := range m.ids {
		if m.selection[id] {
			selected = append(selected, m.records[i])
		}
	}
	return selected
}

// totalRecords is the number of records the kernel counted in every channel.
func (m *Model) totalRecords() int {
	m.ensure()
	return m.totalCount
}

// selectedLine is the source line of the selected record, or 0.
func (m *Model) selectedLine() int {
	if record, ok := m.selectedRecord(); ok {
		return record.LineNumber
	}
	return 0
}

// selectIDs replaces the selection and loads the call chain of the selected operation.
func (m *Model) selectIDs(ids map[string]bool) {
	if ids == nil {
		ids = map[string]bool{}
	}
	m.selection = ids
	m.selectionRevision++
	m.dirty = true
	m.syncDetail()
	record, ok := m.selectedRecord()
	op := ""
	if ok {
		op = record.Op
	}
	if op == m.traceOp {
		return
	}
	if m.traceCancel != nil {
		m.traceCancel()
		m.traceCancel = nil
	}
	m.trace = nil
	m.traceOp = op
	if op == "" {
		return
	}
	ctx, cancel := context.WithCancel(m.ctx)
	m.traceCancel = cancel
	q := logstore.Query{Session: m.prefs.Query.Session, Op: op}
	m.spawn(func() {
		defer cancel()
		collection, err := m.opts.Source.QueryWindow(ctx, q)
		m.post(func() {
			if m.traceOp != op {
				return
			}
			if err != nil {
				m.report(err)
				return
			}
			m.trace = &collection.Result
		})
	})
}

// toggleRun expands or folds a run of repeated records.
func (m *Model) toggleRun(id string) {
	if m.expandedRuns[id] {
		delete(m.expandedRuns, id)
	} else {
		m.expandedRuns[id] = true
	}
	m.dirty = true
}

// syncDetail formats the selected record for the details pane when the selection moved to
// another record.
func (m *Model) syncDetail() {
	record, ok := m.selectedRecord()
	id := ""
	if ok {
		id = m.ids[m.selected]
	}
	if id == m.detailID {
		return
	}
	m.detailID = id
	m.detailText = ""
	if id == "" {
		return
	}
	line := record.Line
	m.spawn(func() {
		text, err := m.opts.Kernel.FormatLogRecords(m.ctx, []string{line}, "json", nil)
		m.post(func() {
			if m.detailID != id {
				return
			}
			if err != nil {
				m.report(err)
				return
			}
			m.detailText = text
		})
	})
}

// userScrolledUp pauses following when the user scrolls away from the newest record.
func (m *Model) userScrolledUp() {
	if !m.follows {
		return
	}
	m.follows = false
	m.scrolledUp = true
	m.newCount = 0
}

// retry reconnects live following if it failed and queries again.
func (m *Model) retry() {
	if m.started && m.liveFailed {
		m.subscribe()
	}
	m.refresh(false)
}

// resume follows the newest records again and scrolls to them.
func (m *Model) resume() {
	m.follows = true
	m.scrolledUp = false
	m.newCount = 0
	m.scrollTarget = ""
	m.scrollRevision++
	if m.liveFailed {
		m.retry()
	}
}

func (m *Model) toggleFollow() {
	if m.follows {
		m.follows = false
		m.scrolledUp = false
		return
	}
	m.resume()
}

// clearDisplay empties the table without touching the files: later queries leave out
// every record up to the newest one seen so far.
func (m *Model) clearDisplay() {
	m.watermarks = maps.Clone(m.latestSequences)
	m.activeQuery.AfterSequences = maps.Clone(m.watermarks)
	// A query or batch in flight must not bring the cleared rows back.
	m.generation++
	m.queryPending = false
	m.needsRefresh = false
	m.records = nil
	m.ids = nil
	m.keyBase = m.keyNext
	m.selection = map[string]bool{}
	m.selectionRevision++
	m.expandedRuns = map[string]bool{}
	m.trace = nil
	m.cleared = true
	m.newCount = 0
	m.follows = true
	if m.traceCancel != nil {
		m.traceCancel()
		m.traceCancel = nil
	}
	m.traceOp = ""
	m.dirty = true
	m.syncDetail()
}

// jump selects the first record at or after epochMs and scrolls to it.
func (m *Model) jump(epochMs int64) {
	for i, record := range m.records {
		if record.EpochMs >= epochMs {
			id := m.ids[i]
			m.follows = false
			m.scrollTarget = id
			m.scrollRevision++
			m.selectIDs(map[string]bool{id: true})
			return
		}
	}
}

// changeQuery applies update to the user's query, saves it and queries again.
func (m *Model) changeQuery(update func(q *windowQuery)) {
	update(&m.prefs.Query)
	m.prefs.Query.sanitize()
	for _, channel := range m.prefs.Query.ChannelPrefixes {
		delete(m.unreadErrors, channel)
	}
	m.persist()
	m.refresh(false)
}

// setExpression is the user typing in the filter field.
func (m *Model) setExpression(value string) {
	m.prefs.Query.Expression = boundExpression(value)
	m.persist()
	m.refresh(true)
}

// replaceExpression changes the expression from outside the filter field.
func (m *Model) replaceExpression(value string) {
	m.expressionRevision++
	m.setExpression(value)
}

// toggleLevel shows or hides one level.
func (m *Model) toggleLevel(level core.LogLevel) {
	m.changeQuery(func(q *windowQuery) {
		if slices.Contains(q.Levels, level) {
			q.Levels = slices.DeleteFunc(q.Levels, func(l core.LogLevel) bool { return l == level })
		} else {
			q.Levels = append(q.Levels, level)
		}
	})
}

func (m *Model) levelEnabled(level core.LogLevel) bool {
	return slices.Contains(m.prefs.Query.Levels, level)
}

// setSession switches between the current, the previous and every session.
func (m *Model) setSession(session string) {
	m.changeQuery(func(q *windowQuery) { q.Session = session })
}

// setChannels restricts the table to channels; empty shows every channel.
func (m *Model) setChannels(channels []string) {
	sorted := slices.Clone(channels)
	slices.Sort(sorted)
	m.changeQuery(func(q *windowQuery) { q.ChannelPrefixes = slices.Compact(sorted) })
}

// setRange limits the table to [since, until], both in milliseconds since the epoch.
func (m *Model) setRange(since, until int64) {
	m.follows = false
	m.changeQuery(func(q *windowQuery) {
		q.Since = formatInstant(since)
		q.Until = formatInstant(until)
	})
}

// clearRange removes the time limit.
func (m *Model) clearRange() {
	m.changeQuery(func(q *windowQuery) { q.Since, q.Until = "", "" })
}

// formatInstant is an RFC 3339 instant with milliseconds, in UTC.
func formatInstant(epochMs int64) string {
	return time.UnixMilli(epochMs).UTC().Format("2006-01-02T15:04:05.000Z07:00")
}

// parseInstant reads an instant the query holds, in milliseconds since the epoch.
func parseInstant(value string) (int64, bool) {
	if value == "" {
		return 0, false
	}
	at, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return 0, false
	}
	return at.UnixMilli(), true
}

// compose adds a term to the expression, the way the kernel writes it.
func (m *Model) compose(term core.LogFilterTerm) {
	expression := m.prefs.Query.Expression
	m.spawn(func() {
		composed, err := m.opts.Kernel.ComposeLogFilter(m.ctx, expression, term)
		m.post(func() {
			if err != nil {
				m.report(err)
				return
			}
			m.replaceExpression(composed)
		})
	})
}

// copyFormatted formats records in format, json or markdown, and puts the text on the
// clipboard. Copies carry the description of the client; the details pane does not.
func (m *Model) copyFormatted(records []core.LogRecord, format string) {
	if len(records) == 0 || m.opts.Clipboard == nil {
		return
	}
	lines := make([]string, len(records))
	for i, record := range records {
		lines[i] = record.Line
	}
	var environment *core.LogEnvironment
	if m.opts.Environment != nil {
		env := m.opts.Environment()
		environment = &env
	}
	m.spawn(func() {
		text, err := m.opts.Kernel.FormatLogRecords(m.ctx, lines, format, environment)
		m.post(func() {
			if err != nil {
				m.report(err)
				return
			}
			m.copyText(text)
		})
	})
}

// copyText puts text on the clipboard.
func (m *Model) copyText(text string) {
	if m.opts.Clipboard == nil {
		return
	}
	if err := m.opts.Clipboard(text); err != nil {
		m.report(err)
	}
}

func (m *Model) toggleCollapse() {
	m.prefs.Collapse = !m.prefs.Collapse
	m.dirty = true
	m.persist()
}

func (m *Model) cycleTime() {
	m.prefs.TimeMode = (m.prefs.TimeMode + 1) % 3
	m.persist()
}

func (m *Model) columnHidden(column string) bool { return slices.Contains(m.prefs.Hidden, column) }

func (m *Model) setColumnHidden(column string, hidden bool) {
	m.prefs.Hidden = slices.DeleteFunc(m.prefs.Hidden, func(c string) bool { return c == column })
	if hidden {
		m.prefs.Hidden = append(m.prefs.Hidden, column)
	}
	m.persist()
}

// columnWidthOf is a column's width; fallback when the user never resized it.
func (m *Model) columnWidthOf(column string, fallback float64) float64 {
	if width, ok := m.prefs.Widths[column]; ok {
		return width
	}
	return fallback
}

// setColumnWidth remembers a resized column. persist is false while the user drags, so the
// file is written once when the drag ends.
func (m *Model) setColumnWidth(column string, width float64, persist bool) {
	m.prefs.Widths[column] = columnWidth(width)
	if persist {
		m.persist()
	}
}

// saveBookmark saves the current filter under name.
func (m *Model) saveBookmark(name string) {
	name = strings.TrimSpace(name)
	if name == "" || len(m.prefs.Bookmarks) >= maxBookmarks {
		return
	}
	q := m.prefs.Query
	q.ChannelPrefixes = slices.Clone(q.ChannelPrefixes)
	q.Levels = slices.Clone(q.Levels)
	m.prefs.Bookmarks = append(m.prefs.Bookmarks, bookmark{ID: newID(), Name: truncateRunes(name, maxBookmarkName), Query: q})
	m.persist()
}

func (m *Model) applyBookmark(id string) {
	for _, b := range m.prefs.Bookmarks {
		if b.ID == id {
			q := b.Query
			q.ChannelPrefixes = slices.Clone(q.ChannelPrefixes)
			q.Levels = slices.Clone(q.Levels)
			m.prefs.Query = q
			m.prefs.Query.sanitize()
			m.expressionRevision++
			m.persist()
			m.refresh(false)
			return
		}
	}
}

func (m *Model) deleteBookmark(id string) {
	m.prefs.Bookmarks = slices.DeleteFunc(m.prefs.Bookmarks, func(b bookmark) bool { return b.ID == id })
	m.persist()
}

// setDiagnosticsEnabled turns detailed diagnostics on or off and reads the logs again.
func (m *Model) setDiagnosticsEnabled(enabled bool) {
	m.spawn(func() {
		m.opts.Source.ConfigureDiagnostics(enabled)
		m.post(func() { m.refresh(false) })
	})
}

// loadUsedBytes measures the log directory for the maintenance menu.
func (m *Model) loadUsedBytes() {
	m.spawn(func() {
		used := m.opts.Source.UsedBytes()
		m.post(func() { m.usedBytes = used })
	})
}

// revealDirectory shows the log directory in the file manager.
func (m *Model) revealDirectory() {
	if m.directory == "" || m.opts.Reveal == nil {
		return
	}
	if err := m.opts.Reveal(m.directory); err != nil {
		m.report(err)
	}
}

// chooseDirectory asks for a new log directory and moves logging there.
func (m *Model) chooseDirectory() {
	if m.busy || m.opts.ChooseDirectory == nil {
		return
	}
	m.busy = true
	current := m.directory
	m.spawn(func() {
		dir, err := m.opts.ChooseDirectory(current)
		if err == nil && dir != "" {
			err = m.opts.Source.ChangeDirectory(dir)
		}
		m.post(func() {
			m.busy = false
			if err != nil {
				m.report(err)
				return
			}
			if dir != "" {
				m.refresh(false)
			}
		})
	})
}

// canRestoreDirectory reports whether the log directory is not the default one.
func (m *Model) canRestoreDirectory() bool {
	return !m.busy && m.directory != "" && m.defaultDirectory != "" && m.directory != m.defaultDirectory
}

// restoreDirectory moves logging back to the default directory.
func (m *Model) restoreDirectory() {
	if !m.canRestoreDirectory() {
		return
	}
	m.busy = true
	m.spawn(func() {
		err := m.opts.Source.RestoreDefaultDirectory()
		m.post(func() {
			m.busy = false
			if err != nil {
				m.report(err)
				return
			}
			m.refresh(false)
		})
	})
}

// clearLogs deletes every log file in the directory and reads the logs again.
func (m *Model) clearLogs() {
	if m.busy {
		return
	}
	m.busy = true
	m.spawn(func() {
		err := m.opts.Source.ClearLogs()
		m.post(func() {
			m.busy = false
			if err != nil {
				m.report(err)
			}
			m.usedBytes = 0
			m.refresh(false)
		})
	})
}

// report records a failure to read the logs and shows the error line.
func (m *Model) report(err error) {
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	m.opts.Source.Emit(core.LevelWarn, diagnosticsFailed, "", ErrorFields(err))
	m.failed = true
}

// ErrorFields encodes an error the way the event catalog asks: a bounded message without
// control characters, a code and the domain the code belongs to.
func ErrorFields(err error) map[string]any {
	message := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return ' '
		}
		return r
	}, err.Error())
	if len(message) > 1024 {
		cut := 1024
		for cut > 0 && !utf8.RuneStart(message[cut]) {
			cut--
		}
		message = message[:cut]
	}
	code, domain := any("unknown"), "go"
	var logErr *core.LogError
	var coreErr *core.Error
	var errno syscall.Errno
	switch {
	case errors.As(err, &logErr):
		code, domain = logErr.Code, "lithe.logging"
	case errors.As(err, &coreErr):
		code, domain = string(coreErr.Code), "lithe.core"
	case errors.As(err, &errno):
		code, domain = int(errno), "posix"
	}
	return map[string]any{"error": message, "error_code": code, "error_domain": domain}
}
