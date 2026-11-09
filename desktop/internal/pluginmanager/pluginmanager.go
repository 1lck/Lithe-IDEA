// Package pluginmanager is the one place the workbench asks about installed
// plugins.
//
// It owns no policy of its own: extracting and installing belongs to pluginpkg,
// approving to plugintrust, enablement to pluginstate. What it adds is the
// lifecycle that spans them, which is where the mistakes live — forgetting an
// approval when the package is removed, keeping a user's enablement choice while
// another version of the same plugin is still installed, and dropping it when the
// last one goes.
package pluginmanager

import (
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

// ErrUnknownPlugin reports a plugin that has no installed version.
var ErrUnknownPlugin = errors.New("plugin is not installed")

// Entry is one installed plugin version and whether its plugin is enabled.
type Entry struct {
	// Installed is the package on disk.
	Installed pluginpkg.Installed
	// Enabled is the user's choice for this plugin, not for this version.
	Enabled bool
}

// Manager ties the installed packages to their approval records and enablement
// choices.
type Manager struct {
	root      string
	approvals *plugintrust.Store
	state     *pluginstate.Store
}

// New returns a manager for the plugin root root.
func New(root string, approvals *plugintrust.Store, state *pluginstate.Store) *Manager {
	return &Manager{root: root, approvals: approvals, state: state}
}

// Installed reports every installed version with its plugin's enablement.
func (m *Manager) Installed() ([]Entry, error) {
	installed, err := pluginpkg.List(m.root)
	if err != nil {
		return nil, err
	}
	entries := make([]Entry, 0, len(installed))
	for _, packageEntry := range installed {
		enabled, err := m.state.Enabled(packageEntry.ID)
		if err != nil {
			return nil, err
		}
		entries = append(entries, Entry{Installed: packageEntry, Enabled: enabled})
	}
	return entries, nil
}

// Uninstall removes one installed version, drops its approval and, when it was
// the last installed version of that plugin, drops the enablement choice too so
// a later installation starts disabled.
//
// The package is removed before anything else, so a failure to clean up a record
// never leaves a half-removed package that still looks installed. Such a failure
// is returned and the caller should log it; the next installation of the same
// version asks the user again.
func (m *Manager) Uninstall(id, version string) error {
	if err := pluginpkg.Uninstall(m.root, id, version); err != nil {
		return err
	}
	var failures []error
	if err := m.approvals.Forget(id, version); err != nil {
		failures = append(failures, fmt.Errorf("forget the approval of %s %s: %w", id, version, err))
	}
	remaining, err := pluginpkg.List(m.root)
	if err != nil {
		failures = append(failures, fmt.Errorf("list installed plugins: %w", err))
	} else if !installsID(remaining, id) {
		if err := m.state.Forget(id); err != nil {
			failures = append(failures, fmt.Errorf("forget the enablement of %s: %w", id, err))
		}
	}
	return errors.Join(failures...)
}

// SetEnabled records an enablement choice for a plugin that has an installed
// version. Enabling a plugin that is not installed would silently enable it the
// moment a later installation lands.
func (m *Manager) SetEnabled(id string, enabled bool) error {
	installed, err := pluginpkg.List(m.root)
	if err != nil {
		return err
	}
	if !installsID(installed, id) {
		return fmt.Errorf("%w: %s", ErrUnknownPlugin, id)
	}
	return m.state.SetEnabled(id, enabled)
}

// Enabled reports whether a plugin is enabled.
func (m *Manager) Enabled(id string) (bool, error) {
	return m.state.Enabled(id)
}

func installsID(installed []pluginpkg.Installed, id string) bool {
	for _, entry := range installed {
		if entry.ID == id {
			return true
		}
	}
	return false
}
