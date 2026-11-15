// Package pluginstate keeps the enablement choices the user made, one per plugin.
//
// It only stores them. What a plugin without a choice is, when a choice is recorded
// or dropped, and in which order with the plugin's other records, is Core's
// (plugins.installed.lifecycle); pluginmanager asks Core and carries out its steps.
package pluginstate

import (
	"errors"
	"fmt"
	"sort"
	"sync"

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
	mu          sync.Mutex
	preferences *store.Store
}

// New returns a store backed by the client's preferences.
func New(preferences *store.Store) *Store {
	return &Store{preferences: preferences}
}

// SetEnabled records an explicit choice for a plugin.
func (s *Store) SetEnabled(id string, enabled bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
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

// Forget drops the choice for a plugin. Dropping one that was never recorded is
// not an error.
func (s *Store) Forget(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
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
	s.mu.Lock()
	defer s.mu.Unlock()
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
