package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// The editor of a remote workspace reads and writes its files on the host (#2231, R0 step 3).
// A document keeps the placeholder path the Project tool window shows; each read and write
// translates it to the host path (remoteplaceholder.HostPath) and goes over the workspace's
// current session. Nothing is read from or written to the placeholder. A host file outside the
// workspace's folder, which Open File on Host opens (remote_host_files.go), is only read: a save
// or a create of one is refused (S25), and any other path is refused outright.
//
// A read asks the host what the path is first (remote.stat) to reject links and special files
// in the editor. The server also opens nonblocking and checks the opened file's type, so a
// replacement with a named pipe cannot block the read. A save reads the file again, compares
// its bytes with the ones the editor last read or wrote, and sends that read's precise revision.
// The host checks the revision before and after staging, and serializes cooperating saves.
// An external writer that ignores the lock still has a final check-to-rename race. A missing
// file is a conflict; recreating it uses atomic no-replace publication. The workspace root is
// sent with every editor write so the host refuses descendant links. Temporary sibling saves
// leave the old bytes in other hard links.
//
// Core decodes, encodes, recovers and names the language of a file without reading it: those
// are payload-only commands, which the Core client sends without the workspace's binding, so
// they also work while the host is away. A change on the host is found when the host watch
// reports it (remote_watch.go), when a document is saved, before it closes and after the
// connection opens again. A host file opens up to remoteDocumentReadLimit, Core's limit, and
// saves up to remoteDocumentWriteLimit, the most the host takes in one request. Unsaved edits are
// drafts on this computer under the placeholder path, which is the same each time the folder
// opens.
// Core's message of a failure may name a host path, so the log keeps only its command and code.

const (
	// remoteDocumentReadLimit is the largest host file the editor opens: Core reads no more in
	// one request.
	remoteDocumentReadLimit = 16 << 20
	// remoteDocumentWriteLimit is the largest file the editor saves on the host: the host takes
	// no more in one request.
	remoteDocumentWriteLimit = 8 << 20
	// remoteDocumentTimeout bounds one read or write of a host file, which may cross a slow link.
	remoteDocumentTimeout = 2 * time.Minute
)

// These errors explain why a host file could not be read or written, besides the reasons a
// local file has.
var (
	// errRemoteDisconnected: the workspace has no session, or the request found its connection
	// closed.
	errRemoteDisconnected = errors.New("the remote workspace is not connected")
	// errRemoteTimedOut: the host did not answer in time.
	errRemoteTimedOut = errors.New("the host did not answer in time")
	// errRemoteFileFailed: the host could not read or write the file for another reason.
	errRemoteFileFailed = errors.New("the host could not read or write the file")
	// errRemoteOutsideFolder is the cause of a refused path that names no host path.
	errRemoteOutsideFolder = errors.New("the path is outside the remote workspace's folder")
	// errRemoteReadOnly: the file is on the host outside the workspace's folder, which the editor
	// does not write (S25).
	errRemoteReadOnly = errors.New("the host file is outside the remote workspace's folder and opens read-only")
	// errRemoteSaveTooLarge: the file is larger than the host takes in one save
	// (remoteDocumentWriteLimit), which is less than a local file saves.
	errRemoteSaveTooLarge = errors.New("the file is larger than the host takes in one save")
)

// remoteFileError is a failed read or write of a host file. reason is what the editor tells the
// user and matches with errors.Is; cause is the failure as the log keeps it, nil when there is
// nothing more to say.
type remoteFileError struct {
	reason error
	cause  error
}

func (e *remoteFileError) Error() string { return e.reason.Error() }

func (e *remoteFileError) Unwrap() []error {
	if e.cause == nil {
		return []error{e.reason}
	}
	return []error{e.reason, e.cause}
}

// documentBytes reads up to limit bytes of the file of a document at path, which is the
// placeholder path in a remote workspace. A file larger than limit is errTooLarge.
type documentBytes func(ctx context.Context, path string, limit int64) ([]byte, error)

// localDocumentBytes reads a document's file on this computer.
func localDocumentBytes(_ context.Context, path string, limit int64) ([]byte, error) {
	return documentio.ReadFileLimit(path, limit)
}

// documentBytesOf is where the documents of p are read from: the host of a remote workspace, or
// this computer. It runs on the window thread; what it returns runs on any.
func (a *App) documentBytesOf(p *project) documentBytes {
	if r := a.remoteDocuments(p); r != nil {
		return r.read
	}
	return localDocumentBytes
}

// documentTextOf is how a check of the documents of p reads a file as editor text: a.documentReader
// on this computer, which tests replace, or the host's bytes classified the same way. It runs on
// the window thread; what it returns runs on any.
func (a *App) documentTextOf(p *project) func(context.Context, string) ([]byte, error) {
	if r := a.remoteDocuments(p); r != nil {
		return func(ctx context.Context, path string) ([]byte, error) {
			return classifiedDocument(r.read(ctx, path, remoteDocumentReadLimit))
		}
	}
	read := a.documentReader
	return func(_ context.Context, path string) ([]byte, error) { return read(path) }
}

// documentRawOf is how a check of the documents of p reads the bytes of a file that is not plain
// UTF-8. It runs on the window thread; what it returns runs on any.
func (a *App) documentRawOf(p *project) func(context.Context, string) ([]byte, error) {
	read := a.documentBytesOf(p)
	return func(ctx context.Context, path string) ([]byte, error) { return read(ctx, path, rawDocumentLimit) }
}

// remoteDocuments reads and writes the files of a remote workspace's documents on its host.
type remoteDocuments struct {
	kernel  Kernel
	binding *core.RemoteWorkspace
	// lost reports that a request found the connection of a session closed. Core reports only
	// the requests that carry the binding, and these name their session themselves.
	lost func(session string)
}

// remoteDocuments is how the documents of p reach its host, nil for a local project.
func (a *App) remoteDocuments(p *project) *remoteDocuments {
	if p == nil || p.remote == nil {
		return nil
	}
	return &remoteDocuments{kernel: a.kernel, binding: p.remote.binding, lost: a.remoteSessionLost(p)}
}

// read returns the bytes of the host file of local, a path below the workspace's placeholder.
// A file larger than limit, or than Core reads, is errTooLarge.
func (r *remoteDocuments) read(ctx context.Context, local string, limit int64) ([]byte, error) {
	host, session, _, err := r.target(local)
	if err != nil {
		return nil, err
	}
	data, _, err := r.readHost(ctx, session, host, limit)
	return data, err
}

// save replaces the host file of local with data while it still holds expected, the bytes the
// editor last read or wrote. A file that changed or no longer exists is documentio.ErrConflict,
// and so is one that changes between the comparison and the write.
func (r *remoteDocuments) save(ctx context.Context, local string, data, expected []byte) error {
	if len(data) > remoteDocumentWriteLimit {
		return &remoteFileError{reason: errRemoteSaveTooLarge}
	}
	host, session, err := r.writable(local)
	if err != nil {
		return err
	}
	current, version, err := r.readHost(ctx, session, host, remoteDocumentReadLimit)
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, errTooLarge):
		// The expected bytes were read, so a file too large to read holds others.
		return documentio.ErrConflict
	case err != nil:
		return err
	case !bytes.Equal(current, expected):
		return documentio.ErrConflict
	}
	return r.write(ctx, session, host, data, &version)
}

// create writes data as the host file of local, which must not exist: one that exists again is
// documentio.ErrConflict.
func (r *remoteDocuments) create(ctx context.Context, local string, data []byte) error {
	if len(data) > remoteDocumentWriteLimit {
		return &remoteFileError{reason: errRemoteSaveTooLarge}
	}
	host, session, err := r.writable(local)
	if err != nil {
		return err
	}
	return r.write(ctx, session, host, data, nil)
}

// target is the host path of local and the session to reach it over; outside says the path is
// outside the workspace's folder.
func (r *remoteDocuments) target(local string) (host, session string, outside bool, err error) {
	root := r.binding.LocalRoot()
	host, ok := remoteplaceholder.HostPath(root, r.binding.RemoteRoot(), local)
	if !ok {
		return "", "", false, &remoteFileError{reason: errRemoteFileFailed, cause: errRemoteOutsideFolder}
	}
	if session = r.binding.SessionID(); session == "" {
		return "", "", false, &remoteFileError{reason: errRemoteDisconnected}
	}
	return host, session, remoteplaceholder.Outside(root, local), nil
}

// writable is target for a write, which only a path in the workspace's folder takes.
func (r *remoteDocuments) writable(local string) (host, session string, err error) {
	host, session, outside, err := r.target(local)
	if err == nil && outside {
		return "", "", &remoteFileError{reason: errRemoteReadOnly}
	}
	return host, session, err
}

// readHost reads the host file host over session and returns the version its bytes were read at.
func (r *remoteDocuments) readHost(ctx context.Context, session, host string, limit int64) ([]byte, core.RemoteFileVersion, error) {
	limit = min(limit, remoteDocumentReadLimit)
	ctx, cancel := context.WithTimeout(ctx, remoteDocumentTimeout)
	defer cancel()
	metadata, err := r.kernel.RemoteStat(ctx, session, host)
	if err != nil {
		return nil, core.RemoteFileVersion{}, r.failed(session, err)
	}
	switch {
	case metadata.Kind == core.RemoteFileKindSymlink:
		return nil, core.RemoteFileVersion{}, documentio.ErrSymbolicLink
	case metadata.Kind != core.RemoteFileKindFile:
		return nil, core.RemoteFileVersion{}, documentio.ErrNotRegular
	case limit < 0 || metadata.Size > uint64(limit):
		return nil, core.RemoteFileVersion{}, errTooLarge
	}
	data, version, err := r.kernel.RemoteReadFile(ctx, session, host)
	if err != nil {
		return nil, core.RemoteFileVersion{}, r.failed(session, err)
	}
	if int64(len(data)) > limit {
		// The file grew after it was described.
		return nil, core.RemoteFileVersion{}, errTooLarge
	}
	return data, version, nil
}

// write replaces the host file host with data over session while it has expected, or creates it
// while it does not exist when expected is nil.
func (r *remoteDocuments) write(ctx context.Context, session, host string, data []byte, expected *core.RemoteFileVersion) error {
	ctx, cancel := context.WithTimeout(ctx, remoteDocumentTimeout)
	defer cancel()
	_, saved, err := r.kernel.RemoteWriteFile(ctx, session, host, data, expected, r.binding.RemoteRoot())
	if err != nil {
		if failure := r.failed(session, err); !errors.Is(failure, errTooLarge) {
			return failure
		}
		// The host refused this many bytes: the save says so with the host's limit, not with
		// the open's reason or a local file's limit.
		return &remoteFileError{reason: errRemoteSaveTooLarge, cause: remoteLogError(err)}
	}
	if !saved {
		return documentio.ErrConflict
	}
	return nil
}

// failed is err, a failed request over session, as the editor handles it. A closed connection is
// reported lost, so the workspace connects again.
func (r *remoteDocuments) failed(session string, err error) error {
	var coreErr *core.Error
	if !errors.As(err, &coreErr) {
		if errors.Is(err, context.DeadlineExceeded) {
			return &remoteFileError{reason: errRemoteTimedOut, cause: err}
		}
		return &remoteFileError{reason: errRemoteFileFailed, cause: documentLogError(err)}
	}
	reason := errRemoteFileFailed
	switch coreErr.Code {
	case core.CodeConnectionClosed:
		if r.lost != nil {
			r.lost(session)
		}
		reason = errRemoteDisconnected
	case core.CodeWorkspaceNotFound:
		reason = fs.ErrNotExist
	case core.CodePermissionDenied:
		reason = fs.ErrPermission
	case core.CodeTimedOut:
		reason = errRemoteTimedOut
	case core.CodeCancelled:
		reason = context.Canceled
	case core.CodeNotSupported:
		if coreErr.Command == "remote.readFile" {
			// Core reads no larger file in one request.
			reason = errTooLarge
		}
	case core.CodeProcessFailed:
		switch remoteFailureCode(coreErr) {
		case "TOO_LARGE":
			reason = errTooLarge
		case "ALREADY_EXISTS":
			reason = fs.ErrExist
		}
	}
	return &remoteFileError{reason: reason, cause: remoteLogError(err)}
}

// remoteFailureCode is the host's own code of a failed request, "" when Core gave none.
func remoteFailureCode(err *core.Error) string {
	var details struct {
		RemoteCode string `json:"remoteCode"`
	}
	if json.Unmarshal([]byte(err.Details), &details) != nil {
		return ""
	}
	return details.RemoteCode
}

// remoteDocumentReason is the words for err when a host file could not be read or written for a
// reason only a remote workspace has, or that the system would name in a local one. ok is false
// for the editor's own reasons, which read the same for both.
func (a *App) remoteDocumentReason(err error) (string, bool) {
	var remoteErr *remoteFileError
	if !errors.As(err, &remoteErr) {
		return "", false
	}
	lang := a.language()
	switch {
	case errors.Is(remoteErr.reason, errRemoteDisconnected):
		return i18n.Shared(lang, "desktop.remote.document.disconnected"), true
	case errors.Is(remoteErr.reason, errRemoteTimedOut):
		return i18n.Shared(lang, "desktop.remote.document.timedOut"), true
	case errors.Is(remoteErr.reason, fs.ErrNotExist):
		return i18n.Shared(lang, "desktop.remote.document.notFound"), true
	case errors.Is(remoteErr.reason, fs.ErrPermission):
		return i18n.Shared(lang, "desktop.remote.document.permissionDenied"), true
	case errors.Is(remoteErr.reason, errTooLarge):
		return a.text.Editor.TooLarge, true
	case errors.Is(remoteErr.reason, errRemoteReadOnly):
		return i18n.Shared(lang, "desktop.remote.document.readOnly"), true
	case errors.Is(remoteErr.reason, errRemoteSaveTooLarge):
		limit := strconv.Itoa(remoteDocumentWriteLimit>>20) + " MiB"
		return i18n.SharedFormat(lang, "desktop.remote.document.tooLargeToSave", map[string]string{"limit": limit}), true
	}
	return i18n.Shared(lang, "desktop.remote.document.failed"), true
}
