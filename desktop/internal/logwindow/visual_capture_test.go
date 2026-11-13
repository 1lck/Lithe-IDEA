//go:build vivahead && lithevisual

package logwindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualLogs renders synthetic records through the production diagnostics Page.
func TestVisualLogs(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, dark := range []bool{true, false} {
		t.Run(map[bool]string{true: "dark", false: "light"}[dark], func(t *testing.T) {
			fixture := newExportFixture(t)
			fixture.model.started = true
			fixture.model.follows = false
			ctrl := NewController(WindowOptions{Text: func() *i18n.Messages { return i18n.For(i18n.Chinese) }, Dark: func() bool { return dark }})
			w := newWindow(ctrl, fixture.model)
			fixture.model.opts.Wake = w.inv.Invalidate
			fillRecords(fixture.model, 40)
			session, err := headless.Open(w.config(), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			if err := session.Screenshot(filepath.Join(out, "72-logs-"+map[bool]string{true: "dark", false: "light"}[dark]+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
