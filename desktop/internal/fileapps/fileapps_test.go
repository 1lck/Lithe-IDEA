package fileapps

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestListAnswersInTheSystemsOrder asks the real association database about a text file. Which
// applications a machine has is not fixed, so the test checks only what holds on any machine:
// no error, at most one default and it comes first, and every application can be handed back.
func TestListAnswersInTheSystemsOrder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.txt")
	if err := os.WriteFile(path, []byte("notes\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	apps, err := List(path)
	if err != nil {
		t.Fatalf("List(%q) failed: %v", path, err)
	}
	t.Logf("offered %+v", apps)
	for i, app := range apps {
		if app.ID == "" || app.Name == "" {
			t.Fatalf("application %d is %+v, want an ID and a name", i, app)
		}
		if app.Default && i != 0 {
			t.Fatalf("the default application is at %d, want it first: %+v", i, apps)
		}
		if runtime.GOOS == "darwin" && (!filepath.IsAbs(app.ID) || !strings.HasSuffix(app.ID, ".app")) {
			t.Fatalf("application %d is at %q, want an application bundle", i, app.ID)
		}
	}
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" && len(apps) != 0 {
		t.Fatalf("List offered %+v on %s, want no application", apps, runtime.GOOS)
	}
}

func TestListAndOpenRefuseARelativePath(t *testing.T) {
	if _, err := List("notes.txt"); err == nil {
		t.Fatal("List accepted a relative path")
	}
	if err := Open("notes.txt", App{ID: "editor", Name: "Editor"}); err == nil {
		t.Fatal("Open accepted a relative path")
	}
	if err := Open(filepath.Join(t.TempDir(), "notes.txt"), App{}); err == nil {
		t.Fatal("Open accepted an empty application")
	}
}

func TestLabelsAddTheLocationOnlyToSharedNames(t *testing.T) {
	apps := []App{
		{ID: "/Applications/Editor.app", Name: "Editor", Default: true},
		{ID: "/Applications/Viewer.app", Name: "Viewer"},
		{ID: "/Users/me/Applications/Editor.app", Name: "Editor"},
	}
	got := Labels(apps, func(name, path string) string { return name + " @ " + path })
	want := []string{
		"Editor @ /Applications/Editor.app",
		"Viewer",
		"Editor @ /Users/me/Applications/Editor.app",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("Labels = %q, want %q", got, want)
	}
	if got := Labels(nil, nil); len(got) != 0 {
		t.Fatalf("Labels(nil) = %q, want none", got)
	}
}
