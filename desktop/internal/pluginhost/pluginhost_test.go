package pluginhost

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// fakeValidator records what Validate passed to Core and returns a fixed answer.
type fakeValidator struct {
	manifest     json.RawMessage
	err          error
	capabilities map[string][]int
	called       bool
}

func (v *fakeValidator) ValidatePluginManifest(_ context.Context, _ json.RawMessage, capabilities map[string][]int) (json.RawMessage, error) {
	v.called = true
	v.capabilities = capabilities
	return v.manifest, v.err
}

func TestValidatePassesCapabilitiesToCore(t *testing.T) {
	validator := &fakeValidator{manifest: json.RawMessage(`{"id":"example"}`)}
	capabilities := Declared().With("backend", 1)
	normalised, err := Validate(context.Background(), validator, json.RawMessage(`{"id":"example"}`), capabilities)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if string(normalised) != `{"id":"example"}` {
		t.Fatalf("manifest = %s", normalised)
	}
	if !validator.called {
		t.Fatal("the validator was never called")
	}
	if versions := validator.capabilities["backend"]; len(versions) != 1 || versions[0] != 1 {
		t.Fatalf("capabilities = %v", validator.capabilities)
	}
}

func TestValidateRefusesBrokenValidator(t *testing.T) {
	if _, err := Validate(context.Background(), nil, json.RawMessage(`{}`), Declared()); err == nil {
		t.Fatal("a missing validator was accepted")
	}
	refusal := errors.New("core refused the manifest")
	if _, err := Validate(context.Background(), &fakeValidator{err: refusal}, json.RawMessage(`{}`), Declared()); !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
	if _, err := Validate(context.Background(), &fakeValidator{}, json.RawMessage(`{}`), Declared()); err == nil {
		t.Fatal("an empty normalised manifest was accepted")
	}
}

func TestDeclaredServesLanguagesOnly(t *testing.T) {
	declared := Declared()
	if len(declared) != 1 {
		t.Fatalf("declared = %v", declared)
	}
	versions := declared["languages"]
	if len(versions) != 2 || versions[0] != 1 || versions[1] != 3 {
		t.Fatalf("languages = %v", versions)
	}
}

func TestCapabilitiesAreIndependent(t *testing.T) {
	base := Declared().With("backend", 1)
	extended := base.With("backend", 2)
	if len(base["backend"]) != 1 || base["backend"][0] != 1 {
		t.Fatalf("the original was mutated: %v", base)
	}
	if len(extended["backend"]) != 2 || extended["backend"][1] != 2 {
		t.Fatalf("extended = %v", extended)
	}
	cloned := base.Clone()
	cloned["backend"][0] = 99
	if base["backend"][0] != 1 {
		t.Fatalf("the clone shares storage: %v", base)
	}
}

// writePackage creates a package directory holding the given files.
func writePackage(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestResolvePackagePath(t *testing.T) {
	root := writePackage(t, map[string]string{
		"plugin.json":     "{}",
		"bin/server":      "binary",
		"lib/nested/a.js": "code",
	})
	resolved, err := ResolvePackagePath(root, "lib/nested/a.js")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if want := filepath.Join(root, "lib", "nested", "a.js"); resolved != want {
		t.Fatalf("resolved = %q, want %q", resolved, want)
	}
}

func TestResolvePackagePathRefusesUnsafeNames(t *testing.T) {
	root := writePackage(t, map[string]string{"plugin.json": "{}"})
	for _, name := range []string{"", "/etc/passwd", "../escape", `lib\a`, "CON"} {
		if _, err := ResolvePackagePath(root, name); !errors.Is(err, ErrPackagePath) {
			t.Fatalf("ResolvePackagePath(%q) = %v", name, err)
		}
	}
	if _, err := ResolvePackagePath("relative", "plugin.json"); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("a relative package directory was accepted: %v", err)
	}
}

func TestResolvePackagePathRefusesMissingFile(t *testing.T) {
	root := writePackage(t, map[string]string{"plugin.json": "{}"})
	if _, err := ResolvePackagePath(root, "bin/absent"); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolvePackagePathRefusesDirectory(t *testing.T) {
	root := writePackage(t, map[string]string{"lib/a.js": "code"})
	if _, err := ResolvePackagePath(root, "lib"); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolvePackagePathRefusesPathThroughFile(t *testing.T) {
	root := writePackage(t, map[string]string{"lib": "not a directory"})
	if _, err := ResolvePackagePath(root, "lib/a.js"); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolvePackagePathRefusesSymlinkLeaf(t *testing.T) {
	root := writePackage(t, map[string]string{"plugin.json": "{}"})
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked.txt")); err != nil {
		t.Skipf("this platform cannot create symbolic links: %v", err)
	}
	if _, err := ResolvePackagePath(root, "linked.txt"); !errors.Is(err, ErrPackageSymlink) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolvePackagePathRefusesSymlinkAncestor(t *testing.T) {
	root := writePackage(t, map[string]string{"plugin.json": "{}"})
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "lib")); err != nil {
		t.Skipf("this platform cannot create symbolic links: %v", err)
	}
	// The leaf is a regular file and the path is package-relative, but it would
	// resolve outside the package.
	if _, err := ResolvePackagePath(root, "lib/secret.txt"); !errors.Is(err, ErrPackageSymlink) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolveExecutableRequiresExecuteBit(t *testing.T) {
	root := writePackage(t, map[string]string{"bin/server": "binary"})
	if _, err := ResolveExecutable(root, "bin/server"); !errors.Is(err, ErrNotExecutable) {
		t.Fatalf("err = %v", err)
	}
	if err := os.Chmod(filepath.Join(root, "bin", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := ResolveExecutable(root, "bin/server")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if want := filepath.Join(root, "bin", "server"); resolved != want {
		t.Fatalf("resolved = %q, want %q", resolved, want)
	}
}

func TestResolvePackagePathsKeepsOrder(t *testing.T) {
	root := writePackage(t, map[string]string{"a.txt": "a", "b.txt": "b"})
	resolved, err := ResolvePackagePaths(root, []string{"b.txt", "a.txt"})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if len(resolved) != 2 || resolved[0] != filepath.Join(root, "b.txt") || resolved[1] != filepath.Join(root, "a.txt") {
		t.Fatalf("resolved = %v", resolved)
	}
}

func TestResolvePackagePathsRefusesAnyUnusablePath(t *testing.T) {
	root := writePackage(t, map[string]string{"a.txt": "a"})
	if _, err := ResolvePackagePaths(root, []string{"a.txt", "absent.txt"}); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}
