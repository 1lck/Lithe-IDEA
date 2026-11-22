package core

import "context"

// Remote workspace preferences: the values of the settings page Tools › Remote Workspace. The
// document is machine-local; the desktop reads and publishes it like the saved connections, and
// Core validates it, applies one edit at a time and tells what each automatic value resolves to.

// RemotePreferenceSource says whether a value is the user's setting or the automatic one.
type RemotePreferenceSource string

const (
	// RemotePreferenceFromSetting is a value the user chose.
	RemotePreferenceFromSetting RemotePreferenceSource = "setting"
	// RemotePreferenceAutomatic is the value Core picks when the user chose none.
	RemotePreferenceAutomatic RemotePreferenceSource = "automatic"
)

// RemoteProgramStatus is what is at the SSH program path when the page reads it.
type RemoteProgramStatus string

const (
	// RemoteProgramFound is an executable file.
	RemoteProgramFound RemoteProgramStatus = "found"
	// RemoteProgramMissing is nothing at the saved path; for the automatic value, no ssh on
	// PATH, so Core starts the bare name ssh for the system to look up.
	RemoteProgramMissing RemoteProgramStatus = "missing"
	// RemoteProgramNotExecutable is a directory or a file that cannot be run.
	RemoteProgramNotExecutable RemoteProgramStatus = "notExecutable"
)

// RemotePreferenceValues are the stored values; nil is automatic.
type RemotePreferenceValues struct {
	SSHProgram            *string `json:"sshProgram"`
	ReconnectLimitSeconds *uint32 `json:"reconnectLimitSeconds"`
	// AllowReverseForwarding is whether the Ports window may start reverse forwards.
	AllowReverseForwarding *bool                `json:"allowReverseForwarding"`
	ClosePrograms          *RemoteClosePrograms `json:"closePrograms"`
}

// RemoteSSHProgram is the OpenSSH client Core starts. Path is nil only when the automatic
// value finds no ssh on PATH.
type RemoteSSHProgram struct {
	Source RemotePreferenceSource `json:"source"`
	Path   *string                `json:"path"`
	Status RemoteProgramStatus    `json:"status"`
}

// RemoteReconnect is how a dropped session is reconnected: one attempt after each pause in
// DelaysMilliseconds, which add up to LimitSeconds. No pauses means no automatic reconnect.
type RemoteReconnect struct {
	Source             RemotePreferenceSource `json:"source"`
	LimitSeconds       uint32                 `json:"limitSeconds"`
	DelaysMilliseconds []uint64               `json:"delaysMilliseconds"`
}

// RemoteClosing is what closing a window does to the processes and terminals still running on
// the host. Programs is RemoteCloseAsk when automatic: the client asks every time.
// IdleTimeoutSeconds is how long the host keeps a session whose connection was lost and whose
// programs nobody kept; the remote server sets it, so no edit changes it.
type RemoteClosing struct {
	Source             RemotePreferenceSource `json:"source"`
	Programs           RemoteClosePrograms    `json:"programs"`
	IdleTimeoutSeconds uint64                 `json:"idleTimeoutSeconds"`
}

// RemoteReverseForwarding is whether reverse forwards may start. The automatic value refuses
// them, because a port a reverse forward opens is open to every user of the host.
type RemoteReverseForwarding struct {
	Source  RemotePreferenceSource `json:"source"`
	Allowed bool                   `json:"allowed"`
}

// RemotePreferenceStorage is where the document lives below the application's preference root.
type RemotePreferenceStorage struct {
	RelativePath string `json:"relativePath"`
	MaximumBytes int64  `json:"maximumBytes"`
}

// RemoteSSHConfigFile is the user's ~/.ssh/config.
type RemoteSSHConfigFile struct {
	Path   string `json:"path"`
	Exists bool   `json:"exists"`
}

// RemotePreferences is what remote.preferences reports. SSHConfig is set only when a home
// directory was given.
type RemotePreferences struct {
	Preferences RemotePreferenceValues  `json:"preferences"`
	SSH         RemoteSSHProgram        `json:"ssh"`
	Reconnect   RemoteReconnect         `json:"reconnect"`
	Reverse     RemoteReverseForwarding `json:"reverseForwarding"`
	Closing     RemoteClosing           `json:"closing"`
	Storage     RemotePreferenceStorage `json:"storage"`
	SSHConfig   *RemoteSSHConfigFile    `json:"sshConfig"`
}

// RemotePreferences reads document, the preference document's text or nil when there is none.
// homeDirectory, an absolute path or empty, adds the SSH configuration file. A document that
// cannot be decoded fails with CodeParseFailed; a relative home directory with
// CodeInvalidRequest naming homeDirectory in RemoteConnectionFieldError.
func (c *Client) RemotePreferences(ctx context.Context, document *string, homeDirectory string) (RemotePreferences, error) {
	var result RemotePreferences
	err := c.Execute(ctx, "remote.preferences", struct {
		Document      *string `json:"document"`
		HomeDirectory string  `json:"homeDirectory,omitempty"`
	}{document, homeDirectory}, &result)
	result.Reconnect.DelaysMilliseconds = nonNil(result.Reconnect.DelaysMilliseconds)
	if result.Closing.Programs == "" {
		result.Closing.Programs = RemoteCloseAsk
	}
	return result, err
}

// RemotePreferenceEdit changes one value: set exactly one field. A nil Path, Seconds or Programs
// makes the value automatic again.
type RemotePreferenceEdit struct {
	SSHProgram     *RemoteSSHProgramEdit        `json:"sshProgram,omitempty"`
	ReconnectLimit *RemoteReconnectLimitEdit    `json:"reconnectLimit,omitempty"`
	Reverse        *RemoteReverseForwardingEdit `json:"reverseForwarding,omitempty"`
	ClosePrograms  *RemoteCloseProgramsEdit     `json:"closePrograms,omitempty"`
}

// RemoteReverseForwardingEdit allows or refuses reverse forwards; a nil Allowed is automatic,
// which refuses them.
type RemoteReverseForwardingEdit struct {
	Allowed *bool `json:"allowed"`
}

// RemoteCloseProgramsEdit stores what closing a window does to the host's programs.
type RemoteCloseProgramsEdit struct {
	Programs *RemoteClosePrograms `json:"programs"`
}

// RemoteSSHProgramEdit sets the SSH program to an absolute path of an executable file.
type RemoteSSHProgramEdit struct {
	Path *string `json:"path"`
}

// RemoteReconnectLimitEdit sets how long a dropped session is reconnected, 0 to 3600 seconds.
type RemoteReconnectLimitEdit struct {
	Seconds *uint32 `json:"seconds"`
}

// EditRemotePreferences applies edit to document. changed is false, and the document nil, when
// nothing changes. A refused value fails with CodeInvalidRequest and names sshProgram or
// reconnectLimitSeconds with the reason (invalid, tooLong, relative, missing, notExecutable,
// outOfRange) in RemoteConnectionFieldError; a damaged document fails with CodeParseFailed.
func (c *Client) EditRemotePreferences(ctx context.Context, document *string, edit RemotePreferenceEdit) (changed bool, updated *string, err error) {
	var result struct {
		Changed  bool    `json:"changed"`
		Document *string `json:"document"`
	}
	err = c.Execute(ctx, "remote.editPreferences", struct {
		Document *string `json:"document"`
		RemotePreferenceEdit
	}{document, edit}, &result)
	return result.Changed, result.Document, err
}
