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

// RemoteConnectRequest opens a session to the host of Connection, to the local WSL distribution
// WSL names, or to the running container Container names, installing the server build for the
// host's platform when the host does not already run that exact build. At most one of Connection
// and WSL is set; without either, Container is a container on this machine. Core refuses a
// request that names none of the three, or both Connection and WSL, as CodeInvalidRequest, before
// anything starts.
type RemoteConnectRequest struct {
	Connection SSHConnection `json:"connection,omitzero"`
	// WSL opens a distribution of the Windows Subsystem for Linux through the system's wsl.exe
	// instead of OpenSSH. Core asks nothing of the user for it: there is no AskPass.
	WSL *WSLConnection `json:"wsl,omitempty"`
	// Container enters a running Docker or Podman container through its engine's exec: on the
	// host Connection or WSL names, or, on its own, on this machine, where Core starts the engine
	// CLI in place of OpenSSH and asks nothing. Core never starts, creates or changes it.
	Container *ContainerConnection `json:"container,omitempty"`
	// Servers are the builds the application ships; Core picks the one for the host.
	Servers []RemoteServerBuild `json:"servers"`
	// ServerVersion is the version of the shipped builds.
	ServerVersion string `json:"serverVersion"`
	// InstallRoot is where the host keeps installed servers; empty is $HOME/.lithe-server.
	InstallRoot string `json:"installRoot,omitempty"`
	// Preferences is the remote workspace preference document, or nil. It names the SSH program;
	// a WSL connection or a container on this machine ignores it.
	Preferences *string `json:"preferences,omitempty"`
	// Resume attaches to the host session an earlier connection kept; nil starts a new session.
	// Core refuses a malformed key or token as CodeInvalidRequest naming resume in
	// RemoteConnectionFieldError, before anything starts, and connects once more without it when
	// the host refuses the token.
	Resume *RemoteResume `json:"resume,omitempty"`
}

// RemoteResume names a host session an earlier connection kept, with the values its RemoteSession
// returned. Token is a secret: it is stored like a password and never logged.
type RemoteResume struct {
	Key     string `json:"key"`
	Token   string `json:"token"`
	Binding string `json:"binding,omitempty"`
}

// WSLConnection is a distribution of the Windows Subsystem for Linux on this machine, as
// remote.connect's wsl field names it. Core trims both fields; an empty User is the
// distribution's default user. Core refuses a malformed field by name ("distribution" or "user")
// with the reasons required, tooLong and invalid, read by RemoteConnectionFieldError.
type WSLConnection struct {
	// Distribution is the name wsl.exe --list prints, such as Ubuntu-24.04.
	Distribution string `json:"distribution"`
	// User is the Linux account, passed as wsl.exe --user.
	User string `json:"user,omitempty"`
}

// Identity is the connection as Core names it in the trust records and the recent projects:
// wsl:distribution, or wsl:user@distribution.
func (c WSLConnection) Identity() string {
	distribution, user := strings.TrimSpace(c.Distribution), strings.TrimSpace(c.User)
	if user == "" {
		return "wsl:" + distribution
	}
	return "wsl:" + user + "@" + distribution
}

// Container engines whose CLI remote.connect and remote.listContainers run.
const (
	ContainerEngineDocker = "docker"
	ContainerEnginePodman = "podman"
)

// ContainerConnection is a running container, as remote.connect's container field names it.
// Core trims Container and User; an empty User is the image's default user. Core refuses a
// malformed field by name ("container" or "user") with the reasons required and invalid, read by
// RemoteConnectionFieldError.
type ContainerConnection struct {
	Context string `json:"context,omitempty"`
	// Engine is ContainerEngineDocker or ContainerEnginePodman.
	Engine string `json:"engine"`
	// Container is the container's name or id, as remote.listContainers lists it.
	Container string `json:"container"`
	// User is the user, uid or user:group inside the container, passed as exec --user.
	User string `json:"user,omitempty"`
}

// Identity is the container as the window and the recent projects name it:
// engine:container, or engine:user@container, the form RemoteWorkspaceTrustTarget.Place uses.
func (c ContainerConnection) Identity() string {
	container, user := strings.TrimSpace(c.Container), strings.TrimSpace(c.User)
	engine := c.Engine
	if c.Context != "" {
		engine += "[" + c.Context + "]"
	}
	if user == "" {
		return engine + ":" + container
	}
	return engine + ":" + user + "@" + container
}

// RemoteContainer is a running container remote.listContainers found.
type RemoteContainer struct {
	// ID is the container's full id.
	ID string `json:"id"`
	// Name is the first of the container's names.
	Name string `json:"name"`
	// Image and Status are the engine's text, such as nginx:1 and Up 2 hours, at most 256 bytes
	// each and without control characters. They are upstream text, shown as they are.
	Image  string `json:"image"`
	Status string `json:"status"`
}

// RemoteContainers is what remote.listContainers found.
type RemoteContainers struct {
	// Available says whether the engine CLI ran: false when the machine has no such CLI.
	Available bool `json:"available"`
	// Containers are the running containers in the engine's order, at most 256.
	Containers []RemoteContainer `json:"containers"`
	// Diagnostics is what the CLI printed when it failed, such as the message that its service is
	// not running, redacted. It is upstream text, shown as it is and never logged.
	Diagnostics string `json:"diagnostics"`
}

// RemoteListContainers lists the running containers of engine on this machine, or on the host of
// session sessionID when it is set. Core runs the engine CLI's ps, bounded to 15 seconds
// (CodeTimedOut past them), and saves nothing; an unknown session is CodeConnectionClosed.
func (c *Client) RemoteListContainers(ctx context.Context, engine, sessionID string) (RemoteContainers, error) {
	var result RemoteContainers
	request := struct {
		Engine    string `json:"engine"`
		SessionID string `json:"sessionId,omitempty"`
	}{Engine: engine, SessionID: sessionID}
	if err := c.Execute(ctx, "remote.listContainers", request, &result); err != nil {
		return RemoteContainers{}, err
	}
	result.Containers = nonNil(result.Containers)
	return result, nil
}

// RemoteWSLDistributions is what remote.listWslDistributions found on this machine.
type RemoteWSLDistributions struct {
	// Available says whether wsl.exe ran: false on systems other than Windows and on a Windows
	// without WSL.
	Available bool `json:"available"`
	// Distributions are the installed distributions in wsl.exe's order, without Docker Desktop's
	// engine distributions; at most 64.
	Distributions []string `json:"distributions"`
	// Diagnostics is what wsl.exe printed when it failed, such as the message that WSL is not set
	// up, redacted. It is upstream text, shown as it is and never logged.
	Diagnostics string `json:"diagnostics"`
}

// RemoteListWSLDistributions lists the WSL distributions installed on this machine. Core runs
// wsl.exe --list, bounded to 15 seconds (CodeTimedOut past them), and saves nothing.
func (c *Client) RemoteListWSLDistributions(ctx context.Context) (RemoteWSLDistributions, error) {
	var result RemoteWSLDistributions
	if err := c.Execute(ctx, "remote.listWslDistributions", nil, &result); err != nil {
		return RemoteWSLDistributions{}, err
	}
	result.Distributions = nonNil(result.Distributions)
	return result, nil
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
	// SessionKey names the persistent session on the host, for a later Resume.
	SessionKey string `json:"sessionKey"`
	// SessionToken is the secret a later Resume presents, nil when the host issued none. It is
	// stored like a password and never logged.
	SessionToken *string `json:"sessionToken"`
	// SessionBinding identifies the verified target. Empty disables automatic recovery.
	SessionBinding string `json:"sessionBinding"`
	// ResumeConsumed says Core verified and tried the supplied record. A mismatch leaves it stored.
	ResumeConsumed bool `json:"resumeConsumed"`
	// Resumed says this connection attached to the session Resume named. False can also mean the
	// target binding did not match or lacked verified evidence.
	Resumed bool `json:"resumed"`
	// KeptPrograms are the processes and terminals the resumed session still runs, which an
	// earlier connection kept; empty for a new session.
	KeptPrograms []RemoteProgram `json:"keptPrograms"`
}

// Resume is what a later connection presents to attach to this session again, nil when the host
// issued no token or Core could not verify a reusable target identity.
func (s RemoteSession) Resume() *RemoteResume {
	if s.SessionKey == "" || s.SessionToken == nil || *s.SessionToken == "" || s.SessionBinding == "" {
		return nil
	}
	return &RemoteResume{Key: s.SessionKey, Token: *s.SessionToken, Binding: s.SessionBinding}
}

// RemoteProgramKind says whether a host program is a process or a terminal.
type RemoteProgramKind string

const (
	RemoteProgramProcess  RemoteProgramKind = "process"
	RemoteProgramTerminal RemoteProgramKind = "terminal"
)

// RemoteProgram is a process or terminal a host session still runs.
type RemoteProgram struct {
	Kind RemoteProgramKind `json:"kind"`
	// ID is the id the program was started with, unique per kind.
	ID uint64 `json:"id"`
	// Argv is the program and its arguments, user content shown as it is and never logged.
	Argv []string `json:"argv"`
	// Label is the label the program was started with, or nil.
	Label *RemoteResourceLabel `json:"label"`
	// RunningMs is how long the program has run, on the host's clock.
	RunningMs uint64 `json:"runningMs"`
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
// included, to five minutes; a WSL connection asks nothing, a distribution that is not
// installed is RemoteProbeUnreachable, and an unknown user of an installed one is
// RemoteProbeFailed with what wsl.exe printed. Failures are CodeInvalidRequest before OpenSSH or
// wsl.exe starts, CodeRuntimeMissing without ssh, CodeRemoteServerInvalid when the build cannot be
// read or differs from its SHA-256, and the context's error when ctx ends. A session whose events could
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
			// A resumed session holds what the user kept, so it is left as it was.
			programs := RemoteCloseEnd
			if result.Session.Resumed {
				programs = RemoteCloseKeep
			}
			_, _ = c.RemoteDisconnect(context.Background(), result.Session.ID, programs)
		}
		return RemoteConnectResult{}, observationErr
	}
	if result.Session != nil {
		result.Session.KeptPrograms = nonNil(result.Session.KeptPrograms)
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

// RemoteClosePrograms is what closing a connection does to the processes and terminals its host
// session still runs.
type RemoteClosePrograms string

const (
	// RemoteCloseAsk asks the user every time; it is the automatic choice. RemoteDisconnect
	// treats it as RemoteCloseEnd.
	RemoteCloseAsk RemoteClosePrograms = "ask"
	// RemoteCloseEnd ends the host session with everything it runs.
	RemoteCloseEnd RemoteClosePrograms = "end"
	// RemoteCloseKeep tells the host to keep them, for a later RemoteResume.
	RemoteCloseKeep RemoteClosePrograms = "keep"
)

// RemoteDisconnectResult is what remote.disconnect did. Closed is false when Core no longer knew
// the session; Kept says the host keeps the session's programs, false for RemoteCloseEnd and when
// the host could not be told, whose programs then end after the server's idle timeout.
type RemoteDisconnectResult struct {
	Closed bool `json:"closed"`
	Kept   bool `json:"kept"`
}

// RemoteDisconnect closes the session sessionID and its OpenSSH or wsl.exe process tree, ending
// the host session with programs RemoteCloseEnd or keeping what it runs with RemoteCloseKeep. Core
// bounds the request to the host, so closing a window does not hang.
func (c *Client) RemoteDisconnect(ctx context.Context, sessionID string, programs RemoteClosePrograms) (RemoteDisconnectResult, error) {
	if programs != RemoteCloseKeep {
		programs = RemoteCloseEnd
	}
	var result RemoteDisconnectResult
	err := c.Execute(ctx, "remote.disconnect", struct {
		SessionID string              `json:"sessionId"`
		Programs  RemoteClosePrograms `json:"programs"`
	}{sessionID, programs}, &result)
	return result, err
}

// RemoteRunningPrograms lists the processes and terminals the host session of sessionID still
// runs, processes first.
func (c *Client) RemoteRunningPrograms(ctx context.Context, sessionID string) ([]RemoteProgram, error) {
	var result struct {
		Programs []RemoteProgram `json:"programs"`
	}
	err := c.Execute(ctx, "remote.runningPrograms", struct {
		SessionID string `json:"sessionId"`
	}{sessionID}, &result)
	return nonNil(result.Programs), err
}

// RemoteEndPrograms ends the processes and terminals the host session of sessionID runs, every
// one when programs is nil and otherwise those of programs, as RemoteRunningPrograms listed them:
// SIGTERM for each process session and a hang-up for each terminal. ended counts those that were
// still running; one that ignores the signal is still listed afterwards.
func (c *Client) RemoteEndPrograms(ctx context.Context, sessionID string, programs []RemoteProgram) (ended int, err error) {
	type program struct {
		Kind RemoteProgramKind `json:"kind"`
		ID   uint64            `json:"id"`
	}
	var named []program
	if programs != nil {
		named = make([]program, len(programs))
		for i, p := range programs {
			named[i] = program{p.Kind, p.ID}
		}
	}
	var result struct {
		Ended int `json:"ended"`
	}
	err = c.Execute(ctx, "remote.endPrograms", struct {
		SessionID string    `json:"sessionId"`
		Programs  []program `json:"programs,omitempty"`
	}{sessionID, named}, &result)
	return result.Ended, err
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
	// Revision is the host's opaque file identity and precise timestamps.
	Revision string `json:"revision,omitempty"`
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
	// Revision is the host's opaque file identity and precise timestamps.
	Revision string `json:"revision,omitempty"`
}

// RemoteReadFile reads the whole host file path over the session sessionID and returns its
// bytes and the version they were read at. A file larger than Core opens for editing fails with
// CodeNotSupported; otherwise it fails like RemoteReadDir. path must name a regular file or a
// link to one. The host opens nonblocking and checks the opened file's type, so a pipe cannot
// block the read. Core bounds the cumulative bytes, overall deadline and cancellation wait.
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
// through a temporary sibling. With root, descendant links are refused; without it, a leaf link
// is followed for an explicit host write. With expected, a file that no longer has that
// version is left alone; without it, the file must not exist yet. saved is false for either
// refusal, and the version is the saved content's otherwise. Content larger than the host
// accepts in one request fails with CodeProcessFailed. A writer ignoring the host's advisory
// lock can still race between the final version check and replacement.
func (c *Client) RemoteWriteFile(ctx context.Context, sessionID, path string, data []byte, expected *RemoteFileVersion, root ...string) (version RemoteFileVersion, saved bool, err error) {
	var result struct {
		Status string `json:"status"`
		RemoteFileVersion
	}
	var boundary string
	if len(root) > 0 {
		boundary = root[0]
	}
	err = c.Execute(ctx, "remote.writeFile", struct {
		SessionID string             `json:"sessionId"`
		Path      string             `json:"path"`
		Data      []byte             `json:"data"`
		Expected  *RemoteFileVersion `json:"expected,omitempty"`
		Root      string             `json:"root,omitempty"`
	}{sessionID, path, data, expected, boundary}, &result)
	if err != nil {
		return RemoteFileVersion{}, false, err
	}
	if result.Status != "saved" {
		return RemoteFileVersion{}, false, nil
	}
	return result.RemoteFileVersion, true, nil
}

// RemoteCreateDirectory creates the host folder path over the session sessionID with its missing
// parents; a folder already there is left as it is. RemoteWriteFile creates no parent, so a file
// whose folder may be missing is written after it.
func (c *Client) RemoteCreateDirectory(ctx context.Context, sessionID, path string) error {
	return c.RemoteHostRequest(ctx, sessionID, "fs.createDir", struct {
		Path      string `json:"path"`
		Recursive bool   `json:"recursive"`
	}{path, true}, nil)
}

// RemoteMakeDirectory creates the host folder path over the session sessionID without creating
// missing parents; an existing entry at path fails with remoteCode ALREADY_EXISTS.
func (c *Client) RemoteMakeDirectory(ctx context.Context, sessionID, path string) error {
	return c.RemoteHostRequest(ctx, sessionID, "fs.createDir", struct {
		Path      string `json:"path"`
		Recursive bool   `json:"recursive"`
	}{path, false}, nil)
}

// RemoteRename moves the host entry at from to to over the session sessionID. When overwrite is
// false, an existing destination fails with remoteCode ALREADY_EXISTS.
func (c *Client) RemoteRename(ctx context.Context, sessionID, from, to string, overwrite bool) error {
	return c.RemoteHostRequest(ctx, sessionID, "fs.rename", struct {
		From      string `json:"from"`
		To        string `json:"to"`
		Overwrite bool   `json:"overwrite"`
	}{from, to, overwrite}, nil)
}

// RemoteCopy copies the host entry at from to to over the session sessionID, copying a directory
// tree when recursive is set. When overwrite is false, an existing destination fails with
// remoteCode ALREADY_EXISTS.
func (c *Client) RemoteCopy(ctx context.Context, sessionID, from, to string, recursive, overwrite bool) error {
	var ignored json.RawMessage
	return c.RemoteHostRequest(ctx, sessionID, "fs.copy", struct {
		From      string `json:"from"`
		To        string `json:"to"`
		Recursive bool   `json:"recursive"`
		Overwrite bool   `json:"overwrite"`
	}{from, to, recursive, overwrite}, &ignored)
}

// RemoteTrash moves the host entry at path to the host account's system trash over the session
// sessionID.
func (c *Client) RemoteTrash(ctx context.Context, sessionID, path string) error {
	return c.RemoteHostRequest(ctx, sessionID, "fs.trash", struct {
		Path string `json:"path"`
	}{path}, nil)
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

// payloadOnlyCommands are the commands an open document, the Project tool window or the search
// sends that compute only from their payload: Core's handler reads no file, starts no process and names no
// workspace path, so the answer is the same on any computer. They go without the remote
// workspace, which Core would refuse for want of an adapter, and keep working while the host is
// disconnected, so the user can still type, decode the bytes the host returned and plan the save
// that will then fail. workspace.filterChanges drops the host watch's changes in folders Core
// hides, by name alone; workspace.searchPresentation groups search results by the paths it is
// sent, and workspace.replaceText replaces in the text it is sent, which Replace All read from
// the host. editor.find searches the text of the editor or the diff side it is sent, and
// github.parseRemote reads the GitHub repository out of the remote URL the host's Git answered.
//
// Add a command here only after reading its Core handler; a command that touches the workspace
// sent without the binding would read the empty placeholder instead of the host.
var payloadOnlyCommands = map[string]bool{
	"document.lifecycle":              true,
	"document.planSaveBatch":          true,
	"document.reduceSaveBatch":        true,
	"editor.find":                     true,
	"editor.lineEdit":                 true,
	"editor.navigationHistory.reduce": true,
	"editor.parseNavigationInput":     true,
	"editor.recent.reduce":            true,
	"editor.recovery.decide":          true,
	"github.parseRemote":              true,
	"languages.matchFirstLine":        true,
	"markdown.outline":                true,
	"text.decode":                     true,
	"text.encode":                     true,
	"workspace.filterChanges":         true,
	"workspace.replaceText":           true,
	"workspace.searchPresentation":    true,
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
