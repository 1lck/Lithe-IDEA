package remoteserver

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
)

const (
	x86Target = "x86_64-unknown-linux-musl"
	armTarget = "aarch64-unknown-linux-musl"
)

// fakeBuild is one build of a test manifest.
type fakeBuild struct {
	target string
	data   []byte
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// manifestOf writes the manifest build-remote-server.sh writes for builds, with the fields this
// package does not read, so a test also shows that they are accepted.
func manifestOf(t *testing.T, builds ...fakeBuild) []byte {
	t.Helper()
	artifacts := make([]map[string]any, len(builds))
	for i, build := range builds {
		artifacts[i] = map[string]any{
			"target": build.target,
			"path":   build.target + "/" + BinaryName,
			"size":   len(build.data),
			"sha256": digest(build.data),
		}
	}
	data, err := json.Marshal(map[string]any{
		"schemaVersion": 1,
		"coreRevision":  "0123456789abcdef0123456789abcdef01234567",
		"coreWorktree":  "clean",
		"coreSource":    "pinned",
		"serverVersion": "0.1.0",
		"rustc":         "rustc 1.100.0",
		"profile":       "release",
		"artifacts":     artifacts,
	})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// withEmbedded makes manifest and builds the client's embedded files for the test.
func withEmbedded(t *testing.T, manifest []byte, builds ...fakeBuild) {
	t.Helper()
	files := make(map[string][]byte, len(builds))
	for _, build := range builds {
		files[build.target] = build.data
	}
	original := embedded
	embedded = func() *source {
		return &source{manifest: manifest, build: func(target string) ([]byte, error) {
			if data, ok := files[target]; ok {
				return data, nil
			}
			return nil, fs.ErrNotExist
		}}
	}
	t.Cleanup(func() { embedded = original })
}

func withoutEmbedded(t *testing.T) {
	t.Helper()
	original := embedded
	embedded = func() *source { return nil }
	t.Cleanup(func() { embedded = original })
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestInstallWritesEachBuildOnceAndRestoresAReplacedOne(t *testing.T) {
	builds := []fakeBuild{{x86Target, []byte("x86_64 server")}, {armTarget, []byte("aarch64 server")}}
	withEmbedded(t, manifestOf(t, builds...), builds...)
	dir := t.TempDir()

	bundle, err := Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.Version != "0.1.0" || len(bundle.Builds) != 2 {
		t.Fatalf("bundle = %+v, want version 0.1.0 and two builds", bundle)
	}
	for i, build := range builds {
		got := bundle.Builds[i]
		want := Build{Target: build.target, Path: filepath.Join(dir, build.target, BinaryName), SHA256: digest(build.data)}
		if got != want {
			t.Fatalf("build %d = %+v, want %+v", i, got, want)
		}
		if content := readFile(t, got.Path); content != string(build.data) {
			t.Fatalf("%s holds %q, want %q", got.Path, content, build.data)
		}
		info, err := os.Stat(got.Path)
		if err != nil {
			t.Fatal(err)
		}
		// Windows has no permission bits: Go reports every writable file as 0666 there, and the
		// user's profile directory is what keeps the copy private.
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %v, want a file only the user can read and write", got.Path, info.Mode())
		}
	}

	// A second connection keeps the files it finds with the right bytes.
	first, err := os.Stat(bundle.Builds[0].Path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Install(dir); err != nil {
		t.Fatal(err)
	}
	second, err := os.Stat(bundle.Builds[0].Path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(first, second) || !second.ModTime().Equal(first.ModTime()) {
		t.Fatal("installing the same build rewrote it")
	}

	// A file with other bytes, such as a build another release installed or one replaced on disk,
	// is replaced with the embedded bytes.
	if err := os.WriteFile(bundle.Builds[1].Path, []byte("replaced"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(dir); err != nil {
		t.Fatal(err)
	}
	if content := readFile(t, bundle.Builds[1].Path); content != "aarch64 server" {
		t.Fatalf("the replaced build holds %q after installation", content)
	}
	entries, err := os.ReadDir(filepath.Dir(bundle.Builds[1].Path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("the target directory holds %d entries, want only the build", len(entries))
	}
}

func TestInstallReplacesALinkWithAFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("creating a symbolic link needs a privilege Windows test accounts usually lack")
	}
	build := fakeBuild{x86Target, []byte("x86_64 server")}
	withEmbedded(t, manifestOf(t, build), build)
	dir := t.TempDir()
	elsewhere := filepath.Join(t.TempDir(), "same bytes elsewhere")
	if err := os.WriteFile(elsewhere, build.data, 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, x86Target, BinaryName)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, path); err != nil {
		t.Fatal(err)
	}

	if _, err := Install(dir); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() {
		t.Fatalf("%s is %v after installation, want a regular file", path, info.Mode())
	}
	if content := readFile(t, path); content != "x86_64 server" {
		t.Fatalf("%s holds %q", path, content)
	}
}

func TestInstallAcceptsTheSameBuildFromAClientThatWonTheRace(t *testing.T) {
	build := fakeBuild{x86Target, []byte("x86_64 server")}
	withEmbedded(t, manifestOf(t, build), build)
	path := func(dir string) string { return filepath.Join(dir, x86Target, BinaryName) }
	// The rename fails, as on Windows when a process holds the file open, after another client
	// left winner at the target.
	loseTo := func(t *testing.T, winner []byte) {
		t.Helper()
		original := rename
		rename = func(_, target string) error {
			if err := os.WriteFile(target, winner, 0o600); err != nil {
				t.Fatal(err)
			}
			return errors.New("the file is in use")
		}
		t.Cleanup(func() { rename = original })
	}
	onlyTheBuild := func(t *testing.T, dir string) {
		t.Helper()
		entries, err := os.ReadDir(filepath.Dir(path(dir)))
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) != 1 {
			t.Fatalf("the target directory holds %d entries, want only the build", len(entries))
		}
	}

	t.Run("same bytes", func(t *testing.T) {
		loseTo(t, build.data)
		dir := t.TempDir()
		bundle, err := Install(dir)
		if err != nil {
			t.Fatalf("Install refused the build another client installed: %v", err)
		}
		if bundle.Builds[0].Path != path(dir) || readFile(t, path(dir)) != string(build.data) {
			t.Fatalf("bundle = %+v", bundle)
		}
		onlyTheBuild(t, dir)
	})
	t.Run("other bytes", func(t *testing.T) {
		loseTo(t, []byte("another release"))
		dir := t.TempDir()
		if _, err := Install(dir); err == nil {
			t.Fatal("Install reported a build it could not install")
		}
		onlyTheBuild(t, dir)
	})
}

func TestInstallRefusesEmbeddedBuildsThatDoNotMatchTheManifest(t *testing.T) {
	good := fakeBuild{x86Target, []byte("x86_64 server")}
	cases := map[string][]fakeBuild{
		"other bytes":   {good, {armTarget, []byte("aarch64 serveR")}},
		"other size":    {good, {armTarget, []byte("aarch64 server, longer")}},
		"missing build": {good},
	}
	for name, embeddedBuilds := range cases {
		t.Run(name, func(t *testing.T) {
			withEmbedded(t, manifestOf(t, good, fakeBuild{armTarget, []byte("aarch64 server")}), embeddedBuilds...)
			dir := filepath.Join(t.TempDir(), "remote-server")
			_, err := Install(dir)
			if err == nil {
				t.Fatal("Install accepted a build its manifest does not describe")
			}
			if name != "missing build" && !errors.Is(err, ErrMismatch) {
				t.Fatalf("err = %v, want ErrMismatch", err)
			}
			if _, statErr := os.Stat(dir); !errors.Is(statErr, fs.ErrNotExist) {
				t.Fatalf("Install created %s before refusing (%v)", dir, statErr)
			}
		})
	}
}

func TestInstallChecksTheManifestBeforeWritingAnything(t *testing.T) {
	build := fakeBuild{x86Target, []byte("x86_64 server")}
	entry := func(change func(map[string]any)) map[string]any {
		value := map[string]any{"target": x86Target, "path": x86Target + "/" + BinaryName, "size": len(build.data), "sha256": digest(build.data)}
		if change != nil {
			change(value)
		}
		return value
	}
	document := func(schema int, version string, artifacts ...map[string]any) string {
		data, err := json.Marshal(map[string]any{"schemaVersion": schema, "serverVersion": version, "artifacts": artifacts})
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	cases := map[string]string{
		"not JSON":          "{",
		"another schema":    document(2, "0.1.0", entry(nil)),
		"no version":        document(1, "", entry(nil)),
		"no builds":         document(1, "0.1.0"),
		"a repeated target": document(1, "0.1.0", entry(nil), entry(nil)),
		"a target path":     document(1, "0.1.0", entry(func(v map[string]any) { v["target"] = "../" + x86Target })),
		"another location":  document(1, "0.1.0", entry(func(v map[string]any) { v["path"] = "../" + BinaryName })),
		"no size":           document(1, "0.1.0", entry(func(v map[string]any) { v["size"] = 0 })),
		"an uppercase hash": document(1, "0.1.0", entry(func(v map[string]any) { v["sha256"] = fmt.Sprintf("%X", sha256.Sum256(build.data)) })),
		"a short hash":      document(1, "0.1.0", entry(func(v map[string]any) { v["sha256"] = digest(build.data)[:63] })),
	}
	for name, manifest := range cases {
		t.Run(name, func(t *testing.T) {
			withEmbedded(t, []byte(manifest), build)
			dir := filepath.Join(t.TempDir(), "remote-server")
			if _, err := Install(dir); err == nil {
				t.Fatal("Install accepted the manifest")
			}
			if _, err := os.Stat(dir); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("Install created %s before refusing (%v)", dir, err)
			}
		})
	}
}

// stage writes what build-remote-server.sh stages for builds and returns the stage.
func stage(t *testing.T, builds ...fakeBuild) string {
	t.Helper()
	dir := t.TempDir()
	for _, build := range builds {
		path := filepath.Join(dir, build.target, BinaryName)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, build.data, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), manifestOf(t, builds...), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestStagedReadsTheBuildsWhereTheyAreAndRefusesAChangedOne(t *testing.T) {
	builds := []fakeBuild{{x86Target, []byte("x86_64 server")}, {armTarget, []byte("aarch64 server")}}
	dir := stage(t, builds...)
	bundle, err := Staged(dir)
	if err != nil {
		t.Fatal(err)
	}
	for i, build := range builds {
		want := Build{Target: build.target, Path: filepath.Join(dir, build.target, BinaryName), SHA256: digest(build.data)}
		if bundle.Builds[i] != want {
			t.Fatalf("build %d = %+v, want %+v", i, bundle.Builds[i], want)
		}
	}
	// A build rebuilt without its manifest, or edited, no longer matches.
	if err := os.WriteFile(filepath.Join(dir, armTarget, BinaryName), []byte("aarch64 serveR"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Staged(dir); !errors.Is(err, ErrMismatch) {
		t.Fatalf("err = %v, want ErrMismatch", err)
	}
}

func TestResolvePrefersTheEmbeddedBuildsOverAStage(t *testing.T) {
	staged := fakeBuild{x86Target, []byte("staged server")}
	stageDir := stage(t, staged)

	t.Run("development build without a stage", func(t *testing.T) {
		withoutEmbedded(t)
		t.Setenv(StageEnv, "")
		if _, err := Resolve(t.TempDir()); !errors.Is(err, ErrNotBundled) {
			t.Fatalf("err = %v, want ErrNotBundled", err)
		}
	})
	t.Run("development build with a stage", func(t *testing.T) {
		withoutEmbedded(t)
		t.Setenv(StageEnv, stageDir)
		bundle, err := Resolve(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		if got := bundle.Builds[0].Path; got != filepath.Join(stageDir, x86Target, BinaryName) {
			t.Fatalf("path = %q, want the staged build", got)
		}
	})
	t.Run("packaged client ignores the stage", func(t *testing.T) {
		build := fakeBuild{x86Target, []byte("embedded server")}
		withEmbedded(t, manifestOf(t, build), build)
		t.Setenv(StageEnv, stageDir)
		dir := t.TempDir()
		bundle, err := Resolve(dir)
		if err != nil {
			t.Fatal(err)
		}
		if got := bundle.Builds[0]; got.Path != filepath.Join(dir, x86Target, BinaryName) || got.SHA256 != digest(build.data) {
			t.Fatalf("build = %+v, want the embedded build installed below %s", got, dir)
		}
	})
}

// A connection installs the server builds from a client installed the way a release is, and the
// installed package stays byte for byte as it was: the builds land below the user's cache
// directory, which Core then reads and uploads (#2231). Run checks the package in the test process.
func TestResolveLeavesTheInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	builds := []fakeBuild{{x86Target, []byte("x86 server")}, {armTarget, []byte("arm server")}}
	withEmbedded(t, manifestOf(t, builds...), builds...)
	t.Setenv(StageEnv, "")
	dir, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	// The second connection finds the builds installed and reads them where they are.
	for range 2 {
		bundle, err := Resolve(dir)
		if err != nil {
			t.Fatal(err)
		}
		if len(bundle.Builds) != len(builds) {
			t.Fatalf("builds = %+v, want %d", bundle.Builds, len(builds))
		}
		for i, build := range bundle.Builds {
			installedpackagetest.Outside(t, build.Path)
			if got := readFile(t, build.Path); got != string(builds[i].data) {
				t.Fatalf("%s holds %q, want %q", build.Target, got, builds[i].data)
			}
		}
	}
}
