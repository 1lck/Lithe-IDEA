package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"
)

// Client sends commands to the Rust kernel. The zero value is ready to use and a Client is safe
// for concurrent use; every call gets its own operation id, so concurrent calls and their
// cancellations never interfere. A Client must not be copied after first use.
type Client struct {
	// nextOperation numbers the calls so each one gets a unique operation id.
	nextOperation atomic.Uint64
}

// NewClient returns a Client.
func NewClient() *Client {
	return &Client{}
}

// Version returns the kernel's C ABI version string, for diagnostics.
func (c *Client) Version() string {
	return coreVersion()
}

// requestEnvelope is the request the kernel decodes (CoreRequest in the Rust protocol).
type requestEnvelope struct {
	OperationID string `json:"operationId"`
	Command     string `json:"command"`
	Payload     any    `json:"payload"`
}

// responseEnvelope is the response the kernel encodes (CoreResponse in the Rust protocol).
type responseEnvelope struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error *wireError      `json:"error"`
}

// wireError is the failure object of a response (CoreError in the Rust protocol).
type wireError struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
	Details string    `json:"details"`
}

// Execute runs one kernel command and blocks until it answers.
//
// payload is encoded as the command's JSON payload; nil sends an empty object. When result is
// not nil, the command's data is decoded into it. Failures are returned as *Error, except:
//
//   - A context that is already done makes Execute return ctx.Err() without calling the kernel.
//   - If ctx is done while the kernel runs, the kernel is asked to cancel the request. When the
//     kernel then answers with the cancelled or timed_out code, Execute returns ctx.Err() so the
//     caller can compare with context.Canceled or context.DeadlineExceeded. Cancellation is
//     cooperative: a request that completes before it observes the cancellation returns its
//     result normally.
//
// Execute blocks the calling goroutine; see the package documentation for which callers must
// use a background goroutine.
func (c *Client) Execute(ctx context.Context, command string, payload, result any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if payload == nil {
		payload = struct{}{}
	}
	operationID := fmt.Sprintf("desktop-%d", c.nextOperation.Add(1))
	request, err := json.Marshal(requestEnvelope{
		OperationID: operationID,
		Command:     command,
		Payload:     payload,
	})
	if err != nil {
		return &Error{
			Command: command,
			Code:    CodeInvalidRequest,
			Message: "request could not be encoded",
			Details: err.Error(),
		}
	}
	return decodeResponse(ctx, command, call(ctx, operationID, request), result)
}

// call sends one encoded request while a watcher forwards cancellation of ctx to the kernel.
func call(ctx context.Context, operationID string, request []byte) []byte {
	stop := watchCancellation(ctx, operationID)
	defer stop()
	return executeJSON(request)
}

// watchCancellation cancels the kernel operation operationID when ctx is done. The returned
// stop function ends the watch and must be called exactly once; it returns after the watcher
// goroutine has exited. A context that can never be done (ctx.Done() is nil) needs no watcher,
// so no goroutine is started for it.
func watchCancellation(ctx context.Context, operationID string) (stop func()) {
	done := ctx.Done()
	if done == nil {
		return func() {}
	}
	release := make(chan struct{})
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		select {
		case <-done:
			cancelOperation(operationID)
		case <-release:
		}
	}()
	return func() {
		close(release)
		<-exited
	}
}

// decodeResponse turns the kernel's response into the result of a call. ctx is only consulted
// to translate a cancellation the kernel reports into the context's own error.
func decodeResponse(ctx context.Context, command string, response []byte, result any) error {
	if len(response) == 0 {
		return newParseError(command, "core returned no response", "")
	}
	var envelope responseEnvelope
	if err := json.Unmarshal(response, &envelope); err != nil {
		return newParseError(command, "core response is not a valid envelope", err.Error())
	}
	if !envelope.OK {
		if envelope.Error == nil {
			return newParseError(command, "core reported a failure without an error", "")
		}
		failure := &Error{
			Command: command,
			Code:    envelope.Error.Code,
			Message: envelope.Error.Message,
			Details: envelope.Error.Details,
		}
		if failure.Code == CodeCancelled || failure.Code == CodeTimedOut {
			if cause := ctx.Err(); cause != nil {
				return cause
			}
		}
		return failure
	}
	if result == nil {
		return nil
	}
	if len(envelope.Data) == 0 {
		return newParseError(command, "core reported success without data", "")
	}
	if err := json.Unmarshal(envelope.Data, result); err != nil {
		return newParseError(command, "core response data does not match the expected shape", err.Error())
	}
	return nil
}

// nonNil returns s, or an empty non-nil slice when s is nil, so that a slice encodes as a JSON
// array instead of null. The kernel rejects null for its list fields.
func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}
