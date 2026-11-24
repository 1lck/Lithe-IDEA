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
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
)

// Directory is the name of the client's folder inside the user configuration directory.
const Directory = "Lithe Desktop"

// Store reads and writes the client's preference files in one directory.
type Store struct {
	dir string

	mu sync.Mutex
	// kept is, per file, what its last load found that the value could not hold.
	kept map[string]*keptObject
	// unread is, per file, why its last load could not read a stored value it kept (Unread).
	unread map[string]error
	// failedLoad is, per file, why its last load could not read or decode it. The next Save
	// moves that file aside before it writes (setAside).
	failedLoad map[string]error
	// now stamps the name of a file set aside; tests replace it.
	now func() time.Time
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
	return &Store{dir: dir, now: time.Now}
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
// the stored values back. Unknown lists them, and Unread is why a known key's value could not be
// read. A file that is not JSON still fails.
func (store *Store) Load(name string, value any) (found bool, err error) {
	data, err := os.ReadFile(filepath.Join(store.dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		store.keep(name, nil, nil, nil)
		return false, nil
	}
	if err != nil {
		store.keep(name, nil, nil, fmt.Errorf("read %s: %w", name, err))
		return false, err
	}
	decodeErr := json.Unmarshal(data, value)
	kept := walk(data, reflect.TypeOf(value))
	if decodeErr != nil && (kept == nil || !foreignAnywhere(kept)) {
		loadErr := fmt.Errorf("decode %s: %w", name, decodeErr)
		store.keep(name, nil, nil, loadErr)
		return true, loadErr
	}
	var unread error
	if decodeErr != nil {
		unread = fmt.Errorf("decode %s: %w", name, decodeErr)
	}
	if kept != nil {
		// The value has just decoded, so it encodes; if it ever did not, the next Save fails the
		// same way, and until then the foreign values count as left out.
		encoded, err := json.Marshal(value)
		if err != nil {
			unread = errors.Join(unread, fmt.Errorf("encode %s: %w", name, err))
		} else {
			kept.noteLoaded(encoded)
		}
	}
	store.keep(name, kept, unread, nil)
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

func (store *Store) keep(name string, kept *keptObject, unread, failed error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if failed == nil {
		delete(store.failedLoad, name)
	} else {
		if store.failedLoad == nil {
			store.failedLoad = map[string]error{}
		}
		store.failedLoad[name] = failed
	}
	if unread == nil {
		delete(store.unread, name)
	} else {
		if store.unread == nil {
			store.unread = map[string]error{}
		}
		store.unread[name] = unread
	}
	if kept == nil {
		delete(store.kept, name)
		return
	}
	if store.kept == nil {
		store.kept = map[string]*keptObject{}
	}
	store.kept[name] = kept
}

// Unread is why the last load of name could not read a known key's stored value, nil when it
// read every key it has a field for. That load still succeeded and left those fields at what the
// value held, so they run on defaults until the next save writes the stored values back; a
// caller that logs stored state it replaced with defaults logs this as well.
func (store *Store) Unread(name string) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.unread[name]
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
// name could not read written back beside it. When that load could not read or decode the file,
// the file is first moved aside to SetAsideName(name, time), so a save never destroys content a
// load could not read, and the file that holds the new value works again from this save on.
func (store *Store) Save(name string, value any) error {
	_, err := store.SaveWithBackup(name, value)
	return err
}

// SaveWithBackup also returns the path of an unreadable file moved aside by this save.
// The path is returned even if writing its replacement fails.
func (store *Store) SaveWithBackup(name string, value any) (string, error) {
	backup, err := store.setAside(name)
	if err != nil {
		return "", err
	}
	return backup, store.saveJSON(name, value)
}

func (store *Store) saveJSON(name string, value any) error {
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

// SetAsideName is the name an unreadable file name gets when a save moves it aside at time at.
func SetAsideName(name string, at time.Time) string {
	return name + ".unreadable-" + at.UTC().Format("20060102T150405.000000000Z")
}

// setAside moves the file name aside when its last load failed, at most once per failure: the
// check, the rename and clearing the failure happen under one lock, so concurrent saves never move
// the file a first save has just written. A file already gone has nothing to keep. A rename that
// fails keeps the failure and fails the save, so the unreadable file stays where it was.
func (store *Store) setAside(name string) (string, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	failed := store.failedLoad[name]
	if failed == nil {
		return "", nil
	}
	path := filepath.Join(store.dir, name)
	aside := filepath.Join(store.dir, SetAsideName(name, store.now()))
	err := os.Rename(path, aside)
	if errors.Is(err, fs.ErrNotExist) {
		delete(store.failedLoad, name)
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("move unreadable %s aside before saving: %w", name, errors.Join(err, failed))
	}
	delete(store.failedLoad, name)
	return aside, nil
}

// Path is where the file name lives, for a reader that streams it instead of loading it whole,
// such as an image decoder.
func (store *Store) Path(name string) string {
	return filepath.Join(store.dir, name)
}

// Remove deletes the file name. A file that does not exist is already removed.
func (store *Store) Remove(name string) error {
	if err := os.Remove(filepath.Join(store.dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	store.keep(name, nil, nil, nil)
	return nil
}

// WriteFile replaces the file name with data atomically, as Save does for JSON.
// It keeps a file the client owns that is not JSON, such as a background image.
func (store *Store) WriteFile(name string, data []byte) error {
	if err := os.MkdirAll(store.dir, 0o755); err != nil {
		return err
	}
	return atomicfile.Write(filepath.Join(store.dir, name), data, 0o600)
}
