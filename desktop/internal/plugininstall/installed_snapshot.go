package plugininstall

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// ErrInstalledSeal indicates that a mutable installation cannot be reproduced as approved.
var ErrInstalledSeal = errors.New("installed plugin files differ from the approved package")

func newTreeSeal() hash.Hash {
	seal := sha256.New()
	seal.Write([]byte("lithe-installed-plugin-tree-v1\x00"))
	return seal
}

func addTreeFile(seal hash.Hash, file pluginpkg.File) {
	seal.Write([]byte(file.Path))
	seal.Write([]byte{0, byte(file.Mode.Perm() & 0o100)})
	seal.Write(binary.BigEndian.AppendUint64(nil, uint64(file.Size)))
}

// digestExtractedTree retains the previous content digest for approval reuse
// and seals the file sizes and executable permissions in the same read pass.
func digestExtractedTree(ctx context.Context, directory string, files []pluginpkg.File) (string, string, error) {
	legacy := sha256.New()
	seal := newTreeSeal()
	for _, entry := range files {
		legacy.Write([]byte(entry.Path))
		legacy.Write([]byte{0})
		addTreeFile(seal, entry)
		file, err := os.Open(filepath.Join(directory, filepath.FromSlash(entry.Path)))
		if err != nil {
			return "", "", err
		}
		err = copySealedFile(ctx, io.MultiWriter(legacy, seal), file, entry.Size)
		if err := errors.Join(err, file.Close()); err != nil {
			return "", "", err
		}
		legacy.Write([]byte{0})
	}
	return hex.EncodeToString(legacy.Sum(nil)), hex.EncodeToString(seal.Sum(nil)), nil
}

// SnapshotInstalledVariant copies a same-platform installation into a private
// directory. The seal is computed over the bytes written there, and the staged
// manifest is reviewed before any of those bytes can reach the workspace host.
func SnapshotInstalledVariant(ctx context.Context, installed, want string, review core.MarketplaceVariantReview, verify func(context.Context, core.MarketplaceVariantReview) (json.RawMessage, error)) (result RemoteVariant, err error) {
	var staging string
	defer func() {
		if err != nil && staging != "" {
			result = RemoteVariant{}
			err = errors.Join(err, os.RemoveAll(staging))
		}
	}()
	root, err := os.OpenRoot(installed)
	if err != nil {
		return RemoteVariant{}, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	files, err := inventoryInstalledFiles(ctx, root)
	if err != nil {
		return RemoteVariant{}, err
	}
	staging, err = os.MkdirTemp("", "lithe-remote-installed-")
	if err != nil {
		return RemoteVariant{}, err
	}
	seal := newTreeSeal()
	inventory := make([]pluginpkg.File, 0, len(files))
	for _, file := range files {
		entry := pluginpkg.File{Path: file.path, Size: file.info.Size(), Mode: file.info.Mode()}
		addTreeFile(seal, entry)
		if err := writeSnapshotFile(ctx, root, staging, file, seal); err != nil {
			return RemoteVariant{}, err
		}
		inventory = append(inventory, entry)
	}
	if want != hex.EncodeToString(seal.Sum(nil)) {
		return RemoteVariant{}, ErrInstalledSeal
	}
	review.VariantManifest, err = readManifest(staging)
	if err != nil {
		return RemoteVariant{}, err
	}
	manifest, err := verify(ctx, review)
	if err != nil {
		return RemoteVariant{}, err
	}
	return RemoteVariant{Directory: staging, Manifest: manifest, Files: inventory}, nil
}

type installedFile struct {
	path string
	info fs.FileInfo
}

func inventoryInstalledFiles(ctx context.Context, root *os.Root) ([]installedFile, error) {
	var files []installedFile
	var total int64
	var entries int
	err := fs.WalkDir(root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path == "." {
			return nil
		}
		entries++
		if entries > pluginpkg.MaxEntries {
			return pluginpkg.ErrTooManyEntries
		}
		if _, err := pluginpkg.ValidatePath(path); err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return pluginpkg.ErrNotPackageFile
		}
		if info.Size() > pluginpkg.MaxFileBytes {
			return pluginpkg.ErrFileTooLarge
		}
		total += info.Size()
		if total > pluginpkg.MaxExtractedBytes {
			return pluginpkg.ErrArchiveTooLarge
		}
		files = append(files, installedFile{path, info})
		return nil
	})
	slices.SortFunc(files, func(a, b installedFile) int { return strings.Compare(a.path, b.path) })
	return files, err
}

func writeSnapshotFile(ctx context.Context, root *os.Root, staging string, file installedFile, seal hash.Hash) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	source, err := root.OpenFile(file.path, snapshotReadFlags, 0)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	opened, err := source.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(file.info, opened) || !opened.Mode().IsRegular() ||
		file.info.Size() != opened.Size() || file.info.Mode()&0o100 != opened.Mode()&0o100 {
		return ErrInstalledSeal
	}
	path := filepath.Join(staging, filepath.FromSlash(file.path))
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	target, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	writeErr := copySealedFile(ctx, io.MultiWriter(target, seal), source, opened.Size())
	return errors.Join(writeErr, target.Close())
}

func copySealedFile(ctx context.Context, target io.Writer, source *os.File, size int64) error {
	read, err := io.Copy(target, io.LimitReader(sealReader{ctx, source}, size+1))
	if err != nil {
		return err
	}
	if read != size {
		return ErrInstalledSeal
	}
	return ctx.Err()
}

type sealReader struct {
	ctx    context.Context
	source *os.File
}

func (r sealReader) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(buffer)
}
