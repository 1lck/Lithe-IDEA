package toolchain

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// LocalDirectory is the workspace directory that owns machine-local choices.
	LocalDirectory = ".lithe/toolchains"
	// LocalDocumentName is the local toolchain document inside LocalDirectory.
	LocalDocumentName = "local.json"
	// LocalIgnorePath is the entry the workspace ignore file must carry because
	// the document stores machine-local installation paths.
	LocalIgnorePath = "/toolchains/local.json"
)

func documentPath(root string) string {
	return filepath.Join(root, filepath.FromSlash(LocalDirectory), LocalDocumentName)
}

// readDocument reads the local document and returns its exact bytes as the
// edit baseline. A missing file is the default document with a nil baseline;
// reading never creates the directory or the file.
func readDocument(root string) (json.RawMessage, []byte, error) {
	data, err := os.ReadFile(documentPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return append(json.RawMessage(nil), DefaultDocument...), nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	if len(bytes.TrimSpace(data)) == 0 || !json.Valid(data) {
		return nil, nil, fmt.Errorf("toolchain: %s is not valid JSON", documentPath(root))
	}
	return append(json.RawMessage(nil), data...), data, nil
}

// SavePin replaces exactly one directory pin and preserves every other entry
// Core accepts, including legacy `toolchains` values and pins for other tools.
//
// Commit order matters: the workspace ignore entry is written first, then the
// local document. If the ignore entry cannot be prepared, the document is not
// touched, so a failure is never reported after the user's config already
// changed. The ignore write is idempotent and harmless if the later document
// write fails. Both writes are atomic, and cancellation is checked after every
// Core validation and before each rename.
func SavePin(ctx context.Context, kernel Kernel, root, directory, tool string, pin *core.ToolchainPin, baseline []byte) (json.RawMessage, []byte, error) {
	return SavePins(ctx, kernel, root, directory, []Edit{{Tool: tool, Pin: pin}}, baseline)
}

// SavePins applies every draft change in one document transaction. The same
// commit order, validation and cancellation rules as one pin apply, so a page
// Save either publishes all changed tools or leaves the document untouched.
func SavePins(ctx context.Context, kernel Kernel, root, directory string, edits []Edit, baseline []byte) (json.RawMessage, []byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if len(edits) == 0 {
		return nil, nil, fmt.Errorf("toolchain: no pin edits were supplied")
	}
	path := documentPath(root)
	current, err := os.ReadFile(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	switch {
	case baseline == nil && exists:
		return nil, nil, ErrPinConflict
	case baseline != nil && (!exists || !bytes.Equal(current, baseline)):
		return nil, nil, ErrPinConflict
	}
	document := DefaultDocument
	if exists {
		document = current
	}
	if !json.Valid(document) {
		return nil, nil, fmt.Errorf("toolchain: %s is not valid JSON", path)
	}
	encoded, err := kernel.EditToolchainPins(ctx, document, directory, edits)
	if err != nil {
		return nil, nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	checkBaseline := func() error {
		current, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			if baseline == nil {
				return nil
			}
			return ErrPinConflict
		}
		if err != nil {
			return err
		}
		if baseline == nil || !bytes.Equal(current, baseline) {
			return ErrPinConflict
		}
		return nil
	}
	if err := checkBaseline(); err != nil {
		return nil, nil, err
	}
	// The ignore entry is a harmless prerequisite: if it fails, the document is
	// still the old one and the caller can retry the same draft.
	if err := ensureLocalIgnore(ctx, root); err != nil {
		return nil, nil, fmt.Errorf("toolchain: could not update the workspace ignore entry; the toolchain document was not changed: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if err := writeProtectedChecked(ctx, path, encoded, checkBaseline); err != nil {
		return nil, nil, fmt.Errorf("toolchain: could not write %s; the toolchain document was not changed: %w", path, err)
	}
	return encoded, encoded, nil
}

// writeProtected writes one machine-local document with its directory owned by
// the user, an explicit mode and an atomic replacement. Cancellation before the
// final rename leaves the existing file untouched; cancellation after the
// rename is a completed write, not a partial one.
func writeProtected(ctx context.Context, path string, data []byte) error {
	return writeProtectedChecked(ctx, path, data, nil)
}

// writeProtectedChecked rechecks the captured source immediately before publication.
func writeProtectedChecked(ctx context.Context, path string, data []byte, check func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	temporary, err := os.CreateTemp(directory, ".local-*.tmp")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if check != nil {
		if err := check(); err != nil {
			return err
		}
	}
	return os.Rename(name, path)
}

// ensureLocalIgnore adds the exact ignore entry without replacing the file's
// other lines or permissions. It runs only after an explicit save, and a
// cancelled save does not create or rewrite the file.
func ensureLocalIgnore(ctx context.Context, root string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path := filepath.Join(root, ".lithe", ".gitignore")
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	text := string(data)
	for _, line := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		if strings.TrimSpace(line) == LocalIgnorePath {
			return nil
		}
	}
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	text += LocalIgnorePath + "\n"
	return writeProtected(ctx, path, []byte(text))
}
