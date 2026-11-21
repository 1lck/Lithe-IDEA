package workbench

import (
	"context"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Git authentication: a Git operation the user started (a fetch, pull, push, clone, or the
// checkout of a pull request) may ask for a user name, a password, token or passphrase, or,
// after its transfer failed to authenticate, whether to retry it once with credentials typed
// here instead of the credential helper (core.WithGitAuthentication). The questions queue in
// the order Git asked them. One dialog, over everything else, answers the first, and the next
// follows; a question leaves the queue once it is answered or its request has returned.
//
// The SSH client of a remote connection asks through the same queue and dialog (core.RemoteProbe
// marks its questions Remote): only the title, the hint and the command that answers differ.

const (
	// gitAuthRespondTimeout bounds passing one answer to Core, which replies at once.
	gitAuthRespondTimeout = 10 * time.Second
	// gitAuthDialogWidth is the width of the dialog: room for Git's question with a URL.
	gitAuthDialogWidth = 480
)

// gitAuthState is what the window keeps of the questions Git is waiting on.
type gitAuthState struct {
	// queue is every question still waiting, the first asked first.
	queue []core.GitAuthChallenge
	// field holds what is typed for queue[0]. Each question gets a field of its own (fieldFor
	// names it), so neither an answer nor its undo history outlives the question.
	field    ui.Field
	fieldFor string
	// open is the dialog's flag; the dialog is open while the queue is not empty.
	open bool
}

// gitAuthentication returns ctx with this window as the prompt for the questions of the Git
// operation it carries. Give it only to an operation the user started, never to an automatic
// refresh: Core lets that one fail instead of asking. The prompt runs on the request's
// goroutine, so it only posts the question to the window thread, and posts its removal once the
// request has returned.
func (a *App) gitAuthentication(ctx context.Context) context.Context {
	return core.WithGitAuthentication(ctx, func(challenge core.GitAuthChallenge) {
		a.post(func(a *App) { a.gitAuth.queue = append(a.gitAuth.queue, challenge) })
		go func() {
			<-challenge.Done
			a.post(func(a *App) { a.dropGitAuth(challenge.RequestID) })
		}()
	})
}

// dropGitAuth removes the question requestID, whose request has returned, with what was typed
// for it.
func (a *App) dropGitAuth(requestID string) {
	g := &a.gitAuth
	g.queue = slices.DeleteFunc(g.queue, func(challenge core.GitAuthChallenge) bool { return challenge.RequestID == requestID })
	if g.fieldFor == requestID {
		g.field, g.fieldFor = ui.Field{}, ""
	}
}

// gitAuthDialog declares the dialog that answers the first waiting question. Git's or SSH's own
// question is upstream text, shown as Core redacted it; the question whether to retry is
// Lithe's own and is translated. Dismissing the dialog cancels the question, which fails the
// operation that asked.
func (a *App) gitAuthDialog(c ui.C) {
	g := &a.gitAuth
	if len(g.queue) == 0 {
		return
	}
	head := g.queue[0]
	if g.fieldFor != head.RequestID {
		g.field, g.fieldFor = ui.Field{}, head.RequestID
	}
	lang := a.language()
	g.open = true
	submitted, cancelled, confirmed := false, false, false
	title := i18n.Shared(lang, "desktop.gitAuth.title")
	if head.Remote {
		title = i18n.Shared(lang, "desktop.remoteAuth.title")
	}
	closed := ui.ModalWith(c, &g.open, title, ui.ModalSpec{Width: gitAuthDialogWidth}, func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			if head.Retry {
				ui.Wrap(c, i18n.Shared(lang, "desktop.gitAuth.retryMessage"))
			} else {
				ui.Wrap(c, strings.TrimSpace(head.Prompt))
				if head.Attempt > 1 {
					ui.Wrap(c, i18n.SharedFormat(lang, "desktop.gitAuth.again", map[string]string{"attempt": strconv.Itoa(head.Attempt)})).
						FontSize(12).Color(a.colors.Warning)
				}
				// The field is the question's own part, so it takes the focus again for the next
				// question as it appears.
				field := ui.TextField(c.Part(head.RequestID), &g.field, i18n.Shared(lang, "desktop.gitAuth.answer"), "").FillWidth().AutoFocus()
				if head.Secret {
					field = field.Secure()
				}
				submitted = field.Submitted()
				if head.Secret {
					hint := i18n.Shared(lang, "desktop.gitAuth.secretHint")
					if head.Remote {
						hint = i18n.Shared(lang, "desktop.remoteAuth.secretHint")
					}
					ui.Wrap(c, hint).FontSize(12).Color(a.colors.Subtle)
				}
			}
			if head.WorkingDirectory != "" {
				ui.Wrap(c, i18n.SharedFormat(lang, "desktop.gitAuth.directory", map[string]string{"path": head.WorkingDirectory})).
					FontSize(12).Color(a.colors.Subtle)
			}
		})
	}, func() {
		cancelled = ui.Button(c, i18n.Shared(lang, "desktop.gitAuth.cancel")).Outline().Clicked()
		label := i18n.Shared(lang, "desktop.gitAuth.submit")
		if head.Retry {
			label = i18n.Shared(lang, "desktop.gitAuth.retry")
		}
		confirmed = ui.Button(c, label).Clicked()
	})
	switch {
	case closed || cancelled:
		c.After(func() { a.answerGitAuth(head.RequestID, false) })
	case confirmed || submitted:
		c.After(func() { a.answerGitAuth(head.RequestID, true) })
	}
}

// answerGitAuth answers the question requestID if it is still the first: with what was typed,
// or with core.GitRetryAnswer for the retry question, when confirm is set, and otherwise cancels
// it. The question leaves the queue at once; Core's verdict arrives later. An answer Core no
// longer takes is for a question that expired or whose request returned, and the dialog has
// moved on; an answer Core refused, too long or with a line break, cancels the question and
// says why.
func (a *App) answerGitAuth(requestID string, confirm bool) {
	g := &a.gitAuth
	if len(g.queue) == 0 || g.queue[0].RequestID != requestID {
		return
	}
	head := g.queue[0]
	g.queue = g.queue[1:]
	var answer *string
	kind, site, respond := "git.authentication.", "git_authentication", a.kernel.GitAuthRespond
	if head.Remote {
		kind, site, respond = "remote.authentication.", "remote_authentication", a.kernel.RemoteAuthRespond
	}
	action := kind + "cancel"
	switch {
	case confirm && head.Retry:
		retry := core.GitRetryAnswer
		answer, action = &retry, kind+"retry"
	case confirm:
		typed := g.field.Text()
		answer, action = &typed, kind+"answer"
	}
	g.field, g.fieldFor = ui.Field{}, ""
	a.performed(action, surfaceButton)
	a.background(nil, gitAuthRespondTimeout, func(ctx context.Context) func(*App) {
		accepted, err := respond(ctx, head.RequestID, answer)
		refused := false
		if err == nil && !accepted && answer != nil && !requestReturned(head.Done) {
			// Core took no answer although the request still runs: either it refused this one
			// or the question expired. Only a question that still waits accepts the cancel.
			refused, err = respond(ctx, head.RequestID, nil)
		}
		return func(a *App) {
			lang := a.language()
			switch {
			case err != nil:
				a.operationFailed(site, err)
				text := i18n.SharedFormat(lang, "desktop.gitAuth.failed", map[string]string{"reason": err.Error()})
				if head.Remote {
					text = i18n.SharedFormat(lang, "desktop.remoteAuth.failed", map[string]string{"reason": err.Error()})
				}
				a.notifyError(text)
			case refused:
				a.operationRejected(site, "answer_refused")
				text := i18n.Shared(lang, "desktop.gitAuth.refused")
				if head.Remote {
					text = i18n.Shared(lang, "desktop.remoteAuth.refused")
				}
				a.notifyError(text)
			}
		}
	})
}

// requestReturned reports whether done, the Done of a challenge, has been closed.
func requestReturned(done <-chan struct{}) bool {
	select {
	case <-done:
		return true
	default:
		return false
	}
}
