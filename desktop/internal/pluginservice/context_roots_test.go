package pluginservice

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestWorkspaceRootsTrackEachOpenContext(t *testing.T) {
	state := t.TempDir()
	first, second := newWorkspaceContexts(state), newWorkspaceContexts(state)
	t.Cleanup(first.CloseAll)
	t.Cleanup(second.CloseAll)
	alpha, beta := filepath.Join(t.TempDir(), "alpha"), filepath.Join(t.TempDir(), "beta")
	first.Open(alpha)
	first.Open(alpha) // Opening the same context twice retains one owner.
	second.Open(alpha)
	second.Open(beta)
	if got := first.workspaceRoots(); len(got) != 2 {
		t.Fatalf("shared open roots = %v", got)
	}
	if _, local := first.List(); len(local) != 1 || local[0].Path != alpha {
		t.Fatalf("shared runtime facts changed plugin context visibility: %v", local)
	}
	first.Close(alpha)
	first.Close(alpha)
	if got := first.workspaceRoots(); len(got) != 2 {
		t.Fatalf("closing one owner removed another workbench's roots: %v", got)
	}
	snapshot := first.workspaceRoots()
	second.CloseAll()
	second.CloseAll()
	if got := first.workspaceRoots(); len(got) != 0 {
		t.Fatalf("closed contexts retained roots: %v", got)
	}
	if len(snapshot) != 2 {
		t.Fatalf("closing contexts mutated an in-flight snapshot: %v", snapshot)
	}
	first.Open(beta)
	if got := second.workspaceRoots(); !reflect.DeepEqual(got, []string{beta}) {
		t.Fatalf("reopened roots = %v", got)
	}
	independent := newWorkspaceContexts(t.TempDir())
	if got := independent.workspaceRoots(); len(got) != 0 {
		t.Fatalf("roots crossed independent plugin state directories: %v", got)
	}
}
