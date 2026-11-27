package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type relayTestKernel struct {
	*fakeKernel
	plugins []core.RelayPlugin
	err     error
	planErr error
}

func (k *relayTestKernel) ConfigureFunctionRelay(_ context.Context, plugins []core.RelayPlugin, _ []core.RelayContext) error {
	k.plugins = plugins
	return k.err
}

func (k *relayTestKernel) PlanPluginLifecycle(ctx context.Context, request core.PluginLifecycleRequest) (core.PluginLifecycle, error) {
	if k.planErr != nil {
		return core.PluginLifecycle{}, k.planErr
	}
	return k.fakeKernel.PlanPluginLifecycle(ctx, request)
}

func TestSyncFunctionRelayReportsBrokenManifestAndKeepsValidDeclarations(t *testing.T) {
	broken := snapshotEntry(t, "dev.lithe.test.broken-relay", "1.0.0", "{")
	healthy := snapshotEntry(t, "dev.lithe.test.healthy-relay", "1.0.0", `{"pluginFunctions":{"exports":[]}}`)
	noRelay := snapshotEntry(t, "dev.lithe.test.no-relay", "1.0.0", "{}")
	configureErr := errors.New("injected relay configuration failure")
	kernel := &relayTestKernel{fakeKernel: &fakeKernel{}, err: configureErr}
	service := &Service{kernel: kernel, Contexts: newWorkspaceContexts(t.TempDir())}

	err := service.SyncFunctionRelay(context.Background(), []pluginmanager.Entry{broken, healthy, noRelay})
	if len(kernel.plugins) != 1 || kernel.plugins[0].PluginID != healthy.Installed.ID {
		t.Fatalf("configured plugins = %+v, want only %s", kernel.plugins, healthy.Installed.ID)
	}
	var syntaxErr *json.SyntaxError
	if !errors.Is(err, configureErr) || !errors.As(err, &syntaxErr) ||
		!strings.Contains(err.Error(), broken.Installed.ID) || strings.Contains(err.Error(), noRelay.Installed.ID) {
		t.Fatalf("relay error = %v, want the malformed manifest and configuration failure", err)
	}
}

func TestWorkspaceContextObserverReportsRelayFailureOutsideLock(t *testing.T) {
	failure := errors.New("injected relay configuration failure")
	kernel := &relayTestKernel{fakeKernel: &fakeKernel{}, err: failure}
	root := t.TempDir()
	prefs := store.At(t.TempDir())
	service := &Service{
		kernel:   kernel,
		Manager:  pluginmanager.New(kernel, root, plugintrust.New(prefs), pluginstate.New(prefs)),
		Contexts: newWorkspaceContexts(t.TempDir()),
	}
	service.Host = newBackendHost(service)
	type report struct {
		err      error
		unlocked bool
	}
	reported := make(chan report, 1)
	service.ContextIssue = func(_ context.Context, err error) {
		unlocked := service.contextsNotifyMu.TryLock()
		if unlocked {
			service.contextsNotifyMu.Unlock()
		}
		reported <- report{err, unlocked}
	}
	service.Contexts.SetObserver(service.contextsChanged)
	service.Contexts.Open(t.TempDir())

	deadline, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	select {
	case got := <-reported:
		if !errors.Is(got.err, failure) || !got.unlocked {
			t.Fatalf("context diagnostic = %+v, want the relay error outside the notification lock", got)
		}
	case <-deadline.Done():
		t.Fatal("the workspace context observer did not report the relay failure")
	}
}

func TestWorkspaceContextRefreshReportsOncePerRevisionAndRetriesOnChange(t *testing.T) {
	failure := errors.New("injected inventory planning failure")
	kernel := &relayTestKernel{fakeKernel: &fakeKernel{}, planErr: failure}
	prefs := store.At(t.TempDir())
	service := &Service{
		kernel:   kernel,
		Manager:  pluginmanager.New(kernel, t.TempDir(), plugintrust.New(prefs), pluginstate.New(prefs)),
		Contexts: newWorkspaceContexts(t.TempDir()),
	}
	service.Host = newBackendHost(service)
	var reports []error
	service.ContextIssue = func(_ context.Context, err error) { reports = append(reports, err) }
	path := t.TempDir()
	service.Contexts.Open(path)
	service.refreshWorkspaceContexts(t.Context())
	service.refreshWorkspaceContexts(t.Context())
	if len(reports) != 1 || !errors.Is(reports[0], failure) {
		t.Fatalf("reports = %v, want one inventory diagnostic for the revision", reports)
	}
	service.Contexts.Close(path)
	kernel.planErr = nil
	kernel.err = context.Canceled
	service.refreshWorkspaceContexts(t.Context())
	if len(reports) != 1 {
		t.Fatalf("reports after pure cancellation = %v", reports)
	}
	service.Contexts.Open(path)
	kernel.err = errors.Join(context.Canceled, context.DeadlineExceeded)
	service.refreshWorkspaceContexts(t.Context())
	if len(reports) != 2 || !errors.Is(reports[1], context.DeadlineExceeded) {
		t.Fatalf("reports = %v, want a diagnostic for the later timeout despite cancellation", reports)
	}
}
