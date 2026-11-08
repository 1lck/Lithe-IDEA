// Package documentio implements guarded native document persistence.
package documentio

import (
	"bytes"
	"errors"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var (
	// ErrTooLarge means the document exceeds the editor size limit.
	ErrTooLarge = errors.New("document exceeds size limit")
	// ErrNotRegular means the target is not an ordinary file.
	ErrNotRegular = errors.New("document is not a regular file")
	// ErrConflict means the original file no longer matches the opened snapshot.
	ErrConflict = errors.New("document changed on disk")
	// ErrSymbolicLink means a document path cannot safely be replaced.
	ErrSymbolicLink = errors.New("document is a symbolic link")
	// ErrHardLink means saving would change or detach an unconfirmed hard link.
	ErrHardLink = errors.New("document has multiple hard links")
	// ErrUnsupported means a guarded replacement is unavailable on this platform.
	ErrUnsupported = errors.New("guarded document replacement is not supported")
)

const maxBytes = 16 << 20

// Locks bound concurrent writes without retaining a per-path lock forever.
var writeLocks [64]sync.Mutex

func writeLock(path string) *sync.Mutex {
	h := fnv.New32a()
	_, _ = h.Write([]byte(filepath.Clean(path)))
	return &writeLocks[h.Sum32()%uint32(len(writeLocks))]
}

// WriteMissing creates a previously acknowledged missing document without ever
// replacing a newly created directory entry, including a symlink or a directory.
// On Unix the staged file has private permissions because the removed file's metadata
// can no longer be recovered reliably. On Windows it inherits the directory's ACL.
func WriteMissing(path string, data []byte) (err error) {
	lock := writeLock(path)
	lock.Lock()
	defer lock.Unlock()
	if len(data) > maxBytes {
		return ErrTooLarge
	}
	staged, err := os.CreateTemp(filepath.Dir(path), ".lithe-document-*")
	if err != nil {
		return err
	}
	stageName := staged.Name()
	defer func() {
		if staged != nil {
			err = errors.Join(err, staged.Close())
		}
		if removeErr := os.Remove(stageName); removeErr != nil && !os.IsNotExist(removeErr) {
			err = errors.Join(err, removeErr)
		}
	}()
	if _, err = staged.Write(data); err != nil {
		return err
	}
	if err = staged.Sync(); err != nil {
		return err
	}
	if err = staged.Close(); err != nil {
		staged = nil
		return err
	}
	staged = nil
	if err = installMissingDocument(stageName, path); os.IsExist(err) {
		return ErrConflict
	}
	return err
}

// WriteGuarded replaces an existing document only when its bytes still match expected.
// The caller retains both its buffer and expected until this operation returns.
func WriteGuarded(path string, data, expected []byte) (err error) {
	lock := writeLock(path)
	lock.Lock()
	defer lock.Unlock()
	source, info, err := openDocument(path)
	if os.IsNotExist(err) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	current, err := io.ReadAll(io.LimitReader(source, maxBytes+1))
	if err != nil {
		return err
	}
	if len(current) > maxBytes || len(data) > maxBytes {
		return ErrTooLarge
	}
	if !bytes.Equal(current, expected) {
		return ErrConflict
	}
	staged, err := os.CreateTemp(filepath.Dir(path), ".lithe-document-*")
	if err != nil {
		return err
	}
	stageName := staged.Name()
	defer func() {
		if staged != nil {
			err = errors.Join(err, staged.Close())
		}
		if removeErr := os.Remove(stageName); removeErr != nil && !os.IsNotExist(removeErr) {
			err = errors.Join(err, removeErr)
		}
	}()
	if err = copyMetadata(source, staged, info); err != nil {
		return err
	}
	if _, err = staged.Write(data); err != nil {
		return err
	}
	if err = staged.Sync(); err != nil {
		return err
	}
	if err = staged.Close(); err != nil {
		staged = nil
		return err
	}
	staged = nil
	latest, latestInfo, err := openDocument(path)
	if os.IsNotExist(err) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	latestBytes, readErr := io.ReadAll(io.LimitReader(latest, maxBytes+1))
	closeErr := latest.Close()
	if err = errors.Join(readErr, closeErr); err != nil {
		return err
	}
	if !os.SameFile(info, latestInfo) || !bytes.Equal(expected, latestBytes) {
		return ErrConflict
	}
	return replaceDocument(stageName, path)
}
