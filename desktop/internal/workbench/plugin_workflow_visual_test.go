//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualPluginWorkflow captures the actual native surfaces reached by the
// generic host API. The input is synthetic; no installed plugin is required.
func TestVisualPluginWorkflow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1100, 720
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				root := t.TempDir()
				h.open(root)
				screenshot := func(scene string) {
					t.Helper()
					h.settleChain()
					if err := session.Screenshot(filepath.Join(out, scene+"-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
				screenshot("workflow-before")
				w := pluginWorkbench{app: h.app}
				if _, err := callOnWindow(h, "Markdown preview", func(ctx context.Context) (pluginservice.PreviewResult, error) {
					return w.OpenPreview(ctx, root, pluginservice.PreviewRequest{PluginID: "dev.lithe.test.workflow", Owner: "visual:context", ID: "guide", Title: "Workflow", Text: "# Workflow\n\nRead-only plugin content.\n\n- Stable resource identity\n- Session and context isolation\n\n```go\nfmt.Println(42)\n```", Kind: "Markdown", Presentation: "editorAndPreview"})
				}); err != nil {
					t.Fatal(err)
				}
				for _, update := range []pluginservice.OutputUpdate{
					{ID: "output", Name: "Workflow output", Action: "create"},
					{ID: "output", Action: "append", Lines: []string{"Preparing request", "Response received: 200", "Completed"}, MaxLines: 4000, MaxBytes: 512 * 1024},
					{ID: "output", Action: "show"},
				} {
					if err := callOnWindowErr(h, "output", func(ctx context.Context) error { return w.UpdateOutput(ctx, root, update) }); err != nil {
						t.Fatal(err)
					}
				}
				if err := callOnWindowErr(h, "status", func(ctx context.Context) error {
					return w.UpdateStatus(ctx, root, pluginservice.StatusUpdate{ID: "status", Text: "Ready", Tooltip: "Workflow status"})
				}); err != nil {
					t.Fatal(err)
				}
				percentage := 65.0
				if err := callOnWindowErr(h, "progress", func(ctx context.Context) error {
					return w.UpdateProgress(ctx, root, pluginservice.ProgressUpdate{ID: "progress", Title: "Indexing", Message: "Reading results", Percentage: &percentage, Cancellable: true, Cancel: func() {}})
				}); err != nil {
					t.Fatal(err)
				}
				screenshot("workflow-output-preview")
				h.clickNamed(h.shared("desktop.pluginHost.backgroundTasks"))
				if !h.shows("Indexing 65%") {
					t.Fatal("background task menu did not open")
				}
				screenshot("workflow-progress-menu")
				h.key(gfx.KeyEscape)
				if err := callOnWindowErr(h, "text diff", func(ctx context.Context) error {
					return w.ShowTextDiff(ctx, root, pluginservice.DiffRequest{Title: "Comparison", Original: "first\nunchanged\n", Modified: "updated\nunchanged\n"})
				}); err != nil {
					t.Fatal(err)
				}
				screenshot("workflow-readonly-diff")
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				defer cancel()
				done := make(chan error, 1)
				go func() {
					_, err := w.QuickInput(ctx, root, pluginservice.QuickInput{
						Title: "Choose an item", Pick: true, CanPickMany: true,
						Items:    []pluginservice.QuickItem{{ID: "first", Label: "First item", Description: "Available", Picked: true}, {ID: "second", Label: "Second item", Description: "Available"}},
						Validate: func(context.Context, string) (bool, error) { return true, nil },
						Filter:   func(context.Context, string) ([]int, error) { return []int{0, 1}, nil },
					})
					done <- err
				}()
				h.await("quick pick ready", func() bool { return len(h.app.prompts.queue) > 0 && h.app.prompts.queue[0].quick.ready })
				screenshot("workflow-quick-pick")
				h.app.answerPrompt(nil)
				select {
				case err := <-done:
					if err != nil {
						t.Fatal(err)
					}
				case <-ctx.Done():
					t.Fatal("quick pick did not close")
				}
			})
		}
	}
}
