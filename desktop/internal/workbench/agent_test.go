package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// fakeAgentSession is a scripted ACP connection. It records the commands the
// panel sends and delivers events the test pushes.
type fakeAgentSession struct {
	mu     sync.Mutex
	sent   []map[string]any
	events chan json.RawMessage
	closed chan struct{}
	once   sync.Once
}

func newFakeAgentSession() *fakeAgentSession {
	return &fakeAgentSession{events: make(chan json.RawMessage, 16), closed: make(chan struct{})}
}

func (s *fakeAgentSession) Send(raw json.RawMessage) error {
	var command map[string]any
	if err := json.Unmarshal(raw, &command); err != nil {
		return err
	}
	s.mu.Lock()
	s.sent = append(s.sent, command)
	s.mu.Unlock()
	return nil
}

func (s *fakeAgentSession) Next(ctx context.Context) (json.RawMessage, error) {
	select {
	case event := <-s.events:
		return event, nil
	case <-s.closed:
		return nil, core.ErrAgentClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (s *fakeAgentSession) Close() {
	s.once.Do(func() { close(s.closed) })
}

func (s *fakeAgentSession) push(event any) {
	raw, err := json.Marshal(event)
	if err != nil {
		panic(err)
	}
	s.events <- raw
}

func (s *fakeAgentSession) commands() []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]map[string]any(nil), s.sent...)
}

// fakeAgentKernel answers detection and provider discovery from the test, and
// returns the scripted session from OpenAgentSession.
type fakeAgentKernel struct {
	mu        sync.Mutex
	status    core.AgentManagementStatus
	config    *core.AIConfiguration
	session   *fakeAgentSession
	opened    chan json.RawMessage
	openErr   error
	installFn func(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error)
}

func (k *fakeAgentKernel) ReadAgentManagementStatus(context.Context, string) (core.AgentManagementStatus, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.status, nil
}

func (k *fakeAgentKernel) setStatus(status core.AgentManagementStatus) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.status = status
}

func (k *fakeAgentKernel) AIConfigurationSources(context.Context, string, string, map[string]string) ([]core.AIConfigurationFile, error) {
	return nil, nil
}

func (k *fakeAgentKernel) ParseAIConfiguration(context.Context, core.AIConfigurationParseRequest) (*core.AIConfiguration, error) {
	return k.config, nil
}

func (k *fakeAgentKernel) InstallAgentAdapter(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
	if k.installFn == nil {
		return core.AgentAdapterInstallResult{}, nil, errors.New("install is not scripted")
	}
	return k.installFn(ctx, dataDirectory, agentID, progress)
}

func (k *fakeAgentKernel) OpenAgentSession(launch json.RawMessage) (AgentSession, error) {
	if k.openErr != nil {
		return nil, k.openErr
	}
	if k.opened != nil {
		k.opened <- append(json.RawMessage(nil), launch...)
	}
	return k.session, nil
}

func newAgentHarness(t *testing.T, kernel AgentKernel) *harness {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.agentKernel = kernel
	return h
}

func (h *harness) openAssistant() {
	h.t.Helper()
	h.app.chrome.open[slotRightTop] = catalogIndex[itemAssistant]
	h.app.invalidator.Invalidate()
	h.settle()
	h.settle()
}

// agentHit finds a control of the Agent panel by its accessible name.
func (h *harness) agentHit(name string) (gfx.Rect, bool) {
	hit, ok := h.findPageHit(name)
	return hit.Bounds, ok
}

func (h *harness) agentClick(name string) {
	h.t.Helper()
	// Not clickNamed: that settles, which waits for the background work the click may start.
	point := center(h.pageHit(name).Bounds)
	if err := h.driver.Click(point.X, point.Y); err != nil {
		h.t.Fatalf("click %q: %v", name, err)
	}
}

// agentClickPrefix clicks the front-most control whose name starts with prefix.
func (h *harness) agentClickPrefix(prefix string) {
	h.t.Helper()
	hits := h.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hit := hits[i]; strings.HasPrefix(hit.Label, prefix) && !hit.IsLabel && !hit.ID.IsZero() {
			point := center(hit.Bounds)
			if err := h.driver.Click(point.X, point.Y); err != nil {
				h.t.Fatalf("click %q: %v", hit.Label, err)
			}
			return
		}
	}
	h.t.Fatalf("no control named %q...", prefix)
}

// await pumps frames until condition is true, or fails at the deadline. It
// observes the driver's wake channel rather than sleeping.
func (h *harness) await(what string, condition func() bool) {
	h.t.Helper()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for {
		if condition() {
			return
		}
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				h.t.Fatalf("pump while waiting for %s: %v", what, err)
			}
		case <-deadline.C:
			h.t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func installedAgentStatus() core.AgentManagementStatus {
	version := "1.0.0"
	return core.AgentManagementStatus{Agents: []core.AgentCatalogStatus{{
		ID: "codex-acp", Name: "Codex", Protocol: "responses", Verified: true,
		InstalledVersion: &version,
	}}}
}

func uninstalledAgentStatus() core.AgentManagementStatus {
	return core.AgentManagementStatus{Agents: []core.AgentCatalogStatus{{
		ID: "codex-acp", Name: "Codex", Protocol: "responses", Verified: true,
	}}}
}

func fixtureAgentConfiguration() *core.AIConfiguration {
	return &core.AIConfiguration{
		Model: "fixture-model",
		Provider: &core.AIConfigurationProvider{
			ID: "imported-codex", Name: "Fixture provider",
			Endpoint: "https://example.test/v1", Model: "fixture-model",
			APIProtocol: "responses", Authentication: "bearer", Source: "codex", RequiresAPIKey: true,
		},
		HasCredential: true,
		Credential:    &core.AIConfigurationCredential{Kind: "environment", Name: "FIXTURE_AGENT_KEY"},
	}
}

// connectAgent drives the setup panel through a scripted connection.
func (h *harness) connectAgent(session *fakeAgentSession) {
	h.t.Helper()
	h.agentClick(h.app.text.Agent.Start)
	session.push(map[string]any{"kind": "ready"})
	h.await("newSession command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "newSession" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "sessionCreated", "token": "desktop-1", "sessionId": "session-1"})
	h.await("ready session", func() bool {
		p := h.app.project
		return p != nil && p.agent.sessionID == "session-1" && p.agent.phase == agentPhaseReady
	})
}

func (h *harness) typePrompt(value string) {
	h.t.Helper()
	input, ok := h.agentHit(h.app.text.Agent.MessageLabel)
	if !ok {
		h.t.Fatal("the composer is not shown")
	}
	if err := h.driver.Click(center(input).X, center(input).Y); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Type(value); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyEnter, ui.Primary); err != nil {
		h.t.Fatal(err)
	}
}

func TestAgentPanelDiscoversProviderStartsSessionAndStreams(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{
		status: installedAgentStatus(), config: fixtureAgentConfiguration(),
		session: session, opened: make(chan json.RawMessage, 1),
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()

	if !h.shows("Fixture provider") || !h.shows("https://example.test/v1") {
		t.Fatal("the panel did not show the discovered provider")
	}
	h.agentClick(h.app.text.Agent.Start)
	select {
	case launch := <-kernel.opened:
		var decoded map[string]any
		if err := json.Unmarshal(launch, &decoded); err != nil {
			t.Fatal(err)
		}
		if decoded["agentId"] != "codex-acp" || decoded["cwd"] == "" {
			t.Fatalf("launch = %v", decoded)
		}
		provider, _ := decoded["provider"].(map[string]any)
		if provider["baseUrl"] != "https://example.test/v1" || provider["apiKey"] != "fixture-secret" {
			t.Fatalf("launch provider = %v", provider)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the panel did not open a session")
	}

	session.push(map[string]any{"kind": "ready"})
	h.await("newSession command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "newSession" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "sessionCreated", "token": "desktop-1", "sessionId": "session-1"})
	h.await("ready session", func() bool {
		p := h.app.project
		return p != nil && p.agent.sessionID == "session-1" && p.agent.phase == agentPhaseReady
	})

	input, ok := h.agentHit(h.app.text.Agent.MessageLabel)
	if !ok {
		t.Fatal("the composer is not shown")
	}
	if err := h.driver.Click(center(input).X, center(input).Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("hello"); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyEnter, ui.Primary); err != nil {
		t.Fatal(err)
	}
	h.await("prompt command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				return command["text"] == "hello" && command["sessionId"] == "session-1"
			}
		}
		return false
	})

	session.push(map[string]any{"kind": "update", "sessionId": "session-1", "update": map[string]any{
		"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "fixture reply"},
	}})
	h.await("streamed reply", func() bool { return h.shows("fixture reply") })

	session.push(map[string]any{"kind": "permission", "sessionId": "session-1", "requestId": "permission-1", "request": map[string]any{
		"toolCall": map[string]any{"title": "Run tests"},
		"options": []any{
			map[string]any{"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"},
			map[string]any{"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
		},
	}})
	h.await("permission card", func() bool { return h.shows("Run tests") })
	for _, command := range session.commands() {
		if command["kind"] == "permission" {
			t.Fatal("the panel answered a permission request without the user")
		}
	}
	h.agentClick("Allow Once")
	h.await("permission command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "permission" {
				return command["requestId"] == "permission-1" && command["optionId"] == "allow_once"
			}
		}
		return false
	})

	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "stopReason": "end_turn"})
	h.await("finished turn", func() bool {
		p := h.app.project
		return p != nil && p.agent.phase == agentPhaseReady
	})

	// Closing the project must close the Core connection and clear the secret.
	h.app.closeProject()
	h.settle()
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the Agent session was not closed with the project")
	}
	if h.app.project != nil {
		t.Fatal("the project did not close")
	}
}

func TestAgentPanelKeepsProviderWithoutCredentialDisabled(t *testing.T) {
	session := newFakeAgentSession()
	config := fixtureAgentConfiguration()
	config.HasCredential = false
	config.Credential = nil
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: config, session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()

	if !h.shows(h.app.text.Agent.MissingKey) {
		t.Fatal("the panel did not explain the missing credential")
	}
	p := h.app.project
	if p == nil || p.canStartAgent() {
		t.Fatal("a provider without a credential must not be startable")
	}
}

func TestAgentStartFailureIsShown(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	kernel := &fakeAgentKernel{
		status: installedAgentStatus(), config: fixtureAgentConfiguration(),
		session: newFakeAgentSession(), openErr: errors.New("fixture launch failed"),
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.agentClick(h.app.text.Agent.Start)
	h.await("start failure", func() bool {
		p := h.app.project
		return p != nil && p.agent.err == h.app.text.Agent.ErrorConnection
	})
	if !h.shows(h.app.text.Agent.ErrorConnection) {
		t.Fatal("the panel did not show the launch failure")
	}
}

func TestAgentCancelWaitsForTurnFinished(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)

	h.typePrompt("hello")
	h.await("prompt command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				return true
			}
		}
		return false
	})
	h.agentClick(h.app.text.Agent.Stop)
	h.await("cancel command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "cancel" {
				return command["sessionId"] == "session-1"
			}
		}
		return false
	})
	p := h.app.project
	if p == nil || p.agent.phase != agentPhaseCancelling {
		t.Fatalf("phase = %v, want cancelling", p.agent.phase)
	}
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "stopReason": "cancelled"})
	h.await("cancelled turn", func() bool { return h.app.project.agent.phase == agentPhaseReady })
	if p.agent.permission != nil {
		t.Fatal("a cancelled turn kept a permission request")
	}
}

func TestAgentRequestFailureAndStopAreShown(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)

	session.push(map[string]any{"kind": "requestFailed", "sessionId": "session-1", "message": "fixture request failed"})
	h.await("request failure", func() bool {
		p := h.app.project
		return p != nil && p.agent.err == "fixture request failed" && p.agent.phase == agentPhaseFailed
	})
	if !h.shows("fixture request failed") {
		t.Fatal("the panel did not show the request failure")
	}

	session.push(map[string]any{"kind": "stopped", "message": "fixture stopped"})
	h.await("stopped connection", func() bool {
		p := h.app.project
		return p != nil && p.agent.conn == nil && p.agent.err == "fixture stopped"
	})
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the stopped session was not closed")
	}
}

func TestAgentTranscriptStaysBounded(t *testing.T) {
	state := newAgentState()
	project := &project{agent: state}
	app := &App{}
	for i := 0; i < agentMessageLimit+20; i++ {
		project.agent.messages = append(project.agent.messages, agentMessage{Role: agentRoleUser, Text: "message"})
		project.agent.bytes += len("message")
	}
	app.trimAgentTranscript(project)
	if len(project.agent.messages) != agentMessageLimit {
		t.Fatalf("messages = %d, want %d", len(project.agent.messages), agentMessageLimit)
	}
	if project.agent.bytes != agentMessageLimit*len("message") {
		t.Fatalf("bytes = %d", project.agent.bytes)
	}
}

func TestAgentTranscriptLimitPreservesUTF8(t *testing.T) {
	for _, appendToExisting := range []bool{false, true} {
		t.Run(fmt.Sprint(appendToExisting), func(t *testing.T) {
			p := &project{agent: newAgentState()}
			p.agent.phase = agentPhaseBusy
			prefix := strings.Repeat("a", agentMessageTextLimit-1)
			chunk := prefix + "中文😀"
			if appendToExisting {
				p.agent.messages = []agentMessage{{Role: agentRoleAssistant, Text: prefix, Streaming: true}}
				p.agent.bytes = len(prefix)
				chunk = "中文😀"
			}
			raw, err := json.Marshal(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]string{"type": "text", "text": chunk}})
			if err != nil {
				t.Fatal(err)
			}
			(&App{}).applyAgentUpdate(p, "", raw)
			got := p.agent.messages[0].Text
			if !utf8.ValidString(got) || got != prefix || p.agent.bytes != len(got) {
				t.Fatalf("invalid display truncation: valid=%v length=%d accounted=%d", utf8.ValidString(got), len(got), p.agent.bytes)
			}
		})
	}
}

func TestAgentCredentialLocatorResolution(t *testing.T) {
	texts := map[string]string{
		"auth":   `{"OPENAI_API_KEY":"fixture-secret","nested":{"key":"nested-secret"}}`,
		"config": "model = 'fixture'\n",
	}
	environment := map[string]string{"COMPANY_KEY": "environment-secret"}
	value, err := resolveAgentCredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"OPENAI_API_KEY"}})
	if err != nil || value != "fixture-secret" {
		t.Fatalf("auth locator = %q, %v", value, err)
	}
	value, err = resolveAgentCredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"nested", "key"}})
	if err != nil || value != "nested-secret" {
		t.Fatalf("nested locator = %q, %v", value, err)
	}
	value, err = resolveAgentCredential(texts, environment, &core.AIConfigurationCredential{Kind: "environment", Name: "COMPANY_KEY"})
	if err != nil || value != "environment-secret" {
		t.Fatalf("environment locator = %q, %v", value, err)
	}
	if _, err := resolveAgentCredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "config", Path: []string{"experimental_bearer_token"}}); err == nil {
		t.Fatal("a TOML file locator must be reported as unsupported")
	}
	if _, err := resolveAgentCredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"missing"}}); err == nil {
		t.Fatal("a missing JSON path must fail")
	}
}

// fileAgentKernel uses the real Core parser with files the test writes.
type fileAgentKernel struct {
	client *core.Client
	files  []core.AIConfigurationFile
}

func (k fileAgentKernel) ReadAgentManagementStatus(context.Context, string) (core.AgentManagementStatus, error) {
	return core.AgentManagementStatus{}, nil
}

func (k fileAgentKernel) AIConfigurationSources(_ context.Context, source, _ string, _ map[string]string) ([]core.AIConfigurationFile, error) {
	if source != "codex" {
		return nil, nil
	}
	return k.files, nil
}

func (k fileAgentKernel) ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error) {
	return k.client.ParseAIConfiguration(ctx, request)
}

func (k fileAgentKernel) InstallAgentAdapter(context.Context, string, string, func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
	return core.AgentAdapterInstallResult{}, nil, errors.New("not used")
}

func (k fileAgentKernel) OpenAgentSession(json.RawMessage) (AgentSession, error) {
	return nil, errors.New("not used")
}

func TestAgentProviderDiscoveryUsesRealCoreParser(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config.toml")
	authPath := filepath.Join(directory, "auth.json")
	if err := os.WriteFile(configPath, []byte("model = 'fixture-model'\nmodel_provider = 'gateway'\n[model_providers.gateway]\nbase_url = 'https://example.test/v1'\nrequires_openai_auth = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(authPath, []byte(`{"OPENAI_API_KEY":"fixture-file-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	app := &App{agentKernel: fileAgentKernel{client: core.NewClient(), files: []core.AIConfigurationFile{
		{File: "config", Path: configPath},
		{File: "auth", Path: authPath},
	}}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	providers, issues := app.discoverAgentProviders(ctx)
	if issues["codex"] != "" {
		t.Fatalf("codex issue = %q", issues["codex"])
	}
	if len(providers["codex"]) != 1 {
		t.Fatalf("codex providers = %d, want 1", len(providers["codex"]))
	}
	provider := providers["codex"][0]
	if provider.Endpoint != "https://example.test/v1" || provider.Model != "fixture-model" ||
		provider.Protocol != "responses" || provider.APIKey != "fixture-file-secret" {
		t.Fatalf("provider endpoint=%q model=%q protocol=%q keyPresent=%v", provider.Endpoint, provider.Model, provider.Protocol, provider.APIKey != "")
	}
}

func TestAgentSessionClosesWhenProjectIsReplaced(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)

	h.open(t.TempDir())
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("replacing the project did not close the Agent session")
	}
	if h.app.project == nil || h.app.project.agent.conn != nil {
		t.Fatal("the replacement project kept the old Agent connection")
	}
}

func TestAgentTranscriptPaintsOnlyTheVisibleWindow(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)

	p := h.app.project
	for i := 0; i < 100; i++ {
		p.agent.messages = append(p.agent.messages, agentMessage{
			Role: agentRoleAssistant, Text: fmt.Sprintf("message %d", i),
		})
	}
	h.app.invalidator.Invalidate()
	h.settle()
	// A list measures the rows it shows and places the ones it follows or scrolls to in
	// the paints after, so each request settles over a few frames.
	frames := func() {
		for i := 0; i < 3; i++ {
			h.app.invalidator.Invalidate()
			h.settle()
		}
	}
	frames()
	if !h.shows("message 99") {
		t.Fatal("a transcript that follows its end did not show the last message")
	}
	if h.shows("message 0") || h.shows("message 50") {
		t.Fatal("the transcript painted rows outside the virtual window")
	}
	painted := 0
	for _, label := range h.driver.Snapshot().Labels {
		if strings.HasPrefix(label.Value, "message ") {
			painted++
		}
	}
	if painted == 0 || painted > 20 {
		t.Fatalf("the transcript painted %d rows of 100, want only the window", painted)
	}
}

func TestAgentPermissionIsNotAnsweredOnCancel(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)
	h.typePrompt("hello")
	h.await("prompt command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "permission", "sessionId": "session-1", "requestId": "permission-1", "request": map[string]any{
		"toolCall": map[string]any{"title": "Run tests"},
		"options":  []any{map[string]any{"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"}},
	}})
	h.await("permission card", func() bool { return h.shows("Run tests") })
	h.agentClick(h.app.text.Agent.Stop)
	h.await("cancel command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "cancel" {
				return true
			}
		}
		return false
	})
	for _, command := range session.commands() {
		if command["kind"] == "permission" {
			t.Fatal("cancelling the turn answered the permission request")
		}
	}
	if p := h.app.project; p == nil || p.agent.permission != nil {
		t.Fatal("cancelling the turn kept the permission request")
	}
}

func TestAgentProjectCloseWhileBusyClosesSession(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)
	h.typePrompt("hello")
	h.await("prompt command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				return true
			}
		}
		return false
	})
	h.app.closeProject()
	h.settle()
	select {
	case <-session.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("closing a busy project did not close the Agent session")
	}
	if h.app.project != nil {
		t.Fatal("the busy project did not close")
	}
}

func TestAgentCredentialsStayInMemoryAndOutOfLogs(t *testing.T) {
	const secret = "fixture-memory-secret"
	t.Setenv("FIXTURE_AGENT_KEY", secret)
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.open(t.TempDir())
	h.openAssistant()
	h.connectAgent(session)

	p := h.app.project
	if p == nil || len(p.agent.providers["codex"]) != 1 || p.agent.providers["codex"][0].APIKey != secret {
		t.Fatal("the discovered credential is not held in memory")
	}
	h.typePrompt("hello")
	h.await("prompt command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "permission", "sessionId": "session-1", "requestId": "permission-1", "request": map[string]any{
		"toolCall": map[string]any{"title": "Run tests"},
		"options":  []any{map[string]any{"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"}},
	}})
	h.await("permission card", func() bool { return h.shows("Run tests") })
	h.agentClick(h.app.text.Agent.Stop)
	h.await("cancel command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "cancel" {
				return true
			}
		}
		return false
	})

	providers := p.agent.providers
	h.app.closeAgent(p)
	if providers["codex"][0].APIKey != "" {
		t.Fatal("closing the project did not clear the in-memory credential")
	}
	logger.mu.Lock()
	for _, event := range logger.events {
		if strings.Contains(fmt.Sprint(event.Fields), secret) {
			logger.mu.Unlock()
			t.Fatal("a log event contains the provider credential")
		}
	}
	logger.mu.Unlock()
	for _, label := range h.driver.Snapshot().Labels {
		if strings.Contains(label.Value, secret) {
			t.Fatal("the panel shows the provider credential")
		}
	}
}

func TestAgentInstallRequiresExplicitClickAndReloadsStatus(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	started := make(chan struct{})
	release := make(chan struct{})
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: uninstalledAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	kernel.installFn = func(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
		close(started)
		progress(core.AgentInstallProgress{Stage: "downloading", DownloadedBytes: 1024, BytesPerSecond: 2048, ElapsedMilliseconds: 500})
		select {
		case <-release:
		case <-ctx.Done():
			return core.AgentAdapterInstallResult{}, nil, ctx.Err()
		}
		kernel.setStatus(installedAgentStatus())
		return core.AgentAdapterInstallResult{AgentID: agentID, InstalledVersion: "1.0.0"}, nil, nil
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()

	select {
	case <-started:
		t.Fatal("opening the panel started an adapter install")
	default:
	}
	if !h.shows(h.app.text.Agent.Install) {
		t.Fatal("the panel did not offer an install for the missing adapter")
	}
	h.agentClick(h.app.text.Agent.Install)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("the explicit install click did not start an install")
	}
	h.await("install progress", func() bool {
		p := h.app.project
		return p != nil && p.agent.installProgress.Stage == "downloading" && h.shows(h.app.text.Agent.InstallDownloading)
	})
	if !h.shows("1.0 KB") {
		t.Fatal("the install card did not show the real downloaded bytes")
	}
	close(release)
	h.await("installed status", func() bool {
		p := h.app.project
		return p != nil && p.agent.installing == "" && len(p.agent.agents) == 1 &&
			p.agent.agents[0].InstalledVersion != nil && p.canStartAgent()
	})
}

func TestAgentInstallCanBeCancelled(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	started := make(chan struct{})
	var calls atomic.Int32
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: uninstalledAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	kernel.installFn = func(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
		calls.Add(1)
		close(started)
		progress(core.AgentInstallProgress{Stage: "downloading", DownloadedBytes: 512, ElapsedMilliseconds: 200})
		<-ctx.Done()
		return core.AgentAdapterInstallResult{}, nil, ctx.Err()
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.agentClick(h.app.text.Agent.Install)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("the install did not start")
	}
	h.await("install progress", func() bool { return h.shows(h.app.text.Agent.InstallDownloading) })
	h.agentClick(h.app.text.Agent.InstallCancel)
	h.await("cancelled install", func() bool {
		p := h.app.project
		return p != nil && p.agent.installing == "" && p.agent.installErr == h.app.text.Agent.InstallCancelled
	})
	if calls.Load() != 1 {
		t.Fatalf("install calls = %d, want 1", calls.Load())
	}
}

func TestAgentInstallFailureCanBeRetried(t *testing.T) {
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	var calls atomic.Int32
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: uninstalledAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	kernel.installFn = func(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
		if calls.Add(1) == 1 {
			return core.AgentAdapterInstallResult{}, nil, errors.New("fixture install failed")
		}
		kernel.setStatus(installedAgentStatus())
		return core.AgentAdapterInstallResult{AgentID: agentID, InstalledVersion: "1.0.0"}, nil, nil
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.agentClick(h.app.text.Agent.Install)
	h.await("install failure", func() bool {
		p := h.app.project
		return p != nil && p.agent.installing == "" &&
			p.agent.installErr == h.app.text.Agent.InstallFailed(h.app.text.Agent.InstallFailedDetail) &&
			h.shows(h.app.text.Agent.InstallFailed(h.app.text.Agent.InstallFailedDetail))
	})
	if _, ok := h.agentHit(h.app.text.Agent.InstallRetry); !ok {
		t.Fatal("the failed install has no retry control")
	}
	h.agentClick(h.app.text.Agent.InstallRetry)
	h.await("retried install", func() bool {
		p := h.app.project
		return p != nil && p.agent.installing == "" && len(p.agent.agents) == 1 && p.agent.agents[0].InstalledVersion != nil
	})
	if calls.Load() != 2 {
		t.Fatalf("install calls = %d, want 2", calls.Load())
	}
}

func TestAgentProviderWithoutCredentialExplainsDisabledStart(t *testing.T) {
	config := fixtureAgentConfiguration()
	config.HasCredential = false
	config.Credential = nil
	config.Provider.RequiresAPIKey = false
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: config, session: newFakeAgentSession()}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()

	p := h.app.project
	if p == nil || len(p.agent.providers["codex"]) != 1 || !p.agent.providers["codex"][0].MissingKey {
		t.Fatal("a provider without a credential must be marked missing its key")
	}
	if p.canStartAgent() {
		t.Fatal("a provider without a credential must not be startable")
	}
	if !h.shows(h.app.text.Agent.MissingKey) {
		t.Fatal("the panel did not explain why Start is disabled")
	}
}

func TestAgentProviderProtocolMustMatchAgent(t *testing.T) {
	config := fixtureAgentConfiguration()
	config.Provider.APIProtocol = "anthropicMessages"
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: config, session: newFakeAgentSession()}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()

	if !h.shows(h.app.text.Agent.NoProviders) {
		t.Fatal("a provider with a mismatched protocol was offered to the agent")
	}
}

func TestAgentProjectCloseCancelsInstall(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: uninstalledAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	kernel.installFn = func(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return core.AgentAdapterInstallResult{}, nil, ctx.Err()
	}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.agentClick(h.app.text.Agent.Install)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("the install did not start")
	}
	h.app.closeProject()
	h.settle()
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("closing the project did not cancel the install")
	}
	if h.app.project != nil {
		t.Fatal("the project did not close")
	}
}
