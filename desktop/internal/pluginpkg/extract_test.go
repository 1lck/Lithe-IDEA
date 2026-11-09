package pluginpkg

import (
	"archive/zip"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
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

// Windows exposes the read-only attribute through permission bits; Unix
// exposes the archive's owner/group/other permissions.
func extractedFilePermissions() fs.FileMode {
	if runtime.GOOS == "windows" {
		return 0o666
	}
	return 0o644
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
	if info.Mode().Perm() != extractedFilePermissions() {
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
	if info.Mode().Perm() != extractedFilePermissions() {
		t.Fatalf("on-disk mode = %v", info.Mode().Perm())
	}
}

func TestExtractAcceptsTheContractDirectoryLayout(t *testing.T) {
	const root = "io.github.lithe-idea.cargo-build"
	pkg, target, err := extractInto(t, []archiveEntry{
		{name: root + "/", mode: fs.ModeDir | 0o755},
		{name: root + "/plugin.json", body: []byte(`{"id":"io.github.lithe-idea.cargo-build"}`), mode: 0o644},
		{name: root + "/backend/main.mjs", body: []byte("export {};"), mode: 0o644},
		{name: root + "/templates/project/plugin.json.template", body: []byte("{}"), mode: 0o644},
	})
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if pkg.ContentRoot != root {
		t.Fatalf("content root = %q, want %q", pkg.ContentRoot, root)
	}
	want := []string{"backend/main.mjs", "plugin.json", "templates/project/plugin.json.template"}
	if len(pkg.Files) != len(want) {
		t.Fatalf("files = %+v", pkg.Files)
	}
	for i, path := range want {
		if pkg.Files[i].Path != path {
			t.Fatalf("file %d = %q, want %q", i, pkg.Files[i].Path, path)
		}
	}
	// The content root is the package, so the staging directory holds
	// plugin.json directly and no copy of the archive directory.
	if _, err := os.Stat(filepath.Join(target, ManifestFile)); err != nil {
		t.Fatalf("the manifest is not at the package root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(target, root)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the archive directory survived extraction: %v", err)
	}
}

func TestExtractAcceptsAFlatArchive(t *testing.T) {
	pkg, _, err := extractInto(t, []archiveEntry{
		{name: ManifestFile, body: []byte("{}"), mode: 0o644},
		{name: "backend/main.mjs", body: []byte("export {};"), mode: 0o644},
	})
	if err != nil {
		t.Fatalf("a flat archive was refused: %v", err)
	}
	if pkg.ContentRoot != "" {
		t.Fatalf("content root = %q, want the archive root", pkg.ContentRoot)
	}
}

func TestExtractRefusesAmbiguousOrEscapingLayouts(t *testing.T) {
	cases := []struct {
		name    string
		entries []archiveEntry
		want    error
	}{
		{"two content roots", []archiveEntry{
			{name: "first/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "second/plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrManifestAmbiguous},
		{"root manifest beside a directory manifest", []archiveEntry{
			{name: ManifestFile, body: []byte("{}"), mode: 0o644},
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrManifestAmbiguous},
		{"manifest deeper than the content root", []archiveEntry{
			{name: ManifestFile, body: []byte("{}"), mode: 0o644},
			{name: "templates/project/plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrManifestAmbiguous},
		{"manifest spelled with an uppercase letter", []archiveEntry{
			{name: "package/Plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrManifestAmbiguous},
		{"sibling file beside the content root", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "README.md", body: []byte("notes"), mode: 0o644},
		}, ErrOutsideContentRoot},
		{"sibling directory beside the content root", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "other/", mode: fs.ModeDir | 0o755},
		}, ErrOutsideContentRoot},
		{"content root is also a file", []archiveEntry{
			{name: "package", body: []byte("x"), mode: 0o644},
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
		}, ErrPathConflict},
		{"nested parent segment", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "package/../escape.txt", body: []byte("x"), mode: 0o644},
		}, ErrUnsafePath},
		{"nested symbolic link", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "package/link", body: []byte("/etc/passwd"), mode: fs.ModeSymlink | 0o777},
		}, ErrSymbolicLink},
		{"nested duplicate differing in case", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "package/lib/a.txt", body: []byte("x"), mode: 0o644},
			{name: "package/lib/A.txt", body: []byte("y"), mode: 0o644},
		}, ErrDuplicatePath},
		{"nested file used as a directory", []archiveEntry{
			{name: "package/plugin.json", body: []byte("{}"), mode: 0o644},
			{name: "package/lib", body: []byte("x"), mode: 0o644},
			{name: "package/lib/a.txt", body: []byte("y"), mode: 0o644},
		}, ErrPathConflict},
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
		{"manifest two directories down", []archiveEntry{
			{name: "sub/nested/plugin.json", body: []byte("{}"), mode: 0o644},
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

func TestExtractReportsAFileSystemNameCollision(t *testing.T) {
	// Two spellings of one name that the package treats as distinct but a
	// normalising file system collapses.
	_, target, err := extractInto(t, []archiveEntry{
		{name: ManifestFile, body: []byte("{}"), mode: 0o644},
		{name: "caf\u00e9.txt", body: []byte("a"), mode: 0o644},
		{name: "cafe\u0301.txt", body: []byte("b"), mode: 0o644},
	})
	if err == nil {
		// A file system that keeps both forms apart extracts both, which is not a
		// collision to report.
		t.Skip("this file system keeps both normalisation forms apart")
	}
	if !errors.Is(err, ErrDuplicatePath) {
		t.Fatalf("err = %v", err)
	}
	if _, statErr := os.Stat(target); !errors.Is(statErr, fs.ErrNotExist) {
		t.Fatalf("a refused extraction left its directory behind: %v", statErr)
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

func TestExtractRefusesNonEmptyDirectory(t *testing.T) {
	archive := writeArchive(t, []archiveEntry{{name: ManifestFile, body: []byte("{}"), mode: 0o644}})
	target := filepath.Join(t.TempDir(), "package")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "leftover"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Extract(archive, target); !errors.Is(err, ErrStagingNotEmpty) {
		t.Fatalf("err = %v", err)
	}
}

func TestExtractAcceptsEmptyExistingDirectory(t *testing.T) {
	archive := writeArchive(t, []archiveEntry{{name: ManifestFile, body: []byte("{}"), mode: 0o644}})
	target := filepath.Join(t.TempDir(), "package")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Extract(archive, target); err != nil {
		t.Fatalf("extract: %v", err)
	}
}
