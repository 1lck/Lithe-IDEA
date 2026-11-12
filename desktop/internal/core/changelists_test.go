package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestChangeListsUseSharedMembershipAndScope(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "git", "changelists-reducer-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Request  ChangeListRequest `json:"request"`
		Response ChangeListResult  `json:"response"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	result, err := NewClient().ReduceChangeLists(testContext(t), fixture.Request)
	if err != nil || !reflect.DeepEqual(result, fixture.Response) {
		t.Fatalf("result = %#v, error = %v; want %#v", result, err, fixture.Response)
	}
	// An explicit empty move is a valid no-op; it must remain [] on the wire.
	empty := []ChangeListFile{}
	request := fixture.Request
	request.Action = &ChangeListAction{Type: "move", ID: "one", Files: &empty}
	if _, err := NewClient().ReduceChangeLists(testContext(t), request); err != nil {
		t.Fatalf("empty move: %v", err)
	}
}

func TestWorkspaceCommitScopeProtectsStagedChanges(t *testing.T) {
	requireGit(t)
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
	root := newRepository(t)
	writeFile(t, filepath.Join(root, "base.txt"), "base")
	runGit(t, root, "add", "base.txt")
	runGit(t, root, "commit", "-m", "base")
	originalHead := runGit(t, root, "rev-parse", "HEAD")
	writeFile(t, filepath.Join(root, "a.txt"), "a")
	writeFile(t, filepath.Join(root, "b.txt"), "b")
	runGit(t, root, "add", "a.txt", "b.txt")
	client, ctx := NewClient(), testContext(t)
	repositories := []WorkspaceCommitRepository{{ID: ".", Root: root}}
	// The captured file list contains only a.txt; the persisted assignment for
	// b.txt still needs to protect b.txt if it is staged outside this snapshot.
	lists, err := client.ReduceChangeLists(ctx, ChangeListRequest{
		State: ChangeListState{
			Lists:       []ChangeList{{ID: "default"}, {ID: "private", Name: "Private"}},
			ActiveID:    "default",
			Assignments: map[string]map[string]string{root: {"b.txt": "private"}},
		},
		Files:        []ChangeListFile{{Root: root, Path: "a.txt"}},
		Repositories: repositories,
	})
	if err != nil || lists.Scope.Membership == nil {
		t.Fatalf("Core scope = %#v, error = %v", lists.Scope, err)
	}
	request := WorkspaceCommitRequest{
		Repositories: repositories,
		Message:      "scoped",
		PathScope:    &lists.Scope,
	}
	_, err = client.WorkspaceCommitPrepare(ctx, request)
	requireCode(t, err, CodeInvalidRequest)
	if got := runGit(t, root, "diff", "--cached", "--name-only"); got != "a.txt\nb.txt" {
		t.Fatalf("rejected preparation changed the index: %q", got)
	}
	runGit(t, root, "reset", "--", "b.txt")
	prepared, err := client.WorkspaceCommitPrepare(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	var plan struct {
		PathScope ChangeListScope `json:"pathScope"`
	}
	if err := json.Unmarshal(prepared.Session.plan, &plan); err != nil || !reflect.DeepEqual(plan.PathScope, *request.PathScope) {
		t.Fatalf("prepared scope = %#v, error = %v", plan.PathScope, err)
	}
	// A newly staged file cannot enter the reviewed commit unnoticed.
	runGit(t, root, "add", "b.txt")
	next, err := client.WorkspaceCommitStep(ctx, prepared.Session)
	if err == nil && next.Succeeded {
		t.Fatal("commit succeeded after an out-of-scope file was staged")
	}
	if got := runGit(t, root, "rev-parse", "HEAD"); got != originalHead {
		t.Fatalf("HEAD changed after stale scoped preparation: %q", got)
	}
	if got := runGit(t, root, "diff", "--cached", "--name-only"); got != "a.txt\nb.txt" {
		t.Fatalf("stale scoped preparation changed the index: %q", got)
	}
}
