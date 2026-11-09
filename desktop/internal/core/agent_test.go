package core

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestAgentBridgeHelper is a local ACP fixture, not an installed agent or model.
// The parent starts the current test binary with a private argument marker.
func TestAgentBridgeHelper(t *testing.T) {
	marker := -1
	for i, arg := range os.Args {
		if arg == "lithe-agent-fixture" {
			marker = i
			break
		}
	}
	if marker < 0 {
		return
	}
	if marker+1 >= len(os.Args) || os.WriteFile(os.Args[marker+1], []byte(strconv.Itoa(os.Getpid())), 0o600) != nil {
		os.Exit(7)
	}
	reader := bufio.NewScanner(os.Stdin)
	reader.Buffer(make([]byte, 4096), 2<<20)
	writer := bufio.NewWriter(os.Stdout)
	write := func(value any) {
		data, err := json.Marshal(value)
		if err != nil {
			os.Exit(8)
		}
		if _, err := fmt.Fprintln(writer, string(data)); err != nil || writer.Flush() != nil {
			os.Exit(9)
		}
	}
	for reader.Scan() {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if json.Unmarshal(reader.Bytes(), &request) != nil {
			os.Exit(10)
		}
		if len(request.ID) == 0 {
			continue
		}
		var result any
		switch request.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": 1, "agentInfo": map[string]any{"name": "fixture", "version": "1"}, "agentCapabilities": map[string]any{}, "authMethods": []any{map[string]any{"id": "gateway", "name": "Fixture"}}}
		case "authenticate":
			result = map[string]any{}
		case "session/new":
			result = map[string]any{"sessionId": "fixture-session"}
		case "session/prompt":
			write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "fixture-session", "update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "fixture reply"}}}})
			result = map[string]any{"stopReason": "end_turn"}
		case "session/list":
			result = map[string]any{"sessions": []any{}}
		default:
			write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "error": map[string]any{"code": -32601, "message": "unsupported fixture method"}})
			continue
		}
		write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result})
	}
	os.Exit(0)
}

func agentTestEvent(t *testing.T, session *AgentSession, kind string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	for count := 0; count < 64; count++ {
		raw, err := session.Next(ctx)
		if err != nil {
			t.Fatalf("waiting for %s: %v", kind, err)
		}
		var event map[string]any
		if err := json.Unmarshal(raw, &event); err != nil {
			t.Fatalf("invalid Core event: %v", err)
		}
		if event["kind"] == kind {
			return event
		}
		if event["kind"] == "stopped" {
			t.Fatalf("agent stopped before %s: %v", kind, event["message"])
		}
	}
	t.Fatalf("too many events while waiting for %s", kind)
	return nil
}

func openAgentFixture(t *testing.T) (*AgentSession, int) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	pidFile := filepath.Join(root, "agent.pid")
	launch, err := json.Marshal(map[string]any{
		"command":  executable,
		"args":     []string{"-test.run=^TestAgentBridgeHelper$", "--", "lithe-agent-fixture", pidFile},
		"cwd":      root,
		"provider": map[string]any{"protocol": "responses", "baseUrl": "https://example.invalid/v1", "apiKey": "fixture-key"},
	})
	if err != nil {
		t.Fatal(err)
	}
	session, err := OpenAgentSession(launch)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.Close)
	agentTestEvent(t, session, "ready")
	pidText, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(pidText)))
	if err != nil || pid <= 0 {
		t.Fatalf("invalid fixture pid %q", pidText)
	}
	t.Cleanup(func() {
		session.Close()
		assertAgentFixtureStopped(t, pid)
	})
	return session, pid
}

func TestAgentSessionUsesCoreAndCleansUp(t *testing.T) {
	session, pid := openAgentFixture(t)
	if err := session.Send(json.RawMessage(`{"kind":"newSession","token":"fixture-token"}`)); err != nil {
		t.Fatal(err)
	}
	created := agentTestEvent(t, session, "sessionCreated")
	if created["token"] != "fixture-token" || created["sessionId"] != "fixture-session" {
		t.Fatalf("sessionCreated = %v", created)
	}
	if err := session.Send(json.RawMessage(`{"kind":"prompt","sessionId":"fixture-session","text":"hello"}`)); err != nil {
		t.Fatal(err)
	}
	update := agentTestEvent(t, session, "update")
	if update["sessionId"] != "fixture-session" {
		t.Fatalf("update = %v", update)
	}
	finished := agentTestEvent(t, session, "turnFinished")
	if finished["stopReason"] != "end_turn" {
		t.Fatalf("turnFinished = %v", finished)
	}
	// Send and close must not race a freed native handle.
	start := make(chan struct{})
	var sends sync.WaitGroup
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		sends.Add(1)
		go func() {
			defer sends.Done()
			<-start
			results <- session.Send(json.RawMessage(`{"kind":"listSessions","token":"fixture-list"}`))
		}()
	}
	close(start)
	closed := make(chan struct{})
	go func() {
		session.Close()
		sends.Wait()
		close(closed)
	}()
	timer := time.NewTimer(12 * time.Second)
	defer timer.Stop()
	select {
	case <-closed:
	case <-timer.C:
		t.Fatal("agent close and concurrent sends did not finish")
	}
	close(results)
	for err := range results {
		if err != nil && !errors.Is(err, ErrAgentClosed) && !errors.Is(err, ErrAgentCommandRejected) {
			t.Fatalf("concurrent send: %v", err)
		}
	}
	session.Close()
	if err := session.Send(json.RawMessage(`{"kind":"newSession","token":"after-close"}`)); !errors.Is(err, ErrAgentClosed) {
		t.Fatalf("send after close = %v", err)
	}
	if _, err := session.Next(context.Background()); !errors.Is(err, ErrAgentClosed) {
		t.Fatalf("next after close = %v", err)
	}
	assertAgentFixtureStopped(t, pid)
}

func TestAgentSessionsRemainIndependent(t *testing.T) {
	first, firstPID := openAgentFixture(t)
	second, secondPID := openAgentFixture(t)
	if firstPID == secondPID {
		t.Fatal("separate sessions unexpectedly share a fixture process")
	}
	first.Close()
	assertAgentFixtureStopped(t, firstPID)
	if err := second.Send(json.RawMessage(`{"kind":"newSession","token":"second-token"}`)); err != nil {
		t.Fatal(err)
	}
	created := agentTestEvent(t, second, "sessionCreated")
	if created["token"] != "second-token" || created["sessionId"] != "fixture-session" {
		t.Fatalf("second session response = %v", created)
	}
	second.Close()
	assertAgentFixtureStopped(t, secondPID)
}

func TestAgentEventQueueOverflowIsExplicit(t *testing.T) {
	queue := newAgentEventQueue()
	for i := 0; i < agentEventCountLimit; i++ {
		if !queue.reserve(2) {
			t.Fatal("queue rejected an event below its limit")
		}
		queue.publish(json.RawMessage(`{}`))
	}
	if !queue.reserve(2) {
		t.Fatal("queue rejected the final reservation before publish")
	}
	queue.publish(json.RawMessage(`{}`))
	session := &AgentSession{queue: queue}
	if _, err := session.Next(context.Background()); !errors.Is(err, ErrAgentEventOverflow) {
		t.Fatalf("overflow was not surfaced: %v", err)
	}
	oversized := newAgentEventQueue()
	if oversized.reserve(agentEventSingleLimit+1) || !oversized.failed.Load() {
		t.Fatal("oversized event did not invalidate the stream")
	}
	total := newAgentEventQueue()
	for i := 0; i < agentEventBytesLimit/agentEventSingleLimit; i++ {
		if !total.reserve(agentEventSingleLimit) {
			t.Fatal("queue rejected bytes at or below its total limit")
		}
	}
	if total.reserve(1) || !total.failed.Load() {
		t.Fatal("total byte limit did not invalidate the stream")
	}
}

func TestAgentNextHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	session := &AgentSession{queue: newAgentEventQueue()}
	if _, err := session.Next(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("next with canceled context = %v", err)
	}
}
