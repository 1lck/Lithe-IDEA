package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
)

// Remote development sessions: the connections Core keeps open to a host after remote.connect,
// the requests that address one by its session id, and the remote workspace a context binds its
// requests to (design R0, S16, S17). Core owns the OpenSSH process tree of each session and ends
// it on remote.disconnect, remote.closeAll or its own exit.

// RemoteServerBuild is one remote server build the application ships: the Rust target it runs
// on, the absolute path of the read-only file, and the SHA-256 the application's manifest names
// for it. Core checks the bytes it sends against SHA256, never against a hash of the file.
type RemoteServerBuild struct {
	Target string `json:"target"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// RemoteConnectRequest opens a session to the host of Connection, installing the server build
// for the host's platform when the host does not already run that exact build.
type RemoteConnectRequest struct {
	Connection SSHConnection `json:"connection"`
	// Servers are the builds the application ships; Core picks the one for the host.
	Servers []RemoteServerBuild `json:"servers"`
	// ServerVersion is the version of the shipped builds.
	ServerVersion string `json:"serverVersion"`
	// InstallRoot is where the host keeps installed servers; empty is $HOME/.lithe-server.
	InstallRoot string `json:"installRoot,omitempty"`
}

// RemoteSession is a session remote.connect opened.
type RemoteSession struct {
	// ID names the session in every later request.
	ID string `json:"id"`
	// Uploaded says whether this connection sent the server to the host.
	Uploaded bool `json:"uploaded"`
	// HostName is the host's own name, for display.
	HostName string `json:"hostName"`
	// UserName is the account the server runs as, empty when unknown.
	UserName string `json:"userName"`
	// HomeDirectory is that account's home directory, empty when unknown.
	HomeDirectory string `json:"homeDirectory"`
}

// RemoteConnectResult is the outcome of remote.connect. Session is set only when Status is
// RemoteProbeConnected; the other statuses mean the same as for a probe.
type RemoteConnectResult struct {
	Status  RemoteProbeStatus `json:"status"`
	Session *RemoteSession    `json:"session"`
	Host    *RemoteProbedHost `json:"host"`
	// Diagnostics is the redacted end of OpenSSH's standard error. It is upstream text, shown
	// as it is, and may still name the host, so it is never logged.
	Diagnostics string `json:"diagnostics"`
}

// RemoteConnect opens a session as request asks. Questions OpenSSH asks reach the prompt
// WithGitAuthentication put in ctx, as for RemoteProbe. Core bounds an attempt, answers
// included, to five minutes. Failures are CodeInvalidRequest before OpenSSH starts,
// CodeRuntimeMissing without ssh, CodeRemoteServerInvalid when the build cannot be read or
// differs from its SHA-256, and the context's error when ctx ends. A session whose events could
// not all be observed is closed again and the observation failure returned: the user may not
// have seen every question it asked.
func (c *Client) RemoteConnect(ctx context.Context, request RemoteConnectRequest) (RemoteConnectResult, error) {
	request.Servers = nonNil(request.Servers)
	var result RemoteConnectResult
	observationErr, err := c.executeRemoteWithPrompts(ctx, "remote.connect", request, &result)
	if err != nil {
		return RemoteConnectResult{}, err
	}
	if observationErr != nil {
		if result.Session != nil {
			_, _ = c.RemoteDisconnect(context.Background(), result.Session.ID)
		}
		return RemoteConnectResult{}, observationErr
	}
	return result, nil
}

// RemoteStageName is a step remote.connect reports while it connects. Stages only move forward.
type RemoteStageName string

const (
	// RemoteStageAuthenticated means the host's shell printed its first line.
	RemoteStageAuthenticated RemoteStageName = "authenticated"
	// RemoteStagePlatformChecked means the shell reported the host's platform.
	RemoteStagePlatformChecked RemoteStageName = "platformChecked"
	// RemoteStageUploading reports the server upload: once when it starts and every 256 KiB.
	RemoteStageUploading RemoteStageName = "uploading"
	// RemoteStageInstalled means the server is in place; Uploaded says whether it was sent.
	RemoteStageInstalled RemoteStageName = "installed"
)

// RemoteStage is one remoteStage event of remote.connect.
type RemoteStage struct {
	Stage      RemoteStageName `json:"stage"`
	SentBytes  uint64          `json:"sentBytes"`
	TotalBytes uint64          `json:"totalBytes"`
	Uploaded   bool            `json:"uploaded"`
}

type remoteStagesKey struct{}

// WithRemoteStages returns a context whose RemoteConnect hands each stage to observe. observe runs
// on the request's goroutine and must return promptly, posting the stage to the UI thread.
func WithRemoteStages(ctx context.Context, observe func(RemoteStage)) context.Context {
	return context.WithValue(ctx, remoteStagesKey{}, observe)
}

// remoteStageEvent is the execution event of a connection step.
var remoteStageEvent = []byte(`"remoteStage"`)

// remoteStageObserver hands each remoteStage event to the observer WithRemoteStages put in ctx;
// nil when ctx has none.
func remoteStageObserver(ctx context.Context) func(json.RawMessage) {
	observe, _ := ctx.Value(remoteStagesKey{}).(func(RemoteStage))
	if observe == nil {
		return nil
	}
	return func(raw json.RawMessage) {
		// Only the few lines naming the event are decoded.
		if !bytes.Contains(raw, remoteStageEvent) {
			return
		}
		var event struct {
			Type string `json:"type"`
			RemoteStage
		}
		if json.Unmarshal(raw, &event) == nil && event.Type == "remoteStage" && event.Stage != "" {
			observe(event.RemoteStage)
		}
	}
}

// executeRemoteWithPrompts runs a remote request whose OpenSSH questions reach the prompt
// WithGitAuthentication put in ctx as challenges with Remote set, and whose stages reach the
// observer WithRemoteStages put there. Without a prompt each question is cancelled at once.
func (c *Client) executeRemoteWithPrompts(ctx context.Context, command string, payload, result any) (observationErr, err error) {
	prompt, _ := ctx.Value(gitAuthenticationKey{}).(func(GitAuthChallenge))
	if prompt == nil {
		prompt = func(challenge GitAuthChallenge) {
			// The answer must not wait on the request's goroutine, which delivers the event.
			go func() { _, _ = c.RemoteAuthRespond(context.Background(), challenge.RequestID, nil) }()
		}
	}
	returned := make(chan struct{})
	defer close(returned)
	observer := gitAuthenticationObserver(func(challenge GitAuthChallenge) {
		challenge.Remote = true
		prompt(challenge)
	}, returned, remoteStageObserver(ctx))
	return c.ExecuteWithEvents(ctx, command, payload, result, observer)
}

// RemoteDisconnect ends the session sessionID and its OpenSSH process tree. closed is false when
// Core no longer knew the session.
func (c *Client) RemoteDisconnect(ctx context.Context, sessionID string) (closed bool, err error) {
	var result struct {
		Closed bool `json:"closed"`
	}
	err = c.Execute(ctx, "remote.disconnect", struct {
		SessionID string `json:"sessionId"`
	}{sessionID}, &result)
	return result.Closed, err
}

// RemoteCloseAll ends every session Core keeps open and returns how many it closed. The
// application calls it once, while quitting: exiting without it can leave OpenSSH and the remote
// server running. Afterwards Core refuses every remote.connect of the process with
// CodeCancelled, so closing a window or a project must use RemoteDisconnect instead.
func (c *Client) RemoteCloseAll(ctx context.Context) (closed int, err error) {
	var result struct {
		Closed int `json:"closed"`
	}
	err = c.Execute(ctx, "remote.closeAll", nil, &result)
	return result.Closed, err
}

// RemoteFileKind is the kind of a host entry itself; links are never followed.
type RemoteFileKind string

const (
	RemoteFileKindFile      RemoteFileKind = "file"
	RemoteFileKindDirectory RemoteFileKind = "directory"
	RemoteFileKindSymlink   RemoteFileKind = "symlink"
	// RemoteFileKindOther is a socket, a device or a FIFO.
	RemoteFileKindOther RemoteFileKind = "other"
)

// RemoteFileMetadata is the metadata of a host path itself.
type RemoteFileMetadata struct {
	Kind RemoteFileKind `json:"kind"`
	// Size is in bytes; for a link, the length of its target text.
	Size uint64 `json:"size"`
	// ModifiedMs is milliseconds since the Unix epoch, nil when the host did not report it.
	ModifiedMs *int64 `json:"modifiedMs"`
	// Readonly is true when no write permission bit is set.
	Readonly bool `json:"readonly"`
	// Mode is the permission bits.
	Mode uint32 `json:"mode"`
	// SymlinkTarget is a link's target as stored, when it is valid UTF-8.
	SymlinkTarget string `json:"symlinkTarget,omitempty"`
	// SymlinkTargetKind is the kind of what a link resolves to; empty for a dangling link.
	SymlinkTargetKind RemoteFileKind `json:"symlinkTargetKind,omitempty"`
}

// IsDirectory reports whether the entry is a directory or a link that resolves to one.
func (m RemoteFileMetadata) IsDirectory() bool {
	return m.Kind == RemoteFileKindDirectory ||
		(m.Kind == RemoteFileKindSymlink && m.SymlinkTargetKind == RemoteFileKindDirectory)
}

// RemoteDirectoryEntry is one entry of a host directory.
type RemoteDirectoryEntry struct {
	Name     string             `json:"name"`
	Metadata RemoteFileMetadata `json:"metadata"`
}

// RemoteDirectory is a host directory's listing.
type RemoteDirectory struct {
	// Entries are sorted by the byte order of Name.
	Entries []RemoteDirectoryEntry `json:"entries"`
	// SkippedNonUTF8 counts the entries whose names are not UTF-8; the protocol cannot name them.
	SkippedNonUTF8 uint32 `json:"skippedNonUtf8"`
}

// RemoteReadDir lists the absolute host directory path over the session sessionID. A broken or
// unknown session fails with CodeConnectionClosed, a missing path with CodeWorkspaceNotFound
// and a denied one with CodePermissionDenied.
func (c *Client) RemoteReadDir(ctx context.Context, sessionID, path string) (RemoteDirectory, error) {
	var result RemoteDirectory
	err := c.Execute(ctx, "remote.readDir", struct {
		SessionID string `json:"sessionId"`
		Path      string `json:"path"`
	}{sessionID, path}, &result)
	return result, err
}

// RemoteStat is the metadata of the absolute host path itself over the session sessionID; a
// link is described, not followed. It fails like RemoteReadDir.
func (c *Client) RemoteStat(ctx context.Context, sessionID, path string) (RemoteFileMetadata, error) {
	var result RemoteFileMetadata
	err := c.RemoteHostRequest(ctx, sessionID, "fs.stat", struct {
		Path string `json:"path"`
	}{path}, &result)
	return result, err
}

// RemoteFileVersion identifies the content of a host file as it was read or saved; a guarded
// write is refused when the file no longer has it.
type RemoteFileVersion struct {
	Size uint64 `json:"size"`
	// ModifiedMs is milliseconds since the Unix epoch, nil when the host did not report it.
	ModifiedMs *int64 `json:"modifiedMs"`
}

// RemoteReadFile reads the whole host file path over the session sessionID and returns its
// bytes and the version they were read at. A file larger than Core opens for editing fails with
// CodeNotSupported; otherwise it fails like RemoteReadDir. path must name a regular file or a
// link to one: the host server opens the path before it checks what it is, so the caller checks
// with RemoteStat first.
func (c *Client) RemoteReadFile(ctx context.Context, sessionID, path string) ([]byte, RemoteFileVersion, error) {
	var result struct {
		Data []byte `json:"data"`
		RemoteFileVersion
	}
	err := c.Execute(ctx, "remote.readFile", struct {
		SessionID string `json:"sessionId"`
		Path      string `json:"path"`
	}{sessionID, path}, &result)
	if err != nil {
		return nil, RemoteFileVersion{}, err
	}
	return result.Data, result.RemoteFileVersion, nil
}

// RemoteWriteFile replaces the host file path over the session sessionID with data, atomically
// through a temporary sibling and through a link. With expected, a file that no longer has that
// version is left alone; without it, the file must not exist yet. saved is false for either
// refusal, and the version is the saved content's otherwise. Content larger than the host
// accepts in one request fails with CodeProcessFailed.
func (c *Client) RemoteWriteFile(ctx context.Context, sessionID, path string, data []byte, expected *RemoteFileVersion) (version RemoteFileVersion, saved bool, err error) {
	var result struct {
		Status string `json:"status"`
		RemoteFileVersion
	}
	err = c.Execute(ctx, "remote.writeFile", struct {
		SessionID string             `json:"sessionId"`
		Path      string             `json:"path"`
		Data      []byte             `json:"data"`
		Expected  *RemoteFileVersion `json:"expected,omitempty"`
	}{sessionID, path, data, expected}, &result)
	if err != nil {
		return RemoteFileVersion{}, false, err
	}
	if result.Status != "saved" {
		return RemoteFileVersion{}, false, nil
	}
	return result.RemoteFileVersion, true, nil
}

// RemoteHostRequest performs the finite host method with params over the session sessionID and
// decodes its result into result, which may be nil. Core accepts the filesystem, environment
// and port queries, server.state and the controls of existing processes and terminals; a
// method that would create a resource is CodeInvalidRequest. A broken or unknown session fails
// with CodeConnectionClosed.
func (c *Client) RemoteHostRequest(ctx context.Context, sessionID, method string, params, result any) error {
	if params == nil {
		params = struct{}{}
	}
	return c.Execute(ctx, "remote.hostRequest", struct {
		SessionID string `json:"sessionId"`
		Method    string `json:"method"`
		Params    any    `json:"params"`
	}{sessionID, method, params}, result)
}

// RemoteServerState asks the server of sessionID what still runs; the connection's heartbeat
// uses it, since it is the cheapest request that reaches the server.
func (c *Client) RemoteServerState(ctx context.Context, sessionID string) error {
	var ignored json.RawMessage
	return c.RemoteHostRequest(ctx, sessionID, "server.state", nil, &ignored)
}

// RemoteWorkspace binds the requests of a context (WithRemoteWorkspace) to a folder on a
// connected host. LocalRoot is the placeholder the window shows as the project's root and
// RemoteRoot the host folder it stands for; Core translates every schema-owned path between
// them and never reads or writes the placeholder. The session is swapped as the connection is
// lost and opened again, and is safe to change from any goroutine.
type RemoteWorkspace struct {
	localRoot  string
	remoteRoot string
	session    atomic.Pointer[string]
	lost       func(sessionID string)
}

// NewRemoteWorkspace returns a binding of localRoot to the host folder remoteRoot with no
// session yet. lost, when not nil, runs on the request's goroutine the first time a request of
// the current session fails with CodeConnectionClosed; the session is then already detached.
func NewRemoteWorkspace(localRoot, remoteRoot string, lost func(sessionID string)) *RemoteWorkspace {
	return &RemoteWorkspace{localRoot: localRoot, remoteRoot: remoteRoot, lost: lost}
}

// LocalRoot is the placeholder folder of the binding.
func (w *RemoteWorkspace) LocalRoot() string { return w.localRoot }

// RemoteRoot is the host folder of the binding.
func (w *RemoteWorkspace) RemoteRoot() string { return w.remoteRoot }

// Attach makes sessionID the session the binding's requests go over.
func (w *RemoteWorkspace) Attach(sessionID string) { w.session.Store(&sessionID) }

// Detach leaves the binding without a session and returns the one it had, empty for none.
func (w *RemoteWorkspace) Detach() string {
	if previous := w.session.Swap(nil); previous != nil {
		return *previous
	}
	return ""
}

// SessionID is the session the binding's requests go over, empty while it has none.
func (w *RemoteWorkspace) SessionID() string {
	if current := w.session.Load(); current != nil {
		return *current
	}
	return ""
}

type remoteWorkspaceKey struct{}

// WithRemoteWorkspace returns a context whose requests run on the host of binding. Every
// request of the context carries the binding except the remote.* commands, which name their
// session themselves, and the payload-only commands (payloadOnlyCommands); Core refuses a
// command that has no remote adapter with CodeNotSupported, so nothing of the context falls
// back to the local placeholder. While the binding has no session a request fails at once with
// CodeConnectionClosed and Core never sees it.
func WithRemoteWorkspace(ctx context.Context, binding *RemoteWorkspace) context.Context {
	if binding == nil {
		return ctx
	}
	return context.WithValue(ctx, remoteWorkspaceKey{}, binding)
}

// payloadOnlyCommands are the commands an open document or the Project tool window sends that
// compute only from their payload: Core's handler reads no file, starts no process and names no
// workspace path, so the answer is the same on any computer. They go without the remote
// workspace, which Core would refuse for want of an adapter, and keep working while the host is
// disconnected, so the user can still type, decode the bytes the host returned and plan the save
// that will then fail. workspace.filterChanges drops the host watch's changes in folders Core
// hides, by name alone.
//
// Add a command here only after reading its Core handler; a command that touches the workspace
// sent without the binding would read the empty placeholder instead of the host.
var payloadOnlyCommands = map[string]bool{
	"document.lifecycle":              true,
	"document.planSaveBatch":          true,
	"document.reduceSaveBatch":        true,
	"editor.lineEdit":                 true,
	"editor.navigationHistory.reduce": true,
	"editor.parseNavigationInput":     true,
	"editor.recent.reduce":            true,
	"editor.recovery.decide":          true,
	"languages.matchFirstLine":        true,
	"markdown.outline":                true,
	"text.decode":                     true,
	"text.encode":                     true,
	"workspace.filterChanges":         true,
}

// RemoteWorkspaceOf is the binding WithRemoteWorkspace put in ctx, nil for a local context.
func RemoteWorkspaceOf(ctx context.Context) *RemoteWorkspace {
	binding, _ := ctx.Value(remoteWorkspaceKey{}).(*RemoteWorkspace)
	return binding
}

// remoteWorkspace is the request's remote workspace on the wire (Workspace in the Rust
// protocol).
type remoteWorkspace struct {
	SessionID  string `json:"sessionId"`
	LocalRoot  string `json:"localRoot"`
	RemoteRoot string `json:"remoteRoot"`
}

// remoteWorkspaceRequest is what a request of ctx sends as its remote workspace: nil for a
// local context, a remote.* command and a payload-only command, the binding's session and roots
// otherwise. session is the pointer the request read, so a later loss detaches only that
// session.
func remoteWorkspaceRequest(ctx context.Context, command string) (wire *remoteWorkspace, binding *RemoteWorkspace, session *string, err error) {
	binding = RemoteWorkspaceOf(ctx)
	if binding == nil || isRemoteSessionCommand(command) || payloadOnlyCommands[command] {
		return nil, nil, nil, nil
	}
	session = binding.session.Load()
	if session == nil {
		return nil, nil, nil, &Error{
			Command: command,
			Code:    CodeConnectionClosed,
			Message: "the remote workspace is not connected",
		}
	}
	return &remoteWorkspace{SessionID: *session, LocalRoot: binding.localRoot, RemoteRoot: binding.remoteRoot}, binding, session, nil
}

// isRemoteSessionCommand reports whether command addresses a session by its id rather than
// through the request's remote workspace.
func isRemoteSessionCommand(command string) bool {
	return strings.HasPrefix(command, "remote.")
}

// remoteWorkspaceAnswered detaches session from binding when the request failed because its
// connection closed, and tells the binding's owner once.
func remoteWorkspaceAnswered(binding *RemoteWorkspace, session *string, err error) {
	if binding == nil || session == nil {
		return
	}
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		return
	}
	if binding.session.CompareAndSwap(session, nil) && binding.lost != nil {
		binding.lost(*session)
	}
}
