package pluginservice

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// LanguageStatus is the preparation state a plugin backend reported for its
// language server (languageServer/setStatus).
type LanguageStatus struct {
	State      string
	Message    string
	Percentage *int
}

// languageSessionState is the part of a language session plugin backends reach:
// the requests they forward and the status they report.
type languageSessionState struct {
	mu      sync.Mutex
	waiters map[string]chan core.BackendEvent
	status  LanguageStatus
	state   string
	ended   bool
}

var nextLanguageOperation atomic.Uint64

// Status returns the latest preparation status the plugin reported.
func (l *LanguageSession) Status() LanguageStatus {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.status
}

func (l *LanguageSession) setStatus(status LanguageStatus) {
	l.mu.Lock()
	l.status = status
	l.mu.Unlock()
}

// request forwards one backend request to the server and waits for its answer.
// Core enforces the declared session policy, gates and timeouts; the answer is
// the requestCompleted event of the language-server session.
func (l *LanguageSession) request(ctx context.Context, kernel Kernel, pluginID, serverID, method string, params json.RawMessage, timeoutMilliseconds int) (json.RawMessage, error) {
	operation := fmt.Sprintf("plugin-server-%d", nextLanguageOperation.Add(1))
	completed := make(chan core.BackendEvent, 1)
	l.mu.Lock()
	if l.ended {
		l.mu.Unlock()
		return nil, ErrBackendUnavailable
	}
	if l.waiters == nil {
		l.waiters = make(map[string]chan core.BackendEvent)
	}
	l.waiters[operation] = completed
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		delete(l.waiters, operation)
		l.mu.Unlock()
	}()
	if _, err := kernel.PluginServerRequest(ctx, l.Session.ID, operation, pluginID, serverID, method, params, timeoutMilliseconds); err != nil {
		return nil, err
	}
	select {
	case event := <-completed:
		return decodeCompletion(event)
	case <-ctx.Done():
		cancelCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = kernel.CancelPluginOperation(cancelCtx, l.Session.ID, operation)
		return nil, ctx.Err()
	}
}

// deliver hands a completion to the request waiting for it.
func (l *LanguageSession) deliver(event core.BackendEvent) bool {
	l.mu.Lock()
	waiter := l.waiters[event.OperationID]
	l.mu.Unlock()
	if waiter == nil {
		return false
	}
	select {
	case waiter <- event:
	default:
	}
	return true
}

// end fails every request still waiting, the way a stopped server does.
func (l *LanguageSession) end() {
	l.mu.Lock()
	l.ended = true
	for _, waiter := range l.waiters {
		select {
		case waiter <- core.BackendEvent{}:
		default:
		}
	}
	l.mu.Unlock()
}

// reference is the context the session was started for.
func (l *LanguageSession) reference() ContextRef {
	return ContextRef{ContextID: l.ContextID, Generation: l.ContextGeneration}
}

// stateParams are the didChangeState params of one lifecycle change.
func (l *LanguageSession) stateParams(state string) json.RawMessage {
	data, _ := json.Marshal(map[string]any{
		"context": l.reference(), "serverID": l.LanguageID, "state": state, "generation": l.Generation,
	})
	return data
}

// languageKey identifies a running plugin-owned server.
type languageKey struct{ plugin, server, context string }

// registerLanguageSession makes a started server reachable by its plugin's backend.
func (s *Service) registerLanguageSession(session *LanguageSession) {
	s.lsMu.Lock()
	defer s.lsMu.Unlock()
	if s.lsSessions == nil {
		s.lsSessions = make(map[languageKey]*LanguageSession)
		s.lsGenerations = make(map[languageKey]uint64)
	}
	key := languageKey{session.PluginID, session.LanguageID, session.ContextID}
	s.lsGenerations[key]++
	session.Generation = s.lsGenerations[key]
	s.lsSessions[key] = session
}

func (s *Service) unregisterLanguageSession(session *LanguageSession) {
	s.lsMu.Lock()
	defer s.lsMu.Unlock()
	key := languageKey{session.PluginID, session.LanguageID, session.ContextID}
	if s.lsSessions[key] == session {
		delete(s.lsSessions, key)
	}
}

// languageSession finds the plugin's running server for a context. foreign is
// true when no such server exists but another plugin runs one with that ID.
func (s *Service) languageSession(pluginID, serverID, contextID string) (session *LanguageSession, foreign bool) {
	s.lsMu.Lock()
	defer s.lsMu.Unlock()
	if found := s.lsSessions[languageKey{pluginID, serverID, contextID}]; found != nil {
		return found, false
	}
	for key := range s.lsSessions {
		if key.server == serverID && key.context == contextID && key.plugin != pluginID {
			return nil, true
		}
	}
	return nil, false
}

// languageState maps Core's lifecycle names to the contract's didChangeState names.
func languageState(state string) string {
	switch state {
	case "created", "processStarting", "initializing":
		return "starting"
	case "ready":
		return "running"
	case "stopped":
		return "stopped"
	case "failed":
		return "crashed"
	}
	return ""
}

// observeLanguage routes the events of a plugin-owned language server that a
// backend cares about before the window's own observer sees them.
func (s *Service) observeLanguage(session *LanguageSession, event core.BackendEvent) {
	switch event.Type {
	case "requestCompleted":
		session.deliver(event)
	case "stateChanged":
		state := languageState(event.State)
		if state == "" {
			return
		}
		session.mu.Lock()
		changed := session.state != state
		session.state = state
		session.mu.Unlock()
		if changed {
			s.notifyBackend(session, notifyLSState, session.stateParams(state))
		}
	case "pluginServerNotification":
		var forwarded struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(event.Result, &forwarded) != nil || forwarded.Method == "" {
			return
		}
		body := map[string]any{
			"context": session.reference(), "serverID": session.LanguageID,
			"generation": session.Generation, "method": forwarded.Method,
		}
		if len(forwarded.Params) > 0 {
			body["params"] = forwarded.Params
		}
		data, _ := json.Marshal(body)
		s.notifyBackend(session, notifyLSNotification, data)
	}
}

// notifyBackend sends a language-server notification to the owning plugin's
// backend when it is running and holds the languageServer grant.
func (s *Service) notifyBackend(session *LanguageSession, method string, params json.RawMessage) {
	if s.Host == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s.Host.Notify(ctx, session.PluginID, methodLSRequest, method, params)
}
