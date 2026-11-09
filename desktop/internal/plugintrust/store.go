package plugintrust

import (
	"errors"
	"fmt"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// approvalsFile is the preference file holding every approval record.
const approvalsFile = "plugin-approvals.json"

// ErrInvalidRecord reports a record that cannot be stored.
var ErrInvalidRecord = errors.New("plugin approval record is not valid")

// file is the on-disk shape. Plugins is nested so that a plugin ID or a version
// never has to be encoded into a map key.
type file struct {
	SchemaVersion int                          `json:"schemaVersion"`
	Plugins       map[string]map[string]Record `json:"plugins"`
}

// Store keeps approval records in one preference file.
type Store struct {
	preferences *store.Store
}

// New returns a store backed by the client's preferences.
func New(preferences *store.Store) *Store {
	return &Store{preferences: preferences}
}

// Record returns the approval stored for one plugin version.
func (s *Store) Record(id, version string) (Record, bool, error) {
	contents, err := s.load()
	if err != nil {
		return Record{}, false, err
	}
	versions, ok := contents.Plugins[id]
	if !ok {
		return Record{}, false, nil
	}
	record, ok := versions[version]
	if !ok {
		return Record{}, false, nil
	}
	return record, true, nil
}

// Approve stores record, replacing any earlier approval of the same version.
func (s *Store) Approve(record Record) error {
	if err := record.Validate(); err != nil {
		return err
	}
	contents, err := s.load()
	if err != nil {
		return err
	}
	versions, ok := contents.Plugins[record.PluginID]
	if !ok {
		versions = make(map[string]Record)
		contents.Plugins[record.PluginID] = versions
	}
	versions[record.Version] = record
	return s.save(contents)
}

// Forget drops the approval of one plugin version. Removing a version that was
// never approved is not an error.
func (s *Store) Forget(id, version string) error {
	contents, err := s.load()
	if err != nil {
		return err
	}
	versions, ok := contents.Plugins[id]
	if !ok {
		return nil
	}
	if _, ok := versions[version]; !ok {
		return nil
	}
	delete(versions, version)
	if len(versions) == 0 {
		delete(contents.Plugins, id)
	}
	return s.save(contents)
}

// List reports every stored approval, ordered by plugin ID then version.
func (s *Store) List() ([]Record, error) {
	contents, err := s.load()
	if err != nil {
		return nil, err
	}
	var records []Record
	for _, versions := range contents.Plugins {
		for _, record := range versions {
			records = append(records, record)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].PluginID != records[j].PluginID {
			return records[i].PluginID < records[j].PluginID
		}
		return records[i].Version < records[j].Version
	})
	return records, nil
}

func (s *Store) load() (file, error) {
	contents := file{SchemaVersion: 1}
	found, err := s.preferences.Load(approvalsFile, &contents)
	if err != nil {
		return file{}, fmt.Errorf("read plugin approvals: %w", err)
	}
	if !found {
		contents = file{SchemaVersion: 1}
	}
	if contents.Plugins == nil {
		contents.Plugins = make(map[string]map[string]Record)
	}
	if contents.SchemaVersion == 0 {
		contents.SchemaVersion = 1
	}
	return contents, nil
}

func (s *Store) save(contents file) error {
	contents.SchemaVersion = 1
	if err := s.preferences.Save(approvalsFile, contents); err != nil {
		return fmt.Errorf("write plugin approvals: %w", err)
	}
	return nil
}
