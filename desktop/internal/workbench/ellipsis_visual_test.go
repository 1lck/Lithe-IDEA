//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// ellipsisLooks are the theme and language pairs every ellipsis capture is taken in.
var ellipsisLooks = []struct{ theme, language string }{
	{"dark", "zh-Hans"}, {"dark", "en"}, {"light", "zh-Hans"}, {"light", "en"},
}

// ellipsisVisual opens a headless window of the default size in theme and language and returns it
// with a function that saves the window as name-scene-theme-language.png in the visual output
// directory.
func ellipsisVisual(t *testing.T, kernel Kernel, theme, language, name string) (*harness, *headless.Session, func(scene string)) {
	t.Helper()
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}},
		func(config app.Config) (*app.Driver, func(), error) {
			var err error
			session, err = headless.Open(config, nil, headless.Options{})
			if err != nil {
				return nil, nil, err
			}
			return session.Driver(), session.Close, nil
		})
	shot := func(scene string) {
		t.Helper()
		if err := session.Screenshot(filepath.Join(out, name+"-"+scene+"-"+theme+"-"+language+".png")); err != nil {
			t.Fatal(err)
		}
	}
	return h, session, shot
}

// hoverForTip rests the pointer at point long enough for the tooltip delay and returns the
// text of its tooltip lines joined in order.
func hoverForTip(t *testing.T, h *harness, session *headless.Session, point gfx.Point) string {
	t.Helper()
	if err := h.driver.Move(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	if err := session.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	var tip strings.Builder
	for _, label := range h.tooltips() {
		tip.WriteString(label.Value)
	}
	return tip.String()
}

// TestVisualGitLogEllipsis captures a commit subject the Git log shortens, before the pointer
// rests on it and with its full subject shown.
func TestVisualGitLogEllipsis(t *testing.T) {
	for _, look := range ellipsisLooks {
		t.Run(look.theme+"-"+look.language, func(t *testing.T) {
			h, session, shot := ellipsisVisual(t, gitKernel{core.NewClient()}, look.theme, look.language, "ellipsis-gitlog")
			dir := newTestRepository(t)
			full := strings.Repeat("完整提交说明-long-subject-", 10) + "end"
			gitRun(t, dir, "commit", "--allow-empty", "-m", full)
			h.openLog(t, dir)
			var text gfx.Rect
			for _, label := range h.driver.Snapshot().Labels {
				if strings.HasPrefix(label.Value, "完整提交") && strings.HasSuffix(label.Value, "…") {
					text = label.Bounds
					break
				}
			}
			if text.Width == 0 {
				t.Fatal("the commit subject was not ellipsized")
			}
			shot("before-hover")
			if got := hoverForTip(t, h, session, gfx.Point{X: text.X + 5, Y: text.Y + text.Height/2}); got != full {
				t.Fatalf("commit tooltip %q, want %q", got, full)
			}
			shot("subject-hover")
		})
	}
}

// TestVisualCommitEllipsisSides captures a path the Commit tool window cuts short with its full
// text shown, with the window docked on the left, on the right and in the bottom area: each opens
// it toward the editor.
func TestVisualCommitEllipsisSides(t *testing.T) {
	for _, dock := range commitDocks {
		for _, look := range ellipsisLooks {
			t.Run(dock.name+"-"+look.theme+"-"+look.language, func(t *testing.T) {
				h, session, shot := ellipsisVisual(t, gitKernel{core.NewClient()}, look.theme, look.language, "ellipsis-commit-"+dock.name)
				repo := deepChangeRepository(t, commitDockDir)
				text := h.openCommitIn(repo, dock.zone, dock.in)
				if got := hoverForTip(t, h, session, center(text)); got != commitDockDir {
					t.Fatalf("path tooltip %q, want %q", got, commitDockDir)
				}
				shot("path-hover")
			})
		}
	}
}

// TestVisualTrustEllipsis captures the trust question's "trust the parent folder" checkbox with a
// location too long for its line, before the pointer rests on it and with the full location shown.
func TestVisualTrustEllipsis(t *testing.T) {
	for _, look := range ellipsisLooks {
		t.Run(look.theme+"-"+look.language, func(t *testing.T) {
			h, session, shot := ellipsisVisual(t, &testKernel{Client: core.NewClient()}, look.theme, look.language, "ellipsis-trust")
			h.app.trustEveryWorkspace = false
			dir := filepath.Join(t.TempDir(), strings.Repeat("long-directory-", 6), "project")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			prompt := openAsking(t, h, dir)
			full := i18n.SharedFormat(h.app.language(), "desktop.trust.location", map[string]string{"folder": filepath.Dir(dir)})
			if prompt.checkFull != full || !strings.Contains(prompt.check, "…") {
				t.Fatalf("the shortened trust label %q lost its full location %q", prompt.check, prompt.checkFull)
			}
			shot("before-hover")
			got := hoverForTip(t, h, session, center(h.hitLabeled(prompt.check)))
			if strings.Join(strings.Fields(got), "") != strings.Join(strings.Fields(full), "") {
				t.Fatalf("trust tooltip %q, want %q", got, full)
			}
			shot("location-hover")
		})
	}
}
