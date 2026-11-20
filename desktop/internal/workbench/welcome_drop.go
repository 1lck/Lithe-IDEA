package workbench

import (
	"os"

	"github.com/vivaui/viva/gfx"
)

// fileDrop routes files dropped on the window. The start screen opens a dropped folder as a
// project; with a project open, files dropped on a terminal are typed into it.
func (a *App) fileDrop(event gfx.FileDropEvent) gfx.EventResult {
	if a.documentOnly {
		if result, handled := a.terminalFileDrop(event); handled {
			return result
		}
		if event.Phase == gfx.FileDropDrop {
			for _, path := range event.Paths {
				info, err := os.Stat(path)
				if err != nil {
					a.operationFailed("single_file_drop", documentLogError(err))
					continue
				}
				if info.IsDir() {
					a.openProject(path)
				} else if info.Mode().IsRegular() {
					if a.project == nil {
						a.openStandaloneFile(path)
					} else {
						a.openFile(a.project, path)
					}
				}
			}
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if a.project == nil {
		return a.welcomeFileDrop(event)
	}
	result, _ := a.terminalFileDrop(event)
	return result
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
	a.performed("workspace.drop.open", surfaceDragDrop)
	a.openProject(folder)
	return gfx.EventResult{Handled: true, Repaint: true}
}
