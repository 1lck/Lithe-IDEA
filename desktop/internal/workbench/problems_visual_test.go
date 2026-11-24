//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
	"github.com/vivaui/viva/ui"
)

// TestVisualProblemsToolWindow captures the Problems tool window over two files' diagnostics:
// the File tab on the open file, the Project tab with the selected diagnostic's preview, and the
// View Options menu. Dark/light x Chinese/English are independent sessions and OS-free.
func TestVisualProblemsToolWindow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{
		{"dark", "zh-Hans"}, {"dark", "en"},
		{"light", "zh-Hans"}, {"light", "en"},
	} {
		t.Run(look.theme+"-"+look.language, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme: themeChoice(look.theme), Language: look.language,
				DisableAutoSave: true,
			}); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(t.TempDir(), "shop")
			folder := filepath.Join(root, "src", "main", "java", "shop")
			if err := os.MkdirAll(folder, 0700); err != nil {
				t.Fatal(err)
			}
			service := filepath.Join(folder, "OrderService.java")
			order := filepath.Join(folder, "Order.java")
			files := map[string]string{
				service: "package shop;\n\nimport java.util.List;\n\npublic class OrderService {\n    private final Inventory inventory;\n\n    public OrderService(Inventory inventory) {\n        this.inventory = inventory;\n    }\n\n    public int total(List<Order> orders) {\n        int count = 0;\n        int total = 0;\n        for (Order order : orders) {\n            total += order.price();\n        }\n        return total;\n    }\n}\n",
				order:   "package shop;\n\npublic record Order(String name, int price) {\n    public Order {\n        if (price < 0) throw new IllegalArgumentException();\n    }\n}\n",
			}
			for path, source := range files {
				if err := os.WriteFile(path, []byte(source), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()},
				Store:  prefs, Languages: []string{look.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(root)
			p := h.app.project
			servicePath, orderPath := "src/main/java/shop/OrderService.java", "src/main/java/shop/Order.java"
			h.app.pluginDiagnostics = map[string]*plugindiag.Set{"java": problemSet(t,
				plugindiag.Diagnostic{FileKey: service, DisplayPath: servicePath, Line: 5, Column: 18, EndLine: 5, EndColumn: 27, Severity: plugindiag.SeverityError, Message: "Inventory cannot be resolved to a type", Source: "Java"},
				plugindiag.Diagnostic{FileKey: service, DisplayPath: servicePath, Line: 12, Column: 12, EndLine: 12, EndColumn: 17, Severity: plugindiag.SeverityWarning, Message: "The value of the local variable count is not used", Source: "Java"},
				plugindiag.Diagnostic{FileKey: service, DisplayPath: servicePath, Line: 2, Column: 0, EndLine: 2, EndColumn: 22, Severity: plugindiag.SeverityInformation, Message: "Import 'List' could be on demand", Source: "Java"},
				plugindiag.Diagnostic{FileKey: order, DisplayPath: orderPath, Line: 4, Column: 24, EndLine: 4, EndColumn: 54, Severity: plugindiag.SeverityWarning, Message: "Exception has no message", Source: "Java"},
			)}
			h.app.markProblemsChanged()
			h.app.openFile(p, service)
			h.settleChain()

			// The File tab, which the window opens on, holds the open file's problems.
			openProblemsPanel(t, h)
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "problems-file-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}

			// The Project tab with the preview of the selected diagnostic.
			v := &h.app.problems
			h.clickNamed(problemsProjectTabText(h.app.language(), v.projectCount))
			awaitProblems(t, h)
			h.clickNamed(h.shared("desktop.problems.showPreview"))
			h.settleChain()
			h.clickNamed(problemsRowNamed(t, h, problemsDiagnosticRow(t, h, "The value of the local variable count is not used")))
			h.await("the diagnostic's preview", func() bool { return v.preview.view != nil && v.preview.path == service })
			h.settleChain()
			// A refreshed tree has yet to declare its rows when focus clears. Keep
			// the chosen diagnostic and the preview captured below.
			selected := v.selected
			v.focus = v.view.RowID(v.selectedRow)
			if v.focus.IsZero() {
				t.Fatal("the selected diagnostic has no painted identity")
			}
			v.view = ui.TreeState{}
			h.app.syncProblemsSelection(new(gfx.Canvas))
			if v.selected != selected {
				t.Fatalf("cleared focus selected %q, want %q", v.selected, selected)
			}
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "problems-project-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}

			// The View Options menu: which severities show and how the tree groups them.
			h.clickNamed(h.shared("desktop.problems.viewOptions"))
			h.settleChain()
			h.popupHit(h.shared("desktop.problems.group.severity"))
			if err := session.Screenshot(filepath.Join(out, "problems-options-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
