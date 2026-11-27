package workbench

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"strings"
	"syscall"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
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
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(errUnsupportedEncoding)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(errTooLarge)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(documentio.ErrNotRegular)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(documentio.ErrSymbolicLink)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrNotExist})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrPermission})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(failure)},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&remoteFileError{reason: errRemoteDisconnected})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&remoteFileError{reason: errRemoteTimedOut, cause: context.DeadlineExceeded})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&remoteFileError{reason: fs.ErrPermission, cause: remoteLogError(&core.Error{Command: "remote.stat", Code: core.CodePermissionDenied, Message: "/home/dev/a.txt"})})},
		{documentFailedLevel, documentEventOpenFailed, documentOpenFields(&remoteFileError{reason: errRemoteFileFailed, cause: errRemoteOutsideFolder})},
		{documentFailedLevel, documentEventSaveFailed, documentSaveFields(3, 0, failure)},
		{documentFailedLevel, documentEventSaveFailed, documentSaveFields(4, 2, &remoteFileError{reason: errRemoteSaveTooLarge, cause: remoteLogError(&core.Error{Command: "remote.writeFile", Code: core.CodeProcessFailed, Details: `{"remoteCode":"TOO_LARGE"}`})})},
		{core.LevelWarn, "editor.document.watch_failed", map[string]any{"stage": "create"}},
		{core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "document_external_change", "reason": "disk_conflict"}},
		{documentFailedLevel, documentEventSaveFailed, documentSaveFields(12, 41, failure)},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "document.discardDeleted", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_list", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("project_tree_list", failure)},
		{core.LevelWarn, "app.settings.decode_failed", storedStateFields("settings", failure)},
		{core.LevelWarn, "app.settings.decode_failed", storedStateFields("directory_rules", failure)},
		{core.LevelWarn, "app.settings.decode_failed", storedStateFields("window_background", failure)},
		{core.LevelWarn, "app.settings.decode_failed", storedStateFields("recent_projects", &fs.PathError{Op: "open", Path: "recent.json", Err: fs.ErrPermission})},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("project_tree_move", "cross_wsl_boundary")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("workspace_exclude", "unreadable_stored_rules")},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("editor_encoding_reopen", errLossyDecode)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("git_branch_name_preview", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("git_commit", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("git_authentication", failure)},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("git_authentication", "answer_refused")},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "git.authentication.answer", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "git.authentication.retry", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "git.authentication.cancel", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_authentication", failure)},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("remote_authentication", "answer_refused")},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.authentication.answer", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.authentication.cancel", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_connections_read", documentLogError(failure))},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_connection_save", documentLogError(failure))},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_connection_remove", documentLogError(failure))},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_choose_identity", documentLogError(failure))},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("remote_probe", errors.New("remote probe: unreachable"))},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("remote_connection_save", "field_refused")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("remote_connection_save", "number_invalid")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("remote_connection_save", "changed_on_disk")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("remote_probe", "field_refused")},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connections.open", "surface": surfaceMenu}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.new", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.select", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.save", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.remove", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.test", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "remote.connection.test.stop", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("settings_save", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_reveal_recent", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("editor_open_in_browser", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_open", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_reduce", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_save", failure)},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.recent.reveal", "surface": surfaceMenu}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.recent.remove", "surface": surfaceMenu}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_cleanup", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_watch", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_watch", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_filter_changes", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("project_tree_watch", errWatchEventsLost)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("project_tree_watch", errWatchEventLimit)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere_page", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere_watch", failure)},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("workspace_search", "invalid_result_path")},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("workspace_search_incremental_update", errWatchEventsLost)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("workspace_search_incremental_update", errWatchEventLimit)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background", documentLogError(errors.New("image: unknown format")))},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background_save", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background_remove", failure)},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.background.open", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.searchEverywhere.open", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "title.debug", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.background.choose", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.background.remove", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "workspace.background.strength", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("update_check", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("update", failure)},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.check", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.update", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.cancel", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.channel", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.source", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.skip", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.show", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.show", "surface": surfaceToolbar}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.show", "surface": surfaceNotification}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.downloads", "surface": surfaceButton}},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "updates.notes", "surface": surfaceButton}},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("open_url", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("update_check", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("update_notes", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("update_snapshot", failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields(updateCleanupOperation, failure)},
		{backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("editor_session_load", documentLogError(failure))},
		{core.LevelWarn, "app.settings.decode_failed", storedStateFields("chrome_layout", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("settings_about_copy", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("settings_open_link", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("editor_preferences", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("keymap_schemes", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_settings_surface", failure)},
		{operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_settings_load", failure)},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("plugin_settings_load", "localization_unreadable")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("plugin_settings_load", "invalid_localization")},
		{operationRejectedLevel, operationRejectedEvent, operationRejectedFields("plugin_settings_load", "invalid_stored_values")},
		{core.LevelInfo, "app.action.performed", map[string]any{"action": "settings.openLink", "surface": surfaceButton}},
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
		{documentio.ErrNotRegular, "not_regular"},
		{documentio.ErrSymbolicLink, "symbolic_link"},
		{&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrNotExist}, "not_found"},
		{&fs.PathError{Op: "open", Path: "a.txt", Err: fs.ErrPermission}, "permission_denied"},
		{errors.New("is a directory"), "read_failed"},
	} {
		if got := documentOpenReason(c.err); got != c.want {
			t.Errorf("documentOpenReason(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}

// Document diagnostics must not put the user's paths into exported logs.
func TestDocumentFailureLogsDoNotContainPaths(t *testing.T) {
	const secretPath = "/private/workspace/document.txt"
	pathError := &os.PathError{Op: "open", Path: secretPath, Err: syscall.EACCES}
	linkError := &os.LinkError{Op: "rename", Old: secretPath, New: secretPath + ".tmp", Err: syscall.EACCES}
	for _, err := range []error{pathError, linkError, errors.Join(pathError, errors.New("sync failed"))} {
		for _, fields := range []map[string]any{documentOpenFields(err), documentSaveFields(1, 3, err)} {
			message, ok := fields["error"].(string)
			if !ok || strings.Contains(message, secretPath) {
				t.Fatalf("document error leaked its path: %v", fields)
			}
			if fields["error_code"] != int(syscall.EACCES) || fields["error_domain"] != "posix" {
				t.Fatalf("document error lost the native error: %v", fields)
			}
		}
	}
}
