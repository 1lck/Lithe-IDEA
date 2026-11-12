package pluginservice

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ExecuteLanguageCommand sends workspace/executeCommand to a running language
// server on behalf of the host itself and waits for the server's answer.
//
// This is the host's own use of the server, as when it asks a debug server's
// language server for the port of a debug session. It is not a plugin backend's
// request, so Core's plugin-owned session policy does not apply; the server's
// own executeCommand capability does. The answer is the command's result, which
// may be null.
func (s *Service) ExecuteLanguageCommand(ctx context.Context, session *LanguageSession, command string, arguments []any, timeout time.Duration) (json.RawMessage, error) {
	if session == nil {
		return nil, ErrBackendUnavailable
	}
	if arguments == nil {
		arguments = []any{}
	}
	payload, err := json.Marshal(map[string]any{"command": command, "arguments": arguments})
	if err != nil {
		return nil, err
	}
	operation := fmt.Sprintf("host-command-%d", nextLanguageOperation.Add(1))
	completed := make(chan core.BackendEvent, 1)
	session.mu.Lock()
	if session.ended {
		session.mu.Unlock()
		return nil, ErrBackendUnavailable
	}
	if session.waiters == nil {
		session.waiters = make(map[string]chan core.BackendEvent)
	}
	// Registered before the request is sent, so an answer that arrives at once
	// cannot be missed.
	session.waiters[operation] = completed
	session.mu.Unlock()
	defer func() {
		session.mu.Lock()
		delete(session.waiters, operation)
		session.mu.Unlock()
	}()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	if _, err := s.Backend.Request(ctx, session.Session, core.PluginSemanticRequest{
		Operation:   "executeCommand",
		OperationID: operation,
		Command:     payload,
	}); err != nil {
		return nil, err
	}
	select {
	case event := <-completed:
		return decodeCompletion(event)
	case <-ctx.Done():
		cancelCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.kernel.CancelPluginOperation(cancelCtx, session.Session.ID, operation)
		return nil, ctx.Err()
	}
}
