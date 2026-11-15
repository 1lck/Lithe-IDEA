// Package store keeps the desktop client's own preferences as JSON files in the user's
// configuration directory (on macOS ~/Library/Application Support/Lithe Desktop). It never
// writes next to the executable or inside an app bundle: the installed client stays
// byte-identical to the release, which differential updates depend on.
//
// Each file belongs to one owner (recent projects, workbench layout, settings) and is
// replaced whole on every save through a temporary file in the same directory, so a crash
// leaves either the previous or the new content, never a half-written file.
//
// A save keeps what the last load of the same file could not read, such as keys a newer version
// wrote (see keep.go), so moving between the stable channel and AutoBuild loses no settings.
package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
)

// Directory is the name of the client's folder inside the user configuration directory.
const Directory = "Lithe Desktop"

// Store reads and writes the client's preference files in one directory.
type Store struct {
	dir string

	mu sync.Mutex
	// kept is, per file, what its last load found that the value could not hold.
	kept map[string]*keptObject
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
//
// Keys value has no field for, and known keys whose stored value has a shape the field cannot
// take, do not fail the load: the fields keep what value held, and the next Save of name writes
// the stored values back. Unknown lists them. A file that is not JSON still fails.
func (store *Store) Load(name string, value any) (found bool, err error) {
	data, err := os.ReadFile(filepath.Join(store.dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		store.keep(name, nil)
		return false, nil
	}
	if err != nil {
		return false, err
	}
	decodeErr := json.Unmarshal(data, value)
	kept := walk(data, reflect.TypeOf(value))
	if decodeErr != nil && (kept == nil || !foreignAnywhere(kept)) {
		store.keep(name, nil)
		return true, fmt.Errorf("decode %s: %w", name, decodeErr)
	}
	if kept != nil {
		if encoded, err := json.Marshal(value); err == nil {
			kept.noteLoaded(encoded)
		}
	}
	store.keep(name, kept)
	return true, nil
}

// foreignAnywhere reports whether the walk found a known key it could not decode, the only kind
// of failure json.Unmarshal reports and then completes the value anyway.
func foreignAnywhere(object *keptObject) bool {
	if len(object.foreign) > 0 {
		return true
	}
	for _, inner := range object.inner {
		if foreignAnywhere(inner) {
			return true
		}
	}
	return false
}

func (store *Store) keep(name string, kept *keptObject) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if kept == nil {
		delete(store.kept, name)
		return
	}
	if store.kept == nil {
		store.kept = map[string]*keptObject{}
	}
	store.kept[name] = kept
}

// Unknown lists, as dotted key paths, what the last load of name could not read and the next save
// writes back: keys a newer version wrote, and values of a shape this version cannot take.
func (store *Store) Unknown(name string) []string {
	store.mu.Lock()
	defer store.mu.Unlock()
	kept := store.kept[name]
	if kept == nil {
		return nil
	}
	paths := kept.paths("", nil)
	sort.Strings(paths)
	return paths
}

// Save encodes value and replaces the file name with it atomically, with what the last load of
// name could not read written back beside it.
func (store *Store) Save(name string, value any) error {
	store.mu.Lock()
	kept := store.kept[name]
	store.mu.Unlock()
	if kept == nil {
		data, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return fmt.Errorf("encode %s: %w", name, err)
		}
		return store.WriteFile(name, append(data, '\n'))
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode %s: %w", name, err)
	}
	store.mu.Lock()
	merged := kept.merge(encoded)
	store.mu.Unlock()
	var data bytes.Buffer
	if err := json.Indent(&data, merged, "", "  "); err != nil {
		return fmt.Errorf("encode %s: %w", name, err)
	}
	data.WriteByte('\n')
	return store.WriteFile(name, data.Bytes())
}

// Path is where the file name lives, for a reader that streams it instead of loading it whole,
// such as an image decoder.
func (store *Store) Path(name string) string {
	return filepath.Join(store.dir, name)
}

// Remove deletes the file name. A file that does not exist is already removed.
func (store *Store) Remove(name string) error {
	store.keep(name, nil)
	if err := os.Remove(filepath.Join(store.dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// WriteFile replaces the file name with data atomically, as Save does for JSON. It keeps a
// file the client owns that is not JSON, such as the workbench background image.
func (store *Store) WriteFile(name string, data []byte) error {
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
