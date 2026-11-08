package logstore

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// exportLimit is the most records an export holds, the kernel's own limit of a query.
const exportLimit = 10000

// ExportQuery selects what a diagnostic export holds. The kernel interprets every field; the
// store only forwards them.
type ExportQuery struct {
	// Session is current, previous or all.
	Session string
	// RecentSessions keeps only the newest sessions of all of them; zero keeps every one.
	RecentSessions int
	// Since is an inclusive RFC 3339 bound on the sessions and records collected.
	Since string
	// ChannelPrefixes, Levels and Expression filter the records as the window does: nil
	// prefixes keep every channel, nil levels every severity.
	ChannelPrefixes []string
	Levels          []core.LogLevel
	Expression      string
	// FilterSince and FilterUntil are the window's own time range, which the kernel
	// intersects with Since.
	FilterSince, FilterUntil string
}

// ExportFile is one file of an export, with its path inside the bundle.
type ExportFile struct {
	RelativePath string
	Data         []byte
}

// Export is what Collect gathered for a diagnostic bundle.
type Export struct {
	// Files are the records of each log file read, under logs/, and collection-status.txt,
	// which says how complete they are.
	Files []ExportFile
	// Truncated says evidence was left out: the kernel's budget cut a file, a file shrank or
	// disappeared while it was read, or a line could not be decoded.
	Truncated bool
	// Directory is the log directory that was read.
	Directory string
	// EstimatedBytes is how much the kernel planned to read.
	EstimatedBytes uint64
	// Sessions are the session directories the plan covered.
	Sessions []string
}

// Collect writes what is queued, asks the kernel which files and byte ranges an export of q
// covers, reads them and returns the kernel's redacted lines grouped by the file they came
// from. As with QueryWindow, the reading happens on the writer and the query on the caller's
// goroutine. The macOS client's MacLogStore.collect is the reference.
func (s *Store) Collect(ctx context.Context, q ExportQuery) (Export, error) {
	var (
		sources   []core.LogSource
		directory string
		plan      core.LogCollectionPlan
		short     bool
	)
	err := s.do(ctx, func(job context.Context) error {
		if err := s.drain(job); err != nil {
			return err
		}
		directory = s.directory
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
		plan, err = s.kernel.PlanLogCollection(job, core.LogCollectionRequest{
			Files:          metadata,
			CurrentSession: sessionName(s.sessionPath),
			Session:        q.Session,
			RecentSessions: q.RecentSessions,
			Since:          q.Since,
		})
		if err != nil {
			return err
		}
		sources, short, err = s.readExport(job, directory, known, plan.Reads)
		return err
	})
	if err != nil {
		return Export{}, err
	}

	query := core.LogQuery{
		Sources:         sources,
		ChannelPrefixes: q.ChannelPrefixes,
		Since:           q.Since,
		Limit:           exportLimit,
		Expression:      q.Expression,
		FilterSince:     q.FilterSince,
		FilterUntil:     q.FilterUntil,
	}
	if q.Levels != nil {
		levels := slices.Clone(q.Levels)
		query.Levels = &levels
	}
	result, err := s.kernel.QueryLogs(ctx, query)
	if err != nil {
		return Export{}, err
	}
	if err := ctx.Err(); err != nil {
		return Export{}, err
	}

	// The kernel returns redacted, canonical lines, so an export never holds a raw one.
	grouped := make(map[string][]string)
	for _, record := range result.Records {
		grouped[record.RelativePath] = append(grouped[record.RelativePath], record.Line)
	}
	files := make([]ExportFile, 0, len(grouped)+1)
	for _, path := range slices.Sorted(maps.Keys(grouped)) {
		files = append(files, ExportFile{
			RelativePath: "logs/" + path,
			Data:         []byte(strings.Join(grouped[path], "\n") + "\n"),
		})
	}
	truncated := plan.Truncated || short || result.Truncated || result.SkippedInvalidLines > 0
	dropped, failures := s.Stats()
	status := fmt.Sprintf("truncated=%t dropped_events=%d write_failures=%d skipped_invalid_lines=%d\n",
		truncated, dropped, failures, result.SkippedInvalidLines)
	files = append(files, ExportFile{RelativePath: "collection-status.txt", Data: []byte(status)})
	return Export{
		Files:          files,
		Truncated:      truncated,
		Directory:      directory,
		EstimatedBytes: plan.EstimatedBytes,
		Sessions:       slices.Clone(plan.Sessions),
	}, nil
}

// readExport reads each byte range of an export's plan, as readSources does for the window,
// and says whether a range came back shorter than planned: the file shrank, or retention
// deleted it, since the inventory listed it.
func (s *Store) readExport(ctx context.Context, root string, known map[string]string, reads []core.LogRead) ([]core.LogSource, bool, error) {
	sources := make([]core.LogSource, 0, len(reads))
	short := false
	for _, read := range reads {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		target, ok := known[read.RelativePath]
		if !ok {
			var err error
			if target, err = safePath(root, read.RelativePath); err != nil {
				return nil, false, err
			}
		}
		text, err := s.readRange(target, read.Offset, read.MaxBytes)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				short = true
				continue
			}
			return nil, false, err
		}
		short = short || uint64(len(text)) < read.MaxBytes
		sources = append(sources, core.LogSource{
			RelativePath:  read.RelativePath,
			Text:          text,
			StartsMidLine: read.Offset > 0,
		})
	}
	return sources, short, nil
}
