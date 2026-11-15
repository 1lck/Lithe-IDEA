package workbench

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Plugin-owned terminals share the Terminal tool window, the tab strip and the
// editor groups with the user's own terminals; a plugin never reaches a terminal
// it did not create. The program starts only after the user allowed this exact
// program, argument list and directory.

// pluginTerminal is the plugin's side of a terminal.
type pluginTerminal struct {
	mu     sync.Mutex
	budget int
	// done delivers the one outcome of this run.
	done     chan pluginservice.TerminalExit
	finished bool
}

var _ pluginservice.TerminalHost = pluginWorkbench{}

// pluginTerminalSession is the handle the host service keeps for one run.
type pluginTerminalSession struct {
	app      *App
	project  *project
	terminal int
	plugin   *pluginTerminal
}

// finishPluginTerminal records the outcome of a plugin terminal once: the snapshot
// is taken before the view is released, and later calls do nothing.
func (a *App) finishPluginTerminal(t *terminal, reason string, status *int) {
	plugin := t.plugin
	if plugin == nil {
		return
	}
	plugin.mu.Lock()
	if plugin.finished {
		plugin.mu.Unlock()
		return
	}
	plugin.finished = true
	budget := plugin.budget
	plugin.mu.Unlock()
	plugin.done <- pluginservice.TerminalExit{Code: status, Reason: reason, Retained: t.view.RetainedText(budget)}
}

// pluginTerminalExited runs on the window thread when the program ends on its own.
// It records the outcome, then removes the tab on the next turn: the exit is
// reported from the pump that is walking the terminals.
func (a *App) pluginTerminalExited(p *project, t *terminal, status *int) {
	a.finishPluginTerminal(t, "exited", status)
	id := t.id
	a.post(func(a *App) {
		if a.project == p && p.terms.find(id) != nil {
			a.closeTerminal(p, id)
		}
	})
}

// StartTerminal asks for consent and opens the terminal.
func (w pluginWorkbench) StartTerminal(ctx context.Context, root string, spec pluginservice.TerminalSpec) (pluginservice.TerminalSession, error) {
	a := w.app
	language := a.language()
	prompt := &pluginPrompt{
		title: i18n.SharedFormat(language, "desktop.pluginHost.terminalConsentTitle", map[string]string{"plugin": spec.PluginID}),
		text: i18n.SharedFormat(language, "desktop.pluginHost.terminalConsentDetails", map[string]string{
			"program":   spec.Executable,
			"arguments": quoteArguments(spec.Arguments),
			"directory": spec.Directory,
		}),
		mono: true,
		actions: []string{
			i18n.Shared(language, "desktop.pluginHost.terminalDeny"),
			i18n.Shared(language, "desktop.pluginHost.terminalAllow"),
		},
	}
	choice, err := a.askUser(ctx, prompt)
	if err != nil {
		return nil, err
	}
	if choice == nil || *choice != 1 {
		return nil, hostError(pluginservice.CodePermissionDenied, "The user did not allow the program to run.")
	}
	return onWindow(a, ctx, func(a *App) (pluginservice.TerminalSession, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return nil, err
		}
		plugin := &pluginTerminal{budget: spec.RetainedBytes, done: make(chan pluginservice.TerminalExit, 1)}
		env, unset := terminalEnvironment(spec.Environment)
		title := spec.Title
		if title == "" {
			title = filepath.Base(spec.Executable)
		}
		args := spec.Arguments
		if args == nil {
			args = []string{}
		}
		t := a.newTerminalWith(p, terminalOptions{
			shell: spec.Executable, args: args, env: env, unset: unset, dir: spec.Directory,
			title: title, prefill: spec.Prefill, activate: spec.Show, plugin: plugin,
		})
		if t == nil {
			return nil, hostError(pluginservice.CodeBusy, "The terminal could not be opened.")
		}
		session := &pluginTerminalSession{app: a, project: p, terminal: t.id, plugin: plugin}
		if spec.Show {
			session.reveal(p, t)
		}
		return session, nil
	})
}

// reveal selects the terminal and shows the Terminal tool window when the tab
// lives there.
func (s *pluginTerminalSession) reveal(p *project, t *terminal) {
	a := s.app
	if g := p.terms.bench.GroupOf(terminalMember(t.id)); g != nil && g.ID == toolGroup {
		a.reduceChrome(core.SetChromeOpen(itemTerminal, true))
	}
	a.selectTerminal(p, t.id)
}

func (s *pluginTerminalSession) Show(ctx context.Context) error {
	_, err := onWindow(s.app, ctx, func(a *App) (struct{}, error) {
		if a.project != s.project {
			return struct{}{}, hostError(pluginservice.CodeContextExpired, "The workspace is no longer open.")
		}
		t := s.project.terms.find(s.terminal)
		if t == nil {
			return struct{}{}, hostError(pluginservice.CodePreconditionFailed, "The terminal is closed.")
		}
		s.reveal(s.project, t)
		return struct{}{}, nil
	})
	return err
}

func (s *pluginTerminalSession) Close(ctx context.Context, retainedBytes int) error {
	_, err := onWindow(s.app, ctx, func(a *App) (struct{}, error) {
		s.plugin.mu.Lock()
		s.plugin.budget = retainedBytes
		s.plugin.mu.Unlock()
		if a.project == s.project && s.project.terms.find(s.terminal) != nil {
			a.closeTerminal(s.project, s.terminal)
		}
		return struct{}{}, nil
	})
	return err
}

func (s *pluginTerminalSession) Done() <-chan pluginservice.TerminalExit { return s.plugin.done }

// terminalEnvironment splits the plugin's overrides into variables to set and
// variables to remove, in a fixed order.
func terminalEnvironment(overrides map[string]*string) (set, unset []string) {
	names := make([]string, 0, len(overrides))
	for name := range overrides {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if value := overrides[name]; value == nil {
			unset = append(unset, name)
		} else {
			set = append(set, name+"="+*value)
		}
	}
	return set, unset
}

// quoteArguments shows an argument list the way a person can read it exactly:
// each argument quoted when it holds a space, a quote or nothing.
func quoteArguments(arguments []string) string {
	if len(arguments) == 0 {
		return "-"
	}
	quoted := make([]string, len(arguments))
	for i, argument := range arguments {
		if argument == "" || strings.ContainsAny(argument, " \t\"'\\\n") {
			quoted[i] = `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(argument) + `"`
		} else {
			quoted[i] = argument
		}
	}
	return strings.Join(quoted, " ")
}
