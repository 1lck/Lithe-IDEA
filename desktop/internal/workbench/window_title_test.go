package workbench

import (
	"path/filepath"
	"testing"
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
