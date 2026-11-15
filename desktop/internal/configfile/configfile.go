// Package configfile captures and publishes bounded native configuration files.
// It never interprets their document schema. Roots come from platform storage or
// the user-selected workspace; relative names and read budgets come from Core.
package configfile

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"unicode/utf8"
)

var (
	ErrConflict = errors.New("configuration source changed after it was read")
	ErrTarget   = errors.New("configuration target is not a regular file within its native root")
	ErrTooLarge = errors.New("configuration exceeds its native read budget")
	ErrEncoding = errors.New("configuration source is not UTF-8")
)

// Serialize complete publications, not just rename. The channel permits a
// waiting owner to cancel without creating another goroutine or a lock table.
var publication = make(chan struct{}, 1)

// Snapshot keeps captured bytes private so a UI draft cannot mutate its baseline.
// No native handle survives Capture; each operation owns and closes its handles.
type Snapshot struct {
	root     string
	name     string
	maximum  int64
	rootInfo os.FileInfo
	content  []byte
	exists   bool
}

// Path is a display-only source path. I/O always uses os.Root-relative methods.
func (s Snapshot) Path() string  { return filepath.Join(s.root, s.name) }
func (s Snapshot) Exists() bool  { return s.exists }
func (s Snapshot) Bytes() []byte { return append([]byte(nil), s.content...) }

// Text rejects undecodable bytes before JSON string transport can replace them.
// A nil string means a missing file; an empty existing file remains explicit.
func (s Snapshot) Text() (*string, error) {
	if !s.exists {
		return nil, nil
	}
	if !utf8.Valid(s.content) {
		return nil, ErrEncoding
	}
	text := string(s.content)
	return &text, nil
}

// Capture is read-only, including when the native preference directory is absent.
func Capture(ctx context.Context, rootDirectory, relativeName string, maximumBytes int64) (snapshot Snapshot, err error) {
	if err := ctx.Err(); err != nil {
		return snapshot, err
	}
	if !filepath.IsAbs(rootDirectory) || !filepath.IsLocal(relativeName) || relativeName == "." || maximumBytes <= 0 {
		return snapshot, ErrTarget
	}
	snapshot = Snapshot{root: rootDirectory, name: filepath.FromSlash(relativeName), maximum: maximumBytes}
	root, err := os.OpenRoot(rootDirectory)
	// log-exempt: 预期的缺失：首次保存前应用偏好目录可以不存在，读取不得创建它。
	if errors.Is(err, os.ErrNotExist) {
		return snapshot, nil
	}
	if err != nil {
		return snapshot, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	snapshot.rootInfo, err = root.Stat(".")
	if err != nil {
		return snapshot, err
	}
	snapshot.content, snapshot.exists, err = read(ctx, root, snapshot.name, maximumBytes, false)
	return snapshot, err
}

func read(ctx context.Context, root *os.Root, name string, maximum int64, writable bool) (data []byte, exists bool, err error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	info, err := root.Lstat(name)
	// log-exempt: 预期的缺失：缺失的配置文件是未覆盖的空来源。
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !info.Mode().IsRegular() {
		return nil, false, ErrTarget
	}
	file, err := openSource(root, name, writable)
	if err != nil {
		return nil, false, err
	}
	defer func() { err = errors.Join(err, file.Close()) }()
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if !os.SameFile(info, openedInfo) {
		return nil, false, ErrConflict
	}
	info = openedInfo
	if !info.Mode().IsRegular() {
		return nil, false, ErrTarget
	}
	if info.Size() > maximum {
		return nil, true, ErrTooLarge
	}
	data, err = io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, true, err
	}
	if int64(len(data)) > maximum {
		return nil, true, ErrTooLarge
	}
	if err := ctx.Err(); err != nil {
		return nil, true, err
	}
	return data, true, nil
}

func (s Snapshot) check(ctx context.Context, root *os.Root) error {
	data, exists, err := read(ctx, root, s.name, s.maximum, false)
	if errors.Is(err, ErrTooLarge) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	if exists != s.exists || !bytes.Equal(data, s.content) {
		return ErrConflict
	}
	return nil
}

// Verify rechecks a captured native root and exact bytes without creating state.
func (s Snapshot) Verify(ctx context.Context) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.root == "" || s.maximum <= 0 {
		return ErrTarget
	}
	if s.rootInfo == nil {
		info, statErr := os.Lstat(s.root)
		if errors.Is(statErr, os.ErrNotExist) {
			return nil
		}
		if statErr != nil {
			return statErr
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return ErrConflict
		}
	}
	root, err := os.OpenRoot(s.root)
	if errors.Is(err, os.ErrNotExist) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	current, err := root.Stat(".")
	if err != nil {
		return err
	}
	if s.rootInfo != nil && !os.SameFile(s.rootInfo, current) {
		return ErrConflict
	}
	return s.check(ctx, root)
}

// Replace publishes complete content. committed remains true if a subsequent
// handle/temporary cleanup fails: callers must reread, not retry the old draft.
// check is an optional additional native source/cancellation check at publication.
func (s Snapshot) Replace(ctx context.Context, content []byte, check func() error) (committed bool, err error) {
	return s.publish(ctx, content, false, check)
}

// Remove deletes only the captured owned file after checking its byte baseline.
func (s Snapshot) Remove(ctx context.Context, check func() error) (committed bool, err error) {
	return s.publish(ctx, nil, true, check)
}

func (s Snapshot) publish(ctx context.Context, content []byte, remove bool, check func() error) (committed bool, err error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if s.root == "" || s.maximum <= 0 {
		return false, ErrTarget
	}
	if !remove && int64(len(content)) > s.maximum {
		return false, ErrTooLarge
	}
	select {
	case publication <- struct{}{}:
		defer func() { <-publication }()
	case <-ctx.Done():
		return false, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if s.rootInfo == nil {
		// A previously absent preference root must not become a new alias.
		if info, err := os.Lstat(s.root); err == nil && info.Mode()&os.ModeSymlink != 0 {
			return false, ErrConflict
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
	}
	root, err := os.OpenRoot(s.root)
	if errors.Is(err, os.ErrNotExist) {
		if s.rootInfo != nil {
			return false, ErrConflict
		}
		if remove {
			return false, nil
		}
		if check != nil {
			if err := check(); err != nil {
				return false, err
			}
		}
		if err := os.MkdirAll(s.root, 0o700); err != nil {
			return false, err
		}
		root, err = os.OpenRoot(s.root)
	}
	if err != nil {
		return false, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	currentRoot, err := root.Stat(".")
	if err != nil {
		return false, err
	}
	if s.rootInfo != nil && !os.SameFile(s.rootInfo, currentRoot) {
		return false, ErrConflict
	}
	if err := s.check(ctx, root); err != nil {
		return false, err
	}
	if check != nil {
		if err := check(); err != nil {
			return false, err
		}
	}
	if remove && !s.exists {
		return false, nil
	}
	if !remove && s.exists && bytes.Equal(content, s.content) {
		return false, nil
	}

	// Prove native write access, and retain the original metadata by handle.
	var source *os.File
	if s.exists {
		source, err = openSource(root, s.name, true)
		if err != nil {
			return false, err
		}
		defer func() {
			if source != nil {
				err = errors.Join(err, source.Close())
			}
		}()
	}
	if remove {
		if source != nil {
			if err := source.Close(); err != nil {
				return false, err
			}
			source = nil
		}
		if err := s.check(ctx, root); err != nil {
			return false, err
		}
		if check != nil {
			if err := check(); err != nil {
				return false, err
			}
		}
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if err := root.Remove(s.name); err != nil {
			return false, err
		}
		return true, nil
	}
	parent := filepath.Dir(s.name)
	if err := root.MkdirAll(parent, 0o700); err != nil {
		return false, err
	}
	var temporary *os.File
	var temporaryName string
	for attempt := 0; attempt < 8; attempt++ {
		temporaryName = filepath.Join(parent, ".lithe-config-"+rand.Text()+".tmp")
		temporary, err = root.OpenFile(temporaryName, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
		if !errors.Is(err, os.ErrExist) {
			break
		}
	}
	if err != nil {
		return false, err
	}
	defer func() {
		if temporary != nil {
			err = errors.Join(err, temporary.Close())
		}
		// log-exempt: 预期的缺失：成功改名已移走本次独占临时文件。
		if cleanup := root.Remove(temporaryName); cleanup != nil && !errors.Is(cleanup, os.ErrNotExist) {
			err = errors.Join(err, cleanup)
		}
	}()
	if _, err := temporary.Write(content); err != nil {
		return false, err
	}
	if source != nil {
		if err := copyNativeMetadata(source, temporary); err != nil {
			return false, err
		}
		if err := source.Close(); err != nil {
			return false, err
		}
		source = nil
	}
	if err := temporary.Sync(); err != nil {
		return false, err
	}
	if err := temporary.Close(); err != nil {
		return false, err
	}
	temporary = nil
	if err := s.check(ctx, root); err != nil {
		return false, err
	}
	if check != nil {
		if err := check(); err != nil {
			return false, err
		}
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := root.Rename(temporaryName, s.name); err != nil {
		return false, err
	}
	return true, nil
}
