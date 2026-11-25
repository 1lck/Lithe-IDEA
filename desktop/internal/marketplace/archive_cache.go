package marketplace

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
)

const (
	// The maximum base size mirrors the Core delta contract. Larger ZIPs still install normally.
	maxDeltaZIPBytes     = 64 << 20
	archiveCacheBudget   = 256 << 20
	archiveCacheEntries  = 128
	archiveCacheLockFile = ".archive-cache.lock"
	archiveCacheLockWait = time.Second
	cacheStagingLifetime = 24 * time.Hour
)

// ArchiveCache holds disposable, content-addressed marketplace ZIPs in the user cache.
// A cache hit still needs Core to verify the base against the approval before patching.
type ArchiveCache struct{ directory string }

// UserArchiveCache resolves the writable platform cache independently of the plugin or app bundle.
func UserArchiveCache() (ArchiveCache, error) {
	root, err := os.UserCacheDir()
	if err != nil {
		return ArchiveCache{}, err
	}
	return ArchiveCache{directory: filepath.Join(root, "Lithe", "PluginArchives")}, nil
}

func (c ArchiveCache) path(digest string) (string, error) {
	if len(digest) != 64 {
		return "", errors.New("invalid plugin archive cache digest")
	}
	if _, err := hex.DecodeString(digest); err != nil {
		return "", fmt.Errorf("invalid plugin archive cache digest: %w", err)
	}
	return filepath.Join(c.directory, digest+".zip"), nil
}

func (c ArchiveCache) base(digest string) (string, error) {
	path, err := c.path(digest)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(path)
	// log-exempt: 预期的缺失：新安装、系统清理及淘汰可能使基线不存在。
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxDeltaZIPBytes {
		return "", errors.New("plugin delta base is not a supported cache file")
	}
	return path, nil
}

func (c ArchiveCache) remember(ctx context.Context, digest string, archive *DownloadedArchive) (err error) {
	target, err := c.path(digest)
	if err != nil {
		return err
	}
	source, err := os.Open(archive.Path())
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	info, err := source.Stat()
	if err != nil {
		return err
	}
	if info.Size() > maxDeltaZIPBytes {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.MkdirAll(c.directory, 0o700); err != nil {
		return err
	}
	return c.publish(ctx, source, info.Size(), target)
}

func (c ArchiveCache) publish(ctx context.Context, source io.Reader, size int64, target string) (err error) {
	// The cache is optional for the current install. Bound the wait, then
	// use the caller's context for the copy once we own the lock.
	acquireCtx, cancel := context.WithTimeout(ctx, archiveCacheLockWait)
	unlock, err := filelock.Acquire(acquireCtx, filepath.Join(c.directory, archiveCacheLockFile))
	cancel()
	if err != nil {
		return fmt.Errorf("lock plugin archive cache: %w", err)
	}
	defer func() { err = errors.Join(err, unlock()) }()

	if err := c.prune(size, filepath.Base(target)); err != nil {
		return err
	}
	temp, err := os.CreateTemp(c.directory, ".incoming-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer func() {
		removeErr := os.Remove(name)
		// log-exempt: 预期的缺失：原子发布已经将临时文件移动到目标文件名。
		if removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
			err = errors.Join(err, removeErr)
		}
	}()
	written, err := io.Copy(temp, io.LimitReader(cacheReader{ctx, source}, size+1))
	if err == nil && written != size {
		err = errors.New("plugin archive cache input changed while copying")
	}
	if err = errors.Join(err, temp.Close()); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return os.Rename(name, target)
}

type cacheReader struct {
	context.Context
	io.Reader
}

func (r cacheReader) Read(buffer []byte) (int, error) {
	if err := r.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(buffer)
}

type cachedArchive struct {
	name     string
	size     int64
	modified time.Time
}

func (c ArchiveCache) prune(incoming int64, target string) error {
	entries, err := os.ReadDir(c.directory)
	if err != nil {
		return err
	}
	var archives []cachedArchive
	staleBefore := time.Now().Add(-cacheStagingLifetime)
	for _, entry := range entries {
		name := entry.Name()
		incomingTemp := strings.HasPrefix(name, ".incoming-")
		if name == target || entry.Type() != 0 || (!incomingTemp && filepath.Ext(name) != ".zip") {
			continue
		}
		info, err := entry.Info()
		// log-exempt: 预期的缺失：系统可能已清理此缓存文件。
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if incomingTemp {
			// log-exempt: 预期的缺失：系统可能已清理此临时文件。
			if info.ModTime().Before(staleBefore) {
				if err := os.Remove(filepath.Join(c.directory, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
					return err
				}
			}
			continue
		}
		incoming += info.Size()
		archives = append(archives, cachedArchive{name, info.Size(), info.ModTime()})
	}
	sort.Slice(archives, func(i, j int) bool {
		if archives[i].modified.Equal(archives[j].modified) {
			return archives[i].name < archives[j].name
		}
		return archives[i].modified.Before(archives[j].modified)
	})
	for i, archive := range archives {
		if incoming <= archiveCacheBudget && len(archives)-i < archiveCacheEntries {
			break
		}
		// log-exempt: 预期的缺失：系统可能已清理此缓存文件。
		if err := os.Remove(filepath.Join(c.directory, archive.name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		incoming -= archive.size
	}
	return nil
}
