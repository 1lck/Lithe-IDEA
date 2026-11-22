// Package installedpackagetest runs a workflow under test from a client installed the way a release
// is, and fails unless the installed package is byte for byte the same afterwards.
//
// The installed package (the macOS app bundle or the Windows installation folder) is part of the
// release baseline: its exact bytes carry the code signature, and Sparkle builds each differential
// update against them (see desktop/internal/installedpackage). A workflow may read it, but must not
// write, create, rename, remove or re-permission anything inside it; caches and state belong to the
// user's cache and configuration directories.
//
// A test calls Run first. In the test process, Run copies the test binary into a new installed
// package, records every entry of that package, runs the same test again from the copy, and
// fails unless the copy passed and every entry is still as recorded. In the copy, Run returns true
// and the test goes on with the workflow: installedpackage.Root() there is the new package, found by
// the production resolution of each platform, and the user's home, cache and configuration
// directories lie below a temporary directory of the test process, so the workflow reaches neither
// the real ones nor anything outside the test.
//
// scripts/desktop/verify/verify-runtime-bundle-immutability.sh requires the workflows it names to
// keep such a test. Only tests import this package; it is never linked into the client.
package installedpackagetest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
)

// copyEnv marks the copy of the test binary that Run starts.
const copyEnv = "LITHE_TEST_INSTALLED_PACKAGE_COPY"

// rootEnv carries the root of the new installed package to the copy, which checks that the
// production resolution finds it.
const rootEnv = "LITHE_TEST_INSTALLED_PACKAGE_ROOT"

// copyDeadline bounds the copy's run. The copy is given a shorter -test.timeout of its own, so a
// workflow that hangs fails there with its goroutines' stacks before this deadline stops it.
const (
	copyDeadline = 60 * time.Second
	copyTimeout  = 45 * time.Second
)

// Run reports whether this process is the installed copy, which runs the workflow. In the test
// process it runs the calling test from the copy, checks the installed package afterwards, and
// returns false; the test then returns. Only a top-level test may call it.
func Run(t *testing.T) bool {
	t.Helper()
	if os.Getenv(copyEnv) != "" {
		requireInstalledRoot(t)
		return true
	}
	if strings.Contains(t.Name(), "/") {
		t.Fatalf("installedpackagetest.Run is called from the subtest %s; call it from a top-level test", t.Name())
	}
	base := t.TempDir()
	root, executable := newPackage(t, base)
	copyBinary(t, executable)
	before := Record(t, root)

	home := filepath.Join(base, "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), copyDeadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable,
		"-test.run=^"+regexp.QuoteMeta(t.Name())+"$", "-test.count=1", "-test.v",
		"-test.timeout="+copyTimeout.String())
	cmd.Dir = base
	cmd.Env = copyEnvironment(home, root)
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("the installed copy did not finish within %s:\n%s", copyDeadline, output)
	}
	if err != nil {
		t.Fatalf("the workflow failed in the installed copy: %v\n%s", err, output)
	}
	// A pattern that selects nothing passes too, so the copy must report this test as passed.
	if !strings.Contains(string(output), "--- PASS: "+t.Name()+" ") {
		t.Fatalf("the installed copy did not run %s:\n%s", t.Name(), output)
	}
	before.Unchanged(t)
	return false
}

// newPackage lays out a new installed package below base the way a release installs the client,
// and returns its root and the path of its executable.
func newPackage(t *testing.T, base string) (root, executable string) {
	t.Helper()
	var dir string
	switch runtime.GOOS {
	case "darwin":
		root = filepath.Join(base, "Lithe.app")
		dir = filepath.Join(root, "Contents", "MacOS")
		executable = filepath.Join(dir, "lithe")
	case "windows":
		root = filepath.Join(base, "Lithe")
		dir = root
		executable = filepath.Join(dir, "lithe.exe")
	default:
		root = filepath.Join(base, "Lithe")
		dir = root
		executable = filepath.Join(dir, "lithe")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return root, executable
}

// copyBinary copies the running test binary to destination as an executable file.
func copyBinary(t *testing.T, destination string) {
	t.Helper()
	source, err := installedpackage.Executable()
	if err != nil {
		t.Fatal(err)
	}
	in, err := os.Open(source)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		t.Fatal(err)
	}
	if err := out.Close(); err != nil {
		t.Fatal(err)
	}
}

// copyEnvironment is this process's environment with the user's directories moved below home and
// the variables that mark the copy.
func copyEnvironment(home, root string) []string {
	moved := []string{"HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA",
		"XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", copyEnv, rootEnv}
	var env []string
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if !slices.ContainsFunc(moved, func(m string) bool { return strings.EqualFold(m, name) }) {
			env = append(env, entry)
		}
	}
	return append(env,
		"HOME="+home,
		"USERPROFILE="+home,
		"LOCALAPPDATA="+filepath.Join(home, "AppData", "Local"),
		"APPDATA="+filepath.Join(home, "AppData", "Roaming"),
		copyEnv+"=1",
		rootEnv+"="+root,
	)
}

// requireInstalledRoot fails the copy unless the production resolution finds the package Run
// made, so the workflow really runs from it.
func requireInstalledRoot(t *testing.T) {
	t.Helper()
	got, err := installedpackage.Root()
	if err != nil {
		t.Fatal(err)
	}
	if !samePath(t, got, os.Getenv(rootEnv)) {
		t.Fatalf("installedpackage.Root() = %q in the installed copy, want %q", got, os.Getenv(rootEnv))
	}
}

// Outside fails t unless path lies below the user's cache or configuration directory and outside
// the installed package. The copy calls it for each file the workflow wrote.
func Outside(t testing.TB, path string) {
	t.Helper()
	root, err := installedpackage.Root()
	if err != nil {
		t.Fatal(err)
	}
	if within(t, root, path) {
		t.Fatalf("%q is inside the installed package %q", path, root)
	}
	for _, locate := range []func() (string, error){os.UserCacheDir, os.UserConfigDir} {
		if dir, err := locate(); err == nil && within(t, dir, path) {
			return
		}
	}
	t.Fatalf("%q is below neither the user's cache nor configuration directory", path)
}

// Tree is the record of every entry below a directory: its kind, permission bits, size and
// SHA-256 for a file, and its target for a link.
type Tree struct {
	root    string
	entries map[string]string
}

// Record reads every entry below root.
func Record(t testing.TB, root string) Tree {
	t.Helper()
	entries, err := entriesBelow(root)
	if err != nil {
		t.Fatal(err)
	}
	return Tree{root: root, entries: entries}
}

// Unchanged fails t unless every entry below the recorded root is still as recorded, naming each
// entry that was added, removed or changed by its path relative to the root.
func (tree Tree) Unchanged(t testing.TB) {
	t.Helper()
	now, err := entriesBelow(tree.root)
	if err != nil {
		t.Fatal(err)
	}
	if differences := compare(tree.entries, now); len(differences) > 0 {
		t.Fatalf("the workflow changed %d entries below %q:\n%s", len(differences), tree.root, strings.Join(differences, "\n"))
	}
}

// compare lists, in order, each entry that is in now but not in was, in was but not in now, or
// described differently in the two.
func compare(was, now map[string]string) []string {
	var differences []string
	for name, before := range was {
		switch after, ok := now[name]; {
		case !ok:
			differences = append(differences, "removed "+name)
		case after != before:
			differences = append(differences, fmt.Sprintf("changed %s: %s -> %s", name, before, after))
		}
	}
	for name, after := range now {
		if _, ok := was[name]; !ok {
			differences = append(differences, fmt.Sprintf("added %s: %s", name, after))
		}
	}
	slices.Sort(differences)
	return differences
}

// entriesBelow describes every entry below root, keyed by its slash-separated relative path.
func entriesBelow(root string) (map[string]string, error) {
	entries := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		description, err := describe(path, info)
		if err != nil {
			return err
		}
		entries[filepath.ToSlash(rel)] = description
		return nil
	})
	return entries, err
}

// describe is an entry's kind and permission bits, with the size and SHA-256 of a file and the
// target of a link. Times are left out: reading a file may update them.
func describe(path string, info fs.FileInfo) (string, error) {
	mode := info.Mode()
	switch {
	case mode.IsDir():
		return fmt.Sprintf("dir %v", mode.Perm()), nil
	case mode&fs.ModeSymlink != 0:
		target, err := os.Readlink(path)
		if err != nil {
			return "", err
		}
		return "link " + target, nil
	case mode.IsRegular():
		file, err := os.Open(path)
		if err != nil {
			return "", err
		}
		defer file.Close()
		sum := sha256.New()
		if _, err := io.Copy(sum, file); err != nil {
			return "", err
		}
		return fmt.Sprintf("file %v %d %s", mode.Perm(), info.Size(), hex.EncodeToString(sum.Sum(nil))), nil
	default:
		return fmt.Sprintf("other %v", mode), nil
	}
}

// within reports whether path is dir or lies below it, after resolving the links in both, such as
// /var to /private/var on macOS.
func within(t testing.TB, dir, path string) bool {
	t.Helper()
	dir, path = resolved(t, dir), resolved(t, path)
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// samePath reports whether two paths name the same location after resolving their links.
func samePath(t testing.TB, a, b string) bool {
	t.Helper()
	return resolved(t, a) == resolved(t, b)
}

// resolved is path with the links of its longest existing prefix resolved, so a file the workflow
// has not written yet still compares by where it would be.
func resolved(t testing.TB, path string) string {
	t.Helper()
	path = filepath.Clean(path)
	var rest []string
	for {
		real, err := filepath.EvalSymlinks(path)
		if err == nil {
			return filepath.Join(append([]string{real}, rest...)...)
		}
		if !errors.Is(err, fs.ErrNotExist) {
			t.Fatal(err)
		}
		parent := filepath.Dir(path)
		if parent == path {
			return filepath.Join(append([]string{path}, rest...)...)
		}
		rest = append([]string{filepath.Base(path)}, rest...)
		path = parent
	}
}
