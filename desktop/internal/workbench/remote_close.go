package workbench

import (
	"context"
	"errors"
	"path"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// Closing a remote workspace decides what happens to the programs it started on the host (#2231,
// §9.1): the shells of its terminals and the processes it runs there. While the host still runs
// any, closing the project, its tab or the window, quitting Lithe or opening another folder in its
// place asks whether they end with the workspace or keep running on the host, unless the user
// once chose with "Remember my choice"; Settings › Tools › Remote Workspace changes that choice.
//
// Keeping them leaves the host session running with no connection and no idle timeout, and
// remembers its resume token in the platform secret store (remoteconn.RememberKept). The next
// connection to the same target attaches to it again and offers to end the programs it still
// runs (§9.2, S35); a connection that gives such a session back without opening a workspace keeps
// it again, so they never end without the user choosing it.
//
// The question comes after the local exit confirmation, which covers the runs and the busy local
// terminals, and before the project is taken apart. Taking it apart closes the workspace's
// terminals, which hangs up their shells on the host, so a keep detaches the connection first.

// remoteProgramsTimeout bounds listing or ending the programs the host runs.
const remoteProgramsTimeout = remoteDisconnectTimeout

var (
	// errRemoteNoResumeToken: the host issued no token for its session, so a later connection
	// could not attach to it and keeping it would leave its programs out of reach.
	errRemoteNoResumeToken = errors.New("remote keep: the host issued no resume token")
	// errRemoteNotKept: the host closed the connection without keeping the session.
	errRemoteNotKept = errors.New("remote keep: the host did not keep the session")
)

// remoteSecrets is the secret store the kept host sessions are remembered in.
func (a *App) remoteSecrets() remoteconn.Secrets {
	if a.remoteSecretStore != nil {
		return a.remoteSecretStore
	}
	return credentials.Default()
}

// shownWorkbench is the workbench the window shows: a notification of a tab that is closing goes
// to the one shown in its place.
func (a *App) shownWorkbench() *App {
	if a.sessions != nil && a.sessions.active != nil {
		return a.sessions.active
	}
	return a
}

// confirmRemoteClose decides the programs the host runs for the remote workspace p before its
// project closes, then calls proceed. A local project, or a remote one without a session, goes on
// at once. With no programs running, or a remembered "End", proceed runs and taking the project
// apart ends the session; a remembered "Keep on Host" keeps them; otherwise the user is asked. A
// list that cannot be had is no reason to trap the user in the window: proceed runs and the error
// is logged.
func (a *App) confirmRemoteClose(p *project, proceed func()) {
	r := p.remote
	if r == nil || r.closed || r.session == "" {
		proceed()
		return
	}
	if r.leaving {
		// log-exempt: 用户重复操作：这次关闭的决定已经在进行，先开始的那次会接着关闭。
		return
	}
	r.leaving = true
	session, kernel, root := r.session, a.kernel, a.globalToolchainRoot()
	a.background(nil, remoteProgramsTimeout, func(ctx context.Context) func(*App) {
		programs, err := kernel.RemoteRunningPrograms(ctx, session)
		choice, choiceErr := core.RemoteCloseAsk, error(nil)
		if err == nil && len(programs) > 0 {
			choice, choiceErr = remoteCloseChoice(ctx, kernel, root)
		}
		return func(a *App) {
			r.leaving = false
			switch {
			case a.project != p || r.closed:
				// log-exempt: 用户取消：项目已经关闭或被替换，没有可决定的远端进程。
			case r.session != session:
				// The connection was lost meanwhile: the host ends the unattached session after
				// its idle timeout, and nothing can be asked of it now.
				a.backgroundFailed("remote_close_programs", errRemoteSessionClosed)
				proceed()
			case err != nil:
				a.backgroundFailed("remote_close_programs", remoteLogError(err))
				proceed()
			case len(programs) == 0:
				proceed()
			default:
				if choiceErr != nil {
					a.backgroundFailed("remote_close_preferences", documentLogError(choiceErr))
				}
				switch choice {
				case core.RemoteCloseEnd:
					proceed()
				case core.RemoteCloseKeep:
					a.keepRemoteAndClose(p, len(programs), proceed)
				default:
					a.askRemoteClose(p, programs, proceed)
				}
			}
		}
	})
}

// askRemoteClose asks whether the programs the host runs for p end with the workspace or keep
// running on the host; End is the default. "Remember my choice" stores the answer.
func (a *App) askRemoteClose(p *project, programs []core.RemoteProgram, proceed func()) {
	r := p.remote
	r.leaving = true
	language := a.language()
	running := i18n.SharedFormat(language, "desktop.remote.close.running", map[string]string{"connection": r.name})
	prompt := &pluginPrompt{
		title: i18n.Shared(language, "desktop.remote.close.title"),
		text:  running + "\n\n" + remoteProgramLines(language, programs),
		actions: []string{
			i18n.Shared(language, "desktop.exit.cancel"),
			i18n.Shared(language, "desktop.remote.close.keep"),
			i18n.Shared(language, "desktop.remote.close.end"),
		},
		check:     i18n.Shared(language, "desktop.remote.close.remember"),
		checkHelp: i18n.Shared(language, "desktop.remote.close.rememberHelp"),
	}
	prompt.onAnswer = func(choice *int) {
		r.leaving = false
		if choice == nil {
			// log-exempt: 用户取消：对话框被关闭或随标签页撤下，关闭不再继续。
			return
		}
		if *choice == 0 {
			a.performed("remote.close.cancel", surfaceButton)
			return
		}
		keep := *choice == 1
		action, decided := "remote.close.end", core.RemoteCloseEnd
		if keep {
			action, decided = "remote.close.keep", core.RemoteCloseKeep
		}
		a.performed(action, surfaceButton)
		if prompt.checked {
			a.rememberRemoteClose(decided)
		}
		if a.project != p || r.closed {
			// log-exempt: 用户取消：等待回答时项目已经关闭，没有可决定的远端进程。
			return
		}
		if keep {
			a.keepRemoteAndClose(p, len(programs), proceed)
			return
		}
		proceed()
	}
	a.prompts.queue = append(a.prompts.queue, prompt)
}

// keepRemoteAndClose keeps the programs of p's session running on the host, then lets the project
// close. The workspace lets go of the session first, so nothing of it reaches the host any more,
// and the host is told to keep the session as the connection closes. The resume token is stored
// before that, so the host never keeps a session no later connection can find. When it cannot be
// stored, or the host does not keep the session, the programs end as if the user chose End, and a
// notification says so; so does a connection that was lost before the keep.
func (a *App) keepRemoteAndClose(p *project, count int, proceed func()) {
	r := p.remote
	session, resume, name := r.session, r.resume, r.name
	if session == "" {
		a.operationRejected("remote_keep_programs", "disconnected")
		proceed()
		a.shownWorkbench().notify(i18n.SharedFormat(a.language(), "desktop.remote.close.keepLost", map[string]string{"connection": name}))
		return
	}
	r.leaving = true
	r.stopRemoteTimer()
	a.stopRemoteWatch(p)
	a.closeGitObservation(p)
	// Core stops the session's forwards with the connection.
	r.ports.reset()
	r.binding.Detach()
	r.session, r.resume = "", nil
	kernel, secrets, connectionID := a.kernel, a.remoteSecrets(), r.connectionID
	a.background(nil, remoteDisconnectTimeout, func(ctx context.Context) func(*App) {
		kept, err := keepRemoteSession(ctx, kernel, secrets, connectionID, session, resume)
		return func(a *App) {
			r.leaving = false
			if err != nil {
				a.operationFailed("remote_keep_programs", err)
			}
			proceed()
			language, counted := a.language(), strconv.Itoa(count)
			shown := a.shownWorkbench()
			switch kept {
			case remoteKept:
				shown.notifyInfo(i18n.SharedFormat(language, "desktop.remote.close.kept", map[string]string{"connection": name, "count": counted}))
			case remoteKeepUnstored:
				shown.notify(i18n.SharedFormat(language, "desktop.remote.close.keepFailed", map[string]string{"connection": name}))
			default:
				shown.notify(i18n.SharedFormat(language, "desktop.remote.close.keepRefused", map[string]string{"connection": name}))
			}
		}
	})
}

// remoteKeep is how keeping a host session ended.
type remoteKeep int

const (
	// remoteKept: the host keeps the session and its token is stored.
	remoteKept remoteKeep = iota
	// remoteKeepUnstored: the token could not be stored, or the host issued none, so the session
	// ended.
	remoteKeepUnstored
	// remoteKeepRefused: the host did not keep the session, or did not say it did.
	remoteKeepRefused
)

// keepRemoteSession stores the resume token of session for connectionID and tells the host to
// keep the session as its connection closes. Without a token, or when it cannot be stored, the
// session ends instead. A host that answers it did not keep the session has its token forgotten;
// one that does not answer keeps it stored, since the host may have kept the session, and the next
// connection forgets it if the host did not. It runs off the window thread; err is what the log
// keeps.
func keepRemoteSession(ctx context.Context, kernel Kernel, secrets remoteconn.Secrets, connectionID, session string, resume *core.RemoteResume) (remoteKeep, error) {
	stored := errRemoteNoResumeToken
	if resume != nil {
		stored = remoteconn.RememberKept(ctx, secrets, connectionID, *resume)
	}
	if stored != nil {
		_, err := kernel.RemoteDisconnect(ctx, session, core.RemoteCloseEnd)
		return remoteKeepUnstored, errors.Join(stored, remoteLogErrorOf(err))
	}
	result, err := kernel.RemoteDisconnect(ctx, session, core.RemoteCloseKeep)
	switch {
	case err != nil:
		return remoteKeepRefused, remoteLogError(err)
	case !result.Kept:
		return remoteKeepRefused, errors.Join(errRemoteNotKept, remoteconn.ForgetKept(ctx, secrets, connectionID, resume.Key))
	}
	return remoteKept, nil
}

// remoteLogErrorOf is remoteLogError for an error that may be nil.
func remoteLogErrorOf(err error) error {
	if err == nil {
		return nil
	}
	return remoteLogError(err)
}

// returnRemoteSession gives back a session no workspace took. One that attached to a kept session
// whose programs still run is kept again, so they do not end without the user choosing it
// (§9.2); any other ends.
func (a *App) returnRemoteSession(connectionID string, session core.RemoteSession) {
	if !session.Resumed || len(session.KeptPrograms) == 0 {
		a.releaseRemoteSession(session.ID)
		return
	}
	kernel, secrets, resume := a.kernel, a.remoteSecrets(), session.Resume()
	a.background(nil, remoteDisconnectTimeout, func(ctx context.Context) func(*App) {
		_, err := keepRemoteSession(ctx, kernel, secrets, connectionID, session.ID, resume)
		if err == nil {
			return nil
		}
		return func(a *App) { a.backgroundFailed("remote_keep_session", err) }
	})
}

// offerKeptPrograms tells, once workspace p attached a session an earlier window kept, which
// programs that window left running on the host, and offers to end them or to receive the
// processes again in the Run window (§9.2, S35): those alone, not the ones p started since.
// Keeping them needs nothing; closing p lists them again. A terminal has no output to replay, so
// it is not received again.
func (a *App) offerKeptPrograms(p *project, session core.RemoteSession) {
	if !session.Resumed || len(session.KeptPrograms) == 0 {
		return
	}
	r, kept, key, language := p.remote, session.KeptPrograms, session.SessionKey, a.language()
	var processes []core.RemoteProgram
	for _, program := range kept {
		if program.Kind == core.RemoteProgramProcess {
			processes = append(processes, program)
		}
	}
	text := i18n.SharedFormat(language, "desktop.remote.kept.text", map[string]string{
		"connection": r.name,
		"count":      strconv.Itoa(len(kept)),
	}) + "\n\n" + remoteProgramLines(language, kept)
	actions := []string{i18n.Shared(language, "desktop.remote.kept.end")}
	attach := -1
	if len(processes) > 0 {
		attach = len(actions)
		actions = append(actions, i18n.Shared(language, "desktop.remote.kept.attach"))
		if len(processes) < len(kept) {
			text += "\n\n" + i18n.Shared(language, "desktop.remote.kept.attachTerminals")
		}
	}
	actions = append(actions, i18n.Shared(language, "desktop.remote.kept.keep"))
	a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
		title:   i18n.Shared(language, "desktop.remote.kept.title"),
		text:    text,
		actions: actions,
		onAnswer: func(choice *int) {
			switch {
			case choice == nil:
				// log-exempt: 用户取消：对话框被关闭或随标签页撤下，保留的进程照常运行。
			case *choice == 0:
				a.performed("remote.kept.end", surfaceButton)
				a.endKeptPrograms(p, kept)
			case *choice == attach:
				a.performed("remote.kept.attach", surfaceButton)
				a.attachKeptPrograms(p, key, processes)
			default:
				a.performed("remote.kept.keep", surfaceButton)
			}
		},
	})
}

// attachKeptPrograms receives processes, which an earlier window kept running in host session
// key, again over the session of p, each in a Run tab of its own until it exits, and shows the
// Run window on the last one; stopping the tab ends it on the host. A process a tab already
// receives gets no second one.
func (a *App) attachKeptPrograms(p *project, key string, processes []core.RemoteProgram) {
	r := p.remote
	if session := r.current(); r.closed || session.id == "" || session.key != key {
		a.operationRejected("remote_attach_programs", "disconnected")
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.remote.kept.attachFailed", map[string]string{"connection": r.name}))
		return
	}
	shown := false
	for _, program := range processes {
		runKey := "remote-attach:" + strconv.FormatUint(program.ID, 10)
		if p.build.runOf(runKey) != nil {
			// log-exempt: 用户重复操作：这个进程已经在自己的运行标签里接回，不开第二个。
			continue
		}
		op := a.beginRunOperation(p, remoteProgramName(program), "", runKey, nil)
		a.launchRemoteAttachRun(p, op, key, program.ID)
		shown = true
	}
	if shown {
		a.showBuildConsole(p)
	}
}

// remoteProgramName is what the Run tab of a received program is called: its label's name, else
// the name of the file it runs. It is user content, never logged.
func remoteProgramName(program core.RemoteProgram) string {
	if program.Label != nil && program.Label.Name != "" {
		return program.Label.Name
	}
	if len(program.Argv) > 0 {
		return path.Base(program.Argv[0])
	}
	return ""
}

// endKeptPrograms ends programs, which an earlier window kept on the host of p, over the
// workspace's session; one that already ended is not counted.
func (a *App) endKeptPrograms(p *project, programs []core.RemoteProgram) {
	r := p.remote
	name := r.name
	if r.closed || r.session == "" {
		a.operationRejected("remote_end_programs", "disconnected")
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.remote.kept.endFailed", map[string]string{"connection": name}))
		return
	}
	session, kernel := r.session, a.kernel
	a.background(p, remoteProgramsTimeout, func(ctx context.Context) func(*App) {
		ended, err := kernel.RemoteEndPrograms(ctx, session, programs)
		return func(a *App) {
			if err != nil {
				a.operationFailed("remote_end_programs", remoteLogError(err))
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.remote.kept.endFailed", map[string]string{"connection": name}))
				return
			}
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.remote.kept.ended", map[string]string{
				"connection": name,
				"count":      strconv.Itoa(ended),
			}))
		}
	})
}

// rememberRemoteClose stores decided as what closing a remote workspace does to the host's
// programs, so the question is not asked again; Settings › Tools › Remote Workspace changes it.
func (a *App) rememberRemoteClose(decided core.RemoteClosePrograms) {
	kernel, root := a.kernel, a.globalToolchainRoot()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		read, err := remoteconn.ReadPreferences(ctx, kernel, root, "")
		if err == nil {
			_, _, err = read.Edit(ctx, kernel, core.RemotePreferenceEdit{ClosePrograms: &core.RemoteCloseProgramsEdit{Programs: &decided}})
		}
		if err == nil {
			return nil
		}
		return func(a *App) {
			a.operationFailed("remote_close_remember", documentLogError(err))
			a.shownWorkbench().notify(i18n.Shared(a.language(), "desktop.remote.close.rememberFailed"))
		}
	})
}

// remoteCloseChoice is what closing a remote workspace does to the host's programs, as the
// preferences under root say; RemoteCloseAsk when they cannot be read, with the error. It runs off
// the window thread.
func remoteCloseChoice(ctx context.Context, kernel Kernel, root string) (core.RemoteClosePrograms, error) {
	state, err := remotePreferenceState(ctx, kernel, root)
	if err != nil {
		return core.RemoteCloseAsk, err
	}
	switch choice := state.Closing.Programs; choice {
	case core.RemoteCloseEnd, core.RemoteCloseKeep:
		return choice, nil
	}
	return core.RemoteCloseAsk, nil
}

// remoteProgramLines lists programs one per line, for the close question and the offer to end
// the kept ones: kind, name, command and how long each has run. The command is user content shown
// as it is; neither it nor the name is ever logged.
func remoteProgramLines(language i18n.Language, programs []core.RemoteProgram) string {
	lines := make([]string, len(programs))
	for i, program := range programs {
		kind := i18n.Shared(language, "desktop.remote.close.kindProcess")
		if program.Kind == core.RemoteProgramTerminal {
			kind = i18n.Shared(language, "desktop.remote.close.kindTerminal")
		}
		command, duration := strings.Join(program.Argv, " "), remoteRunningTime(language, program.RunningMs)
		if program.Label != nil && program.Label.Name != "" {
			lines[i] = i18n.SharedFormat(language, "desktop.remote.close.item", map[string]string{
				"kind":     kind,
				"name":     program.Label.Name,
				"command":  command,
				"duration": duration,
			})
			continue
		}
		lines[i] = i18n.SharedFormat(language, "desktop.remote.close.itemUnnamed", map[string]string{
			"kind":     kind,
			"command":  command,
			"duration": duration,
		})
	}
	return strings.Join(lines, "\n")
}

// remoteRunningTime is how long a program has run, in whole minutes, or hours and minutes.
func remoteRunningTime(language i18n.Language, milliseconds uint64) string {
	minutes := milliseconds / 60_000
	switch {
	case minutes == 0:
		return i18n.Shared(language, "desktop.remote.close.ranUnderMinute")
	case minutes < 60:
		return i18n.SharedFormat(language, "desktop.remote.close.ranMinutes", map[string]string{"count": strconv.FormatUint(minutes, 10)})
	}
	return i18n.SharedFormat(language, "desktop.remote.close.ranHours", map[string]string{
		"hours":   strconv.FormatUint(minutes/60, 10),
		"minutes": strconv.FormatUint(minutes%60, 10),
	})
}
