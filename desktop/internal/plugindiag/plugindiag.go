// Package plugindiag holds the diagnostics a language server published for the
// files of one workspace.
//
// The package only stores what a language server sent. Grouping, the order a
// problems panel shows, and filtering belong to Core's lsp.problems.query, so
// nothing here decides which diagnostic a user sees or how a list of them reads.
// What it does own are the two things a client needs from storage: bounds, so a
// runaway server cannot exhaust memory, and a deterministic order, so a query
// over unchanged content always answers the same way.
//
// Storage is bounded per file by MaxDiagnosticsPerFile and per workspace by
// MaxFiles. A replace that would cross either bound is refused as a whole, so a
// caller that publishes too much keeps what it had instead of half of the new
// batch.
//
// A Set is safe for concurrent use: diagnostics arrive from the goroutine that
// reads the language server, while the UI asks for them from its own.
package plugindiag

import (
	"errors"
	"fmt"
	"sort"
	"sync"
)

// Severity is an LSP diagnostic severity number.
type Severity int

const (
	SeverityError       Severity = 1
	SeverityWarning     Severity = 2
	SeverityInformation Severity = 3
	SeverityHint        Severity = 4
)

const (
	// MaxDiagnosticsPerFile bounds how many diagnostics one file may hold.
	MaxDiagnosticsPerFile = 1000

	// MaxFiles bounds how many files one workspace may hold diagnostics for.
	MaxFiles = 5000
)

var (
	// ErrInvalidDiagnostic reports a diagnostic this package refuses to store.
	ErrInvalidDiagnostic = errors.New("plugin diagnostic is not storable")
	// ErrTooMany reports a replace over MaxDiagnosticsPerFile or MaxFiles.
	ErrTooMany = errors.New("plugin diagnostics exceed the storage limit")
)

// Valid reports whether s is one of the four LSP severities.
func (s Severity) Valid() bool {
	switch s {
	case SeverityError, SeverityWarning, SeverityInformation, SeverityHint:
		return true
	default:
		return false
	}
}

// Diagnostic is one published diagnostic.
//
// The fields are the ones Core hands the host. Line and Column are zero-based,
// and Column counts UTF-16 code units, as LSP counts them; the host converts
// them to its own coordinates when it paints them.
type Diagnostic struct {
	FileKey     string
	DisplayPath string
	Line        int
	Column      int
	// EndLine and EndColumn close the range the diagnostic covers, so an editor can
	// underline the whole token rather than one cell.
	EndLine   int
	EndColumn int
	Severity  Severity
	Message   string
	Source    string
	Code      string
}

// Validate reports whether a diagnostic can be stored.
//
// A diagnostic needs a file, a non-negative position, an LSP severity and a
// message, because a marker with no text has nothing to show. DisplayPath,
// Source and Code stay optional: a server may publish a diagnostic without a
// source name or a code, and the host still shows it.
func (d Diagnostic) Validate() error {
	if d.FileKey == "" {
		return fmt.Errorf("%w: file key is empty", ErrInvalidDiagnostic)
	}
	if d.Line < 0 {
		return fmt.Errorf("%w: line %d is negative", ErrInvalidDiagnostic, d.Line)
	}
	if d.Column < 0 {
		return fmt.Errorf("%w: column %d is negative", ErrInvalidDiagnostic, d.Column)
	}
	if d.EndLine < 0 || d.EndColumn < 0 {
		return fmt.Errorf("%w: end position %d:%d is negative", ErrInvalidDiagnostic, d.EndLine, d.EndColumn)
	}
	// A diagnostic that names no end covers its start only, which is what a caller
	// that does not track ranges produces.
	endLine, endColumn := d.EndLine, d.EndColumn
	if endLine == 0 && endColumn == 0 {
		endLine, endColumn = d.Line, d.Column
	}
	if endLine < d.Line || (endLine == d.Line && endColumn < d.Column) {
		return fmt.Errorf("%w: end position %d:%d precedes the start %d:%d",
			ErrInvalidDiagnostic, endLine, endColumn, d.Line, d.Column)
	}
	if !d.Severity.Valid() {
		return fmt.Errorf("%w: severity %d is not an LSP severity", ErrInvalidDiagnostic, int(d.Severity))
	}
	if d.Message == "" {
		return fmt.Errorf("%w: message is empty for file %q", ErrInvalidDiagnostic, d.FileKey)
	}
	return nil
}

// before reports whether a sorts before b. The first four fields are the order
// Core asks for; the rest only make the order total, so that two diagnostics
// differing in nothing else still come back the same way on every call.
func before(a, b Diagnostic) bool {
	if a.FileKey != b.FileKey {
		return a.FileKey < b.FileKey
	}
	if a.Line != b.Line {
		return a.Line < b.Line
	}
	if a.Column != b.Column {
		return a.Column < b.Column
	}
	if a.Message != b.Message {
		return a.Message < b.Message
	}
	if a.DisplayPath != b.DisplayPath {
		return a.DisplayPath < b.DisplayPath
	}
	if a.Source != b.Source {
		return a.Source < b.Source
	}
	if a.Code != b.Code {
		return a.Code < b.Code
	}
	return a.Severity < b.Severity
}

// Set holds the diagnostics of one workspace.
//
// A file key is present exactly while it holds at least one diagnostic, so the
// set never keeps an empty entry behind.
type Set struct {
	mu    sync.Mutex
	files map[string][]Diagnostic
}

// NewSet returns an empty set.
func NewSet() *Set {
	return &Set{files: make(map[string][]Diagnostic)}
}

// Replace swaps the diagnostics of one file. An empty list clears the file.
//
// The whole batch is checked before anything is stored, so a rejected replace
// leaves the file exactly as it was. The batch is copied, so the caller may
// reuse its slice once the call returns.
func (s *Set) Replace(fileKey string, diagnostics []Diagnostic) error {
	if fileKey == "" {
		return fmt.Errorf("%w: file key is empty", ErrInvalidDiagnostic)
	}
	for i := range diagnostics {
		if err := diagnostics[i].Validate(); err != nil {
			return fmt.Errorf("diagnostic %d of file %q: %w", i, fileKey, err)
		}
		// A diagnostic stored under one file but naming another would be listed
		// under the wrong file, because All orders by the diagnostic's own key.
		if diagnostics[i].FileKey != fileKey {
			return fmt.Errorf("%w: diagnostic %d names file %q but is stored for %q",
				ErrInvalidDiagnostic, i, diagnostics[i].FileKey, fileKey)
		}
	}
	if len(diagnostics) > MaxDiagnosticsPerFile {
		return fmt.Errorf("%w: %d diagnostics for file %q, limit %d", ErrTooMany, len(diagnostics), fileKey, MaxDiagnosticsPerFile)
	}

	stored := make([]Diagnostic, len(diagnostics))
	copy(stored, diagnostics)

	s.mu.Lock()
	defer s.mu.Unlock()

	if len(stored) == 0 {
		delete(s.files, fileKey)
		return nil
	}
	if _, present := s.files[fileKey]; !present && len(s.files) >= MaxFiles {
		return fmt.Errorf("%w: %d files already hold diagnostics, limit %d", ErrTooMany, len(s.files), MaxFiles)
	}
	if s.files == nil {
		s.files = make(map[string][]Diagnostic)
	}
	s.files[fileKey] = stored
	return nil
}

// Clear drops one file's diagnostics. Clearing a file that holds none does
// nothing.
func (s *Set) Clear(fileKey string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.files, fileKey)
}

// ClearAll drops every diagnostic.
func (s *Set) ClearAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.files = make(map[string][]Diagnostic)
}

// All returns every diagnostic in a deterministic order: by file key, then
// line, then column, then message.
//
// The slice is new and holds copies, so a caller may sort or edit it without
// touching the set.
func (s *Set) All() []Diagnostic {
	s.mu.Lock()
	all := make([]Diagnostic, 0, s.totalLocked())
	for _, diagnostics := range s.files {
		all = append(all, diagnostics...)
	}
	s.mu.Unlock()

	sort.Slice(all, func(i, j int) bool { return before(all[i], all[j]) })
	return all
}

// Counts reports how many diagnostics of each severity are stored. A severity
// that holds nothing is absent from the map rather than zero.
func (s *Set) Counts() map[Severity]int {
	s.mu.Lock()
	defer s.mu.Unlock()

	counts := make(map[Severity]int, 4)
	for _, diagnostics := range s.files {
		for _, diagnostic := range diagnostics {
			counts[diagnostic.Severity]++
		}
	}
	return counts
}

// Files returns the file keys that hold diagnostics, sorted.
func (s *Set) Files() []string {
	s.mu.Lock()
	defer s.mu.Unlock()

	files := make([]string, 0, len(s.files))
	for fileKey := range s.files {
		files = append(files, fileKey)
	}
	sort.Strings(files)
	return files
}

// totalLocked counts the stored diagnostics. The caller holds s.mu.
func (s *Set) totalLocked() int {
	total := 0
	for _, diagnostics := range s.files {
		total += len(diagnostics)
	}
	return total
}
