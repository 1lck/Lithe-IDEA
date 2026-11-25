package conpty

import (
	"bytes"
	"crypto/sha256"
	"debug/pe"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
)

// noticeRow is one row of the table in NOTICE.md: a file of this folder, its path in the
// NuGet package and its SHA-256.
var noticeRow = regexp.MustCompile("^\\| `([^`]+)` \\| `([^`]+)` \\| `([0-9a-f]{64})` \\|$")

// TestTheConPTYFolderMatchesItsNotice keeps the binaries the client embeds the ones
// NOTICE.md records: the same bytes, the PE machine their folder names, and no other file
// beside them.
func TestTheConPTYFolderMatchesItsNotice(t *testing.T) {
	notice, err := os.ReadFile("NOTICE.md")
	if err != nil {
		t.Fatal(err)
	}
	machines := map[string]uint16{
		"win-x64":   pe.IMAGE_FILE_MACHINE_AMD64,
		"x64":       pe.IMAGE_FILE_MACHINE_AMD64,
		"win-arm64": pe.IMAGE_FILE_MACHINE_ARM64,
		"arm64":     pe.IMAGE_FILE_MACHINE_ARM64,
	}
	listed := map[string]bool{}
	for _, line := range strings.Split(string(notice), "\n") {
		row := noticeRow.FindStringSubmatch(strings.TrimRight(line, "\r"))
		if row == nil {
			continue
		}
		path, sum := row[1], row[3]
		listed[path] = true
		data, err := os.ReadFile(filepath.FromSlash(path))
		if err != nil {
			t.Errorf("NOTICE.md lists %s: %v", path, err)
			continue
		}
		if got := sha256.Sum256(data); hex.EncodeToString(got[:]) != sum {
			t.Errorf("%s is SHA-256 %x, NOTICE.md records %s", path, got, sum)
		}
		want, ok := machines[strings.Split(path, "/")[0]]
		if !ok {
			t.Errorf("%s is in a folder that names no architecture", path)
			continue
		}
		image, err := pe.NewFile(bytes.NewReader(data))
		if err != nil {
			t.Errorf("%s is not a PE image: %v", path, err)
			continue
		}
		if image.Machine != want {
			t.Errorf("%s is for machine 0x%04x, its folder names 0x%04x", path, image.Machine, want)
		}
	}
	for _, path := range []string{"win-x64/conpty.dll", "win-arm64/conpty.dll", "x64/OpenConsole.exe", "arm64/OpenConsole.exe"} {
		if !listed[path] {
			t.Errorf("NOTICE.md does not list %s, which the Windows builds embed", path)
		}
	}
	if info, err := os.Stat("LICENSE.txt"); err != nil || info.Size() == 0 {
		t.Errorf("the license of the binaries is missing: %v", err)
	}
	err = filepath.WalkDir(".", func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		path = filepath.ToSlash(path)
		if !listed[path] && path != "NOTICE.md" && path != "LICENSE.txt" && !strings.HasSuffix(path, ".go") {
			t.Errorf("%s is in the ConPTY folder but not in NOTICE.md", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestTheBuildCarriesItsArchitecturesSet keeps each Windows build's set the files its
// architecture needs and their license, and every other build without one.
func TestTheBuildCarriesItsArchitecturesSet(t *testing.T) {
	sources := map[string]map[string]string{ // installed path → file of this folder
		"windows/amd64": {"LICENSE.txt": "LICENSE.txt", DLL: "win-x64/conpty.dll", "x64/OpenConsole.exe": "x64/OpenConsole.exe", "arm64/OpenConsole.exe": "arm64/OpenConsole.exe"},
		"windows/arm64": {"LICENSE.txt": "LICENSE.txt", DLL: "win-arm64/conpty.dll", "arm64/OpenConsole.exe": "arm64/OpenConsole.exe"},
	}[runtime.GOOS+"/"+runtime.GOARCH]
	if sources == nil {
		if _, err := Install(t.TempDir()); !errors.Is(err, ErrUnavailable) {
			t.Fatalf("Install on %s/%s = %v, want ErrUnavailable", runtime.GOOS, runtime.GOARCH, err)
		}
		return
	}
	if len(bundled) != len(sources) {
		t.Fatalf("the build carries %d files, want %d", len(bundled), len(sources))
	}
	for _, f := range bundled {
		source, ok := sources[f.path]
		if !ok {
			t.Errorf("the build carries %s, which its architecture does not need", f.path)
			continue
		}
		want, err := os.ReadFile(filepath.FromSlash(source))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(f.data, want) {
			t.Errorf("the build's %s is not %s", f.path, source)
		}
	}
}

// fakeSet stands in for a ConPTY: Install only places bytes, and these are never loaded.
func fakeSet(version string) []file {
	return []file{
		{path: DLL, data: []byte("dll " + version)},
		{path: "x64/OpenConsole.exe", data: []byte("x64 host " + version)},
		{path: "arm64/OpenConsole.exe", data: []byte("arm64 host " + version)},
	}
}

func requireInstalled(t *testing.T, dir string, files []file) {
	t.Helper()
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.path)))
		if err != nil {
			t.Fatalf("%s: %v", f.path, err)
		}
		if !bytes.Equal(data, f.data) {
			t.Fatalf("%s holds %q, want %q", f.path, data, f.data)
		}
	}
}

func TestInstallPlacesTheSetInAFolderNamedByItsDigest(t *testing.T) {
	root := t.TempDir()
	files := fakeSet("1")
	path, err := install(root, files)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, digest(files))
	if path != filepath.Join(dir, DLL) {
		t.Fatalf("Install returned %s, want %s", path, filepath.Join(dir, DLL))
	}
	requireInstalled(t, dir, files)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") {
			t.Errorf("a temporary file was left behind: %s", entry.Name())
		}
	}
}

func TestInstallKeepsFilesThatHoldTheRightBytes(t *testing.T) {
	root := t.TempDir()
	files := fakeSet("1")
	path, err := install(root, files)
	if err != nil {
		t.Fatal(err)
	}
	// A file that is rewritten gets a new modification time; this one is far in the past.
	kept := time.Date(2020, time.January, 2, 3, 4, 6, 0, time.UTC)
	if err := os.Chtimes(path, kept, kept); err != nil {
		t.Fatal(err)
	}
	if _, err := install(root, files); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(kept) {
		t.Fatalf("a DLL that already held the right bytes was rewritten (modified %v)", info.ModTime())
	}
}

func TestInstallRepairsAFileWithOtherBytes(t *testing.T) {
	root := t.TempDir()
	files := fakeSet("1")
	if _, err := install(root, files); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, digest(files))
	host := filepath.Join(dir, "x64", "OpenConsole.exe")
	if err := os.WriteFile(host, []byte("truncat"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, "arm64", "OpenConsole.exe")); err != nil {
		t.Fatal(err)
	}
	if _, err := install(root, files); err != nil {
		t.Fatal(err)
	}
	requireInstalled(t, dir, files)
}

func TestADifferentSetInstallsBesideTheOther(t *testing.T) {
	root := t.TempDir()
	first, second := fakeSet("1"), fakeSet("2")
	firstPath, err := install(root, first)
	if err != nil {
		t.Fatal(err)
	}
	secondPath, err := install(root, second)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(firstPath) == filepath.Dir(secondPath) {
		t.Fatalf("two sets share the folder %s", filepath.Dir(firstPath))
	}
	// A running client of the other release may still have its set loaded.
	requireInstalled(t, filepath.Dir(firstPath), first)
	requireInstalled(t, filepath.Dir(secondPath), second)
}

func TestInstallFailsWhereTheRootCannotBeCreated(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := install(filepath.Join(blocker, "conpty"), fakeSet("1")); err == nil {
		t.Fatal("Install below a regular file succeeded")
	}
}

func TestInstallWithoutASetIsUnavailable(t *testing.T) {
	if _, err := install(t.TempDir(), nil); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("Install of no files = %v, want ErrUnavailable", err)
	}
}

func TestTheDigestCoversEveryFilesPathAndBytes(t *testing.T) {
	base := digest(fakeSet("1"))
	moved := fakeSet("1")
	moved[1].path = "x86/OpenConsole.exe"
	// The same bytes split differently between two files are a different set.
	shifted := fakeSet("1")
	shifted[0].data = append(append([]byte(nil), shifted[0].data...), shifted[1].data[0])
	shifted[1].data = shifted[1].data[1:]
	for name, files := range map[string][]file{"moved": moved, "shifted": shifted, "changed": fakeSet("2")} {
		if digest(files) == base {
			t.Errorf("the %s set has the same digest as the original", name)
		}
	}
	if digest(fakeSet("1")) != base {
		t.Error("the same set has two digests")
	}
}

// Opening a terminal from a client installed the way a release is installs the ConPTY below the
// user's cache directory and leaves the installed package byte for byte as it was. On Windows it
// installs the ConPTY this build carries; elsewhere, where a build carries none, a stand-in set.
// Run checks the package in the test process.
func TestInstallLeavesTheInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	files := bundled
	if len(files) == 0 {
		files = fakeSet("1")
	}
	root, err := DefaultRoot()
	if err != nil {
		t.Fatal(err)
	}
	// The second terminal finds the set installed and reads it where it is.
	for range 2 {
		path, err := install(root, files)
		if err != nil {
			t.Fatal(err)
		}
		installedpackagetest.Outside(t, path)
		requireInstalled(t, filepath.Dir(path), files)
	}
}
