package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
)

// TestMain lets this test binary serve as the AskPass helper Core names to the interactive Git
// processes the tests start: such a run relays its one question and exits instead of running the
// tests, as the Lithe executable does in main.
func TestMain(m *testing.M) {
	if prompt, helper := GitAskPassRequest(os.Args); helper {
		os.Exit(GitAskPass(prompt))
	}
	os.Exit(m.Run())
}

// authenticationRemote is a Git HTTP remote that refuses every request with a Basic challenge
// and records the credentials each request carried.
type authenticationRemote struct {
	url         string
	mu          sync.Mutex
	credentials []string
}

func newAuthenticationRemote(t *testing.T) *authenticationRemote {
	t.Helper()
	remote := &authenticationRemote{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if user, password, ok := r.BasicAuth(); ok {
			remote.mu.Lock()
			remote.credentials = append(remote.credentials, user+":"+password)
			remote.mu.Unlock()
		}
		w.Header().Set("WWW-Authenticate", `Basic realm="lithe-test"`)
		http.Error(w, "authentication required", http.StatusUnauthorized)
	}))
	t.Cleanup(server.Close)
	// A proxy of the host must not stand between Git and the local server.
	t.Setenv("no_proxy", "*")
	t.Setenv("NO_PROXY", "*")
	remote.url = server.URL + "/repository.git"
	return remote
}

func (r *authenticationRemote) received() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.credentials)
}

// repositoryOf creates a repository whose origin is remote.
func repositoryOf(t *testing.T, remote *authenticationRemote) string {
	t.Helper()
	repository := newRepository(t)
	runGit(t, repository, "remote", "add", "origin", remote.url)
	return repository
}

// fetchAnswering fetches the origin of repository in ctx, answering each challenge with answer
// off the request's goroutine as the workbench does, and returns the challenges in the order
// they were asked and the fetch's error. Every answer must be accepted.
func fetchAnswering(t *testing.T, ctx context.Context, repository string, answer func(GitAuthChallenge) *string) ([]GitAuthChallenge, error) {
	t.Helper()
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
			accepted, err := client.GitAuthRespond(testContext(t), challenge.RequestID, answer(challenge))
			if err != nil || !accepted {
				t.Errorf("answer to %q: accepted = %v, err = %v", challenge.Prompt, accepted, err)
			}
		}()
	}
	var err error
	finishesWithin(t, "interactive fetch", testDeadline, func() {
		err = client.GitFetch(WithGitAuthentication(ctx, prompt), repository, nil)
	})
	finishesWithin(t, "answers", testDeadline, replies.Wait)
	mu.Lock()
	defer mu.Unlock()
	return slices.Clone(challenges), err
}

// challengeKind names a challenge for comparisons: what it asks, not its wording.
func challengeKind(challenge GitAuthChallenge) string {
	switch {
	case challenge.Retry:
		return "retry"
	case challenge.Secret:
		return "secret"
	default:
		return "user"
	}
}

func answerText(s string) *string { return &s }

// A fetch the user started asks for the user name and the password through Lithe, sends them to
// the remote, and after the remote refuses them asks whether to retry; a retry asks again, and a
// cancelled retry question ends the fetch with the authentication failure.
func TestGitAuthenticationRelaysQuestionsAndAnswers(t *testing.T) {
	requireGit(t)
	remote := newAuthenticationRemote(t)
	repository := repositoryOf(t, remote)
	retries := 0
	challenges, err := fetchAnswering(t, testContext(t), repository, func(challenge GitAuthChallenge) *string {
		switch challengeKind(challenge) {
		case "user":
			return answerText("alice")
		case "secret":
			return answerText("s3cret")
		}
		retries++
		if retries == 1 {
			return answerText(GitRetryAnswer)
		}
		return nil
	})
	if !IsAuthenticationFailure(err) {
		t.Fatalf("fetch error = %v, want the authentication failure", err)
	}
	var kinds []string
	for _, challenge := range challenges {
		kinds = append(kinds, challengeKind(challenge))
	}
	if want := []string{"user", "secret", "retry", "user", "secret", "retry"}; !slices.Equal(kinds, want) {
		t.Fatalf("challenges = %q, want %q", kinds, want)
	}
	user, secret, retry := challenges[0], challenges[1], challenges[2]
	if !strings.Contains(user.Prompt, "Username") || user.Attempt != 1 || user.WorkingDirectory == "" {
		t.Fatalf("user question = %+v, want Git's question, attempt 1 and the working directory", user)
	}
	if !strings.Contains(secret.Prompt, "Password") || strings.Contains(secret.Prompt, "alice") {
		t.Fatalf("password question = %q, want Git's question without the user name", secret.Prompt)
	}
	if retry.Attempt != 2 || challenges[5].Attempt != 3 || retry.Prompt == "" {
		t.Fatalf("retry questions = %+v, %+v, want transfers 2 and 3", retry, challenges[5])
	}
	if got, want := remote.received(), []string{"alice:s3cret", "alice:s3cret"}; !slices.Equal(got, want) {
		t.Fatalf("remote received %q, want %q", got, want)
	}
	for _, challenge := range challenges {
		select {
		case <-challenge.Done:
		default:
			t.Fatalf("challenge %q is still open after its request returned", challenge.Prompt)
		}
	}
	// A dialog answered after the request returned reaches nothing.
	accepted, err := NewClient().GitAuthRespond(testContext(t), user.RequestID, answerText("late"))
	if err != nil || accepted {
		t.Fatalf("late answer: accepted = %v, err = %v, want refused", accepted, err)
	}
}

// Cancelling Git's question fails authentication without sending anything to the remote, and
// Core does not ask again whether to retry: the user has just declined.
func TestGitAuthenticationCancelledQuestionSendsNothing(t *testing.T) {
	requireGit(t)
	remote := newAuthenticationRemote(t)
	repository := repositoryOf(t, remote)
	challenges, err := fetchAnswering(t, testContext(t), repository, func(GitAuthChallenge) *string { return nil })
	if !IsAuthenticationFailure(err) {
		t.Fatalf("fetch error = %v, want the authentication failure", err)
	}
	var kinds []string
	for _, challenge := range challenges {
		kinds = append(kinds, challengeKind(challenge))
	}
	if len(kinds) != 1 || kinds[0] != "user" {
		t.Fatalf("challenges = %q, want only Git's user name question", kinds)
	}
	if got := remote.received(); len(got) != 0 {
		t.Fatalf("remote received %q, want no credentials", got)
	}
}

// An automatic refresh never asks, even in a context that could.
func TestGitAuthenticationAutomaticRefreshNeverAsks(t *testing.T) {
	requireGit(t)
	remote := newAuthenticationRemote(t)
	repository := repositoryOf(t, remote)
	challenges, err := fetchAnswering(t, AutomaticRefresh(testContext(t)), repository, func(GitAuthChallenge) *string { return answerText("alice") })
	if !IsAuthenticationFailure(err) {
		t.Fatalf("fetch error = %v, want the authentication failure", err)
	}
	if len(challenges) != 0 || len(remote.received()) != 0 {
		t.Fatalf("refresh asked %+v and sent %q, want neither", challenges, remote.received())
	}
}

// Only Git requests of a context that can ask are interactive, never an automatic refresh, and
// the observer hands only authentication events to the prompt while passing on every event.
func TestGitAuthenticationMarksOnlyRequestsThatCanAsk(t *testing.T) {
	prompt := func(GitAuthChallenge) {}
	asks := WithGitAuthentication(context.Background(), prompt)
	cases := []struct {
		name    string
		ctx     context.Context
		command string
		want    string
	}{
		{"asks", asks, "git.fetch", `{"interactive":true}`},
		{"refresh", AutomaticRefresh(asks), "git.fetch", `null`},
		{"answer", asks, "git.authRespond", `null`},
		{"never runs Git", asks, "git.consolePresentation", `null`},
		{"not Git", asks, "core.ping", `null`},
		{"cannot ask", context.Background(), "git.fetch", `null`},
	}
	for _, c := range cases {
		got, err := json.Marshal(gitExecutionOf(c.ctx, c.command))
		if err != nil || string(got) != c.want {
			t.Fatalf("%s: gitExecution = %s (%v), want %s", c.name, got, err, c.want)
		}
	}

	done := make(chan struct{})
	var asked []GitAuthChallenge
	var passed []string
	observe := gitAuthenticationObserver(func(challenge GitAuthChallenge) { asked = append(asked, challenge) }, done,
		func(raw json.RawMessage) { passed = append(passed, string(raw)) })
	events := []string{
		`{"type":"output","line":"authentication"}`,
		`{"type":"authentication","requestId":"","prompt":"Username"}`,
		`{"type":"authentication","requestId":"r1","prompt":"Password for 'https://example.invalid': ","secret":true,"attempt":1,"workingDirectory":"/repo"}`,
		`not json "authentication"`,
	}
	for _, event := range events {
		observe(json.RawMessage(event))
	}
	if !slices.Equal(passed, events) {
		t.Fatalf("passed on %q, want every event", passed)
	}
	if len(asked) != 1 {
		t.Fatalf("asked %+v, want only the complete authentication event", asked)
	}
	want := GitAuthChallenge{RequestID: "r1", Prompt: "Password for 'https://example.invalid': ", Secret: true, Attempt: 1, WorkingDirectory: "/repo", Done: done}
	if asked[0] != want {
		t.Fatalf("challenge = %+v, want %+v", asked[0], want)
	}
}
