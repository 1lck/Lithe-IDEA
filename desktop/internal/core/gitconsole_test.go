package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// consoleLifecycleFixture is shared/fixtures/git/console-lifecycle-v1.json, which every host's
// journal replays.
type consoleLifecycleFixture struct {
	Version int `json:"version"`
	Cases   []struct {
		Name  string `json:"name"`
		Steps []struct {
			Event    json.RawMessage `json:"event"`
			Clear    bool            `json:"clear"`
			Commands [][]string      `json:"commands"`
			Running  []string        `json:"running"`
			Errors   []string        `json:"errors"`
			Roots    []string        `json:"roots"`
			States   []string        `json:"states"`
		} `json:"steps"`
	} `json:"cases"`
}

func newTestConsole() *GitConsole {
	console := NewGitConsole(nil)
	console.now = func() time.Time { return time.Unix(0, 0) }
	return console
}

func TestGitConsoleReplaysTheSharedLifecycleFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/git/console-lifecycle-v1.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixture consoleLifecycleFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if fixture.Version != 1 || len(fixture.Cases) == 0 {
		t.Fatalf("fixture version %d with %d cases, want version 1 with cases", fixture.Version, len(fixture.Cases))
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			console := newTestConsole()
			for i, step := range c.Steps {
				if step.Clear {
					console.Clear()
				} else {
					console.receive("", step.Event)
				}
				snapshot := console.Snapshot()
				commands := make([][]string, len(snapshot.Records))
				var errs, roots, states []string
				for j, record := range snapshot.Records {
					commands[j] = record.Arguments
					if record.Error != "" {
						errs = append(errs, record.Error)
					}
					roots = append(roots, record.Root)
					states = append(states, record.State)
				}
				if !slices.EqualFunc(commands, step.Commands, slices.Equal) {
					t.Fatalf("step %d: commands = %q, want %q", i, commands, step.Commands)
				}
				want := slices.Clone(step.Running)
				slices.Sort(want)
				if got := console.runningOperations(); !slices.Equal(got, want) {
					t.Fatalf("step %d: running = %q, want %q", i, got, want)
				}
				if snapshot.Running != (len(want) > 0) {
					t.Fatalf("step %d: snapshot running = %v, want %v", i, snapshot.Running, len(want) > 0)
				}
				if step.Errors != nil && !slices.Equal(errs, step.Errors) {
					t.Fatalf("step %d: errors = %q, want %q", i, errs, step.Errors)
				}
				if step.Roots != nil && !slices.Equal(roots, step.Roots) {
					t.Fatalf("step %d: roots = %q, want %q", i, roots, step.Roots)
				}
				if step.States != nil && !slices.Equal(states, step.States) {
					t.Fatalf("step %d: states = %q, want %q", i, states, step.States)
				}
			}
		})
	}
}

// consoleEvents feeds events, written as JSON objects, to console as one request's.
func consoleEvents(t *testing.T, console *GitConsole, root string, events ...string) {
	t.Helper()
	for _, event := range events {
		if !json.Valid([]byte(event)) {
			t.Fatalf("invalid test event %s", event)
		}
		console.receive(root, json.RawMessage(event))
	}
}

func TestGitConsoleKeepsOutputWithinTheRetentionBudget(t *testing.T) {
	console := newTestConsole()
	changes := 0
	console.changed = func() { changes++ }
	consoleEvents(t, console, "/repo",
		`{"operationId":"a","type":"requestStarted","retention":{"maxRecords":2,"maxRecordOutputCharacters":8,"maxRecordOutputLines":2,"maxTotalOutputCharacters":12}}`,
		`{"operationId":"a","type":"started","invocationId":1,"arguments":["fetch"]}`,
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"one"}`,
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stderr","text":"two"}`,
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"three"}`,
	)
	record := console.Snapshot().Records[0]
	if record.Root != "/repo" {
		t.Fatalf("root = %q, want the request's root /repo", record.Root)
	}
	// "three" alone is six bytes of the eight the record may hold; the older lines went.
	if len(record.Lines) != 1 || record.Lines[0].Text != "three" || !record.Truncated {
		t.Fatalf("lines = %+v truncated %v, want only three and truncated", record.Lines, record.Truncated)
	}
	consoleEvents(t, console, "/repo",
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"Receiving 50%","progress":true}`,
	)
	if got := console.Snapshot().Records[0].Progress; got != "Receiving 50%" {
		t.Fatalf("progress = %q, want the transient line", got)
	}
	// A line longer than the record keeps its end, cut on a character boundary.
	consoleEvents(t, console, "/repo",
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"abc日本語"}`,
		`{"operationId":"a","type":"finished","invocationId":1,"exitCode":0,"durationMilliseconds":1500,"state":"completed"}`,
		`{"operationId":"a","type":"requestFinished","unconfirmedInvocations":[],"failureRecord":false}`,
	)
	record = console.Snapshot().Records[0]
	if last := record.Lines[len(record.Lines)-1].Text; last != "本語" {
		t.Fatalf("last line = %q, want the end that fits, 本語", last)
	}
	if record.Progress != "" || record.State != GitConsoleCompleted || !record.Exited || record.ExitCode != 0 || record.Duration != 1500*time.Millisecond {
		t.Fatalf("finished record = %+v", record)
	}

	// The third record drops the first: only two may be kept.
	for _, id := range []string{"b", "c"} {
		consoleEvents(t, console, "/other",
			`{"operationId":"`+id+`","type":"requestStarted"}`,
			`{"operationId":"`+id+`","type":"started","invocationId":1,"workingDirectory":"/work","arguments":["status"]}`,
			`{"operationId":"`+id+`","type":"output","invocationId":1,"stream":"stdout","text":"1234567"}`,
		)
	}
	snapshot := console.Snapshot()
	if len(snapshot.Records) != 1 || !snapshot.Omitted {
		// b and c each hold eight bytes; together they pass the twelve the console may hold,
		// so b went too.
		t.Fatalf("records = %d omitted %v, want only the newest and omitted", len(snapshot.Records), snapshot.Omitted)
	}
	if snapshot.Records[0].Root != "/work" || snapshot.Records[0].OperationID != "c" {
		t.Fatalf("kept record = %+v, want c in its working directory", snapshot.Records[0])
	}
	if !snapshot.Running {
		t.Fatal("running = false while c has not finished")
	}
	if changes == 0 {
		t.Fatal("changed was never called")
	}
	console.Clear()
	if snapshot := console.Snapshot(); len(snapshot.Records) != 0 || snapshot.Omitted || !snapshot.Running {
		t.Fatalf("after Clear = %+v, want no records, not omitted, c still running", snapshot)
	}
}

func TestGitConsoleSnapshotsDoNotChangeAfterwards(t *testing.T) {
	console := newTestConsole()
	consoleEvents(t, console, "/repo",
		`{"operationId":"a","type":"requestStarted"}`,
		`{"operationId":"a","type":"started","invocationId":1,"arguments":["fetch"]}`,
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"first"}`,
	)
	before := console.Snapshot()
	consoleEvents(t, console, "/repo",
		`{"operationId":"a","type":"output","invocationId":1,"stream":"stdout","text":"second"}`,
		`{"operationId":"a","type":"remoteResult","invocationId":1,"remote":"origin","succeeded":true,"referencesAvailable":true,"updatedReferenceCount":0,"deletedReferences":[]}`,
		`{"operationId":"a","type":"finished","invocationId":1,"exitCode":0,"state":"completed"}`,
	)
	after := console.Snapshot()
	if len(before.Records[0].Lines) != 1 || before.Records[0].State != GitConsoleRunning || before.Records[0].RemoteResult != nil {
		t.Fatalf("earlier snapshot changed: %+v", before.Records[0])
	}
	if after.Revision <= before.Revision || after.Records[0].Revision <= before.Records[0].Revision {
		t.Fatalf("revisions %d→%d and record %d→%d, want both to grow", before.Revision, after.Revision, before.Records[0].Revision, after.Records[0].Revision)
	}
	result := after.Records[0].RemoteResult
	if result == nil || result.UpdatedReferences == nil || *result.UpdatedReferences != 0 || result.DeletedReferences == nil || *result.DeletedReferences != 0 {
		t.Fatalf("remote result = %+v, want both counts known and zero", result)
	}
}

// worktreeConsoleCommands are the commands of the console's records that run git worktree.
func worktreeConsoleCommands(console *GitConsole) []string {
	var commands []string
	for _, record := range console.Snapshot().Records {
		if len(record.Arguments) > 1 && record.Arguments[0] == "worktree" {
			commands = append(commands, record.Arguments[1])
		}
	}
	return commands
}

func TestGitWorktreesAreManagedAndRecordedInTheConsole(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	console := NewGitConsole(nil)
	ctx := WithGitConsole(testContext(t), console, repo)
	destination := filepath.Join(t.TempDir(), "linked")

	if err := client.GitCreateWorktree(ctx, repo, GitWorktreeCreation{
		Mode: GitWorktreeNewBranch, Name: "linked", Reference: new(localBranch("main")), Destination: destination,
	}); err != nil {
		t.Fatalf("GitCreateWorktree() error: %v", err)
	}
	worktrees, err := client.GitWorktrees(ctx, repo)
	if err != nil {
		t.Fatalf("GitWorktrees() error: %v", err)
	}
	if len(worktrees) != 2 || !worktrees[0].IsPrimary || !worktrees[0].IsCurrent {
		t.Fatalf("worktrees = %+v, want the primary current one and the linked one", worktrees)
	}
	linked := worktrees[1]
	if linked.Branch != "refs/heads/linked" || linked.IsPrimary || linked.IsCurrent || linked.Head == "" {
		t.Fatalf("linked worktree = %+v", linked)
	}

	if err := client.GitLockWorktree(ctx, repo, linked.Path); err != nil {
		t.Fatalf("GitLockWorktree() error: %v", err)
	}
	requireCode(t, client.GitRemoveWorktree(ctx, repo, linked.Path, false), CodeGitWorktreeLocked)
	if err := client.GitUnlockWorktree(ctx, repo, linked.Path); err != nil {
		t.Fatalf("GitUnlockWorktree() error: %v", err)
	}
	writeFile(t, filepath.Join(destination, "dirty.txt"), "dirty\n")
	requireCode(t, client.GitRemoveWorktree(ctx, repo, linked.Path, false), CodeGitWorktreeHasChanges)
	if err := client.GitRemoveWorktree(ctx, repo, linked.Path, true); err != nil {
		t.Fatalf("GitRemoveWorktree(force) error: %v", err)
	}
	if _, err := os.Stat(destination); !os.IsNotExist(err) {
		t.Fatalf("checkout still exists after the forced removal: %v", err)
	}
	if branches := runGit(t, repo, "branch", "--list", "linked"); !strings.Contains(branches, "linked") {
		t.Fatalf("branch linked was deleted with its worktree: %q", branches)
	}
	if err := client.GitPruneWorktrees(ctx, repo); err != nil {
		t.Fatalf("GitPruneWorktrees() error: %v", err)
	}
	if err := client.GitRepairWorktrees(ctx, repo); err != nil {
		t.Fatalf("GitRepairWorktrees() error: %v", err)
	}

	want := []string{"add", "lock", "unlock", "remove", "remove", "prune", "repair"}
	if got := worktreeConsoleCommands(console); !slices.Equal(got, want) {
		t.Fatalf("console worktree commands = %q, want %q", got, want)
	}
	snapshot := console.Snapshot()
	var locked GitConsoleRecord
	for _, record := range snapshot.Records {
		if len(record.Arguments) == 0 && record.Error != "" {
			locked = record
		}
	}
	if locked.State != GitConsoleUnconfirmed || locked.Root != repo {
		t.Fatalf("removal refused before Git ran = %+v, want an unconfirmed failure of %s", locked, repo)
	}

	presentation, err := client.GitConsolePresentation(testContext(t), snapshot.Records, "worktree")
	if err != nil {
		t.Fatalf("GitConsolePresentation() error: %v", err)
	}
	if len(presentation.Entries) != len(snapshot.Records) {
		t.Fatalf("entries = %d, want one per record (%d)", len(presentation.Entries), len(snapshot.Records))
	}
	failed := 0
	matched := 0
	for i, entry := range presentation.Entries {
		if entry.ID != snapshot.Records[i].ID {
			t.Fatalf("entry %d is %s, want record %s", i, entry.ID, snapshot.Records[i].ID)
		}
		if entry.Failed {
			failed++
		}
		matched += entry.Matches
	}
	// The locked removal failed before Git ran and the dirty one exited with an error.
	if failed != 2 {
		t.Fatalf("failed entries = %d, want 2", failed)
	}
	if presentation.TotalMatches == 0 || matched != presentation.TotalMatches || len(presentation.Hits) == 0 {
		t.Fatalf("matches: total %d, per entry %d, hits %d", presentation.TotalMatches, matched, len(presentation.Hits))
	}
}

func TestGitConsoleRecordsNothingForADetachedContext(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	console := NewGitConsole(nil)
	attached := WithGitConsole(testContext(t), console, repo)
	if _, err := client.GitWorktrees(WithGitConsole(attached, nil, ""), filepath.Join(repo, "missing")); err == nil {
		t.Fatal("GitWorktrees() of a missing directory succeeded")
	}
	if records := console.Snapshot().Records; len(records) != 0 {
		t.Fatalf("detached request recorded %+v", records)
	}
	// An unrecorded command leaves the console alone even when it fails.
	if _, err := client.GitConsolePresentation(attached, []GitConsoleRecord{{ID: "x", State: "running"}}, strings.Repeat("x", GitConsoleSearchLimit+1)); err == nil {
		t.Fatal("GitConsolePresentation() accepted a search over the limit")
	}
	if records := console.Snapshot().Records; len(records) != 0 {
		t.Fatalf("presentation request recorded %+v", records)
	}
}
