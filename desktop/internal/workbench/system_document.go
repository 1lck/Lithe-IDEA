package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

// openSystemDocument receives Finder's Open With / default-app event. A file
// never replaces a project, opens its parent folder or enters project services.
func (a *App) openSystemDocument(path string) {
	a.performed("editor.systemFile.open", surfaceMenu)
	a.background(nil, kernelCallTimeout, func(ctx context.Context) func(*App) {
		absolute, err := filepath.Abs(path)
		if err == nil {
			var info os.FileInfo
			info, err = os.Stat(absolute)
			if err == nil && !info.Mode().IsRegular() {
				err = errors.New("system document is not a regular file")
			}
		}
		if err == nil {
			err = ctx.Err()
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("system_document_open", err)
				a.notifyError(a.text.Errors.OpenFailed(err.Error()))
				return
			}
			a.sessions.openDocumentTab(absolute)
		}
	})
}

// openDocumentTab reuses an editor-only workbench, with stable document identity,
// or constructs one with OpenFile before any plugin stack can be assembled.
func (s *windowSessions) openDocumentTab(path string) {
	for _, session := range s.list {
		if session.documentOnly && session.project != nil && session.project.docs.byPath(path) != nil {
			s.activate(session)
			session.openFile(session.project, path)
			return
		}
	}
	if a := s.active; a.documentOnly && a.project != nil {
		a.openFile(a.project, path)
		return
	}
	options := s.options
	options.OpenPath, options.OpenFile = "", path
	a := New(options)
	a.startupFile = ""
	s.list = append(s.list, a)
	s.activate(a)
	a.openStandaloneFile(path)
}
