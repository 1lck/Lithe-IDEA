package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// remoteTestReadme is the host file the Project tool window lists as README.md.
const remoteTestReadme = remoteTestHome + "/project/README.md"

// takeFileError is the failure the next request for a host file ends with, once; nil lets it
// through. The lock is held.
func (k *remoteHostKernel) takeFileError(session string) error {
	k.fileSessions = append(k.fileSessions, session)
	err := k.fileErr
	k.fileErr = nil
	return err
}

func (k *remoteHostKernel) RemoteStat(_ context.Context, session, path string) (core.RemoteFileMetadata, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return core.RemoteFileMetadata{}, err
	}
	if kind, ok := k.kinds[path]; ok {
		return core.RemoteFileMetadata{Kind: kind}, nil
	}
	data, ok := k.files[path]
	if !ok {
		return core.RemoteFileMetadata{}, &core.Error{Command: "remote.stat", Code: core.CodeWorkspaceNotFound, Message: "no such file: " + path}
	}
	return core.RemoteFileMetadata{Kind: core.RemoteFileKindFile, Size: uint64(len(data))}, nil
}

func (k *remoteHostKernel) RemoteReadFile(_ context.Context, session, path string) ([]byte, core.RemoteFileVersion, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return nil, core.RemoteFileVersion{}, err
	}
	data, ok := k.files[path]
	if !ok {
		return nil, core.RemoteFileVersion{}, &core.Error{Command: "remote.readFile", Code: core.CodeWorkspaceNotFound, Message: "no such file: " + path}
	}
	return slices.Clone(data), k.versionLocked(path), nil
}

// RemoteWriteFile writes while the file has the expected version, or creates it while it does
// not exist, as the host server does.
func (k *remoteHostKernel) RemoteWriteFile(_ context.Context, session, path string, data []byte, expected *core.RemoteFileVersion, root ...string) (core.RemoteFileVersion, bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return core.RemoteFileVersion{}, false, err
	}
	if len(root) != 1 || root[0] == "" || !strings.HasPrefix(path, root[0]+"/") {
		return core.RemoteFileVersion{}, false, &core.Error{Command: "remote.writeFile", Code: core.CodePermissionDenied, Message: "save must carry its workspace boundary"}
	}
	if err := k.writeErr; err != nil {
		k.writeErr = nil
		return core.RemoteFileVersion{}, false, err
	}
	current, exists := k.files[path]
	switch {
	case expected == nil && exists,
		expected != nil && (!exists || expected.Size != uint64(len(current)) || expected.ModifiedMs == nil || *expected.ModifiedMs != k.modified[path]):
		return core.RemoteFileVersion{}, false, nil
	}
	k.writeLocked(path, data)
	return k.versionLocked(path), true, nil
}

// versionLocked is the version of the host file path. The lock is held.
func (k *remoteHostKernel) versionLocked(path string) core.RemoteFileVersion {
	modified := k.modified[path]
	return core.RemoteFileVersion{Size: uint64(len(k.files[path])), ModifiedMs: &modified}
}

// writeLocked replaces the host file path with data and moves its modification time on. The
// lock is held.
func (k *remoteHostKernel) writeLocked(path string, data []byte) {
	if k.files == nil {
		k.files, k.modified = make(map[string][]byte), make(map[string]int64)
	}
	k.files[path] = slices.Clone(data)
	k.modified[path]++
	k.syncRemoteTreeLocked()
}

// put changes the host file path as someone on the host does.
func (k *remoteHostKernel) put(path, text string) {
	k.set(func(k *remoteHostKernel) { k.writeLocked(path, []byte(text)) })
}

// file is the text of the host file path, and whether it exists.
func (k *remoteHostKernel) file(path string) (string, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	data, ok := k.files[path]
	return string(data), ok
}

// openRemoteFile opens the file name of p's folder and waits for its read to finish; the
// document is nil when the file did not open.
func (h *harness) openRemoteFile(t *testing.T, p *project, name string) *document {
	t.Helper()
	path := filepath.Join(p.root, name)
	h.app.openFile(p, path)
	awaitDocumentState(t, h, func() bool { _, opening := p.docs.opening[path]; return !opening })
	h.settle()
	return p.docs.byPath(path)
}

// typeAtCaret types text into d at its caret.
func typeAtCaret(t *testing.T, d *document, text string) {
	t.Helper()
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: text}); err != nil {
		t.Fatal(err)
	}
}

// saveAndWait saves d and waits for the save and the checks it schedules to finish.
func (h *harness) saveAndWait(t *testing.T, p *project, d *document) {
	t.Helper()
	h.app.saveDocument(p, d.id)
	awaitDocumentState(t, h, func() bool { return !d.saving && !d.checking && !d.checkPending })
	h.settle()
}

// notified reports that a notification says text.
func (h *harness) notified(text string) bool {
	return slices.ContainsFunc(h.app.notifications.list, func(n *notification) bool { return n.text == text })
}

// The editor of a remote workspace opens, saves and compares the host's files over the
// workspace's session, and nothing is read from or written to the placeholder. A save over a file
// changed on the host is refused and shows the conflict, and loading the host's version resolves
// it. Neither the host nor its paths are logged.
func TestRemoteWorkspaceEditsTheHostsFiles(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.put(remoteTestReadme, "# Project\n")
	p := h.openRemoteTestProject(t)

	d := h.openRemoteFile(t, p, "README.md")
	if d == nil {
		t.Fatalf("README.md did not open; notifications %+v", h.app.notifications.list)
	}
	if text, _ := d.view.Text(); string(text) != "# Project\n" {
		t.Fatalf("opened %q, want the host's text", text)
	}
	typeAtCaret(t, d, "local ")
	h.saveAndWait(t, p, d)
	if got, _ := k.file(remoteTestReadme); got != "local # Project\n" || d.dirty() {
		t.Fatalf("host file %q, dirty %v: the save did not reach the host", got, d.dirty())
	}
	if _, err := os.Lstat(d.path); err == nil {
		t.Fatal("the save wrote the file below the placeholder")
	}
	if sessions := k.fileSessions; len(sessions) == 0 || slices.ContainsFunc(sessions, func(s string) bool { return s != "session-1" }) {
		t.Fatalf("the host's files went over sessions %q, want the workspace's", sessions)
	}

	k.put(remoteTestReadme, "changed on the host\n")
	typeAtCaret(t, d, "more ")
	h.saveAndWait(t, p, d)
	if got, _ := k.file(remoteTestReadme); got != "changed on the host\n" {
		t.Fatalf("host file %q: the save overwrote a change made on the host", got)
	}
	if !d.conflicted || !h.notified(h.app.text.Editor.SaveFailed("README.md", i18n.Shared(lang, "editor.externalConflict"))) {
		t.Fatal("the refused save did not show the conflict")
	}
	h.app.loadDocumentDisk(p, d)
	awaitDocumentState(t, h, func() bool { return !d.resolvingConflict })
	h.settle()
	if text, _ := d.view.Text(); string(text) != "changed on the host\n" || d.conflicted || d.dirty() {
		t.Fatalf("text %q, conflicted %v: loading the host's version did not resolve the conflict", text, d.conflicted)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A host file that cannot be read or saved says why in the user's words: it is missing, not a
// regular file, not permitted, larger than the host takes, or the connection closed. A closed
// connection connects again on its own and then compares the documents with the host, so a change
// made on the host meanwhile shows as a conflict. The log keeps only the command and the code.
func TestRemoteDocumentFailuresSayWhy(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.put(remoteTestReadme, "# Project\n")
	k.set(func(k *remoteHostKernel) {
		k.kinds = map[string]core.RemoteFileKind{remoteTestHome + "/project/pipe": core.RemoteFileKindOther}
	})
	p := h.openRemoteTestProject(t)
	r := p.remote
	editor := h.app.text.Editor

	if h.openRemoteFile(t, p, "missing.txt") != nil || !h.notified(editor.OpenFailed("missing.txt", i18n.Shared(lang, "desktop.remote.document.notFound"))) {
		t.Fatal("a missing host file did not say it is gone")
	}
	if h.openRemoteFile(t, p, "pipe") != nil || !h.notified(editor.OpenFailed("pipe", h.app.documentReason(documentio.ErrNotRegular))) {
		t.Fatal("a host path that is not a regular file opened")
	}
	k.set(func(k *remoteHostKernel) {
		k.fileErr = &core.Error{Command: "remote.stat", Code: core.CodePermissionDenied, Message: "permission denied: " + remoteTestReadme}
	})
	if h.openRemoteFile(t, p, "README.md") != nil || !h.notified(editor.OpenFailed("README.md", i18n.Shared(lang, "desktop.remote.document.permissionDenied"))) {
		t.Fatal("a file the host account may not read did not say so")
	}

	d := h.openRemoteFile(t, p, "README.md")
	if d == nil {
		t.Fatal("README.md did not open")
	}
	typeAtCaret(t, d, "local ")
	k.set(func(k *remoteHostKernel) {
		k.writeErr = &core.Error{Command: "remote.writeFile", Code: core.CodeProcessFailed, Message: "too large", Details: `{"remoteCode":"TOO_LARGE"}`}
	})
	h.saveAndWait(t, p, d)
	tooLarge := i18n.SharedFormat(lang, "desktop.remote.document.tooLargeToSave", map[string]string{"limit": "8 MiB"})
	if !d.dirty() || !h.notified(editor.SaveFailed("README.md", tooLarge)) {
		t.Fatal("a save the host refused as too large did not say so with the host's limit")
	}

	// The connection closes during the next save, and the file changes on the host before the
	// workspace connects again.
	k.put(remoteTestReadme, "changed on the host\n")
	k.set(func(k *remoteHostKernel) {
		k.fileErr = &core.Error{Command: "remote.stat", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.app.saveDocument(p, d.id)
	h.fireReconnect(t, timers, r)
	h.await("the new session and the check after it", func() bool {
		return r.session == "session-2" && !r.beating && !d.saving && !d.checking && !d.checkPending
	})
	h.settle()
	if !h.notified(editor.SaveFailed("README.md", i18n.Shared(lang, "desktop.remote.document.disconnected"))) {
		t.Fatal("the save that found the connection closed did not say so")
	}
	if got, _ := k.file(remoteTestReadme); got != "changed on the host\n" || !d.conflicted || !d.dirty() {
		t.Fatalf("host file %q, conflicted %v: the check after reconnecting did not find the host's change", got, d.conflicted)
	}
	if got := countFailures(logger, "remote_session_lost"); got != 1 {
		t.Fatalf("remote_session_lost logged %d times, want once", got)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}
