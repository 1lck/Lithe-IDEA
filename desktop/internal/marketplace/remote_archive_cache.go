package marketplace

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
)

const (
	remoteCacheBytes   int64 = 2 * MaxArchiveBytes
	remoteCacheEntries       = 32
	remoteCachePending       = ".pending"
)

var errRemoteCacheFile = errors.New("remote archive cache entry is not a regular bounded archive")

// RemoteArchiveCache stores completed, checksum-addressed transfers in the
// platform's user cache. Entries are disposable; users of Read verify the
// opened file against its expected checksum before relying on it.
type RemoteArchiveCache struct {
	directory string
	maxBytes  int64
}

// NewRemoteArchiveCache resolves the runtime cache independently of the bundle,
// plugin directory and checkout.
func NewRemoteArchiveCache() (RemoteArchiveCache, error) {
	root, err := os.UserCacheDir()
	if err != nil {
		return RemoteArchiveCache{}, err
	}
	if !filepath.IsAbs(root) {
		return RemoteArchiveCache{}, ErrArchiveSelection
	}
	return RemoteArchiveCache{filepath.Join(root, "Lithe", "remote-plugin-archives"), remoteCacheBytes}, nil
}

// Read holds the entry in place until consume completes, including on Windows.
// The returned boolean reports whether consume ran. An absent entry is a miss.
func (c RemoteArchiveCache) Read(ctx context.Context, digest string, consume func(string) error) (used bool, err error) {
	name, err := remoteArchiveName(digest)
	if err != nil {
		return false, err
	}
	err = c.locked(ctx, func() error {
		path := filepath.Join(c.directory, name)
		info, err := os.Lstat(path)
		// log-exempt: 预期的缺失：只有已经下载且尚未被清理的包才有缓存。
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() > MaxArchiveBytes {
			return errRemoteCacheFile
		}
		used = true
		if err := consume(path); err != nil {
			return err
		}
		now := time.Now()
		return os.Chtimes(path, now, now)
	})
	return used, err
}

// Store publishes a fully downloaded archive. Files reviewed or read by other
// instances are pinned by the same native lock until the reader releases it.
func (c RemoteArchiveCache) Store(ctx context.Context, digest string, archive *DownloadedArchive) error {
	name, err := remoteArchiveName(digest)
	if err != nil {
		return err
	}
	file, err := os.Open(archive.Path())
	if err != nil {
		return err
	}
	saveErr := c.locked(ctx, func() error {
		info, err := file.Stat()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() > MaxArchiveBytes || info.Size() > c.maxBytes {
			return errRemoteCacheFile
		}
		pending := filepath.Join(c.directory, remoteCachePending)
		if err := removeArchiveEntry(pending); err != nil {
			return err
		}
		if err := c.evict(name, info.Size()); err != nil {
			return err
		}
		return copyCacheEntry(ctx, file, info.Size(), pending, filepath.Join(c.directory, name))
	})
	return errors.Join(saveErr, file.Close())
}

// locked serializes disk inventory and publication across desktop processes.
// A slow reader never holds this lock while downloading.
func (c RemoteArchiveCache) locked(ctx context.Context, action func() error) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.MkdirAll(c.directory, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(c.directory)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errRemoteCacheFile
	}
	lockCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	unlock, err := filelock.Acquire(lockCtx, filepath.Join(c.directory, ".lock"))
	cancel()
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, unlock()) }()
	return action()
}

// evict leaves enough room for staging the replacement, both in bytes and in
// file count. Recency is the last verified use, recorded as the file's mtime.
func (c RemoteArchiveCache) evict(replacing string, size int64) error {
	entries, err := os.ReadDir(c.directory)
	if err != nil {
		return err
	}
	var inventory []fs.FileInfo
	total := size
	for _, entry := range entries {
		name, err := remoteArchiveName(entry.Name())
		if err != nil || name != entry.Name() {
			continue
		}
		info, err := entry.Info()
		// log-exempt: 预期的缺失：系统清理缓存后该文件已无需逐出。
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if name == replacing || !info.Mode().IsRegular() || info.Size() > MaxArchiveBytes {
			if err := removeArchiveEntry(filepath.Join(c.directory, name)); err != nil {
				return err
			}
			continue
		}
		inventory = append(inventory, info)
		total += info.Size()
	}
	slices.SortStableFunc(inventory, func(a, b fs.FileInfo) int { return a.ModTime().Compare(b.ModTime()) })
	for index, info := range inventory {
		if total <= c.maxBytes && len(inventory)-index < remoteCacheEntries {
			break
		}
		if err := removeArchiveEntry(filepath.Join(c.directory, info.Name())); err != nil {
			return err
		}
		total -= info.Size()
	}
	return nil
}

func remoteArchiveName(digest string) (string, error) {
	if len(digest) != 64 {
		return "", ErrArchiveSelection
	}
	if _, err := hex.DecodeString(digest); err != nil {
		return "", ErrArchiveSelection
	}
	return strings.ToLower(digest), nil
}

func removeArchiveEntry(path string) error {
	err := os.Remove(path)
	// log-exempt: 预期的缺失：另一个清理者已移除此缓存条目。
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}

func copyCacheEntry(ctx context.Context, source io.Reader, size int64, pending, destination string) (err error) {
	defer func() {
		if err != nil {
			err = errors.Join(err, removeArchiveEntry(pending))
		}
	}()
	temp, err := os.OpenFile(pending, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	// The temporary file stays within the cache budget even if its source
	// grows after Stat. Check the exact byte count before publication.
	written, err := io.Copy(temp, io.LimitReader(cacheCopyReader{ctx, source}, size))
	if err := errors.Join(err, temp.Close(), ctx.Err()); err != nil {
		return err
	}
	if written != size {
		return io.ErrUnexpectedEOF
	}
	return os.Rename(pending, destination)
}

type cacheCopyReader struct {
	ctx    context.Context
	source io.Reader
}

func (r cacheCopyReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}
