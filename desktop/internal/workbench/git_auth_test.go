package workbench

import (
	"context"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// refusingRemote is a Git HTTP remote that refuses every request with a Basic challenge and
// records the credentials each request carried.
type refusingRemote struct {
	url         string
	mu          sync.Mutex
	credentials []string
}

func newRefusingRemote(t *testing.T) *refusingRemote {
	t.Helper()
	remote := &refusingRemote{}
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

func (r *refusingRemote) received() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.credentials)
}

// key presses key in the window and paints what it did, without waiting for the background
// work it started: a Git operation that asks stays running until the question is answered.
func (h *harness) key(key gfx.Key) {
	h.t.Helper()
	if err := h.driver.Key(key, 0); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
}

// typeText types value into the focused field and paints it.
func (h *harness) typeText(value string) {
	h.t.Helper()
	if err := h.driver.Type(value); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
}

// awaitGitQuestion waits until the window shows a question that asked holds and paints it
// with the field focused.
func (h *harness) awaitGitQuestion(what string, asked func(core.GitAuthChallenge) bool) gitAuthQuestion {
	h.t.Helper()
	h.await(what, func() bool { return len(h.app.gitAuth.queue) > 0 && asked(h.app.gitAuth.queue[0].GitAuthChallenge) })
	for range 2 {
		if err := h.driver.Pump(); err != nil {
			h.t.Fatal(err)
		}
	}
	return h.app.gitAuth.queue[0]
}

// gitAuthActions are the answers the window logged as performed, in order.
func gitAuthActions(logger *treeRecordingLog) []string {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var actions []string
	for _, event := range logger.events {
		if action, _ := event.Fields["action"].(string); event.Event == "app.action.performed" && strings.HasPrefix(action, "git.authentication.") {
			actions = append(actions, event.Fields["action"].(string))
		}
	}
	return actions
}

// A clone the user started asks for the user name and the password in the window, through the
// real Core and Git: the password field hides what is typed, both answers reach the remote, and
// cancelling the question whether to retry ends the clone with its failure in the dialog.
func TestCloneAsksForCredentialsInTheWindow(t *testing.T) {
	requireTestGit(t)
	remote := newRefusingRemote(t)
	h := newHarnessWithLanguages(t, &gitKernel{Client: core.NewClient()}, []string{"en-US"})
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	lang := h.app.language()
	parent := t.TempDir()
	h.app.openClone(surfaceButton)
	h.app.clone.source.SetText(remote.url)
	h.app.clone.parent.SetText(parent)
	h.app.clone.name.SetText("project")
	h.app.submitClone()

	user := h.awaitGitQuestion("the user name question", func(c core.GitAuthChallenge) bool { return !c.Secret && !c.Retry })
	if !h.shows("Username for") || !h.showsWrapped(i18n.SharedFormat(lang, "desktop.gitAuth.directory", map[string]string{"path": user.WorkingDirectory})) {
		t.Fatal("the dialog does not show Git's question and where it runs")
	}
	if got := h.focusedName(); got != i18n.Shared(lang, "desktop.gitAuth.answer") {
		t.Fatalf("focused %q, want the answer field", got)
	}
	h.typeText("alice")
	if !h.shows("alice") {
		t.Fatal("the user name field does not show what is typed")
	}
	h.key(gfx.KeyEnter)

	h.awaitGitQuestion("the password question", func(c core.GitAuthChallenge) bool { return c.Secret })
	if !h.shows("Password for") || h.shows("alice") || !h.showsWrapped(i18n.Shared(lang, "desktop.gitAuth.secretHint")) {
		t.Fatal("the password dialog does not show Git's question alone with the note that the answer is not kept")
	}
	if got := h.focusedName(); got != i18n.Shared(lang, "desktop.gitAuth.answer") {
		t.Fatalf("focused %q, want the new answer field", got)
	}
	h.typeText("s3cret")
	if h.shows("s3cret") {
		t.Fatal("the password field shows what is typed")
	}
	h.key(gfx.KeyEnter)

	h.awaitGitQuestion("the question whether to retry", func(c core.GitAuthChallenge) bool { return c.Retry })
	if !h.showsWrapped(i18n.Shared(lang, "desktop.gitAuth.retryMessage")) {
		t.Fatal("the retry question is not the translated one")
	}
	// Escape dismisses the topmost dialog, the question, and leaves the clone dialog alone.
	h.key(gfx.KeyEscape)
	if h.app.clone.cancelling || !h.app.clone.open {
		t.Fatal("Escape reached the clone dialog instead of the question")
	}
	h.await("the clone to fail", func() bool { return !h.app.clone.busy })
	h.settle()
	if h.app.clone.err == "" || h.app.project != nil || len(h.app.gitAuth.queue) != 0 {
		t.Fatalf("clone error = %q, project = %v, waiting = %d, want the failure and nothing waiting", h.app.clone.err, h.app.project, len(h.app.gitAuth.queue))
	}
	if got, want := remote.received(), []string{"alice:s3cret"}; !slices.Equal(got, want) {
		t.Fatalf("remote received %q, want %q", got, want)
	}
	want := []string{"git.authentication.answer", "git.authentication.answer", "git.authentication.cancel"}
	if got := gitAuthActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if _, err := os.Stat(filepath.Join(parent, "project")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the failed clone left its destination behind: %v", err)
	}
}

// gitAuthKernel answers git.authRespond with accept and records what it was sent.
type gitAuthKernel struct {
	*testKernel
	accept  func(answer *string) bool
	mu      sync.Mutex
	answers []string
}

const cancelAnswer = "<cancel>"

func (k *gitAuthKernel) GitAuthRespond(_ context.Context, _ string, answer *string) (bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if answer == nil {
		k.answers = append(k.answers, cancelAnswer)
	} else {
		k.answers = append(k.answers, *answer)
	}
	return k.accept(answer), nil
}

func (k *gitAuthKernel) sent() []string {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.answers)
}

// gitAuthHarness is a window whose kernel answers git.authRespond with accept and that waits
// on challenges.
func gitAuthHarness(t *testing.T, accept func(*string) bool, challenges ...core.GitAuthChallenge) (*harness, *gitAuthKernel, *treeRecordingLog) {
	t.Helper()
	kernel := &gitAuthKernel{testKernel: &testKernel{Client: core.NewClient()}, accept: accept}
	h := newHarnessWithLanguages(t, kernel, []string{"en-US"})
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	for _, challenge := range challenges {
		h.app.gitAuth.queue = append(h.app.gitAuth.queue, gitAuthQuestion{GitAuthChallenge: challenge})
	}
	h.app.invalidator.Invalidate()
	h.settle()
	h.settle()
	return h, kernel, logger
}

// An answer Core does not take while the request still runs is cancelled: if the cancel is
// taken, Core refused the answer and the window says why; if not, the question had expired and
// nothing is said. An answer to a question whose request returned is not followed up.
func TestGitAuthAnswerCoreDidNotTake(t *testing.T) {
	running := make(chan struct{})
	returned := make(chan struct{})
	close(returned)
	refusedNotice := i18n.Shared(i18n.English, "desktop.gitAuth.refused")
	cases := []struct {
		name   string
		done   chan struct{}
		accept func(*string) bool
		sent   []string
		notice bool
	}{
		{"refused", running, func(answer *string) bool { return answer == nil }, []string{"token", cancelAnswer}, true},
		{"expired", running, func(*string) bool { return false }, []string{"token", cancelAnswer}, false},
		{"returned", returned, func(*string) bool { return false }, []string{"token"}, false},
		{"accepted", running, func(*string) bool { return true }, []string{"token"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, kernel, logger := gitAuthHarness(t, c.accept, core.GitAuthChallenge{
				RequestID: "r1", Prompt: "Password for 'https://example.invalid': ", Secret: true, Attempt: 1, Done: c.done,
			})
			if got := h.focusedName(); got != i18n.Shared(i18n.English, "desktop.gitAuth.answer") {
				t.Fatalf("focused %q, want the answer field", got)
			}
			h.typeText("token")
			h.key(gfx.KeyEnter)
			h.settle()
			if got := kernel.sent(); !slices.Equal(got, c.sent) {
				t.Fatalf("sent %q, want %q", got, c.sent)
			}
			if len(h.app.gitAuth.queue) != 0 || h.app.gitAuth.field.Text() != "" {
				t.Fatal("the answered question or its answer stayed in the window")
			}
			if got := h.app.notice == refusedNotice; got != c.notice {
				t.Fatalf("notice = %q, want the refusal = %v", h.app.notice, c.notice)
			}
			logger.mu.Lock()
			rejected := slices.ContainsFunc(logger.events, func(event core.LogEvent) bool {
				return event.Event == operationRejectedEvent && event.Fields["operation"] == "git_authentication" && event.Fields["reason"] == "answer_refused"
			})
			logger.mu.Unlock()
			if rejected != c.notice {
				t.Fatalf("logged the refusal = %v, want %v", rejected, c.notice)
			}
		})
	}
}

// Questions are answered in the order they were asked, each with a field of its own: one whose
// request returned leaves with what was typed for it, the retry question answers with
// core.GitRetryAnswer, and dismissing the dialog cancels.
func TestGitAuthQuestionsQueueInOrder(t *testing.T) {
	running := make(chan struct{})
	h, kernel, logger := gitAuthHarness(t, func(*string) bool { return true },
		core.GitAuthChallenge{RequestID: "r1", Prompt: "Username for 'https://one.invalid': ", Attempt: 1, Done: running},
		core.GitAuthChallenge{RequestID: "r2", Prompt: "Enter passphrase for key '/k': ", Secret: true, Attempt: 2, Done: running},
		core.GitAuthChallenge{RequestID: "r3", Prompt: "Retry", Retry: true, Attempt: 2, Done: running},
		core.GitAuthChallenge{RequestID: "r4", Prompt: "Username for 'https://four.invalid': ", Attempt: 1, Done: running},
	)
	if !h.shows("Username for 'https://one.invalid':") || h.shows("passphrase") {
		t.Fatal("the dialog does not show the first question alone")
	}
	h.typeText("alice")
	// The request of the first question returns: gitAuthentication posts the drop like this.
	h.app.post(func(a *App) { a.dropGitAuth("r1") })
	h.settle()
	if h.app.gitAuth.field.Text() != "" {
		t.Fatal("the answer to a question whose request returned stayed in the window")
	}
	if !h.shows("Enter passphrase for key") || h.shows("alice") || !h.showsWrapped(i18n.SharedFormat(i18n.English, "desktop.gitAuth.again", map[string]string{"attempt": "2"})) {
		t.Fatal("the passphrase question asked again does not show alone with the note that it is asked again")
	}
	h.typeText("phrase")
	h.key(gfx.KeyEnter)
	h.settle()
	h.clickLabeled(i18n.Shared(i18n.English, "desktop.gitAuth.retry"))
	h.key(gfx.KeyEscape)
	h.settle()
	if got, want := kernel.sent(), []string{"phrase", core.GitRetryAnswer, cancelAnswer}; !slices.Equal(got, want) {
		t.Fatalf("sent %q, want %q", got, want)
	}
	if len(h.app.gitAuth.queue) != 0 || h.shows(i18n.Shared(i18n.English, "desktop.gitAuth.title")) {
		t.Fatal("the dialog stayed after every question was answered")
	}
	want := []string{"git.authentication.answer", "git.authentication.retry", "git.authentication.cancel"}
	if got := gitAuthActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
}
