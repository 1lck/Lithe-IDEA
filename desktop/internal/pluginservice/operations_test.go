package pluginservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// languageServerEntry is an enabled package that declares a go language server and ships the
// program its plan starts. The fake kernels never run it, but the runner verifies it exists.
func languageServerEntry(t *testing.T) pluginmanager.Entry {
	t.Helper()
	entry := serverPackage(t, "1.0.0", true, "go")
	program := filepath.Join(entry.Installed.Path, "bin", "server")
	if err := os.MkdirAll(filepath.Dir(program), 0o700); err != nil {
		t.Fatal(err)
	}
	image := []byte("binary")
	if runtime.GOOS == "windows" {
		// The Windows adapter checks for a native image even when the process is fake.
		current, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		if image, err = os.ReadFile(current); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(program, image, 0o755); err != nil {
		t.Fatal(err)
	}
	return entry
}

// packagedServerPlan starts the package's own program.
func packagedServerPlan() core.PluginBackendPlan {
	var plan core.PluginBackendPlan
	plan.Launch.Kind = pluginhost.LaunchPackaged
	plan.Launch.Path = "bin/server"
	return plan
}

// TestLanguageServerStartRecordsWhatFailsBeforeCoreTakesIt checks that a language-server start
// is recorded by the host only up to the handoff: a failure before it is a launch the host
// could not resolve, or a timeout at a deadline, under the action's op; a start handed to Core
// carries the attempt and records nothing here, whatever Core answers; a cancelled start
// records nothing; and a result Core refuses is reported, not lost.
func TestLanguageServerStartRecordsWhatFailsBeforeCoreTakesIt(t *testing.T) {
	refused := errors.New("lithe core: plan refused")
	cases := []struct {
		name      string
		prepare   func(*fakeKernel)
		cancel    bool
		origin    string
		wantStage core.PluginStage
		wantStart bool
	}{
		{name: "plan refused", prepare: func(k *fakeKernel) { k.planErr = refused }, origin: "action-41", wantStage: core.StageResolve},
		{name: "deadline before the handoff", prepare: func(k *fakeKernel) { k.planErr = context.DeadlineExceeded }, origin: "action-41", wantStage: core.StageTimeout},
		{name: "cancelled", prepare: func(k *fakeKernel) { k.planErr = context.Canceled }, cancel: true, origin: "action-41"},
		{name: "handed off", prepare: func(k *fakeKernel) {
			k.plan, k.started = packagedServerPlan(), core.PluginBackendStarted{SessionID: "ls-1"}
		}, origin: "action-41", wantStart: true},
		{name: "refused by core after the handoff", prepare: func(k *fakeKernel) {
			k.plan, k.startErr = packagedServerPlan(), errors.New("lithe core: lsp.startServer: refused")
		}, origin: "action-41", wantStart: true},
		{name: "handed off without an action", prepare: func(k *fakeKernel) {
			k.plan, k.started = packagedServerPlan(), core.PluginBackendStarted{SessionID: "ls-1"}
		}, wantStart: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kernel := &fakeKernel{}
			tc.prepare(kernel)
			service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			ctx := core.WithOrigin(context.Background(), core.Origin{Operation: tc.origin, Trigger: "command.test"})
			if tc.cancel {
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			session, _ := service.StartLanguageServer(ctx, []pluginmanager.Entry{languageServerEntry(t)}, "go", BackendRequest{Architecture: core.PluginArchitecture()})
			if session != nil {
				t.Cleanup(func() { service.unregisterLanguageSession(session) })
			}

			if !tc.wantStart {
				if len(kernel.languageStarts) != 0 {
					t.Fatalf("a start that failed before the handoff reached Core: %+v", kernel.languageStarts)
				}
			} else {
				if len(kernel.languageStarts) != 1 {
					t.Fatalf("Core was asked to start %d servers, want one", len(kernel.languageStarts))
				}
				handoff := kernel.languageStarts[0].StartupOperation
				if handoff == nil || handoff.PluginID != "example" || handoff.ElapsedMs < 0 {
					t.Fatalf("the start did not hand the attempt to Core: %+v", handoff)
				}
				if tc.origin != "" && handoff.OperationID != tc.origin {
					t.Fatalf("the handoff is under %q, want the action's op %q", handoff.OperationID, tc.origin)
				}
				if tc.origin == "" && !strings.HasPrefix(handoff.OperationID, "action-") {
					t.Fatalf("a start without an action handed off op %q, want a fresh one", handoff.OperationID)
				}
			}

			switch {
			case tc.wantStage == "":
				if len(kernel.operations) != 0 {
					t.Fatalf("the host recorded %+v for a start that is not its to record", kernel.operations)
				}
			case len(kernel.operations) != 1:
				t.Fatalf("the host recorded %d results, want one: %+v", len(kernel.operations), kernel.operations)
			default:
				got := kernel.operations[0]
				want := core.PluginOperation{
					PluginID: "example", Operation: core.OperationLanguageServerStart, Outcome: "failed",
					Stage: tc.wantStage, DurationMs: got.DurationMs, OperationID: tc.origin,
				}
				if got != want || got.DurationMs < 0 {
					t.Fatalf("recorded %+v, want %+v", got, want)
				}
			}
		})
	}

	t.Run("refused result", func(t *testing.T) {
		kernel := &fakeKernel{planErr: refused, recordErr: errors.New("log error -32064: Invalid host plugin operation")}
		service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		var reported []error
		service.RecordFailed = func(_ context.Context, err error) { reported = append(reported, err) }
		if _, err := service.StartLanguageServer(context.Background(), []pluginmanager.Entry{languageServerEntry(t)}, "go", BackendRequest{}); !errors.Is(err, refused) {
			t.Fatalf("start = %v, want the plan's refusal", err)
		}
		if len(reported) != 1 || !errors.Is(reported[0], kernel.recordErr) {
			t.Fatalf("a refused result was reported %v, want once", reported)
		}
	})
}
