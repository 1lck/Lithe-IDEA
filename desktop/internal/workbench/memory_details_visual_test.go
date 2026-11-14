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

// TestVisualMemoryDetails captures the memory details above the status bar: an instance with a
// language server, system helpers and child processes, and one whose main process is all it holds.
func TestVisualMemoryDetails(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	only := core.MemorySummary{
		TotalBytes: 302 * mib,
		Categories: []core.MemoryCategory{{Kind: core.MemoryHost, Bytes: 302 * mib, ProcessCount: 1}},
	}
	for _, look := range []struct{ theme, language, empty string }{
		{"dark", "zh-Hans", "Lithe 目前没有启动其他进程。"},
		{"light", "en", "Lithe has not started any other process."},
	} {
		for _, scene := range []struct {
			id      string
			summary core.MemorySummary
			shows   string
		}{
			{"memory-details", memorySummaryFixture(), "Quill Tools · Quill"},
			{"memory-details-host-only", only, look.empty},
		} {
			t.Run(scene.id+"-"+look.theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				kernel := &memoryKernel{Client: core.NewClient(), summary: scene.summary}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.open(t.TempDir())
				h.await("the first reading", func() bool { return h.app.memory.read })
				openMemoryDetails(h, scene.shows)
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, scene.id+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
