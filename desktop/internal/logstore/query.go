package logstore

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"maps"
	"math"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Query selects what the log window shows. The kernel interprets every field; the store only
// forwards them.
type Query struct {
	// Session is current, previous or all.
	Session string
	// Expression is a filter in the log filter language.
	Expression string
	// ChannelPrefixes keeps only the channels that start with one of the prefixes.
	ChannelPrefixes []string
	// Levels is the exact set of severities to keep. Nil keeps every severity; a non-nil empty
	// slice keeps none.
	Levels []core.LogLevel
	// Since and Until are inclusive RFC 3339 bounds.
	Since, Until string
	// Op keeps only the records of one operation.
	Op string
	// AfterSequences hides records at or below a session's watermark. Live batches are
	// addressed by the session directory name, for example 2026-11-08T09-30-00_0d949d58.
	AfterSequences map[string]uint64
}

// Batch is one encoded line and the channel the kernel assigned it to.
type Batch struct {
	Channel, Line string
}

// Collection is the answer to QueryWindow: the kernel's result plus the writer's state.
type Collection struct {
	Result core.LogQueryResult
	// Directory is the log directory that was read.
	Directory string
	// CurrentSessionPath is this process's session directory relative to Directory.
	CurrentSessionPath string
	// Dropped and WriteFailures are the totals reported by Stats.
	Dropped, WriteFailures int
	DiagnosticCategory     string
	DiagnosticRemaining    time.Duration
}

// LiveSummary is the histogram of the records the window currently holds, plus the writer's
// state.
type LiveSummary struct {
	Histogram              *core.LogHistogram
	Dropped, WriteFailures int
	DiagnosticCategory     string
	DiagnosticRemaining    time.Duration
}

// subscriber is one live listener. cancelled stops delivery without taking any lock, so a
// callback that is running can be cancelled from any goroutine.
type subscriber struct {
	fn        func([]Batch)
	cancelled atomic.Bool
}

// QueryWindow writes what is queued, asks the kernel which files and byte ranges answer the
// query, reads them and returns the kernel's result. The reading happens on the writer so it
// sees a consistent directory; the query itself runs on the caller's goroutine.
func (s *Store) QueryWindow(ctx context.Context, q Query) (Collection, error) {
	var (
		sources   []core.LogSource
		directory string
		session   string
	)
	err := s.do(ctx, func(job context.Context) error {
		if err := s.drain(job); err != nil {
			return err
		}
		directory = s.directory
		session = s.sessionPath
		if directory == "" {
			return errNoDirectory
		}
		files, err := inventory(directory)
		if err != nil {
			return err
		}
		known := make(map[string]string, len(files))
		metadata := make([]core.LogFile, 0, len(files))
		for _, file := range files {
			known[file.relative] = file.path
			metadata = append(metadata, core.LogFile{
				RelativePath: file.relative,
				SizeBytes:    uint64(max(0, file.size)),
				ModifiedAt:   formatTime(file.modified),
			})
		}
		plan, err := s.kernel.PlanLogCollection(job, core.LogCollectionRequest{
			Files:          metadata,
			CurrentSession: sessionName(session),
			Session:        q.Session,
		})
		if err != nil {
			return err
		}
		sources, err = s.readSources(job, directory, known, plan.Reads)
		return err
	})
	if err != nil {
		return Collection{}, err
	}

	result, err := s.kernel.QueryLogs(ctx, windowQuery(sources, q))
	if err != nil {
		return Collection{}, err
	}
	dropped, failures := s.Stats()
	category, remaining, _ := s.Diagnostics()
	return Collection{
		Result:              result,
		Directory:           directory,
		CurrentSessionPath:  session,
		Dropped:             dropped,
		WriteFailures:       failures,
		DiagnosticCategory:  category,
		DiagnosticRemaining: remaining,
	}, nil
}

// QueryWindowBatch runs a query over lines that were just written, the ones a subscription
// delivered, without touching the disk. The kernel sees them as files of the current
// session, one per channel, so the result carries the same channel and path as the same lines
// read back from disk.
func (s *Store) QueryWindowBatch(ctx context.Context, batch []Batch, q Query) (core.LogQueryResult, error) {
	grouped := make(map[string][]string)
	for _, entry := range batch {
		grouped[entry.Channel] = append(grouped[entry.Channel], entry.Line)
	}
	prefix := ""
	if session := s.SessionPath(); session != "" {
		prefix = session + "/"
	}
	sources := make([]core.LogSource, 0, len(grouped))
	for _, channel := range slices.Sorted(maps.Keys(grouped)) {
		sources = append(sources, core.LogSource{
			RelativePath: prefix + channel + ".log",
			Text:         strings.Join(grouped[channel], "\n"),
		})
	}
	return s.kernel.QueryLogs(ctx, windowQuery(sources, q))
}

// LiveSummary builds the histogram of the records the window currently holds. The records
// are the kernel's own, so their lines are fed back to it unchanged.
func (s *Store) LiveSummary(ctx context.Context, records []core.LogRecord) (LiveSummary, error) {
	grouped := make(map[string][]string)
	for _, record := range records {
		grouped[record.Channel] = append(grouped[record.Channel], record.Line)
	}
	sources := make([]core.LogSource, 0, len(grouped))
	for _, channel := range slices.Sorted(maps.Keys(grouped)) {
		sources = append(sources, core.LogSource{
			RelativePath: channel + ".log",
			Text:         strings.Join(grouped[channel], "\n"),
		})
	}
	result, err := s.kernel.QueryLogs(ctx, core.LogQuery{
		Sources:          sources,
		Limit:            1,
		HistogramBuckets: windowBuckets,
	})
	if err != nil {
		return LiveSummary{}, err
	}
	dropped, failures := s.Stats()
	category, remaining, _ := s.Diagnostics()
	return LiveSummary{
		Histogram:           result.Histogram,
		Dropped:             dropped,
		WriteFailures:       failures,
		DiagnosticCategory:  category,
		DiagnosticRemaining: remaining,
	}, nil
}

// Subscribe delivers every line the store writes from now on, in batches, to fn. A new
// subscriber first receives the most recent lines (up to recentCount lines or recentLimit
// bytes), so a window opened late still shows the lead-up.
//
// fn runs on the writer goroutine: it must return quickly, must not block, and must not call
// back into the store (Subscribe, Flush, Close, queries). Copy what you need and hand it to
// your own goroutine. The returned cancel stops delivery, is safe to call more than once and
// from any goroutine, and does not wait for a call already running. When the store is closed,
// or already has subscriberLimit subscribers, nothing is delivered and cancel does nothing.
func (s *Store) Subscribe(fn func([]Batch)) (cancel func()) {
	noop := func() {}
	if fn == nil {
		return noop
	}
	sub := &subscriber{fn: fn}
	err := s.do(context.Background(), func(context.Context) error {
		s.subsMu.Lock()
		if len(s.subscribers) >= subscriberLimit {
			s.subsMu.Unlock()
			return ErrBusy
		}
		s.subscribers[sub] = struct{}{}
		s.subsMu.Unlock()
		// The history is delivered once this job has answered, so fn never runs while the
		// caller is still inside Subscribe.
		if len(s.recent) > 0 {
			s.replays = append(s.replays, replay{sub: sub, batches: slices.Clone(s.recent)})
		}
		return nil
	})
	if err != nil {
		return noop
	}
	return func() {
		sub.cancelled.Store(true)
		s.subsMu.Lock()
		delete(s.subscribers, sub)
		s.subsMu.Unlock()
	}
}

// windowQuery turns a window query and its sources into the kernel's query.
func windowQuery(sources []core.LogSource, q Query) core.LogQuery {
	query := core.LogQuery{
		Sources:          sources,
		ChannelPrefixes:  q.ChannelPrefixes,
		Since:            q.Since,
		Until:            q.Until,
		AfterSequences:   q.AfterSequences,
		Op:               q.Op,
		Limit:            windowLimit,
		Expression:       q.Expression,
		HistogramBuckets: windowBuckets,
	}
	if q.Levels != nil {
		levels := q.Levels
		query.Levels = &levels
	}
	return query
}

// readSources reads each byte range of the plan. A file that disappeared since the inventory,
// rotated or deleted by retention, is skipped rather than failing the whole query. known maps
// the kernel's relative paths to the files they were listed from, which differs from the path
// itself only for older root-level files.
func (s *Store) readSources(ctx context.Context, root string, known map[string]string, reads []core.LogRead) ([]core.LogSource, error) {
	sources := make([]core.LogSource, 0, len(reads))
	for _, read := range reads {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		target, ok := known[read.RelativePath]
		if !ok {
			var err error
			if target, err = safePath(root, read.RelativePath); err != nil {
				return nil, err
			}
		}
		text, err := s.readRange(target, read.Offset, read.MaxBytes)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return nil, err
		}
		sources = append(sources, core.LogSource{
			RelativePath:  read.RelativePath,
			Text:          text,
			StartsMidLine: read.Offset > 0,
		})
	}
	return sources, nil
}

// readRange reads at most limit bytes of target starting at offset. The plan's limits come from
// the kernel and are bounded there.
func (s *Store) readRange(target string, offset, limit uint64) (string, error) {
	file, err := os.Open(target)
	if err != nil {
		return "", err
	}
	data, readErr := io.ReadAll(io.NewSectionReader(file, clampInt64(offset), clampInt64(limit)))
	if err := file.Close(); err != nil {
		s.fail()
	}
	if readErr != nil {
		return "", readErr
	}
	return string(data), nil
}

func clampInt64(value uint64) int64 {
	return int64(min(value, math.MaxInt64))
}
