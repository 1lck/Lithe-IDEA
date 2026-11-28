package workbench

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/idehelp"
)

// ideAPIPollInterval is the delay after an empty poll or a transient poll failure.
const ideAPIPollInterval = 200 * time.Millisecond

// ideAPICallTimeout bounds validation, dispatch and the reply to the broker.
const ideAPICallTimeout = 10 * time.Second

// Older brokers expire requests 120 seconds after enqueue but omit the remaining
// budget from poll. Local builds using those revisions use the last known empty
// queue as a lower bound on enqueue time. The pinned broker supplies the budget.
const ideAPIBrokerTimeout = 120 * time.Second

// ideAPIStopTimeout bounds how long closing waits for the loop before it still
// asks the Core to close the connection.
const ideAPIStopTimeout = 5 * time.Second

// ideAPIConnection is one enabled project connection. It exists only while the
// user has enabled it and the project is open.
type ideAPIConnection struct {
	hostID       string
	workspaceKey string
	permissions  core.IDEPermissions
	// exposure is the tool selection the connection was opened with; validation and the
	// helper's catalog use the same list.
	exposure      []core.IDEToolExposure
	configuration json.RawMessage
	cancel        context.CancelFunc
	done          chan struct{}
}

// ideAPIState is the project's connection. Enable and close run on the window thread;
// the loop goroutine reads only the connection it was started with.
type ideAPIState struct {
	mu   sync.Mutex
	conn *ideAPIConnection
	// current is the project's latest Build window execution, the only one the IDE API
	// retains; epoch and nextOperation make its ID (ide_api_dispatch.go). They are
	// window-thread state: a tool call posts its work and reads the answer back.
	current       *ideAPIOperation
	epoch         string
	nextOperation int
}

// ideAPIDirectory is the private directory the Core keeps connection descriptors and
// locks in. It lives in the client's application data, never in the installation.
func (a *App) ideAPIDirectory() string {
	return filepath.Join(a.store.Dir(), "ide-host")
}

// ideAPIOwnerID names this window's connection owner. The native adapter supplies it;
// it is random so a second window never matches another window's owner.
func ideAPIOwnerID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return "ide-api-" + hex.EncodeToString(buf[:]), nil
}

// ideAPIEnable opens the project's connection with the given grants and starts the
// broker loop. helperPath must name an existing lithe-mcp helper. The returned
// configuration is the stdio client configuration to copy; it holds no credential.
func (a *App) ideAPIEnable(p *project, permissions core.IDEPermissions, helperPath string) (json.RawMessage, error) {
	if p == nil || a.kernel == nil {
		return nil, errors.New("no open project")
	}
	p.ideAPI.mu.Lock()
	enabled := p.ideAPI.conn != nil
	p.ideAPI.mu.Unlock()
	if enabled {
		return nil, errors.New("the project already has an IDE API connection")
	}
	owner, err := ideAPIOwnerID()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(p.ctx, ideAPICallTimeout)
	defer cancel()
	exposure := ideAPIToolExposure()
	queueEmptyAt := time.Now() // the descriptor cannot accept calls before open
	opened, err := a.kernel.IDEHostOpen(ctx, core.IDEHostOpenRequest{
		Directory:    a.ideAPIDirectory(),
		WorkspaceKey: p.root,
		HelperPath:   helperPath,
		Permissions:  permissions,
		ToolExposure: exposure,
		OwnerID:      owner,
	})
	if err != nil {
		return nil, err
	}
	loopCtx, loopCancel := context.WithCancel(p.ctx)
	conn := &ideAPIConnection{
		hostID:        opened.HostID,
		workspaceKey:  p.root,
		permissions:   permissions,
		exposure:      exposure,
		configuration: opened.Configuration,
		cancel:        loopCancel,
		done:          make(chan struct{}),
	}
	p.ideAPI.mu.Lock()
	p.ideAPI.conn = conn
	p.ideAPI.mu.Unlock()
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		a.ideAPILoop(loopCtx, conn, queueEmptyAt)
	}()
	return conn.configuration, nil
}

// ideAPIDisable stops the loop and revokes the connection in the Core. It is a no-op
// when the project has no connection. Closing the project calls it.
func (a *App) ideAPIDisable(p *project) {
	if p == nil {
		return
	}
	p.ideAPI.mu.Lock()
	conn := p.ideAPI.conn
	p.ideAPI.conn = nil
	p.ideAPI.mu.Unlock()
	if conn == nil {
		return
	}
	conn.cancel()
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		timer := time.NewTimer(ideAPIStopTimeout)
		defer timer.Stop()
		select {
		case <-conn.done:
		case <-timer.C:
		}
		ctx, cancel := context.WithTimeout(context.Background(), ideAPICallTimeout)
		defer cancel()
		_, _ = a.kernel.IDEHostClose(ctx, conn.hostID)
	}()
}

// ideAPILoop serves one connection until it closes. Core's poll atomically takes an
// unexpired request. Only event-driven hosts that receive a bare ID need a separate claim.
func (a *App) ideAPILoop(ctx context.Context, conn *ideAPIConnection, queueEmptyAt time.Time) {
	defer close(conn.done)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		start := time.Now()
		polled, err := a.kernel.IDEHostPoll(ctx, conn.hostID)
		if err == nil && len(polled.Requests) > 0 {
			for _, request := range polled.Requests {
				deadline := ideAPIRequestDeadline(start, queueEmptyAt, request.RemainingMilliseconds)
				a.ideAPIHandle(ctx, conn, request, deadline)
			}
			timer.Reset(0)
		} else {
			if err == nil {
				queueEmptyAt = start
			}
			timer.Reset(ideAPIPollInterval)
		}
	}
}

// Measure from before poll, so a delayed reply cannot extend either deadline.
func ideAPIRequestDeadline(start, queueEmptyAt time.Time, remaining *int64) time.Time {
	budget := queueEmptyAt.Add(ideAPIBrokerTimeout).Sub(start)
	if remaining != nil {
		budget = time.Duration(max(0, min(*remaining, ideAPICallTimeout.Milliseconds()))) * time.Millisecond
	}
	return start.Add(min(budget, ideAPICallTimeout))
}

// ideAPIHandle validates and executes the request returned by poll exactly once.
func (a *App) ideAPIHandle(ctx context.Context, conn *ideAPIConnection, request core.IDEHostRequest, deadline time.Time) {
	var arguments any = map[string]any{}
	if len(request.Arguments) > 0 {
		arguments = request.Arguments
	}
	callCtx, cancel := context.WithDeadline(ctx, deadline)
	validation, err := a.kernel.IDEHostValidate(callCtx, request.Name, arguments, conn.permissions, conn.exposure)
	var result any
	switch {
	case callCtx.Err() != nil || !time.Now().Before(deadline):
		result = ideAPITimeout()
	case err != nil:
		result = ideAPIFailure("OPERATION_FAILED", err.Error())
	case !validation.OK && validation.Error != nil:
		result = map[string]any{"error": validation.Error}
	case !validation.OK:
		result = ideAPIFailure("INVALID_ARGUMENTS", "The call was rejected")
	default:
		result = a.ideAPIDispatch(callCtx, conn, request.Name, request.Arguments)
	}
	cancel()
	callCtx, cancel = context.WithTimeout(ctx, ideAPICallTimeout)
	_, _ = a.kernel.IDEHostRespond(callCtx, conn.hostID, request.RequestID, result)
	cancel()
}

// ideAPIFailure is the failure shape of a tool result: error with a code and message.
func ideAPIFailure(code, message string) map[string]any {
	return map[string]any{"error": map[string]string{"code": code, "message": message}}
}

// ideAPIHelperPath returns the lithe-mcp helper the connection runs. A packaged build embeds
// it and installs the copy under the client's application data, so the installed bundle is
// never read for it. Development runs may name a staged helper with LITHE_IDE_HELPER, which
// scripts/desktop/desktop-go.sh sets to the Core artifact when it exists.
func (a *App) ideAPIHelperPath() (string, error) {
	if override := os.Getenv("LITHE_IDE_HELPER"); override != "" {
		if info, err := os.Stat(override); err == nil && info.Mode().IsRegular() {
			return filepath.Abs(override)
		}
	}
	return idehelp.Install(a.ideAPIDirectory(), core.IDEHelperName())
}
