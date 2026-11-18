//go:build vivahead && lithevisual

package logwindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

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
			look := map[bool]string{true: "dark", false: "light"}[dark]
			if err := session.Screenshot(filepath.Join(out, "72-logs-"+look+".png")); err != nil {
				t.Fatal(err)
			}
			// Resting on the channel list's ⓘ shows its help in the client's shared tip.
			help := w.text.Logs.ChannelHelp
			rested := false
			for _, hit := range session.Driver().Snapshot().Hits {
				if hit.Hint == help && !hit.IsLabel {
					if err := session.Driver().Move(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
						t.Fatal(err)
					}
					rested = true
					break
				}
			}
			if !rested {
				t.Fatal("the channel list has no ⓘ")
			}
			if err := session.Advance(time.Second); err != nil {
				t.Fatal(err)
			}
			if err := session.Screenshot(filepath.Join(out, "73-logs-channel-tip-"+look+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
