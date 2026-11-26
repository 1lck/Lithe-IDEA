//go:build vivahead && lithevisual

package logwindow

import (
	"os"
	"path/filepath"
	"strings"
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

// TestVisualLogSidebarEllipsis captures a plugin's channel the sidebar cuts short with its full
// name shown to its right, over the table.
func TestVisualLogSidebarEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, dark := range []bool{true, false} {
			look := map[bool]string{true: "dark", false: "light"}[dark] + "-" + language.Code()
			t.Run(look, func(t *testing.T) {
				fixture := newExportFixture(t)
				fixture.model.started, fixture.model.follows = true, false
				fillRecords(fixture.model, 40)
				addChannel(fixture.model, longChannel)
				w := newWindow(NewController(WindowOptions{Text: func() *i18n.Messages { return i18n.For(language) }, Dark: func() bool { return dark }}), fixture.model)
				fixture.model.opts.Wake = w.inv.Invalidate
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				driver := session.Driver()
				settleWindow(t, driver)
				full := "■ " + sidebarTitle(longChannel)
				text := cutSidebarChannel(t, driver, full)
				if err := driver.Move(text.X+text.Width/2, text.Y+text.Height/2); err != nil {
					t.Fatal(err)
				}
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				if got := tableTooltipText(driver); got != full {
					t.Fatalf("channel tooltip %q, want %q", got, full)
				}
				if err := session.Screenshot(filepath.Join(out, "ellipsis-log-sidebar-hover-"+look+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// The records are test inputs rendered by the production table, with the actual
// pointer and frame clock driving the full-text tooltip.
func TestVisualLogEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, dark := range []bool{true, false} {
			look := map[bool]string{true: "dark", false: "light"}[dark] + "-" + language.Code()
			t.Run(look, func(t *testing.T) {
				fixture := newExportFixture(t)
				fixture.model.started, fixture.model.follows = true, false
				fillRecords(fixture.model, 4)
				full := "Workspace indexing: " + strings.Repeat("/workspace/完整项目路径", 8) + "/source.go"
				fixture.model.records[0].Msg = full
				fixture.model.records[0].Fields = map[string]string{"path": strings.Repeat("/workspace/long-directory", 7) + "/source.go"}
				fixture.model.prefs.Hidden = []string{"channel", "event"}
				w := newWindow(NewController(WindowOptions{Text: func() *i18n.Messages { return i18n.For(language) }, Dark: func() bool { return dark }}), fixture.model)
				fixture.model.opts.Wake = w.inv.Invalidate
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				driver := session.Driver()
				settleWindow(t, driver)
				shot := func(scene string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "ellipsis-log-"+scene+"-"+look+".png")); err != nil {
						t.Fatal(err)
					}
				}
				shot("before-hover")
				found := false
				for _, label := range driver.Snapshot().Labels {
					if strings.HasPrefix(label.Value, "Workspace") && strings.HasSuffix(label.Value, "…") {
						if err := driver.Move(label.Bounds.X+5, label.Bounds.Y+label.Bounds.Height/2); err != nil {
							t.Fatal(err)
						}
						found = true
						break
					}
				}
				if !found {
					t.Fatal("the table did not shorten the long message")
				}
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				if got := tableTooltipText(driver); got != full {
					t.Fatalf("message tooltip %q, want %q", got, full)
				}
				shot("message-hover")
				if err := driver.Move(centerOf(hitLabeled(t, driver, "path"))); err != nil {
					t.Fatal(err)
				}
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				if got, want := tableTooltipText(driver), `path="`+fixture.model.records[0].Fields["path"]+`"`; got != want {
					t.Fatalf("field tooltip %q, want %q", got, want)
				}
				shot("field-hover")
			})
		}
	}
}
