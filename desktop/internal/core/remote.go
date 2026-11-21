package core

import (
	"context"
	"encoding/json"
	"errors"
)

// Remote development connections: the SSH connections the user saved, and the probe that checks
// one reaches a Linux host a remote server build exists for. Core validates every entry, picks
// ids and applies one edit at a time against a machine-local document the host keeps in its
// preference directory; it never stores a secret (design S08–S10, S12, S15). Questions OpenSSH
// asks during a probe (passwords, key passphrases, one-time codes, unknown host keys) reach the
// host as authentication challenges, like Git's.

// Authentication modes of an SSHConnection. The empty mode is RemoteAuthenticationAuto.
const (
	// RemoteAuthenticationAuto lets OpenSSH and the user's ~/.ssh/config choose.
	RemoteAuthenticationAuto = "auto"
	// RemoteAuthenticationAgent uses only the keys of the running SSH agent.
	RemoteAuthenticationAgent = "agent"
	// RemoteAuthenticationPrivateKey uses only IdentityFile; Lithe passes its path to OpenSSH and
	// never reads the key.
	RemoteAuthenticationPrivateKey = "privateKey"
	// RemoteAuthenticationPassword asks for a password or one-time code during the connection.
	RemoteAuthenticationPassword = "password"
)

// SSHConnection is how OpenSSH reaches a host. Empty and zero fields are left to OpenSSH and the
// user's ~/.ssh/config, so Host may be an alias defined there.
type SSHConnection struct {
	// Host is a host name, an address or a ~/.ssh/config alias, without a user or a port.
	Host string `json:"host"`
	// Port is the SSH port; 0 leaves it to OpenSSH.
	Port uint16 `json:"port,omitempty"`
	// User is the login name; empty leaves it to OpenSSH.
	User string `json:"user,omitempty"`
	// Authentication is one of the RemoteAuthentication modes; empty is RemoteAuthenticationAuto.
	Authentication string `json:"authentication,omitempty"`
	// IdentityFile is the private key path, required by RemoteAuthenticationPrivateKey and
	// dropped by Core in every other mode.
	IdentityFile string `json:"identityFile,omitempty"`
	// ProxyJump is OpenSSH's jump host list, for example "bastion" or "user@a,user@b:2222".
	ProxyJump string `json:"proxyJump,omitempty"`
	// ConnectTimeoutSeconds bounds the TCP connection, 1 to 600; 0 is Core's default of 15.
	ConnectTimeoutSeconds uint32 `json:"connectTimeoutSeconds,omitempty"`
	// KeepAliveSeconds sends a keep-alive this often, 1 to 3600; 0 sends none.
	KeepAliveSeconds uint32 `json:"keepAliveSeconds,omitempty"`
}

// SavedRemoteConnection is one entry of the saved connections.
type SavedRemoteConnection struct {
	// ID is Core's stable identifier of the entry.
	ID string `json:"id"`
	// Name is the user's label.
	Name string `json:"name"`
	// Connection is how to reach the host.
	Connection SSHConnection `json:"connection"`
	// Color is the entry's accent color; empty for none.
	Color RemoteConnectionColor `json:"color,omitempty"`
	// Group is the group the entry is listed under; empty for none.
	Group string `json:"group,omitempty"`
	// RecentFolders are the host folders opened over the entry, the latest first.
	RecentFolders []string `json:"recentFolders,omitempty"`
	// LastConnectedAt is when a session last opened over the entry, in seconds since the Unix
	// epoch; 0 when none has. Changing the entry's target clears it.
	LastConnectedAt int64 `json:"lastConnectedAt,omitempty"`
}

// RemoteConnectionColor is an accent color Core accepts for a saved connection. The client picks
// the shade for its light and dark themes.
type RemoteConnectionColor string

// The accent colors Core accepts.
const (
	RemoteConnectionRed    RemoteConnectionColor = "red"
	RemoteConnectionOrange RemoteConnectionColor = "orange"
	RemoteConnectionYellow RemoteConnectionColor = "yellow"
	RemoteConnectionGreen  RemoteConnectionColor = "green"
	RemoteConnectionBlue   RemoteConnectionColor = "blue"
	RemoteConnectionPurple RemoteConnectionColor = "purple"
)

// RemoteConnectionColors are the accent colors, in the order the connection window offers them.
var RemoteConnectionColors = []RemoteConnectionColor{
	RemoteConnectionRed, RemoteConnectionOrange, RemoteConnectionYellow,
	RemoteConnectionGreen, RemoteConnectionBlue, RemoteConnectionPurple,
}

// RemoteConnectionSection is one heading of the connection list: the entries of Group, or of no
// group when Group is nil, in the order Core lists them.
type RemoteConnectionSection struct {
	Group *string  `json:"group"`
	IDs   []string `json:"ids"`
}

// RemoteConnectionsStorage says where the host keeps the document: RelativePath inside the
// platform preference directory, at most MaximumBytes long.
type RemoteConnectionsStorage struct {
	RelativePath string `json:"relativePath"`
	MaximumBytes int64  `json:"maximumBytes"`
}

// RemoteConnectionsState is the document as Core reads it.
type RemoteConnectionsState struct {
	Connections []SavedRemoteConnection `json:"connections"`
	// Sections are the headings the window lists the entries under, ungrouped last.
	Sections []RemoteConnectionSection `json:"sections"`
	Storage  RemoteConnectionsStorage  `json:"storage"`
}

// RemoteConnectionSave adds a connection, or replaces the entry ID when ID is set. An empty
// Color or Group saves the entry without one, so a save carries the entry's current values.
type RemoteConnectionSave struct {
	ID         string                `json:"id,omitempty"`
	Name       string                `json:"name"`
	Connection SSHConnection         `json:"connection"`
	Color      RemoteConnectionColor `json:"color,omitempty"`
	Group      string                `json:"group,omitempty"`
}

// RemoteConnectionID names an entry to remove.
type RemoteConnectionID struct {
	ID string `json:"id"`
}

// RemoteConnectionFolder records a host folder opened over the entry ID.
type RemoteConnectionFolder struct {
	ID   string `json:"id"`
	Path string `json:"path"`
}

// RemoteConnectionImport adds Entries in order, each checked as a save without an ID; a name
// already taken gets the first free " (2)" to " (256)" suffix. Fills give saved entries a color
// or a group only where they have none. The first refusal leaves the list as it was.
type RemoteConnectionImport struct {
	Entries []RemoteConnectionSave `json:"entries,omitempty"`
	Fills   []RemoteConnectionFill `json:"fills,omitempty"`
}

// RemoteConnectionFill gives the entry ID the Color and the Group it lacks.
type RemoteConnectionFill struct {
	ID    string                `json:"id"`
	Color RemoteConnectionColor `json:"color,omitempty"`
	Group string                `json:"group,omitempty"`
}

// RemoteConnectionEdit is exactly one of its fields. MarkConnected records the current time as
// the entry's LastConnectedAt.
type RemoteConnectionEdit struct {
	Save           *RemoteConnectionSave   `json:"save,omitempty"`
	Remove         *RemoteConnectionID     `json:"remove,omitempty"`
	RememberFolder *RemoteConnectionFolder `json:"rememberFolder,omitempty"`
	MarkConnected  *RemoteConnectionID     `json:"markConnected,omitempty"`
	Import         *RemoteConnectionImport `json:"import,omitempty"`
}

// RemoteConnectionsPublication is the outcome of an edit. Document is the text to publish, nil
// when the edit changed nothing; ID names the entry a save wrote, and IDs the entries an import
// added, in order.
type RemoteConnectionsPublication struct {
	Changed     bool                      `json:"changed"`
	Document    *string                   `json:"document"`
	Connections []SavedRemoteConnection   `json:"connections"`
	Sections    []RemoteConnectionSection `json:"sections"`
	ID          string                    `json:"id"`
	IDs         []string                  `json:"ids"`
}

// RemoteConnections reads the saved connections from document, the text of the source or nil
// when it does not exist. A document Core cannot decode fails with CodeParseFailed, with the
// field and the reason in RemoteConnectionFieldError.
func (c *Client) RemoteConnections(ctx context.Context, document *string) (RemoteConnectionsState, error) {
	return c.SearchRemoteConnections(ctx, document, "")
}

// SearchRemoteConnections reads document as RemoteConnections does, keeping in Sections only the
// entries whose name, group and [user@]host[:port] contain every word of query, regardless of
// case; Connections stays the whole list. An empty query keeps every entry; one longer than 256
// characters fails with CodeInvalidRequest.
func (c *Client) SearchRemoteConnections(ctx context.Context, document *string, query string) (RemoteConnectionsState, error) {
	var state RemoteConnectionsState
	err := c.Execute(ctx, "remote.connections", struct {
		Document *string `json:"document"`
		Query    string  `json:"query,omitempty"`
	}{document, query}, &state)
	return state, err
}

// EditRemoteConnections applies edit to document. A refused entry fails with CodeInvalidRequest,
// with the field and the reason in RemoteConnectionFieldError.
func (c *Client) EditRemoteConnections(ctx context.Context, document *string, edit RemoteConnectionEdit) (RemoteConnectionsPublication, error) {
	var publication RemoteConnectionsPublication
	err := c.Execute(ctx, "remote.editConnections", struct {
		Document *string `json:"document"`
		RemoteConnectionEdit
	}{document, edit}, &publication)
	return publication, err
}

// RemoteConnectionFieldError reads the field and the reason Core named when it refused a
// connection or a document: field is a JSON name such as "host" or "connectTimeoutSeconds", and
// reason one of "required", "invalid", "tooLong", "duplicate", "full" and "unknown".
func RemoteConnectionFieldError(err error) (field, reason string, ok bool) {
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Details == "" {
		return "", "", false
	}
	if coreErr.Code != CodeInvalidRequest && coreErr.Code != CodeParseFailed {
		return "", "", false
	}
	var details struct {
		Field  string `json:"field"`
		Reason string `json:"reason"`
	}
	if json.Unmarshal([]byte(coreErr.Details), &details) != nil || details.Field == "" || details.Reason == "" {
		return "", "", false
	}
	return details.Field, details.Reason, true
}

// RemoteProbeStatus is the outcome of a probe. A host that cannot be reached is an outcome, not
// an error.
type RemoteProbeStatus string

const (
	// RemoteProbeConnected means a shell ran on the host and a server build exists for it.
	RemoteProbeConnected RemoteProbeStatus = "connected"
	// RemoteProbeUnsupportedPlatform means the host answered, but no server build exists for it.
	RemoteProbeUnsupportedPlatform RemoteProbeStatus = "unsupportedPlatform"
	// RemoteProbeAuthenticationFailed means the server rejected every offered credential.
	RemoteProbeAuthenticationFailed RemoteProbeStatus = "authenticationFailed"
	// RemoteProbeHostKeyRejected means the host key is unknown and was declined, or changed.
	RemoteProbeHostKeyRejected RemoteProbeStatus = "hostKeyRejected"
	// RemoteProbeUnreachable means the name did not resolve or the host did not answer in time.
	RemoteProbeUnreachable RemoteProbeStatus = "unreachable"
	// RemoteProbeFailed means the connection failed for another reason; see Diagnostics.
	RemoteProbeFailed RemoteProbeStatus = "failed"
)

// RemoteHostDetails are facts about a probed host for display; each is empty or zero when the
// host did not report it.
type RemoteHostDetails struct {
	HostName           string `json:"hostName"`
	OperatingSystem    string `json:"operatingSystem"`
	Kernel             string `json:"kernel"`
	CPUCount           uint32 `json:"cpuCount"`
	MemoryBytes        uint64 `json:"memoryBytes"`
	DiskTotalBytes     uint64 `json:"diskTotalBytes"`
	DiskAvailableBytes uint64 `json:"diskAvailableBytes"`
	UptimeSeconds      uint64 `json:"uptimeSeconds"`
}

// RemoteProbedHost is what the host's shell reported.
type RemoteProbedHost struct {
	// System is `uname -s`, for example "Linux".
	System string `json:"system"`
	// Machine is `uname -m`, for example "x86_64" or "aarch64".
	Machine string `json:"machine"`
	// HomeDirectory is the login's home directory, empty when unknown.
	HomeDirectory string `json:"homeDirectory"`
	// ServerTarget is the Rust target of the server build for the host, empty when none exists.
	ServerTarget string `json:"serverTarget"`
	// Details are facts for display.
	Details RemoteHostDetails `json:"details"`
}

// RemoteProbeResult is the outcome of a probe, and the host when its shell ran.
type RemoteProbeResult struct {
	Status RemoteProbeStatus `json:"status"`
	Host   *RemoteProbedHost `json:"host"`
	// Diagnostics is the redacted end of OpenSSH's standard error. It is upstream text, shown
	// as it is, and may still name the host, so it is never logged.
	Diagnostics string `json:"diagnostics"`
}

// RemoteProbe connects to the host of connection with the system OpenSSH client and reports its
// platform. Each question OpenSSH asks reaches the prompt WithGitAuthentication put in ctx as a
// challenge with Remote set, answered with RemoteAuthRespond; without a prompt each question is
// cancelled at once. Core bounds a probe, answers included, to five minutes. The probe changes
// nothing, so an observation failure is reported only when the request itself succeeded.
// preferences is the remote workspace preference document, or nil; it names the SSH program, and
// a damaged one fails with CodeParseFailed before OpenSSH starts.
func (c *Client) RemoteProbe(ctx context.Context, connection SSHConnection, preferences *string) (RemoteProbeResult, error) {
	var result RemoteProbeResult
	observationErr, err := c.executeRemoteWithPrompts(ctx, "remote.probe", struct {
		Connection  SSHConnection `json:"connection"`
		Preferences *string       `json:"preferences,omitempty"`
	}{connection, preferences}, &result)
	if err != nil {
		return RemoteProbeResult{}, err
	}
	if observationErr != nil {
		return RemoteProbeResult{}, observationErr
	}
	return result, nil
}

// RemoteAuthRespond answers the Remote challenge requestID with the text the user typed, or nil
// to cancel. accepted is false when the challenge no longer waits. The answer is never logged.
// Core answers at once, so the call may run on any goroutine, but not on the UI thread.
func (c *Client) RemoteAuthRespond(ctx context.Context, requestID string, answer *string) (accepted bool, err error) {
	var result struct {
		Accepted bool `json:"accepted"`
	}
	err = c.Execute(ctx, "remote.authRespond", gitAuthReply{RequestID: requestID, Answer: answer}, &result)
	return result.Accepted, err
}
