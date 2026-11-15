package gitmetadata

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
)

// The fake returns known Core answers; it does not interpret Git metadata.
type fixtureInterpreter struct {
	pointerText, pointerPath string
}

func (f fixtureInterpreter) GitDirectoryPointer(_ context.Context, text string) (string, error) {
	if text != f.pointerText {
		return "", errors.New("unexpected pointer bytes")
	}
	return f.pointerPath, nil
}

func (fixtureInterpreter) GitCheckoutBranch(_ context.Context, text string) (string, error) {
	if text != "ref: refs/heads/feature/test\n" {
		return "", errors.New("unexpected HEAD bytes")
	}
	return "feature/test", nil
}

func TestNativeGitMetadataReadsBoundedNormalAndWorktreeFiles(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	fake := fixtureInterpreter{}
	if branch, err := ReadBranch(ctx, fake, root); err != nil || branch != "" {
		t.Fatalf("missing repository = %q, %v", branch, err)
	}
	gitdir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitdir, 0o700); err != nil {
		t.Fatal(err)
	}
	head := filepath.Join(gitdir, "HEAD")
	if err := os.WriteFile(head, []byte("ref: refs/heads/feature/test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if branch, err := ReadBranch(ctx, fake, root); err != nil || branch != "feature/test" {
		t.Fatalf("normal repository = %q, %v", branch, err)
	}
	worktree := t.TempDir()
	relative, err := filepath.Rel(worktree, gitdir)
	if err != nil {
		t.Fatal(err)
	}
	fake.pointerText, fake.pointerPath = "pointer-content", relative
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte(fake.pointerText), 0o600); err != nil {
		t.Fatal(err)
	}
	if branch, err := ReadBranch(ctx, fake, worktree); err != nil || branch != "feature/test" {
		t.Fatalf("relative worktree = %q, %v", branch, err)
	}
	fake.pointerPath = gitdir
	if branch, err := ReadBranch(ctx, fake, worktree); err != nil || branch != "feature/test" {
		t.Fatalf("absolute worktree = %q, %v", branch, err)
	}
	if err := os.WriteFile(head, []byte(strings.Repeat("x", MetadataLimit+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadBranch(ctx, fake, root); !errors.Is(err, documentio.ErrTooLarge) {
		t.Fatalf("oversized HEAD = %v", err)
	}
	if err := os.WriteFile(head, []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadBranch(ctx, fake, root); !errors.Is(err, ErrEncoding) {
		t.Fatalf("invalid encoding = %v", err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := ReadBranch(canceled, fake, root); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled read = %v", err)
	}
}
