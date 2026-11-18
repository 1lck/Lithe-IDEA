// Package fileapps asks the system which applications open a file and opens the file with one
// of them, as the system's own Open With menu does: Launch Services on macOS, the shell's
// association handlers on Windows. It keeps no list of its own and never reads the file; it
// changes no association either, so the file's default application stays what it was. Other
// systems answer no application, which leaves the caller its application picker.
package fileapps

import (
	"errors"
	"path/filepath"
)

// App is an application the system offers for a file.
type App struct {
	// ID is what Open hands back to the system: the application bundle on macOS, the
	// handler's name on Windows, which is its executable or the identity of a packaged app.
	ID string
	// Name is what the system's own menu calls the application.
	Name string
	// Default says the system opens the file with this application on a double click.
	Default bool
}

// ErrNotOffered is Open's error when the system no longer offers the application for the
// file: the association changed after List was asked.
var ErrNotOffered = errors.New("fileapps: the application no longer opens this kind of file")

// List returns the applications the system offers for the file at path, in the order its own
// menu shows them, the default application first. It asks the system's association database,
// which can take a moment, so it is called off the window thread. No application is an empty
// list, not an error.
func List(path string) ([]App, error) {
	if path == "" || !filepath.IsAbs(path) {
		return nil, errors.New("fileapps: the path is not absolute")
	}
	return list(filepath.Clean(path))
}

// Open opens the file at path with app, which List returned for the same file. It hands the
// file to the system and returns once the system took it; it does not wait for the
// application. It is called off the window thread.
func Open(path string, app App) error {
	if path == "" || !filepath.IsAbs(path) {
		return errors.New("fileapps: the path is not absolute")
	}
	if app.ID == "" {
		return errors.New("fileapps: the application is empty")
	}
	return open(filepath.Clean(path), app)
}

// Labels are what a menu shows for apps: the name alone, or, for a name two applications
// share, the name with where the application is (withPath), as two copies of an editor in
// different folders are.
func Labels(apps []App, withPath func(name, path string) string) []string {
	count := make(map[string]int, len(apps))
	for _, app := range apps {
		count[app.Name]++
	}
	labels := make([]string, len(apps))
	for i, app := range apps {
		if count[app.Name] > 1 {
			labels[i] = withPath(app.Name, app.ID)
		} else {
			labels[i] = app.Name
		}
	}
	return labels
}
