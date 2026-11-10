package core

import "context"

// DebugTransportEvent is one platform event applied to an IDE-to-adapter byte
// stream lifecycle. Type selects which of the other fields Core requires; a
// field that does not apply to it stays zero and is not sent.
type DebugTransportEvent struct {
	Type string `json:"type"`
	// Limits overrides the policy defaults on a start event.
	Limits *DebugTransportLimitOverrides `json:"limits,omitempty"`
	// Bytes is the size of the frame a send event queues.
	Bytes *uint64 `json:"bytes,omitempty"`
	// Generation is the live generation the host captured when it started the
	// work this event answers.
	Generation *uint64 `json:"generation,omitempty"`
	Host       *string `json:"host,omitempty"`
	Port       *int64  `json:"port,omitempty"`
	Message    *string `json:"message,omitempty"`
	WriteID    *uint64 `json:"writeId,omitempty"`
	TimerID    *uint64 `json:"timerId,omitempty"`
}

// DebugTransportLimitOverrides replaces any of the six default limits.
type DebugTransportLimitOverrides struct {
	DiscoveryMilliseconds *int `json:"discoveryMilliseconds,omitempty"`
	ConnectMilliseconds   *int `json:"connectMilliseconds,omitempty"`
	WriteMilliseconds     *int `json:"writeMilliseconds,omitempty"`
	BufferedBytes         *int `json:"bufferedBytes,omitempty"`
	BufferedWrites        *int `json:"bufferedWrites,omitempty"`
	DrainMilliseconds     *int `json:"drainMilliseconds,omitempty"`
}

// DebugTransportEffect is one thing the platform runs after an event. Kind is
// discoverEndpoint, armTimer, cancelTimer, connect, write, deliverData, close,
// reportFailure or notifyTermination; only the fields of that kind are set.
type DebugTransportEffect struct {
	Kind              string `json:"kind"`
	TimerID           uint64 `json:"timerId,omitempty"`
	Purpose           string `json:"purpose,omitempty"`
	AfterMilliseconds uint64 `json:"afterMilliseconds,omitempty"`
	Host              string `json:"host,omitempty"`
	Port              int    `json:"port,omitempty"`
	WriteID           uint64 `json:"writeId,omitempty"`
	Bytes             uint64 `json:"bytes,omitempty"`
	Reason            string `json:"reason,omitempty"`
	Message           string `json:"message,omitempty"`
	ExitCode          int    `json:"exitCode,omitempty"`
}

// DebugTransportStep is Core's answer to one event: the live generation, the
// stream's phase, whether the event applied and the effects to run in order.
type DebugTransportStep struct {
	Generation uint64                 `json:"generation"`
	Phase      string                 `json:"phase"`
	Outcome    string                 `json:"outcome"`
	Effects    []DebugTransportEffect `json:"effects"`
}

// DebugTransportHandle applies one event to the lifecycle of transportID.
// Core never opens a socket or reads a clock; the platform runs the effects.
func (c *Client) DebugTransportHandle(ctx context.Context, transportID string, event DebugTransportEvent) (DebugTransportStep, error) {
	var step DebugTransportStep
	if err := c.Execute(ctx, "debug.transport.handle", struct {
		TransportID string              `json:"transportId"`
		Event       DebugTransportEvent `json:"event"`
	}{transportID, event}, &step); err != nil {
		return DebugTransportStep{}, err
	}
	return step, nil
}

// DebugTransportRelease forgets the lifecycle of a stopped stream once the
// platform dropped its handles.
func (c *Client) DebugTransportRelease(ctx context.Context, transportID string) error {
	return c.Execute(ctx, "debug.transport.release", struct {
		TransportID string `json:"transportId"`
	}{transportID}, nil)
}
