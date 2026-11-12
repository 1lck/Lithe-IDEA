// Package store keeps the desktop client's own preferences as JSON files in the user's
// configuration directory (on macOS ~/Library/Application Support/Lithe Desktop). It never
// writes next to the executable or inside an app bundle: the installed client stays
// byte-identical to the release, which differential updates depend on.
//
// Each file belongs to one owner (recent projects, workbench layout, settings) and is
// replaced whole on every save through a temporary file in the same directory, so a crash
// leaves either the previous or the new content, never a half-written file.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Directory is the name of the client's folder inside the user configuration directory.
const Directory = "Lithe Desktop"

// Store reads and writes the client's preference files in one directory.
type Store struct {
	dir string
}

// Open returns the store in the user's configuration directory. The directory is created
// on the first save, not here, so opening never writes.
func Open() (*Store, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return nil, fmt.Errorf("find the configuration directory: %w", err)
	}
	return At(filepath.Join(base, Directory)), nil
}

// At returns a store in dir; tests use it with a temporary directory.
func At(dir string) *Store {
	return &Store{dir: dir}
}

// Dir is the directory the store reads and writes.
func (store *Store) Dir() string {
	return store.dir
}

// Load decodes the file name into value. found is false, and value untouched, when the
// file does not exist yet.
func (store *Store) Load(name string, value any) (found bool, err error) {
	data, err := os.ReadFile(filepath.Join(store.dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(data, value); err != nil {
		return true, fmt.Errorf("decode %s: %w", name, err)
	}
	return true, nil
}

// Save encodes value and replaces the file name with it atomically.
func (store *Store) Save(name string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("encode %s: %w", name, err)
	}
	data = append(data, '\n')
	if err := os.MkdirAll(store.dir, 0o755); err != nil {
		return err
	}
	file, err := os.CreateTemp(store.dir, "."+name+".*.tmp")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary) // no-op once the rename succeeded
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(temporary, filepath.Join(store.dir, name))
}
