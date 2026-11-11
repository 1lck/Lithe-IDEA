package workbench

import (
	"os"
	"os/exec"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/wslpath"
)

// Opening a project while another one is open asks where it goes, as the IDE does:
// This Window replaces the open project, New Window starts another client for it.
// "Don't ask again" stores the answer as settings.ProjectOpenDestination, which the
// General settings page shows and can set back to asking.

// openProject opens the folder at path, asking first where to open it when the window
// already has a project.
func (a *App) openProject(path string) {
	if a.missing[path] {
		a.askRemoveUnavailableRecent(path)
		return
	}
	p := a.project
	if p == nil || a.isOpenProjectRoot(path) {
		a.openProjectHere(path)
		return
	}
	switch a.settings.ProjectOpenDestination {
	case settingswindow.ProjectOpenThisWindow:
		a.openProjectHere(path)
	case settingswindow.ProjectOpenNewWindow:
		a.openProjectInNewWindow(path)
	default:
		a.askProjectOpenDestination(path)
	}
}

// isOpenProjectRoot reports whether path names the folder already open.
func (a *App) isOpenProjectRoot(path string) bool {
	root, err := filepath.Abs(wslpath.ToNative(path))
	return err == nil && a.project != nil && filepath.Clean(root) == filepath.Clean(a.project.root)
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
		a.openProjectHere(path)
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
	exe, err := os.Executable()
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
