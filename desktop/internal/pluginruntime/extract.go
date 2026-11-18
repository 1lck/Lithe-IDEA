package pluginruntime

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

const (
	// Native extraction budgets complement the downloader's compressed-byte
	// bound. Neither ZIP metadata nor a small gzip stream can allocate freely.
	maxEntries       = 50000
	maxExpandedBytes = int64(4 << 30)
)

type archiveLink struct {
	name, target string
	hard         bool
}

type extraction struct {
	ctx     context.Context
	root    *os.Root
	prefix  string
	paths   map[string]string
	links   []archiveLink
	total   int64
	entries int
}

func extract(ctx context.Context, file *os.File, directory string, artifact Artifact) (_ []inventoryEntry, err error) {
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	x := extraction{ctx: ctx, root: root, prefix: artifact.StripPrefix, paths: make(map[string]string)}
	switch artifact.Archive {
	case "zip":
		info, err := file.Stat()
		if err != nil {
			return nil, err
		}
		if err := checkZIPDirectory(ctx, file, info.Size()); err != nil {
			return nil, err
		}
		reader, err := zip.NewReader(contextReaderAt{ctx, file}, info.Size())
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrArchive, err)
		}
		if len(reader.File) > maxEntries {
			return nil, ErrArchive
		}
		for _, entry := range reader.File {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if entry.UncompressedSize64 > uint64(maxExpandedBytes) {
				return nil, ErrArchive
			}
			content, err := entry.Open()
			if err != nil {
				return nil, err
			}
			mode := entry.Mode()
			err = x.entry(entry.Name, mode, int64(entry.UncompressedSize64), content, "", false)
			err = errors.Join(err, content.Close())
			if err != nil {
				return nil, err
			}
		}
	case "tar.gz":
		reader, err := gzip.NewReader(contextReader{ctx, file})
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrArchive, err)
		}
		defer func() { err = errors.Join(err, reader.Close()) }()
		archive := tar.NewReader(reader)
		for {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			header, err := archive.Next()
			if errors.Is(err, io.EOF) {
				// Finish gzip validation, including its checksum and trailer. Bound
				// ignored tar padding so trailing compression cannot evade limits.
				remaining := maxExpandedBytes - x.total
				n, tailErr := io.Copy(io.Discard, io.LimitReader(contextReader{ctx, reader}, remaining+1))
				if tailErr != nil || n > remaining {
					return nil, errors.Join(ErrArchive, tailErr)
				}
				break
			}
			if err != nil {
				return nil, fmt.Errorf("%w: %w", ErrArchive, err)
			}
			mode := header.FileInfo().Mode()
			if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA && header.Typeflag != tar.TypeDir && header.Typeflag != tar.TypeSymlink && header.Typeflag != tar.TypeLink {
				return nil, fmt.Errorf("%w: unsupported entry type", ErrArchive)
			}
			if err := x.entry(header.Name, mode, header.Size, archive, header.Linkname, header.Typeflag == tar.TypeLink); err != nil {
				return nil, err
			}
		}
	default:
		return nil, ErrArtifact
	}
	// Link creation is deferred until every ordinary file exists. No archive
	// entry can write through a link laid down by an earlier entry.
	for _, link := range x.links {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if link.hard {
			info, err := root.Lstat(link.target)
			if err != nil || !info.Mode().IsRegular() {
				return nil, fmt.Errorf("%w: hard link target", ErrArchive)
			}
			if err := root.Link(link.target, link.name); err != nil {
				return nil, err
			}
		} else if err := root.Symlink(link.target, link.name); err != nil {
			return nil, err
		}
	}
	return captureInventory(ctx, root)
}

func (x *extraction) entry(raw string, mode fs.FileMode, size int64, source io.Reader, target string, hard bool) error {
	x.entries++
	if x.entries > maxEntries || size < 0 || size > maxExpandedBytes-x.total {
		return ErrArchive
	}
	x.total += size
	name, err := x.name(raw, mode.IsDir())
	if err != nil || name == "" {
		return err
	}
	kind := "file"
	if mode.IsDir() {
		kind = "directory"
	} else if mode&fs.ModeSymlink != 0 || hard {
		kind = "link"
	} else if !mode.IsRegular() {
		return fmt.Errorf("%w: special file", ErrArchive)
	}
	if err := x.reserve(name, kind); err != nil {
		return err
	}
	if err := x.root.MkdirAll(filepath.FromSlash(path.Dir(name)), 0o700); err != nil {
		return err
	}
	if kind == "directory" {
		return x.root.MkdirAll(filepath.FromSlash(name), mode.Perm()|0o700)
	}
	if kind == "link" {
		if target == "" {
			bytes, err := io.ReadAll(io.LimitReader(contextReader{x.ctx, source}, int64(pluginpkg.MaxPathLength)+1))
			if err != nil || len(bytes) > pluginpkg.MaxPathLength {
				return errors.Join(ErrArchive, err)
			}
			target = string(bytes)
		}
		if hard {
			target, err = x.name(target, false)
		} else {
			// Relative parent segments are necessary for real runtime archives.
			// Resolve lexically first, then os.Root checks the complete link chain
			// during inventory capture, rejecting escapes and dangling cycles.
			if path.IsAbs(target) || strings.ContainsAny(target, "\\\x00:") {
				return ErrArchive
			}
			_, err = pluginpkg.ValidatePath(path.Clean(path.Join(path.Dir(name), target)))
		}
		if err != nil || target == "" {
			return errors.Join(ErrArchive, err)
		}
		x.links = append(x.links, archiveLink{filepath.FromSlash(name), filepath.FromSlash(target), hard})
		return nil
	}
	file, err := x.root.OpenFile(filepath.FromSlash(name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode.Perm()|0o600)
	if err != nil {
		return err
	}
	written, writeErr := io.Copy(file, io.LimitReader(contextReader{x.ctx, source}, size+1))
	closeErr := file.Close()
	if written != size {
		return errors.Join(ErrArchive, writeErr, closeErr)
	}
	return errors.Join(writeErr, closeErr)
}

func (x *extraction) name(raw string, directory bool) (string, error) {
	// GNU tar commonly prefixes the archive root with "./". Only that prefix
	// is normalized; internal dot or parent segments are refused by ValidatePath.
	for strings.HasPrefix(raw, "./") {
		raw = strings.TrimPrefix(raw, "./")
	}
	if directory {
		raw = strings.TrimSuffix(raw, "/")
		if raw == "" || raw == "." {
			return "", nil
		}
	}
	if _, err := pluginpkg.ValidatePath(raw); err != nil {
		return "", fmt.Errorf("%w: %w", ErrArchive, err)
	}
	if x.prefix != "" {
		if raw == x.prefix && directory {
			return "", nil
		}
		if !strings.HasPrefix(raw, x.prefix+"/") {
			return "", fmt.Errorf("%w: entry outside strip prefix", ErrArchive)
		}
		raw = strings.TrimPrefix(raw, x.prefix+"/")
	}
	return raw, nil
}

func (x *extraction) reserve(name, kind string) error {
	key := strings.ToLower(name)
	if previous := x.paths[key]; previous != "" && (kind != "directory" || previous != "directory") {
		return fmt.Errorf("%w: duplicate or conflicting entry", ErrArchive)
	}
	x.paths[key] = kind
	for parent := path.Dir(key); parent != "."; parent = path.Dir(parent) {
		if previous := x.paths[parent]; previous != "" && previous != "directory" {
			return fmt.Errorf("%w: entry nested under a file or link", ErrArchive)
		}
		x.paths[parent] = "directory"
	}
	if len(x.paths) > maxEntries {
		return ErrArchive
	}
	return nil
}

func captureInventory(ctx context.Context, root *os.Root) ([]inventoryEntry, error) {
	var entries []inventoryEntry
	err := fs.WalkDir(root.FS(), ".", func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if name == "." {
			return nil
		}
		if len(entries) >= maxEntries {
			return ErrArchive
		}
		entry, err := inspectEntry(ctx, root, name, true)
		if err == nil {
			entries = append(entries, entry)
		}
		return err
	})
	return entries, err
}

func inspectEntry(ctx context.Context, root *os.Root, name string, contents bool) (entry inventoryEntry, err error) {
	entry.Path = name
	info, err := root.Lstat(filepath.FromSlash(name))
	if err != nil {
		return entry, err
	}
	entry.Mode = uint32(info.Mode().Perm())
	switch {
	case info.IsDir():
		entry.Kind = "directory"
	case info.Mode()&os.ModeSymlink != 0:
		entry.Kind = "link"
		entry.Link, err = root.Readlink(filepath.FromSlash(name))
		if err == nil {
			_, err = root.Stat(filepath.FromSlash(name))
		}
	case info.Mode().IsRegular():
		entry.Kind, entry.Size, entry.Modified = "file", info.Size(), info.ModTime().UnixNano()
		if contents {
			file, openErr := root.Open(filepath.FromSlash(name))
			if openErr != nil {
				return entry, openErr
			}
			hash := sha256.New()
			_, readErr := io.Copy(hash, contextReader{ctx, io.LimitReader(file, maxExpandedBytes+1)})
			err = errors.Join(readErr, file.Close())
			entry.SHA256 = hex.EncodeToString(hash.Sum(nil))
		}
	default:
		err = ErrArchive
	}
	return entry, err
}

func verifyInventory(ctx context.Context, directory string, entries []inventoryEntry, contents bool) (err error) {
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%w: generation directory", ErrCorrupt)
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	expected := make(map[string]inventoryEntry, len(entries))
	for _, entry := range entries {
		if _, err := pluginpkg.ValidatePath(entry.Path); err != nil {
			return ErrCorrupt
		}
		if _, exists := expected[entry.Path]; exists {
			return ErrCorrupt
		}
		expected[entry.Path] = entry
	}
	seen := 0
	err = fs.WalkDir(root.FS(), ".", func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if name == "." {
			return nil
		}
		want, ok := expected[name]
		if !ok {
			return ErrCorrupt
		}
		got, err := inspectEntry(ctx, root, name, false)
		if err != nil {
			return err
		}
		if got.Kind != want.Kind || got.Size != want.Size || got.Mode != want.Mode || got.Link != want.Link {
			return ErrCorrupt
		}
		if got.Kind == "file" && (contents || got.Modified != want.Modified) {
			got, err = inspectEntry(ctx, root, name, true)
			if err != nil {
				return err
			}
			if got.SHA256 != want.SHA256 {
				return ErrCorrupt
			}
		}
		seen++
		return nil
	})
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %w", ErrCorrupt, err)
	}
	if seen != len(expected) {
		return ErrCorrupt
	}
	return nil
}

// checkZIPDirectory checks the entry count before archive/zip allocates its
// central directory objects. ZIP64 is supported, but cannot raise the I/O bound.
func checkZIPDirectory(ctx context.Context, source io.ReaderAt, size int64) error {
	if size < 22 {
		return ErrArchive
	}
	length := min(size, 22+65535)
	buffer := make([]byte, int(length))
	reader := contextReaderAt{ctx, source}
	if _, err := reader.ReadAt(buffer, size-length); err != nil {
		return err
	}
	for i := len(buffer) - 22; i >= 0; i-- {
		if binary.LittleEndian.Uint32(buffer[i:]) != 0x06054b50 || i+22+int(binary.LittleEndian.Uint16(buffer[i+20:])) != len(buffer) {
			continue
		}
		if binary.LittleEndian.Uint16(buffer[i+4:]) != 0 || binary.LittleEndian.Uint16(buffer[i+6:]) != 0 {
			return ErrArchive
		}
		count := uint64(binary.LittleEndian.Uint16(buffer[i+10:]))
		centralSize := uint64(binary.LittleEndian.Uint32(buffer[i+12:]))
		centralOffset := uint64(binary.LittleEndian.Uint32(buffer[i+16:]))
		if count == 0xffff || centralSize == 0xffffffff || centralOffset == 0xffffffff {
			position := size - length + int64(i)
			if position < 20 {
				return ErrArchive
			}
			var locator [20]byte
			if _, err := reader.ReadAt(locator[:], position-20); err != nil {
				return err
			}
			if binary.LittleEndian.Uint32(locator[:]) != 0x07064b50 || binary.LittleEndian.Uint32(locator[4:]) != 0 || binary.LittleEndian.Uint32(locator[16:]) != 1 {
				return ErrArchive
			}
			offset := binary.LittleEndian.Uint64(locator[8:])
			if offset > uint64(size-56) {
				return ErrArchive
			}
			var end [56]byte
			if _, err := reader.ReadAt(end[:], int64(offset)); err != nil {
				return err
			}
			if binary.LittleEndian.Uint32(end[:]) != 0x06064b50 {
				return ErrArchive
			}
			count = binary.LittleEndian.Uint64(end[32:])
			centralSize = binary.LittleEndian.Uint64(end[40:])
			centralOffset = binary.LittleEndian.Uint64(end[48:])
		}
		if count == 0 || count > maxEntries || centralSize > inventoryLimit || centralOffset > uint64(size) || centralSize > uint64(size)-centralOffset {
			return ErrArchive
		}
		// Do not trust the count alone: a forged small count can accompany a
		// large actual directory. Walk fixed headers before zip.NewReader is
		// allowed to allocate one object per entry.
		var consumed, actual uint64
		for consumed < centralSize {
			var header [46]byte
			if centralSize-consumed < uint64(len(header)) {
				return ErrArchive
			}
			if _, err := reader.ReadAt(header[:], int64(centralOffset+consumed)); err != nil {
				return err
			}
			if binary.LittleEndian.Uint32(header[:]) != 0x02014b50 {
				return ErrArchive
			}
			length := uint64(len(header)) + uint64(binary.LittleEndian.Uint16(header[28:])) + uint64(binary.LittleEndian.Uint16(header[30:])) + uint64(binary.LittleEndian.Uint16(header[32:]))
			if length > centralSize-consumed {
				return ErrArchive
			}
			consumed += length
			actual++
			if actual > maxEntries {
				return ErrArchive
			}
		}
		if actual != count {
			return ErrArchive
		}
		return nil
	}
	return ErrArchive
}

type contextReaderAt struct {
	ctx    context.Context
	source io.ReaderAt
}

func (r contextReaderAt) ReadAt(p []byte, offset int64) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.ReadAt(p, offset)
}
