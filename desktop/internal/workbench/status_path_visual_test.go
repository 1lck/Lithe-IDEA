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
	"github.com/vivaui/viva/headless"
)

// TestVisualStatusPath captures the status bar's navigation path as it follows the area the user
// clicked: the editor's file, a folder selected in the Project tool window, and the file of a
// problem selected in the Problems tool window. Dark/light x Chinese/English are independent
// sessions and OS-free.
func TestVisualStatusPath(t *testing.T) {
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
				service: "package shop;\n\npublic class OrderService {\n    public int total(Order order) {\n        return order.price();\n    }\n}\n",
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
			p := h.openTree(t, root)
			shot := func(scene string) {
				t.Helper()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "status-path-"+scene+"-"+look.theme+"-"+look.language+".png")); err != nil {
					t.Fatal(err)
				}
			}

			// The editor names its file.
			h.app.openFile(p, service)
			h.settleChain()
			d := p.docs.byPath(service)
			if d == nil {
				t.Fatal("the file did not open")
			}
			h.click(center(h.topHit(d.hit)))
			h.expectStatusPath("shop/src/main/java/shop/OrderService.java")
			shot("editor")

			// The Project tool window names the row selected in it: a click on a folder selects
			// and opens it.
			h.click(center(h.treeRowHit("src").Bounds))
			h.expectStatusPath("shop/src")
			shot("project")

			// The Problems tool window names the file of the problem selected in it.
			h.app.pluginDiagnostics = map[string]*plugindiag.Set{"demo": problemSet(t,
				plugindiag.Diagnostic{FileKey: service, DisplayPath: "src/main/java/shop/OrderService.java", Line: 3, Column: 21, EndLine: 3, EndColumn: 26, Severity: plugindiag.SeverityWarning, Message: "Parameter can be final", Source: "Demo"},
				plugindiag.Diagnostic{FileKey: order, DisplayPath: "src/main/java/shop/Order.java", Line: 4, Column: 24, EndLine: 4, EndColumn: 54, Severity: plugindiag.SeverityWarning, Message: "Exception has no message", Source: "Demo"},
			)}
			h.app.markProblemsChanged()
			h.app.problems.project = true
			openProblemsPanel(t, h)
			h.clickNamed(problemsRowNamed(t, h, problemsDiagnosticRow(t, h, "Exception has no message")))
			h.expectStatusPath("shop/src/main/java/shop/Order.java")
			shot("problems")
		})
	}
}
