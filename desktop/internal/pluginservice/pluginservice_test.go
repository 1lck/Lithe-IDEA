package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fakeKernel records what the stack asked Core to do.
type fakeKernel struct {
	review          core.MarketplaceReview
	reviewErr       error
	reviewManifest  json.RawMessage
	reviewExpected  [2]string
	reviewApproved  []json.RawMessage
	reviewCaps      map[string][]int
	plan            core.PluginBackendPlan
	planErr         error
	started         core.PluginBackendStarted
	startErr        error
	events          [][]core.BackendEvent
	stopErr         error
	destroyErr      error
	hostResponseErr error
}

func (k *fakeKernel) ValidatePluginManifest(_ context.Context, manifest json.RawMessage, _ map[string][]int) (json.RawMessage, error) {
	return manifest, nil
}

func (k *fakeKernel) ReviewMarketplaceInstall(_ context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage, capabilities map[string][]int) (core.MarketplaceReview, error) {
	k.reviewManifest = manifest
	k.reviewExpected = [2]string{expectedID, expectedVersion}
	k.reviewApproved = approvedPrograms
	k.reviewCaps = capabilities
	return k.review, k.reviewErr
}

func (k *fakeKernel) PlanPluginBackend(context.Context, json.RawMessage, core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	return k.plan, k.planErr
}

func (k *fakeKernel) StartPluginBackend(context.Context, core.PluginBackendStart) (core.PluginBackendStarted, error) {
	return k.started, k.startErr
}

func (k *fakeKernel) WaitBackendEvents(context.Context, string, int) ([]core.BackendEvent, error) {
	if len(k.events) == 0 {
		return nil, nil
	}
	batch := k.events[0]
	k.events = k.events[1:]
	return batch, nil
}

func (k *fakeKernel) StopPluginBackend(context.Context, string) error { return k.stopErr }

func (k *fakeKernel) DestroyPluginBackend(context.Context, string) error { return k.destroyErr }

func (k *fakeKernel) RespondPluginHostRequest(context.Context, string, string, json.RawMessage, *core.PluginHostFailure) error {
	return k.hostResponseErr
}

func TestOpenAssemblesEveryPart(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if service.Manager == nil || service.Installer == nil || service.Backend == nil || service.HostServices == nil {
		t.Fatalf("service = %+v", service)
	}
	if service.Root == "" {
		t.Fatal("the service has no root")
	}
	if len(service.Capabilities()) != 0 {
		t.Fatalf("capabilities = %v", service.Capabilities())
	}
}

func TestOpenRefusesIncompleteAssembly(t *testing.T) {
	cases := map[string]struct {
		kernel      Kernel
		preferences *store.Store
		root        string
	}{
		"no kernel":      {preferences: store.At(t.TempDir()), root: t.TempDir()},
		"no preferences": {kernel: &fakeKernel{}, root: t.TempDir()},
		"relative root":  {kernel: &fakeKernel{}, preferences: store.At(t.TempDir()), root: "plugins"},
		"empty root":     {kernel: &fakeKernel{}, preferences: store.At(t.TempDir())},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Open(tc.kernel, tc.preferences, tc.root); !errors.Is(err, ErrAssembly) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestReviewerAdaptsCoreReview(t *testing.T) {
	kernel := &fakeKernel{review: core.MarketplaceReview{
		ID:          "example",
		Version:     "1.0.0",
		Permissions: []string{"workspace.read"},
		Programs:    []json.RawMessage{json.RawMessage(`{"kind":"runtime"}`)},
		NewPrograms: []json.RawMessage{json.RawMessage(`{"kind":"run"}`)},
	}}
	approved := []json.RawMessage{json.RawMessage(`{"kind":"runtime"}`)}
	review, err := NewReviewer(kernel).ReviewPluginInstall(context.Background(), json.RawMessage(`{"id":"example"}`), "example", "1.0.0", approved)
	if err != nil {
		t.Fatalf("review: %v", err)
	}
	if len(review.Permissions) != 1 || review.Permissions[0] != "workspace.read" {
		t.Fatalf("permissions = %v", review.Permissions)
	}
	if len(review.Programs) != 1 || string(review.Programs[0]) != `{"kind":"runtime"}` {
		t.Fatalf("programs = %s", review.Programs)
	}
	if len(review.NewPrograms) != 1 || string(review.NewPrograms[0]) != `{"kind":"run"}` {
		t.Fatalf("new programs = %s", review.NewPrograms)
	}
	if kernel.reviewExpected != [2]string{"example", "1.0.0"} {
		t.Fatalf("expected = %v", kernel.reviewExpected)
	}
	if len(kernel.reviewApproved) != 1 {
		t.Fatalf("approved = %s", kernel.reviewApproved)
	}
	// The capabilities handed to Core must be the ones this client implements, not
	// what Core could parse.
	if len(kernel.reviewCaps) != 0 {
		t.Fatalf("capabilities = %v", kernel.reviewCaps)
	}
}

func TestReviewerRefusesWithoutKernel(t *testing.T) {
	if _, err := NewReviewer(nil).ReviewPluginInstall(context.Background(), json.RawMessage(`{}`), "", "", nil); !errors.Is(err, ErrAssembly) {
		t.Fatalf("err = %v", err)
	}
}

func TestReviewerPropagatesCoreRefusal(t *testing.T) {
	refusal := errors.New("plugin.api.unsupported")
	kernel := &fakeKernel{reviewErr: refusal}
	if _, err := NewReviewer(kernel).ReviewPluginInstall(context.Background(), json.RawMessage(`{}`), "", "", nil); !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
}
