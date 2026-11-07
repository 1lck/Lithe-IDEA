// Package core is the Lithe desktop client's only door into the borrowed Rust kernel
// (Lithe-core-rust). The kernel speaks a JSON envelope over a small C ABI; this package hides
// both the C ABI and the JSON so the rest of the client works with Go types and Go errors.
//
// The package has three layers:
//
//  1. Transport (bridge.go): the only file that imports "C". It copies one request into C
//     memory, calls lithe_core_execute_json, copies the answer out and releases it.
//  2. Envelope (client.go, errors.go): Client.Execute wraps a command and its payload into
//     {operationId, command, payload}, decodes {id, ok, data, error}, turns failures into a
//     typed *Error, and forwards context cancellation to the kernel through lithe_core_cancel.
//  3. Typed commands (recent.go, git.go, chrome.go): small methods on *Client
//     with Go request and response types, so the UI never builds JSON by hand.
//
// Every call is synchronous and blocks the calling goroutine until the kernel answers. GitStatus
// runs Git and can take anything from milliseconds to seconds, so it must be called from a
// background goroutine, never from the UI goroutine. The pure reducers (ReduceRecentProjects,
// ReduceChromeLayout) only compute over their arguments; they are fast enough for event
// handlers, but still not for painting.
//
// A Client is safe for concurrent use. Cancelling the context passed to a call asks the kernel
// to stop cooperatively: the call returns the context's error once the kernel observes the
// request, and a call that finishes before it observes the cancellation returns its result.
//
// The kernel is linked statically. Neither the header nor the library path appears in the
// sources; scripts/desktop/desktop-go.sh supplies both through CGO_CFLAGS and CGO_LDFLAGS.
package core
