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

// ideAPIPollInterval bounds the wait between two polls of the broker. The Core
// delivers at most one request per poll, so this also bounds the latency.
const ideAPIPollInterval = 200 * time.Millisecond

// ideAPICallTimeout bounds one Core call of the loop (claim, validate, respond).
const ideAPICallTimeout = 10 * time.Second

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
	// operations are the Build executions started through this connection. They are
	// window-thread state: a tool call posts its work and reads the answer back.
	operations    []*ideAPIOperation
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
		a.ideAPILoop(loopCtx, conn)
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

// ideAPILoop runs open → poll → claim → dispatch → respond until ctx ends. It polls on a
// bounded interval and holds no state beyond the connection it was started with.
func (a *App) ideAPILoop(ctx context.Context, conn *ideAPIConnection) {
	defer close(conn.done)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		polled, err := a.kernel.IDEHostPoll(ctx, conn.hostID)
		if err != nil && ctx.Err() != nil {
			return
		}
		for _, request := range polled.Requests {
			a.ideAPIHandle(ctx, conn, request.RequestID)
		}
		timer.Reset(ideAPIPollInterval)
	}
}

// ideAPIHandle claims one request right before the action, validates it against the
// connection's grants in the Core, dispatches it and responds. A request the claim
// does not return is never executed.
func (a *App) ideAPIHandle(ctx context.Context, conn *ideAPIConnection, requestID string) {
	callCtx, cancel := context.WithTimeout(ctx, ideAPICallTimeout)
	claim, err := a.kernel.IDEHostClaim(callCtx, conn.hostID, requestID)
	cancel()
	if err != nil || claim.Request == nil || claim.Request.RemainingMilliseconds <= 0 {
		return
	}
	request := claim.Request
	var arguments any = map[string]any{}
	if len(request.Arguments) > 0 {
		arguments = request.Arguments
	}
	callCtx, cancel = context.WithTimeout(ctx, ideAPICallTimeout)
	validation, err := a.kernel.IDEHostValidate(callCtx, request.Name, arguments, conn.permissions, conn.exposure)
	cancel()
	var result any
	switch {
	case err != nil:
		result = ideAPIFailure("OPERATION_FAILED", err.Error())
	case !validation.OK && validation.Error != nil:
		result = map[string]any{"error": validation.Error}
	case !validation.OK:
		result = ideAPIFailure("INVALID_ARGUMENTS", "The call was rejected")
	default:
		dispatchCtx, stop := context.WithTimeout(ctx, ideAPICallTimeout)
		result = a.ideAPIDispatch(dispatchCtx, conn, request.Name, request.Arguments)
		stop()
	}
	callCtx, cancel = context.WithTimeout(ctx, ideAPICallTimeout)
	_, _ = a.kernel.IDEHostRespond(callCtx, conn.hostID, requestID, result)
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
