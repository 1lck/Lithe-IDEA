package workbench

import (
	"os"

	"github.com/vivaui/viva/gfx"
)

// fileDrop routes files dropped on the window. The start screen opens a dropped folder as a
// project; with a project open, files dropped on the Agent composer become its references.
func (a *App) fileDrop(event gfx.FileDropEvent) gfx.EventResult {
	if a.project == nil {
		return a.welcomeFileDrop(event)
	}
	return a.agentFileDrop(event)
}

// welcomeFileDrop opens the first dropped folder as a project. Dropped files that are not folders
// open nothing and say so.
func (a *App) welcomeFileDrop(event gfx.FileDropEvent) gfx.EventResult {
	if event.Phase != gfx.FileDropDrop {
		return gfx.EventResult{}
	}
	folder := ""
	for _, path := range event.Paths {
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			folder = path
			break
		}
	}
	if folder == "" {
		a.notifyInfo(a.text.Welcome.DropFolderOnly)
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	a.performed("workspace.drop.open", surfaceMenu)
	a.openProject(folder)
	return gfx.EventResult{Handled: true, Repaint: true}
}
