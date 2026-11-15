// Package gitmetadata reads bounded native Git metadata for Core to interpret.
package gitmetadata

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
)

// MetadataLimit is the input limit of Core's checkout-metadata commands.
const MetadataLimit = 4096

// ErrEncoding means that metadata is not representable by the Core UTF-8 contract.
var ErrEncoding = errors.New("Git metadata is not valid UTF-8")

// Interpreter is implemented by the Core bridge, which owns both Git formats.
type Interpreter interface {
	GitCheckoutBranch(context.Context, string) (string, error)
	GitDirectoryPointer(context.Context, string) (string, error)
}

// ReadBranch performs only bounded native reads. A missing .git or HEAD is an
// ordinary non-repository result, not an error.
func ReadBranch(ctx context.Context, kernel Interpreter, root string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	dotGit := filepath.Join(root, ".git")
	info, err := os.Stat(dotGit)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	gitdir := dotGit
	if !info.IsDir() {
		if !info.Mode().IsRegular() {
			return "", documentio.ErrNotRegular
		}
		text, err := readMetadata(ctx, dotGit)
		if err != nil {
			return "", err
		}
		gitdir, err = kernel.GitDirectoryPointer(ctx, text)
		if err != nil || gitdir == "" {
			return "", err
		}
		if !filepath.IsAbs(gitdir) {
			gitdir = filepath.Join(root, gitdir)
		}
	}
	text, err := readMetadata(ctx, filepath.Join(gitdir, "HEAD"))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return kernel.GitCheckoutBranch(ctx, text)
}

func readMetadata(ctx context.Context, path string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	data, err := documentio.ReadFileLimit(path, MetadataLimit)
	if err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if !utf8.Valid(data) {
		return "", ErrEncoding
	}
	return string(data), nil
}
