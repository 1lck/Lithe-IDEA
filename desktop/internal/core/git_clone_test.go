package core

import (
	"os"
	"path/filepath"
	"testing"
)

// Integration: exercise the same typed Core command used for a remote clone,
// with a local repository so the test never depends on a network service.
func TestGitCloneUsesCoreAndPreservesExistingDestination(t *testing.T) {
	requireGit(t)
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
	source := newRepository(t)
	writeFile(t, filepath.Join(source, "hello.txt"), "original\n")
	runGit(t, source, "add", "hello.txt")
	runGit(t, source, "commit", "-m", "fixture")
	parent := t.TempDir()
	destination := filepath.Join(parent, "project with spaces")
	client := NewClient()
	if err := client.GitClone(testContext(t), parent, source, destination); err != nil {
		t.Fatalf("clone local repository: %v", err)
	}
	contents, err := os.ReadFile(filepath.Join(destination, "hello.txt"))
	if err != nil || string(contents) != "original\n" {
		t.Fatalf("cloned file = %q, error %v", contents, err)
	}
	writeFile(t, filepath.Join(destination, "keep.txt"), "user data\n")
	if err := client.GitClone(testContext(t), parent, source, destination); err == nil {
		t.Fatal("clone unexpectedly accepted a nonempty destination")
	}
	contents, err = os.ReadFile(filepath.Join(destination, "keep.txt"))
	if err != nil || string(contents) != "user data\n" {
		t.Fatalf("existing file = %q, error %v", contents, err)
	}
}
