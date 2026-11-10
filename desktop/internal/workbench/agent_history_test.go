package workbench

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// agentTestConfigOptions is an adapter-declared catalog: a model, a thought
// level, a permission mode, and a boolean option the panel must not offer
// because Core's setConfigOption command carries a string value.
func agentTestConfigOptions(current string) []map[string]any {
	return []map[string]any{
		{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": current,
			"options": []map[string]any{
				{"value": "model-a", "name": "Model A"},
				{"value": "model-b", "name": "Model B"},
			}},
		{"id": "reasoning_effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": "medium",
			"options": []map[string]any{
				{"value": "medium", "name": "Medium"},
				{"value": "high", "name": "High"},
			}},
		{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "read-only",
			"options": []map[string]any{
				{"value": "read-only", "name": "Read Only"},
				{"value": "auto", "name": "Auto"},
			}},
		{"id": "fast", "name": "Fast mode", "type": "boolean", "currentValue": true},
	}
}

// connectAgentWithHistory opens the scripted connection and confirms one new
// session carrying the Agent's own session settings.
func (h *harness) connectAgentWithHistory(session *fakeAgentSession, canList, canLoad bool) {
	h.t.Helper()
	h.agentClick(h.app.text.Agent.Start)
	session.push(map[string]any{
		"kind": "ready", "canListSessions": canList, "canLoadSessions": canLoad,
	})
	h.await("newSession command", func() bool { return agentSessionHasCommand(session, "newSession", nil) })
	session.push(map[string]any{
		"kind": "sessionCreated", "token": "desktop-1", "sessionId": "session-1",
		"configOptions": agentTestConfigOptions("model-a"),
	})
	h.await("ready session", func() bool {
		p := h.app.project
		return p != nil && p.agent.sessionID == "session-1" && p.agent.phase == agentPhaseReady
	})
}

func agentSessionHasCommand(session *fakeAgentSession, kind string, match func(map[string]any) bool) bool {
	for _, command := range session.commands() {
		if command["kind"] == kind && (match == nil || match(command)) {
			return true
		}
	}
	return false
}

func agentSessionCommand(session *fakeAgentSession, kind string) (map[string]any, bool) {
	for _, command := range session.commands() {
		if command["kind"] == kind {
			return command, true
		}
	}
	return nil, false
}

func agentSessionLastCommand(session *fakeAgentSession, kind string) (map[string]any, bool) {
	var last map[string]any
	for _, command := range session.commands() {
		if command["kind"] == kind {
			last = command
		}
	}
	return last, last != nil
}

func TestAgentHistoryListsRestoresAndContinues(t *testing.T) {
	const secret = "fixture-history-secret"
	t.Setenv("FIXTURE_AGENT_KEY", secret)
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)

	// The panel offers history only after Core declares the capability.
	if !h.shows(h.app.text.Agent.History) {
		t.Fatal("the conversation header has no history entry")
	}
	h.agentClick(h.app.text.Agent.History)
	h.await("listSessions command", func() bool {
		_, ok := agentSessionCommand(session, "listSessions")
		return ok
	})
	listCommand, _ := agentSessionCommand(session, "listSessions")
	token, _ := listCommand["token"].(string)
	if token == "" {
		t.Fatal("listSessions has no correlation token")
	}
	session.push(map[string]any{
		"kind": "sessionsPage", "token": token,
		"sessions": []map[string]any{{"sessionId": "session-2", "title": "Earlier topic"}},
	})
	session.push(map[string]any{
		"kind": "sessions", "token": token,
		"sessions": []map[string]any{
			{"sessionId": "session-2", "title": "Earlier topic", "updatedAt": "2026-11-08T10:00:00Z"},
			{"sessionId": "session-3", "title": "", "updatedAt": ""},
		},
	})
	h.await("history rows", func() bool { return h.shows("Earlier topic") && h.shows(h.app.text.Agent.Untitled) })
	h.settle()

	// Selecting a row asks Core to replay it; a late load token must be ignored.
	h.agentClickPrefix("Earlier topic")
	h.await("loadSession command", func() bool {
		_, ok := agentSessionCommand(session, "loadSession")
		return ok
	})
	loadCommand, _ := agentSessionCommand(session, "loadSession")
	if loadCommand["sessionId"] != "session-2" {
		t.Fatalf("loadSession = %v", loadCommand)
	}
	loadToken, _ := loadCommand["token"].(string)

	// Core replays the transcript before confirming the load.
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-2",
		"update": map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "previous question"}},
	})
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-2",
		"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "previous answer"}},
	})
	session.push(map[string]any{
		"kind": "sessionLoaded", "token": loadToken, "sessionId": "session-2",
		"configOptions": agentTestConfigOptions("model-b"),
	})
	h.await("restored conversation", func() bool {
		p := h.app.project
		return p != nil && p.agent.sessionID == "session-2" && p.agent.phase == agentPhaseReady &&
			h.shows("previous question") && h.shows("previous answer")
	})
	if !h.shows("Model B") {
		t.Fatal("the restored session did not apply the Agent's own model catalog")
	}

	// A stale load answer for another token must not replace the session.
	session.push(map[string]any{"kind": "sessionLoaded", "token": "desktop-load-stale", "sessionId": "session-9"})
	h.settle()
	if p := h.app.project; p.agent.sessionID != "session-2" {
		t.Fatalf("a stale load changed the session to %q", p.agent.sessionID)
	}

	h.typePrompt("follow up")
	h.await("prompt on restored session", func() bool {
		return agentSessionHasCommand(session, "prompt", func(command map[string]any) bool {
			return command["sessionId"] == "session-2" && command["text"] == "follow up"
		})
	})
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-2",
		"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "new answer"}},
	})
	h.await("continued reply", func() bool { return h.shows("new answer") })

	for _, label := range h.driver.Snapshot().Labels {
		if strings.Contains(label.Value, secret) {
			t.Fatal("the history panel shows the provider credential")
		}
	}
	logger.mu.Lock()
	for _, event := range logger.events {
		if strings.Contains(fmt.Sprint(event.Fields), secret) {
			logger.mu.Unlock()
			t.Fatal("a history log event contains the provider credential")
		}
	}
	logger.mu.Unlock()

	h.app.closeProject()
	h.settle()
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("closing the project did not close the restored session")
	}
}

func TestAgentHistoryUnsupportedIsLocalized(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, false, false)

	h.agentClick(h.app.text.Agent.History)
	h.settle()
	if !h.shows(h.app.text.Agent.HistoryUnsupported) {
		t.Fatal("a non-listing Agent did not explain the missing history capability")
	}
	if agentSessionHasCommand(session, "listSessions", nil) {
		t.Fatal("the panel requested history from an Agent that does not list sessions")
	}
}

func TestAgentSessionConfigFollowsCoreConfirmedCatalog(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)

	if !h.shows("Model A") || !h.shows("Medium") || !h.shows("Read Only") {
		t.Fatal("the panel did not show the Agent-declared session settings")
	}
	if h.shows("Fast mode") {
		t.Fatal("a boolean option was offered through a string-only command")
	}
	p := h.app.project
	if len(p.agent.config.options) != 3 {
		t.Fatalf("config options = %d, want the three select options", len(p.agent.config.options))
	}

	model := h.app.text.Agent.ConfigModel
	h.agentClick(model) // the drop-down's trigger
	h.settle()
	h.agentClick("Model B")
	h.await("setConfigOption command", func() bool {
		return agentSessionHasCommand(session, "setConfigOption", func(command map[string]any) bool {
			return command["configId"] == "model" && command["value"] == "model-b" && command["sessionId"] == "session-1"
		})
	})
	if p.agent.config.pendingToken == "" {
		t.Fatal("the panel treated an unconfirmed setting as applied")
	}
	command, _ := agentSessionCommand(session, "setConfigOption")
	token, _ := command["token"].(string)
	session.push(map[string]any{
		"kind": "sessionConfigured", "token": token, "sessionId": "session-1",
		"configOptions": agentTestConfigOptions("model-b"),
	})
	h.await("confirmed setting", func() bool {
		return p.agent.config.pendingToken == "" && h.shows("Model B")
	})

	// A failure keeps the confirmed value and is presented locally.
	h.agentClick(model)
	h.settle()
	h.agentClick("Model A")
	h.await("second setConfigOption", func() bool {
		commands := session.commands()
		count := 0
		var last map[string]any
		for _, candidate := range commands {
			if candidate["kind"] == "setConfigOption" {
				count++
				last = candidate
			}
		}
		return count == 2 && last["token"] != ""
	})
	command, _ = agentSessionLastCommand(session, "setConfigOption")
	token, _ = command["token"].(string)
	session.push(map[string]any{"kind": "requestFailed", "token": token, "sessionId": "session-1", "message": ""})
	h.await("config failure", func() bool {
		return p.agent.config.pendingToken == "" && p.agent.config.err == h.app.text.Agent.ConfigFailed
	})
	if p.agent.config.options[0].Current != "model-b" {
		t.Fatal("a failed setting change replaced the confirmed value")
	}
}

func TestAgentAuthenticationStateIsPresented(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)

	session.push(map[string]any{"kind": "authenticationRequired"})
	h.await("authentication state", func() bool {
		return h.app.project.agent.auth == agentAuthRequired
	})
	if !h.shows(h.app.text.Agent.StatusSignIn) {
		t.Fatalf("the panel did not explain the sign-in requirement")
	}
	if h.shows(h.app.text.Agent.StatusReady) {
		t.Fatal("the panel claimed readiness while the Agent requires sign-in")
	}
	if p := h.app.project; p.agent.sessionID != "session-1" || p.agent.phase != agentPhaseFailed {
		t.Fatalf("sign-in state = %v phase=%v", p.agent.auth, p.agent.phase)
	}

	session.push(map[string]any{"kind": "authenticating"})
	h.await("authenticating", func() bool { return h.app.project.agent.auth == agentAuthSigningIn })
	if !h.shows(h.app.text.Agent.StatusSigningIn) {
		t.Fatal("the panel did not show the Agent's sign-in progress")
	}
	session.push(map[string]any{"kind": "account", "account": map[string]any{"email": "person@example.test", "plan": "plus"}})
	h.await("authenticated", func() bool { return h.app.project.agent.auth == agentAuthNone })
	if h.shows("person@example.test") {
		t.Fatal("the panel displayed account details it does not own")
	}
}

func TestAgentHistoryStateIsProjectScopedAndLateEventsIgnored(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)
	h.agentClick(h.app.text.Agent.History)
	h.await("listSessions command", func() bool {
		_, ok := agentSessionCommand(session, "listSessions")
		return ok
	})
	command, _ := agentSessionCommand(session, "listSessions")
	token, _ := command["token"].(string)

	// Replacing the project drops the previous connection and its history view.
	h.open(t.TempDir())
	h.settle()
	if h.app.project == nil || h.app.project.agent.history.open || len(h.app.project.agent.history.sessions) != 0 {
		t.Fatal("the replacement project inherited the history panel state")
	}
	session.push(map[string]any{
		"kind": "sessions", "token": token,
		"sessions": []map[string]any{{"sessionId": "session-old", "title": "Old project topic"}},
	})
	session.push(map[string]any{"kind": "sessionLoaded", "token": "desktop-load-old", "sessionId": "session-old"})
	h.settle()
	if h.shows("Old project topic") {
		t.Fatal("a late history answer crossed into the replacement project")
	}
	if p := h.app.project; p.agent.sessionID != "" || p.agent.history.restoreSession != "" {
		t.Fatal("a late history answer changed the replacement project's session")
	}
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("replacing the project did not close the previous Agent session")
	}
}

func TestAgentHistoryLoadFailureKeepsCurrentConversation(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)

	// Build conversation A.
	h.typePrompt("A question")
	h.await("A prompt", func() bool {
		return agentSessionHasCommand(session, "prompt", func(command map[string]any) bool {
			return command["sessionId"] == "session-1" && command["text"] == "A question"
		})
	})
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-1",
		"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "A answer"}},
	})
	h.await("A reply", func() bool { return h.shows("A answer") })
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "stopReason": "end_turn"})
	h.await("A idle", func() bool { return h.app.project.agent.phase == agentPhaseReady })
	aBytes := h.app.project.agent.bytes

	// Start restoring B and let part of its replay arrive.
	h.agentClick(h.app.text.Agent.History)
	h.await("history list", func() bool { return agentSessionHasCommand(session, "listSessions", nil) })
	listCommand, _ := agentSessionLastCommand(session, "listSessions")
	listToken, _ := listCommand["token"].(string)
	session.push(map[string]any{
		"kind": "sessions", "token": listToken,
		"sessions": []map[string]any{{"sessionId": "session-2", "title": "Conversation B"}},
	})
	h.await("B row", func() bool { return h.shows("Conversation B") })
	h.settle()
	h.agentClickPrefix("Conversation B")
	h.await("B load", func() bool {
		return agentSessionHasCommand(session, "loadSession", func(command map[string]any) bool {
			return command["sessionId"] == "session-2"
		})
	})
	loadCommand, _ := agentSessionLastCommand(session, "loadSession")
	loadToken, _ := loadCommand["token"].(string)
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-2",
		"update": map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "B partial question"}},
	})
	session.push(map[string]any{
		"kind": "update", "sessionId": "session-2",
		"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "B partial answer"}},
	})
	h.await("B partial replay", func() bool { return h.app.project.agent.history.restoring() })

	// Core rejects the load. A must remain exactly as it was, and B's partial
	// replay must not leak into A's transcript.
	session.push(map[string]any{"kind": "requestFailed", "token": loadToken, "sessionId": "session-2", "message": ""})
	h.await("load failure", func() bool {
		p := h.app.project
		return p.agent.history.listErr == h.app.text.Agent.HistoryRestoreFailed &&
			!p.agent.history.restoring() && p.agent.phase == agentPhaseReady
	})
	p := h.app.project
	if p.agent.sessionID != "session-1" {
		t.Fatalf("failed load changed the session to %q", p.agent.sessionID)
	}
	if p.agent.bytes != aBytes || len(p.agent.messages) != 2 ||
		p.agent.messages[0].Text != "A question" || p.agent.messages[1].Text != "A answer" {
		t.Fatalf("failed load changed conversation A: bytes=%d messages=%+v", p.agent.bytes, p.agent.messages)
	}
	if h.shows("B partial question") || h.shows("B partial answer") {
		t.Fatal("B's partial replay leaked into conversation A")
	}
	if !h.shows("A question") || !h.shows("A answer") {
		t.Fatal("conversation A disappeared after the failed load")
	}
	if len(p.agent.config.options) != 3 || p.agent.config.options[0].Current != "model-a" {
		t.Fatalf("failed load changed conversation A's settings: %+v", p.agent.config.options)
	}
	if len(p.agent.history.replayMessages) != 0 || p.agent.history.replayBytes != 0 {
		t.Fatal("failed load kept B's replay buffer")
	}
}

func TestAgentNewConversationFailureKeepsCurrentSettings(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgentWithHistory(session, true, true)

	before := len(session.commands())
	h.agentClick(h.app.text.Agent.NewChat)
	h.await("second newSession", func() bool {
		count := 0
		for _, command := range session.commands() {
			if command["kind"] == "newSession" {
				count++
			}
		}
		return len(session.commands()) > before && count == 2
	})
	command, _ := agentSessionLastCommand(session, "newSession")
	token, _ := command["token"].(string)
	session.push(map[string]any{"kind": "requestFailed", "token": token, "message": "new conversation failed"})
	h.await("new conversation failure", func() bool {
		p := h.app.project
		return p.agent.phase == agentPhaseFailed && p.agent.pending == ""
	})
	p := h.app.project
	if p.agent.sessionID != "session-1" {
		t.Fatalf("failed new conversation changed the session to %q", p.agent.sessionID)
	}
	if len(p.agent.config.options) != 3 || p.agent.config.options[0].Current != "model-a" {
		t.Fatalf("failed new conversation cleared the confirmed settings: %+v", p.agent.config.options)
	}
}

func TestMergeAgentSessionsBoundsRetainedRowsAndCapacity(t *testing.T) {
	incoming := make([]agentSessionSummary, 500)
	for i := range incoming {
		incoming[i] = agentSessionSummary{SessionID: fmt.Sprintf("session-%d", i)}
	}
	merged := mergeAgentSessions(nil, incoming, agentHistoryLimit)
	if len(merged) != agentHistoryLimit {
		t.Fatalf("merged rows = %d, want %d", len(merged), agentHistoryLimit)
	}
	if cap(merged) > agentHistoryLimit {
		t.Fatalf("merged capacity = %d, want at most %d", cap(merged), agentHistoryLimit)
	}
}
