package core

import "context"

// RemoteForwardKind is which way a forward carries connections.
type RemoteForwardKind string

const (
	// RemoteForwardLocal listens on this computer's loopback interface and reaches a port as the
	// host sees it (remote.startForward).
	RemoteForwardLocal RemoteForwardKind = "local"
	// RemoteForwardHost makes the host listen on a port and connect every accepted connection to
	// another server itself; the bytes never cross the session (remote.startHostForward).
	RemoteForwardHost RemoteForwardKind = "host"
	// RemoteForwardReverse makes the host listen on its loopback interface and brings every
	// accepted connection back to a port on this computer's loopback interface
	// (remote.startReverseForward).
	RemoteForwardReverse RemoteForwardKind = "reverse"
)

// RemoteForward is one forward of a session. A local forward listens on this computer's loopback
// interface and carries its connections over the session to a port as the host sees it; only this
// computer's processes can reach the listener (S27), and the host never reaches back (S29). A host
// or reverse forward listens on the host instead. Fields that do not apply to Kind are zero.
type RemoteForward struct {
	// ID names the forward to RemoteStopForward; it is unique within the session.
	ID uint64 `json:"id"`
	// Kind is local, host or reverse; a Core that predates the kinds sends none, which is local.
	Kind RemoteForwardKind `json:"kind,omitempty"`
	// LocalHost and LocalPort are where a local forward listens on this computer, and the port
	// on this computer a reverse forward reaches; LocalHost is always a loopback address.
	LocalHost string `json:"localHost,omitempty"`
	LocalPort uint16 `json:"localPort,omitempty"`
	// RequestedLocalPort is the local port a local forward was asked for, absent when any was
	// accepted; LocalPortChanged reports that it was taken and the system chose LocalPort.
	RequestedLocalPort *uint16 `json:"requestedLocalPort,omitempty"`
	LocalPortChanged   bool    `json:"localPortChanged"`
	// HostListenHost and HostListenPort are where a host or reverse forward listens on the host,
	// and RequestedHostPort the host port it was asked for, absent when any was accepted.
	// AllInterfaces reports a host forward that listens on every interface of the host.
	HostListenHost    string  `json:"hostListenHost,omitempty"`
	HostListenPort    uint16  `json:"hostListenPort,omitempty"`
	RequestedHostPort *uint16 `json:"requestedHostPort,omitempty"`
	AllInterfaces     bool    `json:"allInterfaces"`
	// TargetHost and TargetPort are a local or host forward's target as the host resolves it,
	// and LoopbackTarget reports that the target is on the host's own loopback interface.
	TargetHost     string `json:"targetHost,omitempty"`
	TargetPort     uint16 `json:"targetPort,omitempty"`
	LoopbackTarget bool   `json:"loopbackTarget"`
	// Connections is the number of connections the forward carries now, and FailedConnections
	// those of a host or reverse forward that could not reach their target.
	Connections       uint64 `json:"connections"`
	FailedConnections uint64 `json:"failedConnections"`
}

// IsLocal reports whether the forward listens on this computer: a local forward, or one from a
// Core that predates the kinds.
func (f RemoteForward) IsLocal() bool {
	return f.Kind == "" || f.Kind == RemoteForwardLocal
}

// RemoteForwardTarget is what RemoteStartForward forwards to.
type RemoteForwardTarget struct {
	// Host is an IP address, with or without brackets for IPv6, or a name the host resolves,
	// such as localhost; Port is the port there.
	Host string `json:"targetHost"`
	Port uint16 `json:"targetPort"`
	// LocalPort is the local port to listen on; 0 lets the system choose one. A taken port is
	// replaced by one the system chooses, which the forward reports as LocalPortChanged.
	LocalPort uint16 `json:"localPort,omitempty"`
	// AllowNonLoopback records that the user confirmed a target outside the host's loopback
	// interface; without it such a target fails with CodeForwardTargetNotConfirmed (S28).
	AllowNonLoopback bool `json:"allowNonLoopbackTarget,omitempty"`
}

// RemoteListeningPort is a TCP port listening on the host.
type RemoteListeningPort struct {
	// Address is the bound address as the host reports it, such as 127.0.0.1, :: or 0.0.0.0.
	Address string `json:"address"`
	Port    uint16 `json:"port"`
	// PID and Process are the process that holds the socket and its command name, which Linux
	// shortens to 15 bytes; both are absent for a process the server's user cannot inspect.
	PID     uint32 `json:"pid,omitempty"`
	Process string `json:"process,omitempty"`
}

// RemoteStartForward forwards a local port to target over the session sessionID. created is
// false when a forward to the same target already ran: forward is then that forward, unchanged.
// A target outside the host's loopback interface that the user did not confirm fails with
// CodeForwardTargetNotConfirmed, a session at its limit with CodeForwardLimitReached, an invalid
// target with CodeInvalidRequest and a broken or unknown session with CodeConnectionClosed.
func (c *Client) RemoteStartForward(ctx context.Context, sessionID string, target RemoteForwardTarget) (forward RemoteForward, created bool, err error) {
	var result struct {
		Forward RemoteForward `json:"forward"`
		Created bool          `json:"created"`
	}
	err = c.Execute(ctx, "remote.startForward", struct {
		SessionID string `json:"sessionId"`
		RemoteForwardTarget
	}{sessionID, target}, &result)
	if err != nil {
		return RemoteForward{}, false, err
	}
	return result.Forward, result.Created, nil
}

// RemoteHostForwardRule is what RemoteStartHostForward makes the host listen on and reach.
type RemoteHostForwardRule struct {
	// Host and Port are the target as the host resolves it, as RemoteForwardTarget names one.
	Host string `json:"targetHost"`
	Port uint16 `json:"targetPort"`
	// ListenPort is the host port to listen on; 0 lets the host choose one. A taken port is never
	// replaced: it fails with CodeForwardHostPortInUse.
	ListenPort uint16 `json:"listenPort,omitempty"`
	// AllInterfaces makes the host listen on every interface instead of its loopback interface;
	// the window asks the user every time and never remembers it.
	AllInterfaces bool `json:"allInterfaces,omitempty"`
	// AllowNonLoopback records that the user confirmed a target outside the host's loopback
	// interface (S28), as for RemoteStartForward.
	AllowNonLoopback bool `json:"allowNonLoopbackTarget,omitempty"`
}

// RemoteStartHostForward makes the host of the session sessionID listen on a port and connect
// every accepted connection to rule's target. created is false when the same rule already ran:
// forward is then that forward, unchanged. Besides RemoteStartForward's failures, a host port in
// use fails with CodeForwardHostPortInUse, one the host refuses with CodeForwardHostPortDenied
// and a server that cannot listen with CodeForwardHostUnsupported.
func (c *Client) RemoteStartHostForward(ctx context.Context, sessionID string, rule RemoteHostForwardRule) (forward RemoteForward, created bool, err error) {
	var result struct {
		Forward RemoteForward `json:"forward"`
		Created bool          `json:"created"`
	}
	err = c.Execute(ctx, "remote.startHostForward", struct {
		SessionID string `json:"sessionId"`
		RemoteHostForwardRule
	}{sessionID, rule}, &result)
	if err != nil {
		return RemoteForward{}, false, err
	}
	return result.Forward, result.Created, nil
}

// RemoteReverseForwardRule is what RemoteStartReverseForward makes the host listen on and reach.
type RemoteReverseForwardRule struct {
	// LocalPort is the port on this computer's loopback interface each connection reaches.
	LocalPort uint16 `json:"localPort"`
	// ListenPort is the port on the host's loopback interface; 0 lets the host choose one.
	ListenPort uint16 `json:"listenPort,omitempty"`
}

// RemoteStartReverseForward makes the host of the session sessionID listen on its loopback
// interface and bring every accepted connection back to rule's port on this computer.
// preferences is the remote preference document, nil when there is none; unless it allows
// reverse forwards the request fails with CodeReverseForwardDisabled. created is false when the
// same rule already ran. A LocalPort of 0 fails with CodeInvalidRequest naming localPort; the
// other failures are RemoteStartHostForward's.
func (c *Client) RemoteStartReverseForward(ctx context.Context, sessionID string, rule RemoteReverseForwardRule, preferences *string) (forward RemoteForward, created bool, err error) {
	var result struct {
		Forward RemoteForward `json:"forward"`
		Created bool          `json:"created"`
	}
	err = c.Execute(ctx, "remote.startReverseForward", struct {
		SessionID string `json:"sessionId"`
		RemoteReverseForwardRule
		Preferences *string `json:"preferences"`
	}{sessionID, rule, preferences}, &result)
	if err != nil {
		return RemoteForward{}, false, err
	}
	return result.Forward, result.Created, nil
}

// RemoteStopForward stops the forward id of the session sessionID and closes its connections;
// stopped is false when the session has no such forward.
func (c *Client) RemoteStopForward(ctx context.Context, sessionID string, id uint64) (stopped bool, err error) {
	var result struct {
		Stopped bool `json:"stopped"`
	}
	err = c.Execute(ctx, "remote.stopForward", struct {
		SessionID string `json:"sessionId"`
		ForwardID uint64 `json:"forwardId"`
	}{sessionID, id}, &result)
	return result.Stopped, err
}

// RemoteForwards lists the running forwards of the session sessionID by id. A session that ends
// stops all of them.
func (c *Client) RemoteForwards(ctx context.Context, sessionID string) ([]RemoteForward, error) {
	var result struct {
		Forwards []RemoteForward `json:"forwards"`
	}
	err := c.Execute(ctx, "remote.forwards", struct {
		SessionID string `json:"sessionId"`
	}{sessionID}, &result)
	return result.Forwards, err
}

// RemoteListeningPorts lists the TCP ports listening on the host of the session sessionID,
// sorted by address and port.
func (c *Client) RemoteListeningPorts(ctx context.Context, sessionID string) ([]RemoteListeningPort, error) {
	var result struct {
		Ports []RemoteListeningPort `json:"ports"`
	}
	err := c.RemoteHostRequest(ctx, sessionID, "ports.listening", nil, &result)
	return result.Ports, err
}

// RemoteForwardAddress is an address the user typed into the Ports window, as a forward target:
// TargetHost and TargetPort are what the host dials, TargetHost without brackets and a name in
// lower case. Scheme and Path come only from an address written as a URL, which the window opens
// the same way: Scheme in lower case, and Path what follows the host and port, its query and
// fragment included, empty when that is empty or "/".
type RemoteForwardAddress struct {
	TargetHost string `json:"targetHost"`
	TargetPort uint16 `json:"targetPort"`
	Scheme     string `json:"scheme,omitempty"`
	Path       string `json:"path,omitempty"`
}

// RemoteParseForwardAddress reads text, a port alone (on localhost), host:port with brackets
// around an IPv6 host, or a URL, whose scheme gives the port when it names none (80 for http and
// ws, 443 for https and wss). A refused address fails with CodeInvalidRequest, and
// RemoteConnectionFieldError names the field text and the reason: empty, tooLong, malformed,
// scheme, credentials (a user name or password, refused rather than kept), host or port. Nothing
// is resolved or contacted, and no session is needed.
func (c *Client) RemoteParseForwardAddress(ctx context.Context, text string) (RemoteForwardAddress, error) {
	var address RemoteForwardAddress
	err := c.Execute(ctx, "remote.parseForwardAddress", struct {
		Text string `json:"text"`
	}{text}, &address)
	return address, err
}
