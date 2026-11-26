package logstore

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func collect(t *testing.T, s *Store, q ExportQuery) Export {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	export, err := s.Collect(ctx, q)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	return export
}

// TestCollectGroupsTheRecordsByFile checks an export of the current session: one file under
// logs/ per log file read, holding the kernel's lines, and a status file that says the export
// is complete.
func TestCollectGroupsTheRecordsByFile(t *testing.T) {
	s, _, dir := openStore(t, nil)
	for _, name := range []string{"step_0", "step_1"} {
		action(s, name)
	}
	flush(t, s)

	export := collect(t, s, ExportQuery{Session: "current"})
	if export.Directory != dir || export.Truncated || export.EstimatedBytes == 0 {
		t.Fatalf("export = %+v", export)
	}
	if len(export.Sessions) != 1 || "sessions/"+export.Sessions[0] != s.SessionPath() {
		t.Fatalf("sessions = %v, want the current one, %q", export.Sessions, s.SessionPath())
	}
	if len(export.Files) != 2 {
		t.Fatalf("files = %d, want the app channel's and the status file", len(export.Files))
	}
	logs, status := export.Files[0], export.Files[1]
	if !strings.HasPrefix(logs.RelativePath, "logs/"+s.SessionPath()+"/") {
		t.Fatalf("log file path = %q", logs.RelativePath)
	}
	text := string(logs.Data)
	if !strings.HasSuffix(text, "\n") || !strings.Contains(text, "action=step_0") || !strings.Contains(text, "action=step_1") {
		t.Fatalf("log file = %q", text)
	}
	if strings.Count(text, "app.action.performed") != 2 || strings.Count(text, "app.session.started") != 1 {
		t.Fatalf("log file holds the wrong records: %q", text)
	}
	if status.RelativePath != "collection-status.txt" ||
		string(status.Data) != "truncated=false dropped_events=0 write_failures=0 rejected_events=0 skipped_invalid_lines=0\n" {
		t.Fatalf("status file = %q: %q", status.RelativePath, status.Data)
	}
}

func TestCollectMarksUnreadableSubtreeAsIncomplete(t *testing.T) {
	s, _, root := openStore(t, nil)
	action(s, "still_readable")
	flush(t, s)
	blocked := filepath.Join(root, filepath.FromSlash(s.SessionPath()), "blocked")
	if err := os.Mkdir(blocked, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chmod(blocked, 0o700); err != nil {
			t.Error(err)
		}
	})
	if err := os.Chmod(blocked, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := os.ReadDir(blocked); err == nil {
		t.Skip("filesystem permissions allow reading the test directory")
	} else if !errors.Is(err, fs.ErrPermission) {
		t.Fatal(err)
	}

	export := collect(t, s, ExportQuery{Session: "current"})
	if len(export.Files) != 2 || !strings.Contains(string(export.Files[0].Data), "action=still_readable") {
		t.Fatalf("export lost the readable channel: %+v", export.Files)
	}
	if !export.Truncated || !strings.Contains(string(export.Files[1].Data), "truncated=true") {
		t.Fatalf("incomplete walk reported truncated=%t, status %q", export.Truncated, export.Files[1].Data)
	}
	result := window(t, s, Query{Session: "current"})
	if !result.Truncated || eventCounts(result.Records)["app.action.performed"] != 1 {
		t.Fatalf("query lost the readable event or the incomplete status: %+v", result)
	}
}

// TestCollectAppliesTheWindowFilter checks that an export of the current filter keeps only the
// records the filter keeps, and still has its status file when none are left.
func TestCollectAppliesTheWindowFilter(t *testing.T) {
	s, _, _ := openStore(t, nil)
	action(s, "step_0")
	flush(t, s)

	only := func(q ExportQuery) []ExportFile {
		t.Helper()
		q.Session = "current"
		return collect(t, s, q).Files
	}
	for name, q := range map[string]ExportQuery{
		"levels":     {Levels: []core.LogLevel{core.LevelError}},
		"channel":    {ChannelPrefixes: []string{"lsp"}},
		"expression": {Expression: "event:app.session.started"},
		"range":      {FilterSince: "2027-01-01T00:00:00.000Z"},
	} {
		files := only(q)
		if name == "expression" {
			if len(files) != 2 || strings.Contains(string(files[0].Data), "app.action.performed") {
				t.Fatalf("%s: files = %+v", name, files)
			}
			continue
		}
		if len(files) != 1 || files[0].RelativePath != "collection-status.txt" {
			t.Fatalf("%s: files = %+v, want only the status file", name, files)
		}
	}
	if files := only(ExportQuery{Levels: []core.LogLevel{core.LevelInfo}}); len(files) != 2 {
		t.Fatalf("an export of INFO has %d files", len(files))
	}
}
