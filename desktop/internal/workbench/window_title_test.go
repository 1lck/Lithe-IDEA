package workbench

import (
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

// Two open tabs of projects with the same folder name get the folder above them in the title,
// so the taskbar and Alt+Tab can tell the checkouts apart; a name nobody shares stays as it is.
func TestProjectDisplayNameTellsSameNamedProjectsApart(t *testing.T) {
	first := &App{project: &project{name: "app", root: filepath.Join("/work", "one", "app")}}
	second := &App{project: &project{name: "app", root: filepath.Join("/work", "two", "app")}}
	sessions := &windowSessions{list: []*App{first, second}}
	first.sessions, second.sessions = sessions, sessions

	if got, want := first.projectDisplayName(first.project), filepath.Join("one", "app"); got != want {
		t.Fatalf("first title = %q, want %q", got, want)
	}
	if got, want := second.projectDisplayName(second.project), filepath.Join("two", "app"); got != want {
		t.Fatalf("second title = %q, want %q", got, want)
	}

	alone := &App{project: &project{name: "app", root: filepath.Join("/work", "one", "app")}}
	alone.sessions = &windowSessions{list: []*App{alone}}
	if got := alone.projectDisplayName(alone.project); got != "app" {
		t.Fatalf("an unshared name = %q, want app", got)
	}
}

// A Linux file name need not be valid UTF-8, and Window.SetTitle refuses such a title and
// keeps the old one, so the title Lithe hands over replaces each invalid sequence and NUL
// with U+FFFD and leaves a valid title untouched.
func TestSystemTitleIsValidUTF8WithoutNUL(t *testing.T) {
	for _, test := range []struct{ title, want string }{
		{"app – main.go", "app – main.go"},
		{"app – caf\xe9.txt", "app – caf\uFFFD.txt"},
		{"app – a\x00b", "app – a\uFFFDb"},
	} {
		got := systemTitle(test.title)
		if got != test.want {
			t.Errorf("systemTitle(%q) = %q, want %q", test.title, got, test.want)
		}
		if !utf8.ValidString(got) || strings.IndexByte(got, 0) >= 0 {
			t.Errorf("systemTitle(%q) = %q, which Window.SetTitle refuses", test.title, got)
		}
	}
}
