package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestAgentManagementFixturePreservesUnknownUpdate(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "agent", "agent-management-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Responses struct {
			Status AgentManagementStatus `json:"status"`
		} `json:"responses"`
		Events map[string]json.RawMessage `json:"events"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	agents := fixture.Responses.Status.Agents
	if len(agents) < 2 || agents[0].UpdateAvailable == nil || *agents[0].UpdateAvailable {
		t.Fatal("fixture's confirmed non-update must remain false")
	}
	if agents[1].UpdateAvailable != nil || agents[1].CLI == nil || agents[1].CLI.Installation == nil || agents[1].CLI.Installation.UpdateAvailable != nil {
		t.Fatal("unavailable adapter and CLI update results must remain unknown")
	}
	if agents[0].CLI == nil || agents[0].CLI.Installation == nil || agents[0].CLI.Installation.UpdateAvailable == nil || !*agents[0].CLI.Installation.UpdateAvailable {
		t.Fatal("confirmed CLI update must remain true")
	}
	progress, present, err := decodeAgentInstallProgress(fixture.Events["downloading"])
	if err != nil || !present || progress.Stage != "downloading" || progress.DownloadedBytes != 25000000 || progress.BytesPerSecond != 75000 {
		t.Fatalf("progress = %#v, present=%v, err=%v", progress, present, err)
	}
	if _, present, err := decodeAgentInstallProgress(json.RawMessage(`{"type":"requestStarted"}`)); err != nil || present {
		t.Fatalf("unrelated request event: present=%v, err=%v", present, err)
	}
	if _, _, err := decodeAgentInstallProgress(json.RawMessage(`{"kind":"agentInstallProgress","progress":null}`)); !errors.Is(err, ErrCoreEventsLost) {
		t.Fatalf("malformed progress error = %v", err)
	}
}

func TestAgentManagementActionsRejectRelativeDirectory(t *testing.T) {
	client := NewClient()
	observed := false
	_, observationErr, requestErr := client.InstallAgentAdapter(testContext(t), "relative", "codex-acp", func(AgentInstallProgress) {
		observed = true
	})
	var coreErr *Error
	if observationErr != nil || !errors.As(requestErr, &coreErr) || coreErr.Code != CodeInvalidRequest || observed {
		t.Fatalf("adapter: observation=%v request=%v progress=%v", observationErr, requestErr, observed)
	}
	_, observationErr, requestErr = client.InstallAgentCLI(testContext(t), "relative", "codex-acp", nil)
	if observationErr != nil || !errors.As(requestErr, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("CLI: observation=%v request=%v", observationErr, requestErr)
	}
	requestErr = client.UninstallAgentAdapter(testContext(t), "relative", "codex-acp")
	if !errors.As(requestErr, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("uninstall: %v", requestErr)
	}
}

func TestAgentManagementCoreProgressBeforeRejectedInstall(t *testing.T) {
	client := NewClient()
	directory := t.TempDir()
	var events []AgentInstallProgress
	_, observationErr, requestErr := client.InstallAgentAdapter(testContext(t), directory, "unknown-fixture-agent", func(event AgentInstallProgress) {
		events = append(events, event)
	})
	var coreErr *Error
	if observationErr != nil || !errors.As(requestErr, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("observation=%v request=%v", observationErr, requestErr)
	}
	if len(events) != 1 || events[0].Stage != "preparing" {
		t.Fatalf("progress = %#v", events)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 0 {
		t.Fatalf("rejected install changed its directory: entries=%v err=%v", entries, err)
	}
	_, observationErr, requestErr = client.InstallAgentCLI(testContext(t), directory, "unknown-fixture-agent", func(AgentInstallProgress) {
		panic("fixture progress observer failure")
	})
	if !errors.Is(observationErr, ErrCoreEventsLost) || !errors.As(requestErr, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("observer failure=%v request=%v", observationErr, requestErr)
	}
}

func TestAgentManagementRejectsRelativeDirectory(t *testing.T) {
	_, err := NewClient().ReadAgentManagementStatus(testContext(t), "relative")
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("relative directory error = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := NewClient().ReadAgentManagementStatus(ctx, t.TempDir()); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled detection error = %v", err)
	}
}
