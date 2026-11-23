//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/cli"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileassociations"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

func TestVisualFileAssociations(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"-"+theme, func(t *testing.T) {
				// These are actual, read-only OS observations. The test never applies defaults.
				launcher := cli.New()
				launcher.Directory = filepath.Join(t.TempDir(), "bin")
				w := newWindow(NewController(Options{
					CLI: launcher, FileAssociations: fileassociations.New(),
					Text:     func() *i18n.Messages { return i18n.For(language) },
					Language: func() i18n.Language { return language }, SystemLanguage: language,
					SystemDark: func() bool { return theme == "dark" },
				}), Values{Theme: theme, Language: language.Code()})
				config := w.config()
				config.Width, config.Height = 1120, 820
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.pump()
				await := func() {
					t.Helper()
					deadline := time.NewTimer(5 * time.Second)
					defer deadline.Stop()
					for w.associations.request != nil || w.cli.request != nil {
						select {
						case <-d.driver.Wakes():
							d.pump()
						case <-deadline.C:
							t.Fatal("native association read timed out")
						}
					}
					if w.associations.err != nil {
						t.Fatal(w.associations.err)
					}
				}
				await()
				s := &w.associations
				if !s.loaded || len(s.state.Formats) < 2 || len(s.state.Formats) != len(s.state.Handlers) {
					t.Fatal("actual OS handler list missing")
				}
				first := s.state.Formats[0].Extension
				d.click(first)
				d.pump()
				if !s.picked[first] {
					t.Fatal("format checkbox did not retain selection")
				}
				// List containers expose accessibility metadata rather than a clickable
				// control. A real visible checkbox supplies the wheel event position.
				listAccessible := false
				for _, hit := range d.driver.Snapshot().Hits {
					if hit.Role == gfx.RoleListBox && hit.Label == i18n.Shared(language, "desktop.associations.formats") {
						listAccessible = true
					}
				}
				if !listAccessible {
					t.Fatal("format list has no accessible name")
				}
				firstHit := d.hit(first)
				scroll := func(delta float32) {
					t.Helper()
					if err := d.driver.Scroll(gfx.ScrollEvent{X: firstHit.Bounds.X + firstHit.Bounds.Width/2, Y: firstHit.Bounds.Y + firstHit.Bounds.Height/2, DeltaY: delta, Precise: true}); err != nil {
						t.Fatal(err)
					}
					d.pump()
				}
				last := s.state.Formats[len(s.state.Formats)-1].Extension
				if d.has(last) {
					t.Fatal("offscreen formats were all instantiated")
				}
				scroll(100000)
				if !d.has(last) {
					t.Fatal("mouse wheel did not reach the final format")
				}
				scroll(-100000)
				if !s.picked[first] || !d.has(first) {
					t.Fatal("scrolling lost checkbox selection")
				}
				d.click(i18n.Shared(language, "desktop.associations.selectAll"))
				d.pump()
				if len(s.picked) != len(s.state.Formats) {
					t.Fatal("select all omitted virtualized formats")
				}
				if err := session.Screenshot(filepath.Join(out, "file-associations-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
				d.click(i18n.Shared(language, "desktop.associations.clearSelection"))
				d.pump()
				if len(s.picked) != 0 {
					t.Fatal("clear selection retained a draft")
				}
				d.click(i18n.Shared(language, "desktop.associations.refresh"))
				d.pump()
				await()
			})
		}
	}
}
