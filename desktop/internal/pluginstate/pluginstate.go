// Package pluginstate keeps which installed plugins the user enabled.
//
// Enablement is per plugin, not per version: installing a new version must not
// silently turn a plugin back on, and uninstalling one version must not reset a
// choice the user made for another.
//
// A plugin with no record is disabled. A package the user downloaded is not
// enabled until they say so, which keeps a fresh installation from contributing
// tool windows, languages or commands before the user asked for them.
package pluginstate

import (
	"errors"
	"fmt"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// stateFile is the preference file holding every explicit choice.
const stateFile = "plugin-state.json"

// ErrInvalidPlugin reports a plugin ID that cannot be a key.
var ErrInvalidPlugin = errors.New("plugin state record is not valid")

// Entry is one explicit enablement choice.
type Entry struct {
	PluginID string `json:"pluginID"`
	Enabled  bool   `json:"enabled"`
}

// file is the on-disk shape.
type file struct {
	SchemaVersion int              `json:"schemaVersion"`
	Plugins       map[string]Entry `json:"plugins"`
}

// Store keeps enablement choices in one preference file.
type Store struct {
	preferences *store.Store
}

// New returns a store backed by the client's preferences.
func New(preferences *store.Store) *Store {
	return &Store{preferences: preferences}
}

// Enabled reports whether a plugin is enabled. A plugin with no record is
// disabled.
func (s *Store) Enabled(id string) (bool, error) {
	if err := checkID(id); err != nil {
		return false, err
	}
	contents, err := s.load()
	if err != nil {
		return false, err
	}
	entry, ok := contents.Plugins[id]
	if !ok {
		return false, nil
	}
	return entry.Enabled, nil
}

// SetEnabled records an explicit choice for a plugin.
func (s *Store) SetEnabled(id string, enabled bool) error {
	if err := checkID(id); err != nil {
		return err
	}
	contents, err := s.load()
	if err != nil {
		return err
	}
	contents.Plugins[id] = Entry{PluginID: id, Enabled: enabled}
	return s.save(contents)
}

// Forget drops a choice, so a later installation starts disabled again. It is
// called when the last installed version of a plugin is removed.
func (s *Store) Forget(id string) error {
	if err := checkID(id); err != nil {
		return err
	}
	contents, err := s.load()
	if err != nil {
		return err
	}
	if _, ok := contents.Plugins[id]; !ok {
		return nil
	}
	delete(contents.Plugins, id)
	return s.save(contents)
}

// List reports every explicit choice, ordered by plugin ID.
func (s *Store) List() ([]Entry, error) {
	contents, err := s.load()
	if err != nil {
		return nil, err
	}
	entries := make([]Entry, 0, len(contents.Plugins))
	for _, entry := range contents.Plugins {
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].PluginID < entries[j].PluginID })
	return entries, nil
}

func (s *Store) load() (file, error) {
	contents := file{SchemaVersion: 1}
	found, err := s.preferences.Load(stateFile, &contents)
	if err != nil {
		return file{}, fmt.Errorf("read plugin state: %w", err)
	}
	if !found {
		contents = file{SchemaVersion: 1}
	}
	if contents.Plugins == nil {
		contents.Plugins = make(map[string]Entry)
	}
	if contents.SchemaVersion == 0 {
		contents.SchemaVersion = 1
	}
	return contents, nil
}

func (s *Store) save(contents file) error {
	contents.SchemaVersion = 1
	if err := s.preferences.Save(stateFile, contents); err != nil {
		return fmt.Errorf("write plugin state: %w", err)
	}
	return nil
}

func checkID(id string) error {
	if id == "" {
		return fmt.Errorf("%w: the plugin ID is empty", ErrInvalidPlugin)
	}
	return nil
}
