package remoteplaceholder

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Ensure creates an empty read-only anchor, keeps it on the next call, and a placeholder below it
// can be neither listed, created nor written by the local file system.
func TestPlaceholdersCannotBeUsedLocally(t *testing.T) {
	anchor := filepath.Join(t.TempDir(), "cache", AnchorName)
	if err := Ensure(anchor); err != nil {
		t.Fatalf("create the anchor: %v", err)
	}
	info, err := os.Lstat(anchor)
	if err != nil || !info.Mode().IsRegular() || info.Size() != 0 {
		t.Fatalf("anchor = %v, %v, want an empty regular file", info, err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o222 != 0 {
		t.Fatalf("anchor mode = %v, want read-only", info.Mode().Perm())
	}
	if err := Ensure(anchor); err != nil {
		t.Fatalf("an existing anchor: %v", err)
	}

	root := Root(anchor, "connection-1", "/home/dev/repo")
	if _, err := os.ReadDir(root); err == nil {
		t.Fatal("listed a placeholder")
	}
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err == nil {
		t.Fatal("created a folder below a placeholder")
	}
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main"), 0o644); err == nil {
		t.Fatal("wrote a file below a placeholder")
	}
	host := root + ".lithe-remote-host"
	if err := os.MkdirAll(host, 0o755); err == nil {
		t.Fatal("created the host-path sibling of a placeholder")
	}
	if entries, err := os.ReadDir(filepath.Dir(anchor)); err != nil || len(entries) != 1 {
		t.Fatalf("cache directory has %d entries, %v; want only the anchor", len(entries), err)
	}
}

// Anything but a regular file at the anchor's path is refused and left there.
func TestEnsureRefusesAnAnchorThatIsNoRegularFile(t *testing.T) {
	directory := filepath.Join(t.TempDir(), AnchorName)
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := Ensure(directory); !errors.Is(err, ErrAnchorUnusable) {
		t.Fatalf("a directory = %v, want ErrAnchorUnusable", err)
	}
	if info, err := os.Lstat(directory); err != nil || !info.IsDir() {
		t.Fatal("the directory was not left as it was")
	}

	if runtime.GOOS == "windows" {
		// Creating a link needs a privilege the Windows runner may not grant.
		return
	}
	link := filepath.Join(t.TempDir(), AnchorName)
	if err := os.Symlink(directory, link); err != nil {
		t.Fatal(err)
	}
	if err := Ensure(link); !errors.Is(err, ErrAnchorUnusable) {
		t.Fatalf("a link to a directory = %v, want ErrAnchorUnusable", err)
	}
}

// A root is the same for the same folder over the same connection, different otherwise, and its
// name is the folder's name in a form every local file system accepts.
func TestRootNamesTheFolderAndTellsWorkspacesApart(t *testing.T) {
	anchor := filepath.Join(string(filepath.Separator)+"cache", AnchorName)
	root := Root(anchor, "c1", "/srv/repo")
	if root != Root(anchor, "c1", "/srv/repo") {
		t.Fatal("the same workspace has two roots")
	}
	if filepath.Dir(filepath.Dir(root)) != anchor || filepath.Base(root) != "repo" {
		t.Fatalf("root = %s, want anchor/<key>/repo", root)
	}
	for _, other := range []string{Root(anchor, "c2", "/srv/repo"), Root(anchor, "c1", "/opt/repo")} {
		if other == root {
			t.Fatalf("two workspaces share the root %s", root)
		}
	}
	for remote, want := range map[string]string{
		"/":                               "root",
		"/home/dev/":                      "dev",
		"/home/项目":                        "项目",
		"/srv/a:b|c":                      "a_b_c",
		"/srv/name.":                      "name",
		"/srv/...":                        "folder",
		"/srv/con":                        "_con",
		"/srv/COM1.txt":                   "_COM1.txt",
		"/srv/" + strings.Repeat("x", 80): strings.Repeat("x", maxNameRunes),
	} {
		if got := filepath.Base(Root(anchor, "c1", remote)); got != want {
			t.Errorf("name of %q = %q, want %q", remote, got, want)
		}
	}
}
