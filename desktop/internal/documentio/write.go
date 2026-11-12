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
	// ErrHardLinkChanged means the file the user agreed to save over is no longer the one
	// at the path, or its links changed, between the question and the write.
	ErrHardLinkChanged = errors.New("hard-linked document changed while saving")
	// ErrInPlaceWriteFailed means writing the shared file of a hard link stopped part way;
	// every link may hold partial contents, so the editor keeps its text.
	ErrInPlaceWriteFailed = errors.New("hard-linked document was only partly written")
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

// fileIdentity is what the native open learned of a document: how many directory entries
// name it and an opaque identity of the file object (device and inode, or volume and index).
type fileIdentity struct {
	links uint64
	id    string
}

// HardLinkMode is how one save writes a file that other paths link to.
type HardLinkMode uint8

const (
	// HardLinkReplacePath saves this path as a file of its own; the other links keep the
	// previous contents.
	HardLinkReplacePath HardLinkMode = iota + 1
	// HardLinkUpdateShared writes the shared file in place, so every link sees the new
	// contents. It is not atomic.
	HardLinkUpdateShared
)

// HardLinkConsent is the user's answer for one save of a hard-linked file, bound to the
// file object they were asked about. It is never a lasting preference.
type HardLinkConsent struct {
	Identity string
	Mode     HardLinkMode
}

// HardLinkRequired is the error of a save that reached a hard-linked file without consent.
// It matches ErrHardLink; Identity is what a consent must name.
type HardLinkRequired struct {
	Identity string
}

func (e *HardLinkRequired) Error() string { return ErrHardLink.Error() }

// Is makes errors.Is(err, ErrHardLink) hold.
func (e *HardLinkRequired) Is(target error) bool { return target == ErrHardLink }

// checkLinks refuses a hard-linked file without consent, and a consent given for another
// file object.
func checkLinks(identity fileIdentity, consent *HardLinkConsent) error {
	if consent != nil {
		if identity.id != consent.Identity {
			return ErrHardLinkChanged
		}
		return nil
	}
	if identity.links != 1 {
		return &HardLinkRequired{Identity: identity.id}
	}
	return nil
}

// WriteGuarded replaces an existing document only when its bytes still match expected.
// The caller retains both its buffer and expected until this operation returns. A
// hard-linked document is refused with HardLinkRequired.
func WriteGuarded(path string, data, expected []byte) error {
	return WriteGuardedLinked(path, data, expected, nil)
}

// WriteGuardedLinked is WriteGuarded with the user's answer for a hard-linked document:
// nil refuses one, HardLinkReplacePath saves this path as its own file and
// HardLinkUpdateShared writes the shared file in place.
func WriteGuardedLinked(path string, data, expected []byte, consent *HardLinkConsent) (err error) {
	lock := writeLock(path)
	lock.Lock()
	defer lock.Unlock()
	source, info, identity, err := openDocument(path)
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
	if err = checkLinks(identity, consent); err != nil {
		return err
	}
	if consent != nil && consent.Mode == HardLinkUpdateShared {
		return writeShared(path, source, identity, data, expected)
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
	latest, latestInfo, latestIdentity, err := openDocument(path)
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
	if err = checkLinks(latestIdentity, consent); err != nil {
		return err
	}
	return replaceDocument(stageName, path)
}

// writeShared writes data over the shared file of a hard link through the open source,
// after checking again, under an advisory lock, that it is the agreed file and still holds
// expected. A failure part way is ErrInPlaceWriteFailed: nothing is rolled back over what
// another writer may have done.
func writeShared(path string, source *os.File, identity fileIdentity, data, expected []byte) error {
	unlock, err := lockShared(source)
	if err != nil {
		return err
	}
	defer unlock()
	// The path must still name the agreed file; its bytes are read again through the
	// locked handle, since a whole-file lock on Windows also bars reads by other handles.
	latest, _, latestIdentity, err := openDocument(path)
	if os.IsNotExist(err) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	if err = latest.Close(); err != nil {
		return err
	}
	if latestIdentity.id != identity.id {
		return ErrHardLinkChanged
	}
	if _, err = source.Seek(0, io.SeekStart); err != nil {
		return err
	}
	latestBytes, err := io.ReadAll(io.LimitReader(source, maxBytes+1))
	if err != nil {
		return err
	}
	if !bytes.Equal(expected, latestBytes) {
		return ErrConflict
	}
	if _, err = source.Seek(0, io.SeekStart); err != nil {
		return errors.Join(ErrInPlaceWriteFailed, err)
	}
	if _, err = source.Write(data); err != nil {
		return errors.Join(ErrInPlaceWriteFailed, err)
	}
	if err = source.Truncate(int64(len(data))); err != nil {
		return errors.Join(ErrInPlaceWriteFailed, err)
	}
	if err = source.Sync(); err != nil {
		return errors.Join(ErrInPlaceWriteFailed, err)
	}
	return nil
}
