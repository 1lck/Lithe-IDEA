// Package keymapimport imports editor shortcuts directly into the Viva client.
// Source documents are read-only, bounded snapshots in memory, owned by one
// import dialog. Nothing is persisted in the source or installed app bundle.
package keymapimport

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"unicode/utf8"
)

const maxSourceBytes = 1 << 20

var ErrSource = errors.New("shortcut source cannot be read as a bounded UTF-8 file")
var ErrChanged = errors.New("shortcut source changed after preview")
var ErrDocument = errors.New("shortcut document is invalid or exceeds import limits")

// Snapshot retains the selected file's identity and exact bytes for confirmation.
// Open the selected file directly: macOS's file-picker grant does not authorize
// opening its parent directory (which can block on a separate privacy prompt).
type Snapshot struct {
	path, text string
	identity   os.FileInfo
	digest     [32]byte
}

func (s Snapshot) Path() string    { return s.path }
func (s Snapshot) Content() string { return s.text }

func Read(ctx context.Context, path string) (snapshot Snapshot, err error) {
	if err = ctx.Err(); err != nil {
		return snapshot, err
	}
	if !filepath.IsAbs(path) {
		return snapshot, ErrSource
	}
	before, err := os.Lstat(path)
	if err != nil || !before.Mode().IsRegular() || before.Size() > maxSourceBytes {
		return Snapshot{}, ErrSource
	}
	file, err := openSelectedSource(path)
	if err != nil {
		return Snapshot{}, ErrSource
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil && err == nil {
			snapshot, err = Snapshot{}, ErrSource
		}
	}()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(before, opened) {
		return Snapshot{}, ErrChanged
	}
	content, err := io.ReadAll(io.LimitReader(file, maxSourceBytes+1))
	if err != nil || len(content) > maxSourceBytes || !utf8.Valid(content) {
		return Snapshot{}, ErrSource
	}
	after, err := file.Stat()
	if err != nil || opened.Size() != after.Size() || !opened.ModTime().Equal(after.ModTime()) {
		return Snapshot{}, ErrChanged
	}
	if err = ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return Snapshot{path: path, text: string(content), identity: opened, digest: sha256.Sum256(content)}, nil
}
func (s Snapshot) Revalidate(ctx context.Context) error {
	current, err := Read(ctx, s.path)
	if err != nil {
		return ErrChanged
	}
	if !os.SameFile(s.identity, current.identity) || s.digest != current.digest {
		return ErrChanged
	}
	return nil
}
