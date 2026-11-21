package core

import "context"

// RemoteForward is one forward of a session: a listener on this computer's loopback interface
// whose connections Core carries over the session to a port as the host sees it. Only this
// computer's processes can reach the listener (S27), and the host never reaches back (S29).
type RemoteForward struct {
	// ID names the forward to RemoteStopForward; it is unique within the session.
	ID uint64 `json:"id"`
	// LocalHost and LocalPort are where the forward listens on this computer; LocalHost is
	// always a loopback address.
	LocalHost string `json:"localHost"`
	LocalPort uint16 `json:"localPort"`
	// RequestedLocalPort is the local port the forward was asked for, absent when any was
	// accepted; LocalPortChanged reports that it was taken and the system chose LocalPort.
	RequestedLocalPort *uint16 `json:"requestedLocalPort,omitempty"`
	LocalPortChanged   bool    `json:"localPortChanged"`
	// TargetHost and TargetPort are the forward's target as the host resolves it, and
	// LoopbackTarget reports that the target is on the host's own loopback interface.
	TargetHost     string `json:"targetHost"`
	TargetPort     uint16 `json:"targetPort"`
	LoopbackTarget bool   `json:"loopbackTarget"`
	// Connections is the number of connections the forward carries now.
	Connections uint64 `json:"connections"`
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
