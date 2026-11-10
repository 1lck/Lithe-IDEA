package settingswindow

import (
	"errors"
	"strings"

	"github.com/vivaui/viva/app"
)

// The skills page works with files the user names: it reads a SKILL.md through Core, reveals a
// skill's path in the system file browser, and picks a SKILL.md or a skill folder with the
// system pickers. The pickers are the Viva wrappers the plugin settings use; a cancelled picker
// returns "" and no error.

// pickSkillSource shows the file picker for a SKILL.md, or the folder picker for a skill package.
// It runs on the window thread, as the plugin settings pickers do.
func pickSkillSource(title string, directory bool) (string, error) {
	if directory {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		if errors.Is(err, app.ErrCanceled) {
			return "", nil
		}
		return path, err
	}
	paths, err := app.OpenFiles(app.OpenFileOptions{
		Title:   title,
		Filters: []app.FileFilter{{Name: "SKILL.md", Pattern: "SKILL.md"}},
	})
	if errors.Is(err, app.ErrCanceled) {
		return "", nil
	}
	if len(paths) == 0 {
		return "", err
	}
	return paths[0], err
}

// revealSkillPath shows path in the system file browser.
func revealSkillPath(path string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	return app.RevealPath(path)
}

// skillMatches says whether a skill is listed for the folded search query: its name, description,
// scope and path contain it. An empty query lists every skill.
func skillMatches(name, description, scope, path, query string) bool {
	if query == "" {
		return true
	}
	for _, field := range []string{name, description, scope, path} {
		if strings.Contains(strings.ToLower(field), query) {
			return true
		}
	}
	return false
}

// isProjectScope says whether a native scope belongs to the project group; user, system and
// admin scopes are global.
func isProjectScope(scope string) bool { return scope == "repo" }
