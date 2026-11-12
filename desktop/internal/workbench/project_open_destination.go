package workbench

import (
	"os"
	"os/exec"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/wslpath"
)

// Opening a project while another one is open asks where it goes, as the IDE does:
// This Window opens it in a new project tab of the window (window_sessions.go), New Window
// starts another client for it. A project already open in a tab of the window is shown.
// "Don't ask again" stores the answer as settings.ProjectOpenDestination, which the
// General settings page shows and can set back to asking.

// openProject opens the folder at path, asking first where to open it when the window
// already has a project.
func (a *App) openProject(path string) {
	if a.missing[path] {
		a.askRemoveUnavailableRecent(path)
		return
	}
	if a.project == nil || a.sessions.showing(path) != nil {
		a.openProjectThisWindow(path)
		return
	}
	switch a.settings.ProjectOpenDestination {
	case settingswindow.ProjectOpenThisWindow:
		a.openProjectThisWindow(path)
	case settingswindow.ProjectOpenNewWindow:
		a.openProjectInNewWindow(path)
	default:
		a.askProjectOpenDestination(path)
	}
}

// sameProjectRoot reports whether path names the project folder root.
func sameProjectRoot(path, root string) bool {
	abs, err := filepath.Abs(wslpath.ToNative(path))
	return err == nil && filepath.Clean(abs) == filepath.Clean(root)
}

// openProjectThisWindow opens path in this window: it shows the tab that already has it, opens it
// here when this workbench has no project, and otherwise opens it in a new project tab.
func (a *App) openProjectThisWindow(path string) {
	if open := a.sessions.showing(path); open != nil {
		a.sessions.activate(open)
		return
	}
	if a.project == nil || a.sessions == nil {
		a.openProjectHere(path)
		return
	}
	a.sessions.openTab(path)
}

// askProjectOpenDestination asks where to open path: Cancel, New Window or This Window,
// the last being the default button.
func (a *App) askProjectOpenDestination(path string) {
	language := a.language()
	name := filepath.Base(filepath.Clean(wslpath.ToNative(path)))
	prompt := &pluginPrompt{
		title: i18n.Shared(language, "native.openProject"),
		text:  i18n.SharedFormat(language, "native.whereWouldYouLikeToOpenTheProject", map[string]string{"arg1": name}),
		check: i18n.Shared(language, "native.donTAskAgain"),
		actions: []string{
			i18n.Shared(language, "desktop.projectOpen.cancel"),
			i18n.Shared(language, "native.newWindow"),
			i18n.Shared(language, "native.thisWindow"),
		},
	}
	prompt.onAnswer = func(choice *int) {
		if choice == nil || *choice == 0 {
			return
		}
		destination := settingswindow.ProjectOpenThisWindow
		if *choice == 1 {
			destination = settingswindow.ProjectOpenNewWindow
		}
		if prompt.checked {
			a.settings.ProjectOpenDestination = destination
			a.saveSettings()
		}
		if destination == settingswindow.ProjectOpenNewWindow {
			a.performed("workspace.open.newWindow", surfaceButton)
			a.openProjectInNewWindow(path)
			return
		}
		a.performed("workspace.open.thisWindow", surfaceButton)
		a.openProjectThisWindow(path)
	}
	a.prompts.queue = append(a.prompts.queue, prompt)
}

// openProjectInNewWindow starts another client that opens path; the window keeps its
// own project.
func (a *App) openProjectInNewWindow(path string) {
	if err := launchClient(path); err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.projectOpen.newWindowFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}

// launchClient starts this executable on path as a separate client and does not wait for it.
func launchClient(path string) error {
	exe, err := installedpackage.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, path)
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// askRemoveUnavailableRecent answers the opening of a recent project whose folder is gone
// (a.missing): it offers to take it off the list, and Cancel keeps it, still marked. The
// folder is looked at again first, since a drive may have come back since the mark.
func (a *App) askRemoveUnavailableRecent(path string) {
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		delete(a.missing, path)
		a.openProject(path)
		return
	}
	language := a.language()
	a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
		title: i18n.Shared(language, "fileSystem.recentProjectUnavailableTitle"),
		text:  i18n.SharedFormat(language, "fileSystem.recentProjectUnavailable", map[string]string{"path": path}),
		actions: []string{
			i18n.Shared(language, "desktop.projectOpen.cancel"),
			i18n.Shared(language, "fileSystem.removeFromList"),
		},
		onAnswer: func(choice *int) {
			if choice != nil && *choice == 1 {
				a.performed("workspace.recent.remove", surfaceButton)
				a.reduceRecent(a.recent, core.RemoveRecent(path), true)
			}
		},
	})
}
