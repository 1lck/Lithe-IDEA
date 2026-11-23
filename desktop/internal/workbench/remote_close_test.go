package workbench

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// memorySecrets is the secret store of the tests' kept host sessions; failSet fails every
// write.
type memorySecrets struct {
	mu      sync.Mutex
	items   map[string]string
	failSet error
}

func (s *memorySecrets) Get(_ context.Context, namespace, key string) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	secret, found := s.items[namespace+"\x00"+key]
	return secret, found, nil
}

func (s *memorySecrets) Set(_ context.Context, namespace, key, secret string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failSet != nil {
		return s.failSet
	}
	if s.items == nil {
		s.items = map[string]string{}
	}
	s.items[namespace+"\x00"+key] = secret
	return nil
}

func (s *memorySecrets) Delete(_ context.Context, namespace, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.items, namespace+"\x00"+key)
	return nil
}

// remoteTestPrograms are what the host runs for the workspace: a named terminal that has run for
// two hours and five minutes, and an unnamed process started half a minute ago.
var remoteTestPrograms = []core.RemoteProgram{
	{Kind: core.RemoteProgramTerminal, ID: 1, Argv: []string{"/bin/bash", "-l"}, Label: &core.RemoteResourceLabel{Kind: "terminal", Name: "watch-shell"}, RunningMs: 125 * 60_000},
	{Kind: core.RemoteProgramProcess, ID: 7, Argv: []string{"npm", "run", "dev"}, RunningMs: 30_000},
}

// The values the log must never hold: the programs' commands and names, and the session tokens.
var remoteCloseSecrets = []string{"npm run dev", "/bin/bash", "watch-shell", "token-"}

// keptOf is the session the host keeps for the saved connection's next connection, nil for none.
func keptOf(t *testing.T, h *harness) *core.RemoteResume {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resume, err := remoteconn.NewestKept(ctx, h.app.remoteSecretStore, savedRemoteConnections(t, h)[0].ID)
	if err != nil {
		t.Fatalf("read the kept sessions: %v", err)
	}
	return resume
}

// closeQuestion closes the project and waits for the question about the host's programs.
func (h *harness) closeQuestion(t *testing.T) *pluginPrompt {
	t.Helper()
	h.app.closeProject()
	h.await("the question about the host's programs", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	return h.app.prompts.queue[0]
}

// answer answers the prompt shown with the action numbered choice.
func (h *harness) answer(choice int) {
	h.app.answerPrompt(&choice)
	h.settle()
}

// awaitClosed waits until the project is closed.
func (h *harness) awaitClosed(t *testing.T) {
	t.Helper()
	h.await("the project closed", func() bool { return h.app.project == nil && !h.app.closingProject })
	h.settle()
}

// remoteChoices are what the host's sessions were closed with, in order.
func remoteChoices(k *remoteHostKernel) []core.RemoteClosePrograms {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.close.choices)
}

// A remote workspace whose host runs nothing of it closes without a question and ends its session.
func TestRemoteCloseEndsWithoutAQuestionWhenTheHostRunsNothing(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	h.openRemoteTestProject(t)
	h.app.closeProject()
	h.awaitClosed(t)
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("closing asked although the host runs nothing")
	}
	if got := remoteChoices(k); !slices.Equal(got, []core.RemoteClosePrograms{core.RemoteCloseEnd}) {
		t.Fatalf("closed the session with %q, want end", got)
	}
}

// While the host runs programs of the workspace, closing asks with their kind, name, command and
// running time; Cancel keeps the workspace open and connected, and End and Close ends them. The
// commands are shown as they are and never logged.
func TestRemoteCloseAsksWhileTheHostRunsPrograms(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })

	prompt := h.closeQuestion(t)
	if prompt.title != i18n.Shared(lang, "desktop.remote.close.title") {
		t.Fatalf("title %q", prompt.title)
	}
	for _, want := range []string{
		i18n.SharedFormat(lang, "desktop.remote.close.running", map[string]string{"connection": remoteTestHost}),
		"• Terminal “watch-shell”: /bin/bash -l (running for 2 h 5 min)",
		"• Process: npm run dev (running for less than a minute)",
	} {
		if !strings.Contains(prompt.text, want) {
			t.Fatalf("the question does not say %q:\n%s", want, prompt.text)
		}
	}
	wantActions := []string{"Cancel", "Keep on Host and Close", "End and Close"}
	if !slices.Equal(prompt.actions, wantActions) {
		t.Fatalf("actions %q, want %q with End and Close the default", prompt.actions, wantActions)
	}
	if prompt.check != i18n.Shared(lang, "desktop.remote.close.remember") || prompt.checkHelp != i18n.Shared(lang, "desktop.remote.close.rememberHelp") {
		t.Fatal("the question does not offer to remember the choice with its help")
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.close.remember")) {
		t.Fatal("the checkbox is not shown")
	}

	h.answer(0)
	if h.app.project != p || p.remote.session != "session-1" || p.remote.leaving || len(remoteChoices(k)) != 0 {
		t.Fatal("Cancel did not keep the workspace open and connected")
	}

	h.closeQuestion(t)
	h.answer(2)
	h.awaitClosed(t)
	if got := remoteChoices(k); !slices.Equal(got, []core.RemoteClosePrograms{core.RemoteCloseEnd}) {
		t.Fatalf("closed the session with %q, want end", got)
	}
	if keptOf(t, h) != nil {
		t.Fatal("ending the programs stored the session")
	}
	actions := remoteActions(logger)
	if want := []string{"remote.close.cancel", "remote.close.end"}; !slices.Equal(actions[len(actions)-2:], want) {
		t.Fatalf("performed %q, want %q last", actions, want)
	}
	if event := loggedAny(t, logger, remoteCloseSecrets...); event != "" {
		t.Fatalf("logged a command, a name or a token: %s", event)
	}
}

// An unconsumed record remains available for its original target after a successful connection.
func TestRemoteConnectRetainsAnUnconsumedKeptSession(t *testing.T) {
	for _, binding := range []string{"", strings.Repeat("c", 64)} {
		t.Run(fmt.Sprintf("binding-length-%d", len(binding)), func(t *testing.T) {
			h, _, _, _ := remoteWorkspaceHarness(t)
			entry := savedRemoteConnections(t, h)[0]
			resume := core.RemoteResume{Key: "key-old", Token: "token-old", Binding: binding}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := remoteconn.RememberKept(ctx, h.app.remoteSecretStore, entry.ID, resume); err != nil {
				t.Fatal(err)
			}
			h.openRemoteTestProject(t)
			if got := keptOf(t, h); got == nil || *got != resume {
				t.Fatal("connecting to another or unverified target removed the original credential")
			}
		})
	}
}

// Keep on Host and Close stores the session's resume token, tells the host to keep the session and
// says how many programs stay. The next connection to the same host resumes the session, forgets
// the stored token and, once the folder opens, offers to end the kept programs: End Them ends
// those alone.
func TestRemoteCloseKeepsTheProgramsForTheNextConnection(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })

	h.closeQuestion(t)
	h.answer(1)
	h.awaitClosed(t)
	if got := remoteChoices(k); !slices.Equal(got, []core.RemoteClosePrograms{core.RemoteCloseKeep}) {
		t.Fatalf("closed the session with %q, want keep", got)
	}
	if got := keptOf(t, h); got == nil || *got != (core.RemoteResume{Key: "key-1", Token: "token-1", Binding: strings.Repeat("b", 64)}) {
		t.Fatal("the session's resume token was not stored")
	}
	kept := i18n.SharedFormat(lang, "desktop.remote.close.kept", map[string]string{"connection": remoteTestHost, "count": "2"})
	if got := lastNotice(h); got != kept {
		t.Fatalf("notified %q, want %q", got, kept)
	}

	k.set(func(k *remoteHostKernel) { k.close.running = nil })
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	h.openRemoteTestProject(t)
	k.mu.Lock()
	resumes := slices.Clone(k.close.resumes)
	k.mu.Unlock()
	if len(resumes) != 2 || resumes[0] != nil || resumes[1] == nil || resumes[1].Key != "key-1" {
		t.Fatal("the next connection did not present the kept session")
	}
	if keptOf(t, h) != nil {
		t.Fatal("the resumed session's token is still stored")
	}
	h.await("the offer to end the kept programs", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	offer := h.app.prompts.queue[0]
	if offer.title != i18n.Shared(lang, "desktop.remote.kept.title") || !strings.Contains(offer.text, "npm run dev") ||
		!strings.Contains(offer.text, i18n.Shared(lang, "desktop.remote.kept.attachTerminals")) ||
		!slices.Equal(offer.actions, []string{"End Them", "Show in Run Window", "Keep Running"}) {
		t.Fatalf("offer %q %q %q", offer.title, offer.text, offer.actions)
	}
	h.answer(0)
	h.await("the kept programs ended", func() bool {
		k.mu.Lock()
		defer k.mu.Unlock()
		return len(k.close.ended) == 1
	})
	h.settle()
	if got := k.close.ended[0]; !slices.EqualFunc(got, remoteTestPrograms, func(a, b core.RemoteProgram) bool { return a.Kind == b.Kind && a.ID == b.ID }) {
		t.Fatalf("ended %+v, want the kept programs alone", got)
	}
	ended := i18n.SharedFormat(lang, "desktop.remote.kept.ended", map[string]string{"connection": remoteTestHost, "count": "2"})
	if got := lastNotice(h); got != ended {
		t.Fatalf("notified %q, want %q", got, ended)
	}
	actions := remoteActions(logger)
	if !slices.Contains(actions, "remote.close.keep") || actions[len(actions)-1] != "remote.kept.end" {
		t.Fatalf("performed %q", actions)
	}
	if event := loggedAny(t, logger, remoteCloseSecrets...); event != "" {
		t.Fatalf("logged a command, a name or a token: %s", event)
	}
}

// Show in Run Window receives each kept process again, in a Run tab of its own that says so, over
// the session that resumed the kept one; the tab ends with the process. A terminal is not received
// again. Neither the programs' commands nor their names are logged.
func TestRemoteCloseShowsTheKeptProcessesInTheRunWindow(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })
	h.closeQuestion(t)
	h.answer(1)
	h.awaitClosed(t)
	k.set(func(k *remoteHostKernel) { k.close.running = nil })
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	p := h.openRemoteTestProject(t)
	h.await("the offer about the kept programs", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	h.answer(1)
	run := h.awaitRemoteRun(p, "npm", nil)
	console := run.output.all()
	if run.outcome != runSucceeded || !run.remote || !strings.Contains(console, i18n.Shared(lang, "desktop.run.remote.attachedKept")) ||
		!strings.Contains(console, remoteHostAttachOutput) {
		t.Fatalf("the kept process's tab ended %v: %s; console:\n%s", run.outcome, run.summary, console)
	}
	if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
		t.Fatal("Show in Run Window did not open the Run window")
	}
	if got := k.remoteAttaches(); !slices.Equal(got, []string{"session-2"}) || len(p.build.runs) != 1 {
		t.Fatalf("received %d kept processes in %d tabs, over the resumed session %v", len(got), len(p.build.runs), slices.Equal(got, []string{"session-2"}))
	}
	if actions := remoteActions(logger); actions[len(actions)-1] != "remote.kept.attach" {
		t.Fatalf("performed %q", actions)
	}
	if event := loggedAny(t, logger, append(slices.Clone(remoteCloseSecrets), "npm")...); event != "" {
		t.Fatalf("logged a command, a name or a token: %s", event)
	}
}

// A connection that resumes a kept session and gives it back without opening a folder keeps it
// again, so its programs do not end without the user choosing it.
func TestRemoteCloseKeepsAResumedSessionNoWorkspaceTook(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })
	h.closeQuestion(t)
	h.answer(1)
	h.awaitClosed(t)

	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	h.connectAndBrowse(t)
	if keptOf(t, h) != nil {
		t.Fatal("the resumed session's token is still stored")
	}
	h.app.closeRemote()
	// A keep that succeeds posts nothing back, so settling (every background task returned) is
	// what to wait for.
	h.settle()
	if got := remoteChoices(k); len(got) != 2 || got[1] != core.RemoteCloseKeep {
		t.Fatalf("gave the resumed session back with %q, want keep", got)
	}
	if got := keptOf(t, h); got == nil || got.Key != "key-1" {
		t.Fatal("the session given back was not stored again")
	}
}

// Remember my choice stores the answer: the next close does as it says without asking, End ending
// the programs and Keep on Host keeping them.
func TestRemoteCloseRemembersTheChoice(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })
	prompt := h.closeQuestion(t)
	prompt.checked = true
	h.answer(2)
	h.awaitClosed(t)
	closing := func() core.RemoteClosing {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		read, err := remoteconn.ReadPreferences(ctx, core.NewClient(), h.store.Dir(), "")
		if err != nil {
			t.Fatalf("read the preferences: %v", err)
		}
		return read.State.Closing
	}
	h.await("the choice stored", func() bool { return closing().Programs == core.RemoteCloseEnd })

	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	h.openRemoteTestProject(t)
	h.app.closeProject()
	h.awaitClosed(t)
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("the remembered End asked again")
	}
	if got := remoteChoices(k); !slices.Equal(got, []core.RemoteClosePrograms{core.RemoteCloseEnd, core.RemoteCloseEnd}) {
		t.Fatalf("closed the sessions with %q", got)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	read, err := remoteconn.ReadPreferences(ctx, core.NewClient(), h.store.Dir(), "")
	if err != nil {
		t.Fatal(err)
	}
	keep := core.RemoteCloseKeep
	if _, _, err := read.Edit(ctx, core.NewClient(), core.RemotePreferenceEdit{ClosePrograms: &core.RemoteCloseProgramsEdit{Programs: &keep}}); err != nil {
		t.Fatal(err)
	}
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	h.openRemoteTestProject(t)
	h.app.closeProject()
	h.awaitClosed(t)
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("the remembered Keep on Host asked")
	}
	if got := remoteChoices(k); got[len(got)-1] != core.RemoteCloseKeep || keptOf(t, h) == nil {
		t.Fatalf("closed the sessions with %q, want the last kept", got)
	}
}

// A keep whose token cannot be stored ends the programs and says so, and so does a host that does
// not keep the session, whose token is then forgotten.
func TestRemoteCloseEndsWhenTheSessionCannotBeKept(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	values := map[string]string{"connection": remoteTestHost}
	secrets := h.app.remoteSecretStore.(*memorySecrets)
	secrets.failSet = errors.New("the secret store is locked")
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })
	h.closeQuestion(t)
	h.answer(1)
	h.awaitClosed(t)
	if got := remoteChoices(k); !slices.Equal(got, []core.RemoteClosePrograms{core.RemoteCloseEnd}) {
		t.Fatalf("closed the session with %q, want end", got)
	}
	if got, want := lastNotice(h), i18n.SharedFormat(lang, "desktop.remote.close.keepFailed", values); got != want {
		t.Fatalf("notified %q, want %q", got, want)
	}
	if countFailures(logger, "remote_keep_programs") != 1 {
		t.Fatal("the failed keep was not logged")
	}

	secrets.failSet = nil
	k.set(func(k *remoteHostKernel) { k.close.refuseKeep = true })
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	h.openRemoteTestProject(t)
	h.closeQuestion(t)
	h.answer(1)
	h.awaitClosed(t)
	if got, want := lastNotice(h), i18n.SharedFormat(lang, "desktop.remote.close.keepRefused", values); got != want {
		t.Fatalf("notified %q, want %q", got, want)
	}
	if keptOf(t, h) != nil {
		t.Fatal("the token of a session the host did not keep is still stored")
	}
	if event := loggedAny(t, logger, remoteCloseSecrets...); event != "" {
		t.Fatalf("logged a command, a name or a token: %s", event)
	}
}

// A list of the host's programs that cannot be had does not trap the user in the window: the
// workspace closes and the failure is logged.
func TestRemoteCloseGoesOnWhenTheProgramsCannotBeListed(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) {
		k.close.runningErr = &core.Error{Command: "remote.runningPrograms", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.app.closeProject()
	h.awaitClosed(t)
	if len(h.app.prompts.queue) != 0 || countFailures(logger, "remote_close_programs") != 1 {
		t.Fatal("the failed list asked or was not logged")
	}
}
