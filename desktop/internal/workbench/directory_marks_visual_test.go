//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualDirectoryMarkContextMenu captures the Project tree's "Mark Directory as ▸"
// second-level submenu including built-in role icons, the default Archive & Read-Only custom
// mode, and the inline 7-swatch quick color strip in both dark/light themes and zh-Hans/en.
func TestVisualDirectoryMarkContextMenu(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{
		{"dark", "zh-Hans"},
		{"light", "zh-Hans"},
		{"dark", "en"},
		{"light", "en"},
	} {
		t.Run(look.language+"-"+look.theme, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "lithe-shop")
			writeTreeFiles(t, root,
				"src/main.go",
				"src/service/order.go",
				"tests/main_test.go",
				"docs/README.md",
				"target/app.jar",
			)
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme:           themeChoice(look.theme),
				Language:        look.language,
				DisableAutoSave: true,
			}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel:    &testKernel{Client: core.NewClient()},
				Store:     prefs,
				Languages: []string{look.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 960, 620
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.openTree(t, root)
			// Seed visible directory marks (including an excluded subtree and a quick-colored
			// folder) and expand branches so the screenshot verifies continuous full-width
			// subtree background tinting + direct icon/name tinting alongside the context menu.
			h.app.setDirectoryRole(h.app.project, "src", "sources")
			h.settle()
			h.app.setDirectoryRole(h.app.project, "tests", "tests")
			h.settle()
			h.app.setDirectoryColor(h.app.project, "docs", "#8b5cf6")
			h.settle()
			h.app.excludeFromSearch(h.app.project, "target", false)
			h.settle()
			for _, name := range []string{"src", "tests", "target"} {
				for _, node := range h.app.project.tree.rows {
					if node.path == name {
						h.app.toggleFolder(h.app.project, node)
						h.settle()
						break
					}
				}
			}
			h.rightClickNamed("src")
			h.popupClick(h.shared("desktop.directoryMarks.menuTitle"))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "directory-mark-menu-"+look.language+"-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// TestVisualDirectoryMarkContextMenuWithPluginTypes captures the same submenu while a plugin
// session has registered a directory type, which adds the plugin group users can pick from.
func TestVisualDirectoryMarkContextMenuWithPluginTypes(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{
		{"dark", "zh-Hans"},
		{"light", "zh-Hans"},
		{"dark", "en"},
		{"light", "en"},
	} {
		t.Run(look.language+"-"+look.theme, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "lithe-shop")
			writeTreeFiles(t, root, "src/main.go", "tests/main_test.go", "gen/out.go")
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme:           themeChoice(look.theme),
				Language:        look.language,
				DisableAutoSave: true,
			}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel:    &testKernel{Client: core.NewClient()},
				Store:     prefs,
				Languages: []string{look.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 960, 700
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			p := h.openTree(t, root)
			p.indexing.pluginTypesByKey = map[string][]core.PluginDirectoryType{
				"session:context:directoryTypes": {{
					PluginID:        "dev.lithe.test.generated",
					ID:              "plugin.generated-cache",
					Name:            "Generated Cache",
					Icon:            "generated",
					Color:           "#64748b",
					ExcludeIndexing: true,
				}},
			}
			h.rightClickNamed("gen")
			h.popupClick(h.shared("desktop.directoryMarks.menuTitle"))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "directory-mark-menu-plugin-"+look.language+"-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
