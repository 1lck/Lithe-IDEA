package pluginpkg

import (
	"archive/zip"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// archiveEntry is one file or directory a test writes into an archive. A
// directory is written by ending its name with a separator, exactly as ZIP does.
type archiveEntry struct {
	name string
	body []byte
	mode fs.FileMode
}

// writeArchive writes a ZIP archive holding entries and returns its path.
func writeArchive(t *testing.T, entries []archiveEntry) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "package.zip")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate}
		if entry.mode != 0 {
			header.SetMode(entry.mode)
		}
		part, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(entry.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

// extractInto extracts entries into a fresh directory and returns what the
// extraction reported together with the directory it would have used.
func extractInto(t *testing.T, entries []archiveEntry) (Package, string, error) {
	t.Helper()
	target := filepath.Join(t.TempDir(), "package")
	pkg, err := Extract(writeArchive(t, entries), target)
	return pkg, target, err
}

func TestExtractWritesFilesInPathOrder(t *testing.T) {
	pkg, target, err := extractInto(t, []archiveEntry{
		{name: "plugin.json", body: []byte(`{"id":"example"}`), mode: 0o644},
		{name: "lib/a.txt", body: []byte("hello"), mode: 0o644},
		{name: "languages/java/tmLanguage.json", body: []byte("{}"), mode: 0o644},
	})
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	want := []string{"languages/java/tmLanguage.json", "lib/a.txt", "plugin.json"}
	if len(pkg.Files) != len(want) {
		t.Fatalf("files = %+v", pkg.Files)
	}
	for i, path := range want {
		if pkg.Files[i].Path != path {
			t.Fatalf("file %d = %q, want %q", i, pkg.Files[i].Path, path)
		}
	}
	var total int64
	for _, file := range pkg.Files {
		total += file.Size
	}
	if pkg.Total != total || total != int64(len(`{"id":"example"}`)+len("hello")+len("{}")) {
		t.Fatalf("total = %d, sum = %d", pkg.Total, total)
	}
	body, err := os.ReadFile(filepath.Join(target, "lib", "a.txt"))
	if err != nil || string(body) != "hello" {
		t.Fatalf("body = %q, err = %v", body, err)
	}
	info, err := os.Stat(filepath.Join(target, "lib", "a.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
}

func TestExtractCreatesExplicitDirectories(t *testing.T) {
	pkg, target, err := extractInto(t, []archiveEntry{
		{name: "plugin.json", body: []byte("{}"), mode: 0o644},
		{name: "lib/", mode: fs.ModeDir | 0o755},
		{name: "lib/a.txt", body: []byte("x"), mode: 0o644},
	})
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if len(pkg.Files) != 2 {
		t.Fatalf("files = %+v", pkg.Files)
	}
	if _, err := os.Stat(filepath.Join(target, "lib")); err != nil {
		t.Fatal(err)
	}
}

func TestExtractDefaultsPermissionWithoutMode(t *testing.T) {
	pkg, target, err := extractInto(t, []archiveEntry{
		{name: "plugin.json", body: []byte("{}")},
	})
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if pkg.Files[0].Mode != 0o644 {
		t.Fatalf("mode = %v", pkg.Files[0].Mode)
	}
	info, err := os.Stat(filepath.Join(target, ManifestFile))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("on-disk mode = %v", info.Mode().Perm())
	}
}

func TestExtractRefusesUnsafeArchives(t *testing.T) {
	manifest := archiveEntry{name: ManifestFile, body: []byte("{}"), mode: 0o644}
	cases := []struct {
		name    string
		entries []archiveEntry
		want    error
	}{
		{"symbolic link", []archiveEntry{
			manifest,
			{name: "link", body: []byte("/etc/passwd"), mode: fs.ModeSymlink | 0o777},
		}, ErrSymbolicLink},
		{"special file", []archiveEntry{
			manifest,
			{name: "pipe", body: []byte("x"), mode: fs.ModeNamedPipe | 0o644},
		}, ErrSpecialFile},
		{"parent segment", []archiveEntry{
			manifest,
			{name: "../escape.txt", body: []byte("x"), mode: 0o644},
		}, ErrUnsafePath},
		{"absolute path", []archiveEntry{
			manifest,
			{name: "/etc/passwd", body: []byte("x"), mode: 0o644},
		}, ErrUnsafePath},
		{"backslash", []archiveEntry{
			manifest,
			{name: `lib\a.txt`, body: []byte("x"), mode: 0o644},
		}, ErrUnsafePath},
		{"device name", []archiveEntry{
			manifest,
			{name: "CON", body: []byte("x"), mode: 0o644},
		}, ErrUnsafePath},
		{"duplicate differing in case", []archiveEntry{
			manifest,
			{name: "lib/a.txt", body: []byte("x"), mode: 0o644},
			{name: "lib/A.txt", body: []byte("y"), mode: 0o644},
		}, ErrDuplicatePath},
		{"file used as a directory", []archiveEntry{
			manifest,
			{name: "lib", body: []byte("x"), mode: 0o644},
			{name: "lib/a.txt", body: []byte("y"), mode: 0o644},
		}, ErrPathConflict},
		{"directory used as a file", []archiveEntry{
			manifest,
			{name: "lib/a.txt", body: []byte("y"), mode: 0o644},
			{name: "lib", body: []byte("x"), mode: 0o644},
		}, ErrPathConflict},
		{"no manifest", []archiveEntry{
			{name: "lib/a.txt", body: []byte("x"), mode: 0o644},
		}, ErrManifestMissing},
		{"manifest below the root", []archiveEntry{
			{name: "sub/plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrManifestMissing},
		{"no entries", nil, ErrManifestMissing},
		{"expansion bomb", []archiveEntry{
			manifest,
			{name: "bomb.bin", body: make([]byte, 1<<20), mode: 0o644},
		}, ErrCompressionRatio},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, target, err := extractInto(t, tc.entries)
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if _, statErr := os.Stat(target); !errors.Is(statErr, fs.ErrNotExist) {
				t.Fatalf("a refused extraction left its directory behind: %v", statErr)
			}
		})
	}
}

func TestExtractRefusesUnreadableArchive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "package.zip")
	if err := os.WriteFile(path, []byte("not a zip archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Extract(path, filepath.Join(t.TempDir(), "package")); !errors.Is(err, ErrNotArchive) {
		t.Fatalf("err = %v", err)
	}
}

func TestExtractRefusesExistingDirectory(t *testing.T) {
	archive := writeArchive(t, []archiveEntry{{name: ManifestFile, body: []byte("{}"), mode: 0o644}})
	target := filepath.Join(t.TempDir(), "package")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Extract(archive, target); err == nil {
		t.Fatal("extraction into an existing directory succeeded")
	}
}
