//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileapps"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualProjectTreeOpenIn captures Open In of the Project tree: a file row's menu, its
// Open In and Open With submenus, with applications standing in for the system's (one name
// shared by two copies, as when an application is in /Applications and ~/Applications), and a
// folder row's Open In.
func TestVisualProjectTreeOpenIn(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	apps := []fileapps.App{
		{ID: "/System/Applications/TextEdit.app", Name: "TextEdit", Default: true},
		{ID: "/Applications/Visual Studio Code.app", Name: "Visual Studio Code"},
		{ID: "/Applications/Lithe.app", Name: "Lithe"},
		{ID: "/Users/me/Applications/Lithe.app", Name: "Lithe"},
		{ID: "/Applications/Xcode.app", Name: "Xcode"},
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []struct {
			id, row string
			// path is the submenus opened in turn, by their keys.
			path []string
		}{
			{"file-menu", "README.md", nil},
			{"file-open-in", "README.md", []string{"desktop.files.openIn"}},
			{"file-open-with", "README.md", []string{"desktop.files.openIn", "desktop.files.openWith"}},
			{"folder-open-in", "src", []string{"desktop.files.openIn"}},
		} {
			t.Run(scene.id+"-"+look.theme, func(t *testing.T) {
				root := filepath.Join(t.TempDir(), "demo")
				writeTreeFiles(t, root, "src/main.go", "README.md", "notes.txt")
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1100, 680
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				stubTreeApps(t, apps, nil)
				h.openTree(t, root)
				h.rightClickNamed(scene.row)
				for _, key := range scene.path {
					h.popupClick(h.shared(key))
				}
				h.settle()
				if err := session.Screenshot(filepath.Join(out, scene.id+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
