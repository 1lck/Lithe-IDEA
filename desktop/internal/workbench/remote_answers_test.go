package workbench

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/gfx"
)

// standInSSHAccepting puts an ssh on PATH that asks OpenSSH's password question up to three times
// through the AskPass helper Core names, as OpenSSH does after a wrong password, and runs the
// remote command with the local shell once the answer is the password accept sets. A cancelled
// question, or three wrong answers, fail like a server rejecting them.
func standInSSHAccepting(t *testing.T) (accept func(string)) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in SSH client is a POSIX shell script")
	}
	dir := t.TempDir()
	script := `#!/bin/sh
for last; do :; done
accept=$(cat "$(dirname "$0")/accept")
for attempt in 1 2 3; do
  answer=$("$SSH_ASKPASS" "dev@devbox's password: ") || break
  if [ "$answer" = "$accept" ]; then
    exec /bin/sh -c "$last"
  fi
  echo 'Permission denied, please try again.' >&2
done
echo 'dev@devbox: Permission denied (password).' >&2
exit 255
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return func(password string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "accept"), []byte(password), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// saveRemoteDevbox saves dev@devbox from the empty page and returns its id, selected.
func saveRemoteDevbox(t *testing.T, h *harness) string {
	t.Helper()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("devbox")
	r.form.user.SetText("dev")
	h.redraw()
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.save"))
	h.settle()
	if r.entry(r.selected) == nil || r.dirty() {
		t.Fatal("the connection was not saved and selected")
	}
	return r.selected
}

// remoteAnswersContext bounds a test's reads and writes of the secret store.
func remoteAnswersContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// rememberedAnswers are the secrets the store keeps for remembered answers.
func rememberedAnswers(store *memorySecrets) []string {
	store.mu.Lock()
	defer store.mu.Unlock()
	var secrets []string
	for item, secret := range store.items {
		if strings.HasPrefix(item, remoteconn.AnswersNamespace+"\x00") {
			secrets = append(secrets, secret)
		}
	}
	return secrets
}

// clickNow clicks the control named label and paints what it did, without waiting for background
// work: a test that waits on a question runs until the question is answered.
func (h *harness) clickNow(label string) {
	h.t.Helper()
	point := center(h.hitLabeled(label))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		h.t.Fatal(err)
	}
	for range 2 {
		if err := h.driver.Pump(); err != nil {
			h.t.Fatal(err)
		}
	}
}

// testSavedRemote tests the selected saved connection and waits for its outcome, which logged in
// to the local machine: it connected, or found no server build for it.
func (h *harness) testSavedRemote(what string) {
	h.t.Helper()
	r := &h.app.remote
	h.app.testRemote()
	if r.probe == nil {
		h.t.Fatal("the test did not start")
	}
	h.await(what, func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if !remoteLoggedIn(r.result.result.Status, r.result.err) {
		h.t.Fatalf("outcome = %+v, want a login", r.result)
	}
}

// A saved connection's password question has a Remember box, unticked. A password typed with it
// ticked is remembered once the login succeeds, never after it fails, and the next test logs in
// without asking. A remembered password the host refuses is asked again, saying so, with the box
// ticked; the new one replaces it, and unticking the box forgets it. Neither a password, the host
// nor OpenSSH's output is logged.
func TestRemoteRemembersAPasswordOnlyWhenTicked(t *testing.T) {
	accept := standInSSHAccepting(t)
	accept("s3cret")
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	store := h.app.remoteSecretStore.(*memorySecrets)
	saveRemoteDevbox(t, h)
	remember := i18n.Shared(lang, "desktop.remoteAuth.rememberPassword")
	submit := i18n.Shared(lang, "desktop.gitAuth.submit")

	// A mistyped password is not remembered although the box was ticked.
	h.app.testRemote()
	h.awaitGitQuestion("the password question", func(c core.GitAuthChallenge) bool { return c.Remote && c.Kind == core.RemoteQuestionPassword })
	if !h.shows(remember) || h.app.gitAuth.remember || h.showsWrapped(i18n.Shared(lang, "desktop.remoteAuth.rememberHint")) {
		t.Fatal("the question does not offer an unticked Remember box")
	}
	h.typeText("wr0ng")
	h.clickNow(remember)
	if !h.app.gitAuth.remember || !h.showsWrapped(i18n.Shared(lang, "desktop.remoteAuth.rememberHint")) {
		t.Fatal("ticking Remember does not say where the password is kept")
	}
	h.clickNow(submit)
	h.awaitGitQuestion("the password question again", func(c core.GitAuthChallenge) bool { return c.Remote && c.Attempt == 2 })
	if !h.app.gitAuth.remember || h.showsWrapped(i18n.Shared(lang, "desktop.remoteAuth.rememberedRefused")) {
		t.Fatal("the question asked again after a typed password lost the box or blamed a remembered one")
	}
	h.key(gfx.KeyEscape)
	h.await("the test to fail", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if got := rememberedAnswers(store); len(got) != 0 {
		t.Fatalf("a password the host refused was remembered: %d items", len(got))
	}

	// The right one, ticked, is remembered once the login succeeds, and answers the next test.
	h.app.testRemote()
	h.awaitGitQuestion("the password question", func(c core.GitAuthChallenge) bool { return c.Remote && c.Attempt == 1 })
	if h.app.gitAuth.remember {
		t.Fatal("the box is ticked although nothing is remembered")
	}
	h.typeText("s3cret")
	h.clickNow(remember)
	h.clickNow(submit)
	h.await("the test to finish", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if got := rememberedAnswers(store); len(got) != 1 || !strings.Contains(got[0], "s3cret") {
		t.Fatal("the ticked password was not remembered after the login")
	}
	h.testSavedRemote("the test with the remembered password")
	if len(h.app.gitAuth.queue) != 0 {
		t.Fatal("the remembered password was asked for")
	}

	// The host refuses the remembered password: asked again, ticked, and the new one replaces it.
	accept("n3w")
	h.app.testRemote()
	h.awaitGitQuestion("the question after the refusal", func(c core.GitAuthChallenge) bool { return c.Remote && c.Attempt == 2 })
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remoteAuth.rememberedRefused")) || !h.app.gitAuth.remember {
		t.Fatal("the question does not say the remembered password was refused, with the box ticked")
	}
	h.typeText("n3w")
	h.key(gfx.KeyEnter)
	h.await("the test to finish", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if got := rememberedAnswers(store); len(got) != 1 || !strings.Contains(got[0], "n3w") || strings.Contains(got[0], "s3cret") {
		t.Fatal("the new password did not replace the refused one")
	}

	// Unticking the box forgets the password.
	accept("l4st")
	h.app.testRemote()
	h.awaitGitQuestion("the question after the second refusal", func(c core.GitAuthChallenge) bool { return c.Remote && c.Attempt == 2 })
	h.typeText("l4st")
	h.clickNow(remember)
	h.clickNow(submit)
	h.await("the test to finish", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if got := rememberedAnswers(store); len(got) != 0 {
		t.Fatal("unticking Remember kept the password")
	}

	want := []string{
		"remote.connections.open", "remote.connection.new", "remote.connection.save",
		"remote.connection.test", "remote.authentication.answer", "remote.authentication.cancel",
		"remote.connection.test", "remote.authentication.answer",
		"remote.connection.test",
		"remote.connection.test", "remote.authentication.answer",
		"remote.connection.test", "remote.authentication.answer",
	}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, "wr0ng", "s3cret", "n3w", "l4st", "devbox", "Permission denied"); event != "" {
		t.Fatalf("logged a password, the host or what OpenSSH said: %s", event)
	}
}

// Forget Remembered Passwords in the overview's ⋯ menu forgets what the connection remembers and
// says so; deleting the connection forgets it too.
func TestRemoteForgetsRememberedPasswords(t *testing.T) {
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	store := h.app.remoteSecretStore.(*memorySecrets)
	id := saveRemoteDevbox(t, h)
	name := r.entry(id).Name
	ctx := remoteAnswersContext(t)
	seed := func() {
		t.Helper()
		if err := remoteconn.ChangeAnswers(ctx, store, id, []remoteconn.AnswerChange{{Question: "question", Answer: "s3cret"}}); err != nil {
			t.Fatal(err)
		}
	}

	seed()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.more"))
	h.settle()
	h.clickFront(i18n.Shared(lang, "desktop.remote.forgetAnswers"))
	forgotten := i18n.SharedFormat(lang, "desktop.remote.answersForgotten", map[string]string{"name": name})
	h.await("the answers to be forgotten", func() bool { return slices.Contains(noticeTexts(h.app), forgotten) })
	if got := rememberedAnswers(store); len(got) != 0 {
		t.Fatal("Forget Remembered Passwords kept the password")
	}

	seed()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.more"))
	h.settle()
	h.clickFront(i18n.SharedFormat(lang, "desktop.remote.deleteNamed", map[string]string{"name": name}))
	h.settle()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.delete"))
	h.await("the deleted connection's answers to be forgotten", func() bool { return len(rememberedAnswers(store)) == 0 })
	h.settle()
	if len(savedRemoteConnections(t, h)) != 0 {
		t.Fatal("the connection was not deleted")
	}
	want := []string{
		"remote.connections.open", "remote.connection.new", "remote.connection.save",
		"remote.connection.forgetAnswers", "remote.connection.deleteAsk", "remote.connection.remove",
	}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, "s3cret", "devbox"); event != "" {
		t.Fatalf("logged a password or the host: %s", event)
	}
}

// remoteAnswerKernel records the answers sent to the questions of remote connections, and
// signals responded for each.
type remoteAnswerKernel struct {
	*testKernel
	responded chan struct{}
	mu        sync.Mutex
	answers   []*string
}

func (k *remoteAnswerKernel) RemoteAuthRespond(_ context.Context, _ string, answer *string) (bool, error) {
	k.mu.Lock()
	k.answers = append(k.answers, answer)
	k.mu.Unlock()
	k.responded <- struct{}{}
	return true, nil
}

// awaitResponse waits for the next answer: an automatic one reaches Core without the window.
func (k *remoteAnswerKernel) awaitResponse(t *testing.T, what string) {
	t.Helper()
	select {
	case <-k.responded:
	case <-time.After(8 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

// sent are the answers recorded, "" for a cancel.
func (k *remoteAnswerKernel) sent() []string {
	k.mu.Lock()
	defer k.mu.Unlock()
	var sent []string
	for _, answer := range k.answers {
		if answer == nil {
			sent = append(sent, "")
		} else {
			sent = append(sent, *answer)
		}
	}
	return sent
}

// An automatic reconnection sends the remembered password the first time OpenSSH asks and cancels
// every other question without showing it; a refused password is forgotten once it ends.
func TestRemoteReconnectionSendsOnlyTheRememberedPassword(t *testing.T) {
	kernel := &remoteAnswerKernel{testKernel: &testKernel{Client: core.NewClient()}, responded: make(chan struct{}, 4)}
	h := newHarnessWithLanguages(t, kernel, []string{"en-US"})
	store := h.app.remoteSecretStore.(*memorySecrets)
	host := remoteHost{ssh: core.SSHConnection{Host: "devbox", User: "dev"}}
	answers := h.app.remoteAnswersFor("build", host)
	if h.app.remoteAnswersFor("", host) != nil || h.app.remoteAnswersFor("build", remoteHost{wsl: &core.WSLConnection{Distribution: "Ubuntu"}}) != nil {
		t.Fatal("an unsaved connection or a WSL distribution remembers answers")
	}
	if other := h.app.remoteAnswersFor("build/container", host); other == nil || other.owner != "build" {
		t.Fatal("a container on a saved host does not use the host's answers")
	}
	prompt := "dev@devbox's password: "
	question := remoteconn.AnswerQuestion(core.RemoteQuestionPassword, answers.login, prompt)
	ctx := remoteAnswersContext(t)
	if err := remoteconn.ChangeAnswers(ctx, store, "build", []remoteconn.AnswerChange{{Question: question, Answer: "s3cret"}}); err != nil {
		t.Fatal(err)
	}
	ask := h.app.remotePrompt(ctx, answers, false)
	done := make(chan struct{})
	t.Cleanup(func() { close(done) })
	challenge := func(id string, kind core.RemoteQuestionKind, attempt int) core.GitAuthChallenge {
		return core.GitAuthChallenge{RequestID: id, Prompt: prompt, Secret: true, Remote: true, Kind: kind, Attempt: attempt, Done: done}
	}
	for _, step := range []struct {
		challenge core.GitAuthChallenge
		want      []string
	}{
		{challenge("1", core.RemoteQuestionPassword, 1), []string{"s3cret"}},
		{challenge("2", core.RemoteQuestionPassword, 2), []string{"s3cret", ""}},
		{challenge("3", core.RemoteQuestionCode, 1), []string{"s3cret", "", ""}},
	} {
		ask(step.challenge)
		kernel.awaitResponse(t, "the answer to "+step.challenge.RequestID)
		if got := kernel.sent(); !slices.Equal(got, step.want) {
			t.Fatalf("sent %q, want %q", got, step.want)
		}
	}
	h.settle()
	if len(h.app.gitAuth.queue) != 0 {
		t.Fatal("an automatic reconnection showed a question")
	}
	if err := answers.settle(core.RemoteProbeAuthenticationFailed, nil); err != nil {
		t.Fatal(err)
	}
	if got := rememberedAnswers(store); len(got) != 0 {
		t.Fatal("the refused password is still remembered")
	}
}

// What a connection learned is applied by how it ended: a typed password is remembered only after
// a login, a remembered one is forgotten when the login fails without a question cancelled, and
// one the host refused is forgotten whatever the outcome.
func TestRemoteAnswersSettleByOutcome(t *testing.T) {
	ctx := remoteAnswersContext(t)
	for _, test := range []struct {
		name      string
		answers   *remoteAnswers
		status    core.RemoteProbeStatus
		err       error
		remembers []string
	}{
		{"typed, connected", &remoteAnswers{choices: []remoteconn.AnswerChange{{Question: "q", Answer: "typed"}}}, core.RemoteProbeConnected, nil, []string{"typed"}},
		{"typed, no server build", &remoteAnswers{choices: []remoteconn.AnswerChange{{Question: "q", Answer: "typed"}}}, core.RemoteProbeUnsupportedPlatform, nil, []string{"typed"}},
		{"typed, refused", &remoteAnswers{choices: []remoteconn.AnswerChange{{Question: "q", Answer: "typed"}}}, core.RemoteProbeAuthenticationFailed, nil, []string{"old"}},
		{"typed, failed to run", &remoteAnswers{choices: []remoteconn.AnswerChange{{Question: "q", Answer: "typed"}}}, core.RemoteProbeConnected, context.DeadlineExceeded, []string{"old"}},
		{"unticked, refused", &remoteAnswers{choices: []remoteconn.AnswerChange{{Question: "q", Forget: true}}}, core.RemoteProbeAuthenticationFailed, nil, nil},
		{"sent, refused", &remoteAnswers{sent: map[string]bool{"q": true}}, core.RemoteProbeAuthenticationFailed, nil, nil},
		{"sent, refused after a cancel", &remoteAnswers{sent: map[string]bool{"q": true}, cancelled: true}, core.RemoteProbeAuthenticationFailed, nil, []string{"old"}},
		{"sent, unreachable", &remoteAnswers{sent: map[string]bool{"q": true}}, core.RemoteProbeUnreachable, nil, []string{"old"}},
		{"asked again, connected", &remoteAnswers{refused: map[string]bool{"q": true}}, core.RemoteProbeConnected, nil, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			store := &memorySecrets{}
			if err := remoteconn.ChangeAnswers(ctx, store, "build", []remoteconn.AnswerChange{{Question: "q", Answer: "old"}}); err != nil {
				t.Fatal(err)
			}
			answers := test.answers
			answers.secrets, answers.owner = store, "build"
			if err := answers.settle(test.status, test.err); err != nil {
				t.Fatal(err)
			}
			var remembers []string
			if answer, found, err := remoteconn.RememberedAnswer(ctx, store, "build", "q"); err != nil {
				t.Fatal(err)
			} else if found {
				remembers = append(remembers, answer)
			}
			if !slices.Equal(remembers, test.remembers) {
				t.Fatalf("remembers %q, want %q", remembers, test.remembers)
			}
			if answers.sent != nil || answers.refused != nil || answers.cancelled || answers.choices != nil {
				t.Fatal("settling kept what the connection learned")
			}
		})
	}
	var none *remoteAnswers
	if err := none.settle(core.RemoteProbeConnected, nil); err != nil {
		t.Fatal(err)
	}
}
