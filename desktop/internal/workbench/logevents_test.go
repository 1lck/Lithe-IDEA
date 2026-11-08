package workbench

import (
	"context"
	"errors"
	"io/fs"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// TestLogEventsMatchCatalog encodes the failure events of the editor, the project tree and
// Git, with the levels and the fields the workbench gives them, through the real kernel with
// catalog validation on, as the log store writes them. The store drops an event the catalog
// does not declare, or whose level or fields differ from the declaration, so a mismatch here
// is a failure that never reaches the log.
func TestLogEventsMatchCatalog(t *testing.T) {
	failure := errors.New("disk full")
	cases := []struct {
		level  core.LogLevel
		event  string
		fields map[string]any
	}{
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(errNotText)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(errTooLarge)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrNotExist})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrPermission})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(failure)},
		{documentFailedLevel, documentEventSaveFailed, documentSaveFields(3, 0, failure)},
		{documentFailedLevel, documentEventSaveFailed, documentSaveFields(12, 41, failure)},
		{treeSkippedLevel, treeEventSkipped, treeSkippedFields("", failure)},
		{treeSkippedLevel, treeEventSkipped, treeSkippedFields("src/main", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("git_branch_name_preview", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("git_commit", failure)},
	}
	events := make([]core.LogEvent, len(cases))
	for i, c := range cases {
		events[i] = core.LogEvent{Ts: "2026-11-08T09:30:00.000Z", Level: c.level, Seq: uint64(i + 1), Event: c.event, Fields: c.fields}
	}
	batch, err := core.NewClient().EncodeLogBatch(context.Background(), core.LogBatch{ValidateCatalog: true, Events: events})
	if err != nil {
		t.Fatalf("EncodeLogBatch: %v", err)
	}
	if len(batch.Results) != len(cases) {
		t.Fatalf("EncodeLogBatch returned %d results for %d events", len(batch.Results), len(cases))
	}
	for i, result := range batch.Results {
		if result.Error != nil || result.Line == "" {
			t.Errorf("%s %s %v was rejected: %v", cases[i].level, cases[i].event, cases[i].fields, result.Error)
		}
	}
}

// TestDocumentOpenReason checks the token each kind of open failure is logged with.
func TestDocumentOpenReason(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{
		{errNotText, "not_text"},
		{errTooLarge, "too_large"},
		{&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrNotExist}, "not_found"},
		{&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrPermission}, "permission_denied"},
		{errors.New("is a directory"), "read_failed"},
	} {
		if got := documentOpenReason(c.err); got != c.want {
			t.Errorf("documentOpenReason(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}
