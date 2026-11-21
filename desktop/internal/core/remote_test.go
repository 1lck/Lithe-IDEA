package core

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

// standInSSH puts an ssh on PATH that ignores its options and, after asking for a password
// through the AskPass helper Core names, runs the remote command with the local shell. A wrong
// or cancelled answer fails like a server rejecting it.
func standInSSH(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in SSH client is a POSIX shell script")
	}
	dir := t.TempDir()
	script := `#!/bin/sh
for last; do :; done
answer=$("$SSH_ASKPASS" "dev@devbox's password: ") || answer=
if [ "$answer" != "s3cret" ]; then
  echo 'dev@devbox: Permission denied (password).' >&2
  exit 255
fi
exec /bin/sh -c "$last"
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// A probe relays OpenSSH's password question as a Remote challenge, sends the answer, and reports
// the platform the host's shell printed.
func TestRemoteProbeAsksThroughTheHostAndReportsThePlatform(t *testing.T) {
	standInSSH(t)
	client := NewClient()
	var mu sync.Mutex
	var challenges []GitAuthChallenge
	var replies sync.WaitGroup
	prompt := func(challenge GitAuthChallenge) {
		mu.Lock()
		challenges = append(challenges, challenge)
		mu.Unlock()
		replies.Add(1)
		go func() {
			defer replies.Done()
			accepted, err := client.RemoteAuthRespond(testContext(t), challenge.RequestID, answerText("s3cret"))
			if err != nil || !accepted {
				t.Errorf("answer: accepted = %v, err = %v", accepted, err)
			}
		}()
	}
	var result RemoteProbeResult
	var err error
	finishesWithin(t, "probe", testDeadline, func() {
		result, err = client.RemoteProbe(WithGitAuthentication(testContext(t), prompt), SSHConnection{Host: "devbox", User: "dev"}, nil)
	})
	finishesWithin(t, "answers", testDeadline, replies.Wait)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(challenges) != 1 {
		t.Fatalf("challenges = %+v, want the one password question", challenges)
	}
	asked := challenges[0]
	if !asked.Remote || asked.Retry || !asked.Secret || !strings.Contains(asked.Prompt, "password") || asked.Attempt != 1 {
		t.Fatalf("question = %+v, want OpenSSH's secret password question from a remote connection", asked)
	}
	select {
	case <-asked.Done:
	default:
		t.Fatal("the question is still open after the probe returned")
	}
	if result.Host == nil || result.Host.System == "" || result.Host.Machine == "" || !filepath.IsAbs(result.Host.HomeDirectory) {
		t.Fatalf("host = %+v, want the shell's platform report", result.Host)
	}
	// The local machine is the host here, so whether a server build exists depends on it.
	want := RemoteProbeUnsupportedPlatform
	if result.Host.ServerTarget != "" {
		want = RemoteProbeConnected
	}
	if result.Status != want || result.Host.Details.CPUCount == 0 {
		t.Fatalf("result = %+v, want %s with details", result, want)
	}
}

// Without a prompt in the context each question is cancelled at once, so the probe ends with the
// server's refusal instead of waiting for Core's prompt deadline.
func TestRemoteProbeWithoutAPromptCancelsEachQuestion(t *testing.T) {
	standInSSH(t)
	var result RemoteProbeResult
	var err error
	finishesWithin(t, "probe", testDeadline, func() {
		result, err = NewClient().RemoteProbe(testContext(t), SSHConnection{Host: "devbox", User: "dev"}, nil)
	})
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if result.Status != RemoteProbeAuthenticationFailed || result.Host != nil || !strings.Contains(result.Diagnostics, "Permission denied") {
		t.Fatalf("result = %+v, want the authentication failure", result)
	}
}

// The saved connections round-trip through the document Core returns, an edit that changes
// nothing returns no document, and a refused entry or document names the field and the reason.
func TestRemoteConnectionsRoundTripAndNameRefusedFields(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	plan, err := client.RemoteConnections(ctx, nil)
	if err != nil || len(plan.Connections) != 0 || plan.Storage.RelativePath != "remote/connections.json" || plan.Storage.MaximumBytes <= 0 {
		t.Fatalf("plan = %+v, err = %v", plan, err)
	}
	saved, err := client.EditRemoteConnections(ctx, nil, RemoteConnectionEdit{Save: &RemoteConnectionSave{
		Name: "Build box",
		Connection: SSHConnection{
			Host:           "build.example",
			User:           "dev",
			Authentication: RemoteAuthenticationPrivateKey,
			IdentityFile:   "~/.ssh/id_ed25519",
		},
	}})
	if err != nil || !saved.Changed || saved.Document == nil || saved.ID == "" {
		t.Fatalf("save = %+v, err = %v", saved, err)
	}
	listed, err := client.RemoteConnections(ctx, saved.Document)
	if err != nil || len(listed.Connections) != 1 {
		t.Fatalf("listed = %+v, err = %v", listed, err)
	}
	entry := listed.Connections[0]
	if entry.ID != saved.ID || entry.Name != "Build box" || entry.Connection.IdentityFile != "~/.ssh/id_ed25519" {
		t.Fatalf("entry = %+v", entry)
	}
	unchanged, err := client.EditRemoteConnections(ctx, saved.Document, RemoteConnectionEdit{Remove: &RemoteConnectionID{ID: "absent"}})
	if err != nil || unchanged.Changed || unchanged.Document != nil || len(unchanged.Connections) != 1 {
		t.Fatalf("no-op = %+v, err = %v", unchanged, err)
	}

	_, err = client.EditRemoteConnections(ctx, nil, RemoteConnectionEdit{Save: &RemoteConnectionSave{
		Name:       "Box",
		Connection: SSHConnection{Host: "dev@box"},
	}})
	if field, reason, ok := RemoteConnectionFieldError(err); !ok || field != "host" || reason != "invalid" {
		t.Fatalf("host with a user: %v (%q, %q, %v)", err, field, reason, ok)
	}
	damaged := `{"version":2,"connections":[]}`
	_, err = client.RemoteConnections(ctx, &damaged)
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeParseFailed {
		t.Fatalf("damaged document: %v, want a parse failure", err)
	}
	if field, reason, ok := RemoteConnectionFieldError(err); !ok || field != "version" || reason != "invalid" {
		t.Fatalf("damaged document: (%q, %q, %v)", field, reason, ok)
	}
	if _, _, ok := RemoteConnectionFieldError(&Error{Code: CodeUnknown, Details: `{"field":"host","reason":"invalid"}`}); ok {
		t.Fatal("an unrelated error named a field")
	}
}
