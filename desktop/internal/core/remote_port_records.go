package core

import "context"

// What the Ports window remembers of a remote workspace after it closes or its connection drops
// (remote.portRecords, remote.editPortRecords, remote.restoreForwards): the ports the user added,
// the labels and local ports chosen for them, the local forwards left running, and the forwarding
// rules the user started on the host. The document is machine-local; the desktop reads and
// publishes it like the remote preferences, and Core validates it and keys it by the connection's
// target and the workspace's real path on the host, so another host, account, container or folder
// never sees it.

// RemotePortRecordAdded is the address the user added a row with, as remote.parseForwardAddress
// read it.
type RemotePortRecordAdded struct {
	// Host is the host read: an IP address, an IPv6 one without brackets, or a name in lower case;
	// localhost for a port alone.
	Host string `json:"host"`
	// Scheme is the URL's scheme in lower case, "" for an address that is not a URL.
	Scheme string `json:"scheme,omitempty"`
	// Path is the URL's path without its query and fragment, "" when nothing but / remains.
	Path string `json:"path,omitempty"`
}

// RemotePortRecord is what one row of the Ports window remembers. A record with nothing but its
// key is no record: Core removes it.
type RemotePortRecord struct {
	// Host is the row's address, "" for the host's own loopback address (localhost, 127.0.0.1,
	// ::1 and the every-interface addresses); Port is the TCP port.
	Host string `json:"host,omitempty"`
	Port uint16 `json:"port"`
	// Added is the address the user added the row with, nil for a listening port the user did not
	// add.
	Added *RemotePortRecordAdded `json:"added,omitempty"`
	// Label is the name the user gave the row, at most 64 characters.
	Label string `json:"label,omitempty"`
	// LocalPort is the local port the user chose, 0 to forward on the row's own number.
	LocalPort uint16 `json:"localPort,omitempty"`
	// ForwardTarget is the target host of the local forward the user started for the row and did
	// not stop, "" for none; it starts again after a reconnect.
	ForwardTarget string `json:"forwardTarget,omitempty"`
	// ConfirmedTarget records that the user confirmed that forward although its target is outside
	// the host's loopback interface (S28). Core keeps it only with a ForwardTarget of such a target.
	ConfirmedTarget bool `json:"confirmedTarget,omitempty"`
}

// RemotePortRule is a forwarding rule the user started on the host. Kind is RemoteForwardHost or
// RemoteForwardReverse; the fields of the other kind are zero. Two rules are the same rule when
// they differ only in their labels. A rule never starts again without the user, and never listens
// on every interface of the host: that is asked every time.
type RemotePortRule struct {
	Kind RemoteForwardKind `json:"kind"`
	// ListenPort is the host port, 0 to let the host choose one at each start.
	ListenPort uint16 `json:"listenPort,omitempty"`
	// TargetHost and TargetPort are a host rule's server, as remote.forwards lists the target.
	TargetHost string `json:"targetHost,omitempty"`
	TargetPort uint16 `json:"targetPort,omitempty"`
	// LocalPort is the port on this computer's loopback interface a reverse rule reaches.
	LocalPort uint16 `json:"localPort,omitempty"`
	// Label is the name the user gave the rule, at most 64 characters.
	Label string `json:"label,omitempty"`
}

// RemotePortRecords are what the Ports window remembers of one workspace: rows by port and then by
// host, the loopback row first, and rules in the order the user added them.
type RemotePortRecords struct {
	Ports []RemotePortRecord `json:"ports"`
	Rules []RemotePortRule   `json:"rules"`
}

// RemotePortRecordsState is what remote.portRecords reports.
type RemotePortRecordsState struct {
	Records RemotePortRecords `json:"records"`
	// Workspace is the workspace's real path on the host, which keys the records.
	Workspace string `json:"workspace"`
	// Storage is where the document lives below the application's preference root.
	Storage RemotePreferenceStorage `json:"storage"`
}

// RemotePortRecordKey names one row of the Ports window: Host as RemotePortRecord keys it, in any
// spelling of the host's loopback address, and the port.
type RemotePortRecordKey struct {
	Host string `json:"host,omitempty"`
	Port uint16 `json:"port"`
}

// RemotePortRecordEdit is one change: exactly one field is set. Port replaces what its row
// remembers, and a row with nothing left is removed; RemovePort forgets a row; Rule records a rule
// or renames the same rule; RemoveRule forgets the same rule, whatever its label.
type RemotePortRecordEdit struct {
	Port       *RemotePortRecord    `json:"port,omitempty"`
	RemovePort *RemotePortRecordKey `json:"removePort,omitempty"`
	Rule       *RemotePortRule      `json:"rule,omitempty"`
	RemoveRule *RemotePortRule      `json:"removeRule,omitempty"`
}

// RemoteRestoredForward is one local forward remote.restoreForwards started again, or why it did
// not start: Forward is set when it started, Err when it failed.
type RemoteRestoredForward struct {
	// Host and Port are the row, as RemotePortRecord keys it.
	Host string
	Port uint16
	// Forward is the running forward and Created whether this request started it; Forward is nil
	// when the forward failed.
	Forward *RemoteForward
	Created bool
	// Err is why the forward did not start, nil when it started.
	Err *Error
}

// RemotePortRecords reads what the Ports window remembers of the workspace opened as workspace
// through the session sessionID. document is the stored text, nil when there is none; a document
// Core cannot decode fails with CodeParseFailed, an unknown or broken session with
// CodeConnectionClosed and a workspace that no longer exists with CodeWorkspaceNotFound.
func (c *Client) RemotePortRecords(ctx context.Context, document *string, sessionID, workspace string) (RemotePortRecordsState, error) {
	var result RemotePortRecordsState
	err := c.Execute(ctx, "remote.portRecords", remotePortRecordsRequest{document, sessionID, workspace}, &result)
	return result, err
}

// EditRemotePortRecords applies edit to document for the workspace. changed is false and updated
// nil when the edit changes nothing, so the caller writes nothing; records is the workspace's
// records after the edit. A refused value fails with CodeInvalidRequest whose details name the
// field.
func (c *Client) EditRemotePortRecords(ctx context.Context, document *string, sessionID, workspace string, edit RemotePortRecordEdit) (changed bool, updated *string, records RemotePortRecords, err error) {
	var result struct {
		Changed  bool              `json:"changed"`
		Document *string           `json:"document"`
		Records  RemotePortRecords `json:"records"`
	}
	err = c.Execute(ctx, "remote.editPortRecords", struct {
		remotePortRecordsRequest
		RemotePortRecordEdit
	}{remotePortRecordsRequest{document, sessionID, workspace}, edit}, &result)
	if err != nil {
		return false, nil, RemotePortRecords{}, err
	}
	return result.Changed, result.Document, result.Records, nil
}

// RestoreRemoteForwards starts again, in row order, the local forwards document records as left
// running in the workspace, each on its row's local port and with the confirmation it was given.
// One that fails is reported with its error and the others still start; a session that closes
// fails the whole request with CodeConnectionClosed. Rules are never started.
func (c *Client) RestoreRemoteForwards(ctx context.Context, document *string, sessionID, workspace string) ([]RemoteRestoredForward, error) {
	var result struct {
		Forwards []struct {
			Host    string         `json:"host"`
			Port    uint16         `json:"port"`
			Forward *RemoteForward `json:"forward"`
			Created bool           `json:"created"`
			Error   *wireError     `json:"error"`
		} `json:"forwards"`
	}
	const command = "remote.restoreForwards"
	if err := c.Execute(ctx, command, remotePortRecordsRequest{document, sessionID, workspace}, &result); err != nil {
		return nil, err
	}
	restored := make([]RemoteRestoredForward, 0, len(result.Forwards))
	for _, item := range result.Forwards {
		forward := RemoteRestoredForward{Host: item.Host, Port: item.Port, Forward: item.Forward, Created: item.Created}
		switch {
		case item.Error != nil:
			forward.Forward = nil
			forward.Err = &Error{Command: command, Code: item.Error.Code, Message: item.Error.Message, Details: item.Error.Details}
		case item.Forward == nil:
			forward.Err = &Error{Command: command, Code: CodeParseFailed, Message: "restored forward without a forward or an error"}
		}
		restored = append(restored, forward)
	}
	return restored, nil
}

// remotePortRecordsRequest names the stored document and the open workspace it is read for.
type remotePortRecordsRequest struct {
	Document  *string `json:"document"`
	SessionID string  `json:"sessionId"`
	Workspace string  `json:"workspace"`
}
