package workbench

import (
	"context"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// A saved SSH connection remembers a password or key passphrase only when the user ticks Remember
// under the question (#2231, S12; remoteconn/answers.go). What a connection learns is applied once
// it has ended:
//
//   - A remembered answer is sent on its own only the first time OpenSSH asks its question in a
//     connection. When OpenSSH asks again, or the login fails without anything cancelled, the host
//     refused it: it is forgotten whatever the connection's outcome, and the window asks.
//   - An answer typed with Remember ticked is stored only once the connection logs in, so a
//     mistyped password is never stored. Typing one with Remember unticked forgets the remembered
//     answer even when the connection fails.
//
// A WSL distribution and a container of this computer ask nothing, and a connection that is not
// saved has no id to remember under, so neither remembers. A container on a saved SSH host logs
// in to the host, so it uses the host's answers. An automatic reconnection asks nothing: it sends
// what is remembered and cancels every other question, as Core does without a prompt.

// remoteAnswersSite names the remembered answers in the log; the events carry only the error.
const remoteAnswersSite = "remote_answers"

// remoteAnswers is what one connection to a saved SSH host remembers and learns.
type remoteAnswers struct {
	secrets remoteconn.Secrets
	kernel  Kernel
	// owner is the saved connection the answers are remembered under; login is how this
	// connection logs in, which the questions' digests include.
	owner string
	login core.SSHConnection

	mu sync.Mutex
	// sent are the questions answered on their own with the remembered answer.
	sent map[string]bool
	// refused are the questions OpenSSH asked again after the remembered answer was sent.
	refused map[string]bool
	// cancelled says a question of this connection went unanswered, so a failed login says
	// nothing about the answers that were sent.
	cancelled bool
	// choices are the user's Remember choices, in the order made.
	choices []remoteconn.AnswerChange
}

// remoteAnswersFor is what the connection named connectionID to host remembers, nil when it
// remembers nothing: host is not reached over SSH, or the connection is not saved. Saved ids
// never contain "/" (Core allows letters, digits and "-"), so the id of a container on a saved
// host starts with the host's id and a "/" (remoteHostContainerTarget).
func (a *App) remoteAnswersFor(connectionID string, host remoteHost) *remoteAnswers {
	owner, _, _ := strings.Cut(connectionID, "/")
	if owner == "" || !host.overSSH() {
		return nil
	}
	return &remoteAnswers{secrets: a.remoteSecrets(), kernel: a.kernel, owner: owner, login: remoteStored(host.ssh)}
}

// remoteAuthentication returns ctx with the prompt of a connection's OpenSSH questions: what
// answers remembers is sent on its own; with ask set every other question reaches the window as
// gitAuthentication posts it, and otherwise it is cancelled. Without answers it is
// gitAuthentication, or ctx itself when nothing asks. It may be called on any goroutine.
func (a *App) remoteAuthentication(ctx context.Context, answers *remoteAnswers, ask bool) context.Context {
	switch {
	case answers == nil && ask:
		return a.gitAuthentication(ctx)
	case answers == nil:
		return ctx
	}
	return core.WithGitAuthentication(ctx, a.remotePrompt(ctx, answers, ask))
}

// remotePrompt is remoteAuthentication's prompt for the questions of the request ctx carries.
func (a *App) remotePrompt(ctx context.Context, answers *remoteAnswers, ask bool) func(core.GitAuthChallenge) {
	return func(challenge core.GitAuthChallenge) {
		// Reading the store takes a moment, and the request's goroutine must not wait on it.
		go func() {
			question, answered, err := answers.offer(ctx, challenge)
			if err != nil && ctx.Err() == nil {
				a.post(func(a *App) { a.backgroundFailed(remoteAnswersSite, err) })
			}
			if answered || requestReturned(challenge.Done) {
				return
			}
			if !ask {
				answers.cancel()
				// log-exempt: 用户取消：自动重连不询问，与 Core 在没有询问者时一样取消这个问题；重连的结果另记 remote_reconnect。
				_, _ = answers.kernel.RemoteAuthRespond(context.Background(), challenge.RequestID, nil)
				return
			}
			a.post(func(a *App) { a.gitAuth.queue = append(a.gitAuth.queue, question) })
			<-challenge.Done
			a.post(func(a *App) { a.dropGitAuth(challenge.RequestID) })
		}()
	}
}

// remoteLoggedIn reports whether a test or connection that ended with status and err logged in
// to the host: it connected, or the host turned out to be one no server build runs on.
func remoteLoggedIn(status core.RemoteProbeStatus, err error) bool {
	return err == nil && (status == core.RemoteProbeConnected || status == core.RemoteProbeUnsupportedPlatform)
}

// offer sends the remembered answer when OpenSSH asks its question for the first time in this
// connection; answered reports that it was taken. Otherwise question is how the window asks it.
// err is a failure of the store or of Core, after which the window asks.
func (s *remoteAnswers) offer(ctx context.Context, challenge core.GitAuthChallenge) (question gitAuthQuestion, answered bool, err error) {
	question = gitAuthQuestion{GitAuthChallenge: challenge, answers: s}
	if challenge.Retry || !remoteconn.Rememberable(challenge.Kind) {
		return question, false, nil
	}
	question.question = remoteconn.AnswerQuestion(challenge.Kind, s.login, challenge.Prompt)
	s.mu.Lock()
	sent := s.sent[question.question]
	if sent && challenge.Attempt > 1 {
		if s.refused == nil {
			s.refused = map[string]bool{}
		}
		s.refused[question.question] = true
		question.refused = true
	}
	chosen, choseRemember := s.choice(question.question)
	s.mu.Unlock()
	if chosen {
		question.remembered = choseRemember
		return question, false, nil
	}
	answer, found, err := remoteconn.RememberedAnswer(ctx, s.secrets, s.owner, question.question)
	if err != nil || !found {
		return question, false, err
	}
	question.remembered = true
	if sent || challenge.Attempt > 1 {
		return question, false, nil
	}
	accepted, err := s.kernel.RemoteAuthRespond(ctx, challenge.RequestID, &answer)
	if err != nil || !accepted {
		// Core takes any remembered answer, which it once took; one it no longer takes is asked.
		return question, false, err
	}
	s.mu.Lock()
	if s.sent == nil {
		s.sent = map[string]bool{}
	}
	s.sent[question.question] = true
	s.mu.Unlock()
	return question, true, nil
}

// choice is the user's last Remember choice for question in this connection; chosen is false
// when none was made. s.mu is held.
func (s *remoteAnswers) choice(question string) (chosen, remember bool) {
	for _, change := range s.choices {
		if change.Question == question {
			chosen, remember = true, !change.Forget
		}
	}
	return chosen, remember
}

// choose records the user's answer to question: remembered once the connection succeeds when
// remember is set, otherwise forgotten if it was remembered.
func (s *remoteAnswers) choose(question gitAuthQuestion, answer string, remember bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case remember && answer != "":
		s.choices = append(s.choices, remoteconn.AnswerChange{Question: question.question, Answer: answer})
	case question.remembered:
		s.choices = append(s.choices, remoteconn.AnswerChange{Question: question.question, Forget: true})
	}
}

// cancel records that a question of this connection went unanswered.
func (s *remoteAnswers) cancel() {
	s.mu.Lock()
	s.cancelled = true
	s.mu.Unlock()
}

// settle applies what the connection learned once it ended with status and err (remoteLoggedIn).
// It runs off the window thread, within remoteReadTimeout of its own since the connection may
// have been stopped; a nil s settles nothing.
func (s *remoteAnswers) settle(status core.RemoteProbeStatus, err error) error {
	if s == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), remoteReadTimeout)
	defer cancel()
	s.mu.Lock()
	var changes []remoteconn.AnswerChange
	forget := func(questions map[string]bool) {
		for question := range questions {
			changes = append(changes, remoteconn.AnswerChange{Question: question, Forget: true})
		}
	}
	loggedIn := remoteLoggedIn(status, err)
	forget(s.refused)
	if err == nil && status == core.RemoteProbeAuthenticationFailed && !s.cancelled {
		forget(s.sent)
	}
	for _, change := range s.choices {
		if change.Forget || loggedIn {
			changes = append(changes, change)
		}
	}
	s.sent, s.refused, s.cancelled, s.choices = nil, nil, false, nil
	s.mu.Unlock()
	return remoteconn.ChangeAnswers(ctx, s.secrets, s.owner, changes)
}

// remoteAnswersSettled reports, on the window thread, a failure of settle; userStarted says the
// user started the connection, which the user is told about.
func (a *App) remoteAnswersSettled(err error, userStarted bool) {
	switch {
	case err == nil:
	case userStarted:
		a.operationFailed(remoteAnswersSite, err)
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.remoteAuth.rememberFailed", map[string]string{"reason": err.Error()}))
	default:
		a.backgroundFailed(remoteAnswersSite, err)
	}
}

// forgetRemoteAnswers forgets every answer the saved connection entry remembers.
func (a *App) forgetRemoteAnswers(entry core.SavedRemoteConnection) {
	if !a.remote.open {
		return
	}
	a.performed("remote.connection.forgetAnswers", surfaceMenu)
	secrets, id, name := a.remoteSecrets(), entry.ID, entry.Name
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		err := remoteconn.ForgetAnswers(ctx, secrets, id)
		return func(a *App) {
			if err != nil {
				a.remoteAnswersSettled(err, true)
				return
			}
			a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.remote.answersForgotten", map[string]string{"name": name}))
		}
	})
}
