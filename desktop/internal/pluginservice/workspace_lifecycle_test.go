package pluginservice

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// A queued task retains the identity from before close. Reopening the same path
// is a new owner; neither delayed activation nor an LSP start may adopt it.
func TestDelayedWorkspaceTasksDoNotReopenOrAdoptAnotherContext(t *testing.T) {
	for _, consumer := range []string{"activation", "language-server"} {
		for _, transition := range []string{"open", "closed", "reopened"} {
			t.Run(consumer+"/"+transition, func(t *testing.T) {
				planned := errors.New("test stopped at language-server planning")
				kernel := &fakeKernel{planErr: planned}
				preferences := store.At(t.TempDir())
				service, err := Open(kernel, preferences, t.TempDir())
				if err != nil {
					t.Fatal(err)
				}
				// This test controls the lifecycle directly, without notification work.
				service.Contexts.SetObserver(nil)
				t.Cleanup(service.Contexts.CloseAll)
				peer, err := OpenAnother(kernel, preferences, service.Root)
				if err != nil {
					t.Fatal(err)
				}
				peer.Contexts.SetObserver(nil)
				t.Cleanup(peer.Contexts.CloseAll)
				peerRoot := t.TempDir()
				peer.Contexts.Open(peerRoot)
				root := t.TempDir()
				captured := service.Contexts.Open(root)
				current := captured
				if transition != "open" {
					service.DetachWorkspaces()()
				}
				if transition == "reopened" {
					current = service.Contexts.Open(root)
					if current.ContextRef == captured.ContextRef {
						t.Fatal("reopening reused a closed workspace identity")
					}
				}
				var entries []pluginmanager.Entry
				if consumer == "language-server" {
					// Planning returns a sentinel error before the runner checks the executable.
					entries = []pluginmanager.Entry{serverPackage(t, "1.0.0", true, "go")}
				}
				ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
				defer cancel()
				if consumer == "activation" {
					err = service.ActivateWorkspace(ctx, nil, captured.ContextRef)
				} else {
					_, err = service.StartLanguageServer(ctx, entries, "go", BackendRequest{
						WorkingDirectory: root, Context: captured.ContextRef, Architecture: core.PluginArchitecture(),
					})
				}
				want := ErrContextExpired
				if transition == "open" {
					want = nil
					if consumer == "language-server" {
						want = planned
					}
				}
				if !errors.Is(err, want) {
					t.Errorf("queued %s with %s context = %v, want %v", consumer, transition, err, want)
				}
				opened, exists := service.Contexts.ByPath(root)
				wantRoots := 2
				if transition == "closed" {
					wantRoots = 1
					if exists {
						t.Fatal("a delayed task retained the closed workspace root")
					}
				} else if !exists || opened.ContextRef != current.ContextRef {
					t.Fatalf("a delayed task replaced the current workspace: %+v, want %+v", opened, current)
				}
				if roots := peer.Contexts.workspaceRoots(); len(roots) != wantRoots {
					t.Fatalf("a delayed task changed another workbench's root snapshot: %v", roots)
				}
				service.Contexts.CloseAll()
				if roots := peer.Contexts.workspaceRoots(); len(roots) != 1 || roots[0] != peerRoot {
					t.Fatalf("closing one workbench removed or leaked another owner's roots: %v", roots)
				}
			})
		}
	}
}
