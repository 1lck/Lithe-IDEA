package core

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"testing"
)

func TestGitWriteFailure(t *testing.T) {
	if err := (gitWriteResponse{}).failure(); err != nil {
		t.Fatalf("a successful answer failed: %v", err)
	}
	err := (gitWriteResponse{ExitCode: 128, Stderr: "\n  fatal: pathspec 'x' did not match\nmore\n", Output: "ignored"}).failure()
	if failure := requireCode(t, err, CodeProcessFailed); failure.Message != "fatal: pathspec 'x' did not match" {
		t.Fatalf("message = %q, want the first line Git printed", failure.Message)
	}
	err = (gitWriteResponse{ExitCode: 1, Output: "only output\n"}).failure()
	if failure := requireCode(t, err, CodeProcessFailed); failure.Message != "only output" {
		t.Fatalf("message = %q, want the output when stderr is empty", failure.Message)
	}
	err = (gitWriteResponse{OperationError: &wireError{Code: CodeInvalidRequest, Message: "refused"}}).failure()
	if failure := requireCode(t, err, CodeInvalidRequest); failure.Message != "refused" || failure.Command != "git.write" {
		t.Fatalf("failure = %+v, want the kernel's operation error", failure)
	}
}

func TestStagingPathsKeepBothSidesOfARename(t *testing.T) {
	if got := (GitChange{Path: "new.txt", OriginalPath: "old.txt"}).StagingPaths(); !slices.Equal(got, []string{"old.txt", "new.txt"}) {
		t.Fatalf("rename paths = %q", got)
	}
	if got := (GitChange{Path: "dir/"}).StagingPaths(); !slices.Equal(got, []string{"dir/"}) {
		t.Fatalf("plain paths = %q", got)
	}
}

func TestPushTargetAnswerNamesTheChosenBranch(t *testing.T) {
	q := PushTargetQuestion{RepositoryID: ".", LocalBranch: "feature", Remote: "origin", Upstream: "origin/release", UpstreamBranch: "release"}
	if got := q.Answer(PushTargetPublish); got != (WorkspaceCommitPushTarget{Choice: PushTargetPublish, Remote: "origin", RemoteBranch: "feature"}) {
		t.Fatalf("publish = %+v", got)
	}
	if got := q.Answer(PushTargetUpstream); got != (WorkspaceCommitPushTarget{Choice: PushTargetUpstream, Remote: "origin", RemoteBranch: "release"}) {
		t.Fatalf("upstream = %+v", got)
	}
}

func TestWorkspaceCommitSessionKeepsTheKernelBytes(t *testing.T) {
	raw := `{"plan":{"message":"m","amend":false,"push":true,"isRetry":false,"orderedIds":["."],"states":{".":{"branch":"main","stagedPaths":["a.txt"],"conflictedPaths":[],"future":1}},"extra":[1,2]},"results":{".":{"committed":true,"pushed":false,"status":"committedPushPending","detail":""}},"blocked":[],"cursor":0,"commandFailed":false,"finished":false,"succeeded":false,"canRetry":false}`
	var session WorkspaceCommitSession
	if err := json.Unmarshal([]byte(raw), &session); err != nil {
		t.Fatal(err)
	}
	if !session.Push || session.Message != "m" || !slices.Equal(session.OrderedIDs, []string{"."}) {
		t.Fatalf("plan summary = %+v", session)
	}
	if state := session.States["."]; state.Branch != "main" || !slices.Equal(state.StagedPaths, []string{"a.txt"}) {
		t.Fatalf("state = %+v", state)
	}
	if result := session.Results["."]; !result.Committed || result.Status != CommitPushPending {
		t.Fatalf("result = %+v", result)
	}
	encoded, err := json.Marshal(workspaceCommitStepRequest{Session: session})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"session":` + raw + `}`; string(encoded) != want {
		t.Fatalf("encoded = %s\nwant %s", encoded, want)
	}
	if _, err := json.Marshal(WorkspaceCommitSession{}); !errors.Is(err, errEmptySession) {
		t.Fatalf("an empty session encoded: %v", err)
	}
}

func TestStageUnstageAndWorkspaceCommit(t *testing.T) {
	requireGit(t)
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
	client := NewClient()
	ctx := testContext(t)
	repo := newRepository(t)
	writeFile(t, filepath.Join(repo, "base.txt"), "base")
	runGit(t, repo, "add", "base.txt")
	runGit(t, repo, "commit", "-m", "base")

	writeFile(t, filepath.Join(repo, "a.txt"), "a")
	if err := client.GitStage(ctx, repo, []string{"a.txt"}); err != nil {
		t.Fatalf("GitStage() error: %v", err)
	}
	if status, err := client.GitStatus(ctx, repo); err != nil || len(status.Changes) != 1 || !status.Changes[0].Staged {
		t.Fatalf("after staging: %+v, %v; want a.txt staged", status.Changes, err)
	}
	if err := client.GitUnstage(ctx, repo, []string{"a.txt"}); err != nil {
		t.Fatalf("GitUnstage() error: %v", err)
	}
	if status, err := client.GitStatus(ctx, repo); err != nil || len(status.Changes) != 1 || status.Changes[0].Staged || !status.Changes[0].Untracked {
		t.Fatalf("after unstaging: %+v, %v; want a.txt untracked", status.Changes, err)
	}

	repositories := []WorkspaceCommitRepository{{ID: ".", Root: repo}}
	_, err := client.WorkspaceCommitPrepare(ctx, WorkspaceCommitRequest{Repositories: repositories, Message: "nothing", IncludeParentReferences: true})
	requireCode(t, err, CodeInvalidRequest)

	if err := client.GitStageAll(ctx, repo); err != nil {
		t.Fatalf("GitStageAll() error: %v", err)
	}
	_, err = client.WorkspaceCommitPrepare(ctx, WorkspaceCommitRequest{Repositories: repositories, Message: "  ", IncludeParentReferences: true})
	requireCode(t, err, CodeInvalidRequest)

	preparation, err := client.WorkspaceCommitPrepare(ctx, WorkspaceCommitRequest{Repositories: repositories, Message: "add a", IncludeParentReferences: true})
	if err != nil {
		t.Fatalf("WorkspaceCommitPrepare() error: %v", err)
	}
	if preparation.RequiresConfirmation || len(preparation.PushTargetQuestions) != 0 {
		t.Fatalf("preparation = %+v, want a plan that runs without review", preparation)
	}
	if state := preparation.Session.States["."]; state.Branch != "refs/heads/main" || state.Head != runGit(t, repo, "rev-parse", "HEAD") || !slices.Equal(state.StagedPaths, []string{"a.txt"}) {
		t.Fatalf("reviewed state = %+v", state)
	}
	session := preparation.Session
	for steps := 0; !session.Finished; steps++ {
		if steps == 4 {
			t.Fatalf("the session did not finish: %+v", session)
		}
		if session, err = client.WorkspaceCommitStep(ctx, session); err != nil {
			t.Fatalf("WorkspaceCommitStep() error: %v", err)
		}
	}
	if result := session.Results["."]; !session.Succeeded || !result.Committed || result.Status != CommitCommitted {
		t.Fatalf("session = %+v, want the repository committed", session)
	}
	if subject := runGit(t, repo, "log", "-1", "--format=%s"); subject != "add a" {
		t.Fatalf("HEAD subject = %q", subject)
	}
}

func TestWorkspaceCommitTakesAnAuthorAndASignOff(t *testing.T) {
	requireGit(t)
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
	client := NewClient()
	ctx := testContext(t)
	repo := newRepository(t)
	writeFile(t, filepath.Join(repo, "a.txt"), "a")
	runGit(t, repo, "add", "a.txt")
	repositories := []WorkspaceCommitRepository{{ID: ".", Root: repo}}

	_, err := client.WorkspaceCommitPrepare(ctx, WorkspaceCommitRequest{Repositories: repositories, Message: "add a", Author: "Pair Author"})
	requireCode(t, err, CodeGitCommitAuthorInvalid)

	preparation, err := client.WorkspaceCommitPrepare(ctx, WorkspaceCommitRequest{
		Repositories: repositories, Message: "add a", Author: "Pair Author <pair@example.invalid>", SignOff: true,
	})
	if err != nil {
		t.Fatalf("WorkspaceCommitPrepare() error: %v", err)
	}
	session := preparation.Session
	if session.Author != "Pair Author <pair@example.invalid>" || !session.SignOff {
		t.Fatalf("plan = author %q, sign-off %v; want both kept", session.Author, session.SignOff)
	}
	for steps := 0; !session.Finished; steps++ {
		if steps == 4 {
			t.Fatalf("the session did not finish: %+v", session)
		}
		if session, err = client.WorkspaceCommitStep(ctx, session); err != nil {
			t.Fatalf("WorkspaceCommitStep() error: %v", err)
		}
	}
	if !session.Succeeded {
		t.Fatalf("session = %+v, want the repository committed", session)
	}
	if author := runGit(t, repo, "log", "-1", "--format=%an <%ae>"); author != "Pair Author <pair@example.invalid>" {
		t.Fatalf("author = %q", author)
	}
	if trailer := runGit(t, repo, "log", "-1", "--format=%(trailers:key=Signed-off-by,valueonly)"); trailer != "Lithe Test <test@example.invalid>" {
		t.Fatalf("Signed-off-by = %q, want the committer", trailer)
	}
}
