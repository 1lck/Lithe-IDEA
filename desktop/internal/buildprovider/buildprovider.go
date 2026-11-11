// Package buildprovider owns one negotiated provider process, a build or a VCS
// provider, and the operations sent to it.
//
// Core plans and verifies the process, keeps its event stream in order and
// accepts only methods the litheBuild or litheVcs negotiation granted. This
// package starts the planned process, waits for the ready state, records the
// VCS a provider negotiated, correlates request events with the host operation,
// and stops the session when its workspace closes.
package buildprovider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

var (
	// ErrNotReady reports a request before the provider completed initialize.
	ErrNotReady = errors.New("build provider is not ready")
	// ErrClosed reports work on a session that already ended.
	ErrClosed = errors.New("build provider session is closed")
)

// Progress is one bounded lithe/build/progress notification.
type Progress struct {
	Message    string
	Percentage *int
	Output     string
}

// Operation is one outstanding build-provider request. Its events arrive in
// Core's session stream and are correlated by Core's operation ID.
type Operation struct {
	ID       string
	Method   string
	progress chan Progress
	done     chan struct{}

	mu       sync.Mutex
	terminal bool
	result   json.RawMessage
	err      error
}

// Progress reports messages and output as the provider sends them. The channel
// is closed when the operation completes; a consumer that stops early must not
// block the session.
func (o *Operation) Progress() <-chan Progress { return o.progress }

// Done closes when the operation reached its terminal event. Reading Progress
// after Done yields any queued notifications and then its closed channel.
func (o *Operation) Done() <-chan struct{} { return o.done }

// Wait blocks until the operation completes or ctx ends. The returned JSON is
// the provider's `result.value`, never the event envelope.
func (o *Operation) Wait(ctx context.Context) (json.RawMessage, error) {
	if o == nil {
		return nil, ErrClosed
	}
	select {
	case <-o.done:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.result, o.err
}

// finish publishes the provider's result and closes the operation exactly once.
// The mutex is the single owner of both channels: progress delivery checks the
// same terminal flag, so a concurrent failAll cannot close a channel under a
// sender.
func (o *Operation) finish(result json.RawMessage, err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.terminal {
		return
	}
	o.terminal = true
	o.result, o.err = result, err
	close(o.progress)
	close(o.done)
}

func (o *Operation) fail(err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.terminal {
		return
	}
	o.terminal = true
	if o.err == nil {
		o.err = err
	}
	close(o.progress)
	close(o.done)
}

func (o *Operation) deliverProgress(progress Progress) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.terminal {
		return
	}
	select {
	case o.progress <- progress:
	default:
		// Progress is advisory; losing a notification must not stall the
		// provider or grow without bound. The final result always arrives.
	}
}

func newOperation(id, method string) *Operation {
	return &Operation{
		ID:       id,
		Method:   method,
		progress: make(chan Progress, 64),
		done:     make(chan struct{}),
	}
}

// Client is one build-provider session.
type Client struct {
	runner  *pluginbackend.Runner
	session pluginbackend.Session
	// shared says another owner keeps the session: language servers that also
	// serve build requests. Close detaches without stopping it.
	shared    bool
	ready     chan struct{}
	readyOnce sync.Once
	done      chan struct{}
	doneOnce  sync.Once
	closeOnce sync.Once
	// closeErr records why the session ended, for requests that arrive later.
	closeErr error

	mu      sync.Mutex
	pending map[string]*Operation
	closed  bool
	// vcs and capabilities are what a VCS provider negotiated, recorded from
	// Core's vcsProvider event before the session turned ready.
	vcs          string
	capabilities map[string]int

	ctx    context.Context
	cancel context.CancelFunc
}

// Start launches the provider Core planned for one build system or VCS and
// waits for its initialize handshake. A request without a role starts a build
// provider. The caller must run this away from the window thread. Close owns
// the process and must be called when the workspace closes.
func Start(ctx context.Context, runner *pluginbackend.Runner, request pluginbackend.StartRequest) (*Client, error) {
	if runner == nil {
		return nil, errors.New("buildprovider: no runner")
	}
	if request.Role == "" {
		request.Role = "build"
	}
	session, err := runner.Start(ctx, request)
	if err != nil {
		return nil, err
	}
	client := newClient(runner, session)
	client.ctx, client.cancel = context.WithCancel(context.Background())
	go client.serve()
	if err := client.WaitReady(ctx); err != nil {
		// The session may have started but never negotiated the protocol. Stop
		// it instead of leaving an unusable process behind.
		stopCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = client.Close(stopCtx)
		return nil, err
	}
	return client, nil
}

// Attach returns a client over a session another owner started, such as a
// language server of the same plugin. The owner must call Observe with every
// event that session produces. Close detaches this client; it never stops the
// shared session.
func Attach(runner *pluginbackend.Runner, session pluginbackend.Session, ready bool) *Client {
	client := newClient(runner, session)
	client.shared = true
	if ready {
		client.markReady()
	}
	return client
}

// markReady records the single readiness transition. Only a real ready event,
// or a shared owner that already observed one, may call it.
func (c *Client) markReady() {
	c.readyOnce.Do(func() { close(c.ready) })
}

func newClient(runner *pluginbackend.Runner, session pluginbackend.Session) *Client {
	return &Client{
		runner:  runner,
		session: session,
		ready:   make(chan struct{}),
		done:    make(chan struct{}),
		pending: make(map[string]*Operation),
	}
}

// Session is the identity Core assigned to the provider.
func (c *Client) Session() pluginbackend.Session { return c.session }

// Closed reports whether the provider's serve loop ended or Close ran.
func (c *Client) Closed() bool {
	if c == nil {
		return true
	}
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// WaitReady blocks until initialize completed, the session ended, or ctx is
// done.
func (c *Client) WaitReady(ctx context.Context) error {
	if c == nil {
		return ErrClosed
	}
	select {
	case <-c.ready:
		return nil
	case <-c.done:
		return c.ended()
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Execute sends one negotiated build method and returns the correlated
// operation. The method and params must come from a Core build plan.
func (c *Client) Execute(ctx context.Context, method string, params json.RawMessage, timeoutMilliseconds int) (*Operation, error) {
	return c.execute(ctx, method, params, func(id string) error {
		_, err := c.runner.RequestBuild(ctx, c.session, core.PluginBuildProviderRequest{OperationID: id, Method: method, Params: params, TimeoutMilliseconds: timeoutMilliseconds})
		return err
	})
}

// VcsProvider is the VCS and capabilities the provider negotiated; ok is false
// when it negotiated none. Core announces them before the session turns ready,
// so they are known once Start returns.
func (c *Client) VcsProvider() (vcs string, capabilities map[string]int, ok bool) {
	if c == nil {
		return "", nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.vcs, c.capabilities, c.vcs != ""
}

// ExecuteVcs sends one VCS operation and returns the correlated operation; its
// result is the provider's reply, which the caller has Core decode. Core
// refuses an operation the provider did not negotiate.
func (c *Client) ExecuteVcs(ctx context.Context, request core.PluginVcsRequest) (*Operation, error) {
	return c.execute(ctx, request.Operation, request.Arguments, func(id string) error {
		request.OperationID = id
		_, err := c.runner.RequestVcs(ctx, c.session, request)
		return err
	})
}

// ExecuteFunction invokes a Core-planned plugin function on this provider's
// existing session. It shares correlation, progress, cancellation and shutdown
// with build operations; it never starts a second reader or provider process.
func (c *Client) ExecuteFunction(ctx context.Context, function string, params json.RawMessage) (*Operation, error) {
	return c.execute(ctx, function, params, func(id string) error {
		_, err := c.runner.RequestFunction(ctx, c.session, id, function, params)
		return err
	})
}

func (c *Client) execute(ctx context.Context, method string, params json.RawMessage, send func(string) error) (*Operation, error) {
	if c == nil {
		return nil, ErrClosed
	}
	select {
	case <-c.ready:
	case <-c.done:
		return nil, c.ended()
	default:
		return nil, ErrNotReady
	}
	if len(params) == 0 || string(params) == "null" {
		return nil, fmt.Errorf("buildprovider: %s has no params", method)
	}
	id := fmt.Sprintf("build-%d", nextOperation.Add(1))
	operation := newOperation(id, method)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, c.ended()
	}
	c.pending[id] = operation
	c.mu.Unlock()
	err := send(id)
	if err != nil {
		c.forget(id)
		operation.fail(err)
		return nil, err
	}
	return operation, nil
}

// Cancel asks Core to cancel one operation. Completion still arrives as its
// normal terminal event, so the caller must keep waiting on the operation.
func (c *Client) Cancel(ctx context.Context, operation *Operation) error {
	if c == nil || operation == nil {
		return nil
	}
	return c.runner.Cancel(ctx, c.session, operation.ID)
}

// Close stops the session this client started.
func (c *Client) Close(ctx context.Context) error {
	if c == nil {
		return nil
	}
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		c.closeErr = ErrClosed
		c.mu.Unlock()
		if c.cancel != nil {
			c.cancel()
		}
		// Fail pending operations before process teardown. A shared Close only
		// detaches, and an owned Close may spend time stopping the session; the
		// progress and done channels must be terminal either way.
		c.failAll(ErrClosed)
	})
	if c.shared {
		c.end(ErrClosed)
		return nil
	}
	var err error
	if c.runner != nil {
		err = c.runner.Stop(ctx, c.session)
	}
	c.end(ErrClosed)
	return err
}

func (c *Client) serve() {
	err := c.runner.Serve(c.ctx, c.session, c.observe)
	if err != nil && !errors.Is(err, context.Canceled) {
		c.failAll(err)
	} else {
		c.failAll(ErrClosed)
	}
	c.end(ErrClosed)
}

func (c *Client) end(err error) {
	c.doneOnce.Do(func() {
		c.mu.Lock()
		if c.closeErr == nil {
			c.closeErr = err
		}
		c.mu.Unlock()
		close(c.done)
	})
}

func (c *Client) observe(event core.BackendEvent) {
	if event.Type == "exit" {
		c.failAll(ErrClosed)
		c.end(ErrClosed)
		return
	}
	if event.Type == "stateChanged" && event.State == "ready" {
		c.markReady()
		return
	}
	if event.Type == "vcsProvider" {
		var negotiated struct {
			Vcs          string         `json:"vcs"`
			Capabilities map[string]int `json:"capabilities"`
		}
		if json.Unmarshal(event.Result, &negotiated) == nil && negotiated.Vcs != "" {
			c.mu.Lock()
			c.vcs, c.capabilities = negotiated.Vcs, negotiated.Capabilities
			c.mu.Unlock()
		}
		return
	}
	if event.OperationID == "" {
		return
	}
	c.mu.Lock()
	operation := c.pending[event.OperationID]
	if event.Type == "requestCompleted" {
		delete(c.pending, event.OperationID)
	}
	c.mu.Unlock()
	if operation == nil {
		return
	}
	switch event.Type {
	case "requestProgress":
		var progress struct {
			Message    string `json:"message"`
			Percentage *int   `json:"percentage"`
			Output     string `json:"output"`
		}
		if json.Unmarshal(event.Result, &progress) != nil {
			return
		}
		operation.deliverProgress(Progress{Message: progress.Message, Percentage: progress.Percentage, Output: progress.Output})
	case "requestCompleted":
		if len(event.Error) != 0 && string(event.Error) != "null" {
			operation.fail(providerError(event.Error))
			return
		}
		var envelope struct {
			Value json.RawMessage `json:"value"`
		}
		if err := json.Unmarshal(event.Result, &envelope); err != nil {
			operation.fail(fmt.Errorf("buildprovider: decode %s result: %w", operation.Method, err))
		} else if len(envelope.Value) == 0 {
			operation.fail(fmt.Errorf("buildprovider: %s completed without a value", operation.Method))
		} else {
			operation.finish(envelope.Value, nil)
		}
	}
}

// Observe feeds an event of a shared session to this client. A shared owner
// calls it from its own serve loop.
func (c *Client) Observe(event core.BackendEvent) { c.observe(event) }

func (c *Client) forget(id string) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

func (c *Client) failAll(err error) {
	c.mu.Lock()
	c.closed = true
	c.closeErr = err
	pending := c.pending
	c.pending = make(map[string]*Operation)
	c.mu.Unlock()
	for _, operation := range pending {
		operation.fail(err)
	}
}

func (c *Client) ended() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closeErr != nil {
		return c.closeErr
	}
	return ErrClosed
}

// ProviderError is the failure a provider completed an operation with: the
// stable code Core kept or normalised, and the bounded message.
type ProviderError struct {
	Code    string
	Message string
}

func (e *ProviderError) Error() string {
	if e.Code == "" {
		return e.Message
	}
	return e.Code + ": " + e.Message
}

func providerError(raw json.RawMessage) error {
	var failure ProviderError
	var decoded struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &decoded) == nil && decoded.Message != "" {
		failure.Code, failure.Message = decoded.Code, decoded.Message
		return &failure
	}
	return fmt.Errorf("build provider failed: %s", string(raw))
}

var nextOperation atomic.Uint64
