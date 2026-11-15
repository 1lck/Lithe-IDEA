package workbench

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

var pastedPicture = []byte("\x89PNG\r\n\x1a\npicture")

// A picture is saved to a new private file of its own, and the pictures older than a week
// beside it go; the new one, newer ones and other files stay.
func TestSavePastedImageWritesAPrivateFileAndTidies(t *testing.T) {
	folder := filepath.Join(t.TempDir(), "paste")
	now := time.Date(2026, 11, 16, 9, 30, 0, 0, time.UTC)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(folder, "paste-20261101-080000-1.png")
	recent := filepath.Join(folder, "paste-20261115-080000-2.png")
	other := filepath.Join(folder, "notes.txt")
	for _, path := range []string{old, recent, other} {
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for path, age := range map[string]time.Duration{old: 8 * 24 * time.Hour, recent: 24 * time.Hour, other: 30 * 24 * time.Hour} {
		if err := os.Chtimes(path, now.Add(-age), now.Add(-age)); err != nil {
			t.Fatal(err)
		}
	}

	path, err := savePastedImage(func() (string, error) { return folder, nil }, pastedPicture, now)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != folder || !strings.HasPrefix(filepath.Base(path), "paste-20261116-093000-") || filepath.Ext(path) != ".png" {
		t.Fatalf("saved as %q", path)
	}
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, pastedPicture) {
		t.Fatalf("saved %q, %v", data, err)
	}
	if runtime.GOOS != "windows" {
		for target, want := range map[string]os.FileMode{folder: 0o700, path: 0o600} {
			if info, err := os.Stat(target); err != nil || info.Mode().Perm() != want {
				t.Fatalf("%s mode %v, %v; want %v", target, info.Mode().Perm(), err, want)
			}
		}
	}
	if _, err := os.Stat(old); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a week-old picture stayed: %v", err)
	}
	for _, kept := range []string{recent, other} {
		if _, err := os.Stat(kept); err != nil {
			t.Fatalf("%s was removed: %v", kept, err)
		}
	}
}

// A folder that cannot be had leaves no file and says why.
func TestSavePastedImageReportsAMissingFolder(t *testing.T) {
	blocked := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if path, err := savePastedImage(func() (string, error) { return filepath.Join(blocked, "paste"), nil }, pastedPicture, time.Now()); err == nil {
		t.Fatalf("saved into a path under a file: %q", path)
	}
	if _, err := savePastedImage(func() (string, error) { return "", errors.New("no cache") }, pastedPicture, time.Now()); err == nil {
		t.Fatal("no cache folder was no error")
	}
}

// The path is one word for the shell it is typed into.
func TestQuotePastedPath(t *testing.T) {
	tests := []struct {
		name, path, distro, goos, want string
	}{
		{"plain", "/Users/me/Library/Caches/Lithe/terminal-paste/paste-1.png", "", "darwin",
			"/Users/me/Library/Caches/Lithe/terminal-paste/paste-1.png"},
		{"space and quote", "/Users/my name/it's.png", "", "darwin", `/Users/my\ name/it\'s.png`},
		{"letters kept", "/home/张三/图.png", "", "linux", "/home/张三/图.png"},
		{"windows", `C:\Users\me\AppData\Local\Lithe\terminal-paste\paste-1.png`, "", "windows",
			`"C:\Users\me\AppData\Local\Lithe\terminal-paste\paste-1.png"`},
		{"wsl", `C:\Users\me\it's.png`, "Ubuntu", "windows", `'/mnt/c/Users/me/it'\''s.png'`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := quotePastedPath(test.path, test.distro, test.goos); got != test.want {
				t.Fatalf("quoted %q, want %q", got, test.want)
			}
		})
	}
}

// pasteTerminal opens a terminal whose program echoes what is typed, with the clipboard and
// the cache folder of the test.
func pasteTerminal(t *testing.T, read func() ([]byte, error)) (*harness, *terminal, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	folder := t.TempDir()
	h.app.clipboardImage = read
	h.app.pasteDirectory = func() (string, error) { return folder, nil }
	p := h.app.project
	term := h.app.newTerminalWith(p, terminalOptions{shell: "/bin/sh", args: []string{"-c", "cat"}, dir: p.root, activate: true})
	if term == nil {
		t.Fatal("the terminal was not opened")
	}
	term.view.Start()
	return h, term, folder
}

// A paste that finds a picture saves it and types the saved file's path at the prompt, and a
// second paste while the first is saved is taken without a second file.
func TestPastingAPictureTypesItsSavedPath(t *testing.T) {
	h, term, folder := pasteTerminal(t, func() ([]byte, error) { return pastedPicture, nil })
	if !h.app.pasteTerminalImage(h.app.project, term) {
		t.Fatal("a picture paste was not taken")
	}
	if !h.app.pasteTerminalImage(h.app.project, term) {
		t.Fatal("a second paste while saving went through as an empty paste")
	}
	prefix := quotePastedPath(folder, "", runtime.GOOS) + string(filepath.Separator) + "paste-"
	awaitStateWithin(t, h, 10*time.Second, "the saved path to be typed", func() bool {
		term.view.Pump()
		return strings.Contains(term.view.RetainedText(1<<16), prefix)
	})
	if term.pastingImage {
		t.Fatal("the terminal still waits for its picture")
	}
	entries, err := os.ReadDir(folder)
	if err != nil || len(entries) != 1 {
		t.Fatalf("the folder holds %v, %v; want one picture", entries, err)
	}
	if data, err := os.ReadFile(filepath.Join(folder, entries[0].Name())); err != nil || !bytes.Equal(data, pastedPicture) {
		t.Fatalf("saved %q, %v", data, err)
	}
}

// No picture leaves the paste as it was; a picture too large, or a clipboard that cannot be
// read, takes the paste and says why.
func TestPictureThatCannotBePastedSaysWhy(t *testing.T) {
	tests := []struct {
		name    string
		err     error
		taken   bool
		message string
	}{
		{"no picture", app.ErrNoImage, false, ""},
		{"unsupported", app.ErrUnsupported, false, ""},
		{"too large", app.ErrTooLarge, true, "The clipboard image is too large to paste."},
		{"unreadable", errors.New("pasteboard busy"), true, "Could not save the clipboard image: pasteboard busy"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h, term, folder := pasteTerminal(t, func() ([]byte, error) { return nil, test.err })
			if got := h.app.pasteTerminalImage(h.app.project, term); got != test.taken {
				t.Fatalf("taken = %v, want %v", got, test.taken)
			}
			var errorsShown []string
			for _, entry := range h.app.notifications.list {
				if entry.kind == ui.ToastError {
					errorsShown = append(errorsShown, entry.text)
				}
			}
			if test.message == "" && len(errorsShown) != 0 || test.message != "" && (len(errorsShown) != 1 || errorsShown[0] != test.message) {
				t.Fatalf("errors shown %q, want %q", errorsShown, test.message)
			}
			if term.pastingImage {
				t.Fatal("a paste with no picture waits for one")
			}
			if entries, _ := os.ReadDir(folder); len(entries) != 0 {
				t.Fatalf("a paste with no picture saved %v", entries)
			}
		})
	}
}

// A terminal closed while its picture is saved gets nothing typed and no message.
func TestPictureForAClosedTerminalIsDropped(t *testing.T) {
	h, term, _ := pasteTerminal(t, func() ([]byte, error) { return pastedPicture, nil })
	p := h.app.project
	h.app.closeTerminal(p, term.id)
	h.app.finishTerminalImage(p, term, "/tmp/paste-1.png", "", errors.New("late"))
	if term.pastingImage {
		t.Fatal("the flag stayed on")
	}
	for _, entry := range h.app.notifications.list {
		if entry.kind == ui.ToastError {
			t.Fatalf("a closed terminal's picture reported %q", entry.text)
		}
	}
}
