//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualStashTabCopy captures the Commit tool window Stash tab in dark Chinese
// and light English so reviewers can verify the "贮藏" tab and empty state copy (#2406).
func TestVisualStashTabCopy(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name     string
		theme    string
		language string
	}{
		{name: "dark-zh", theme: "dark", language: "zh-Hans"},
		{name: "light-en", theme: "light", language: "en-US"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := newTestRepository(t)
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": tc.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel:    &gitKernel{Client: core.NewClient()},
				Store:     prefs,
				Languages: []string{tc.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 960, 620
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			p := h.openCommit(dir)
			lang := h.app.language()
			h.clickNamed(i18n.Shared(lang, "native.stash"))
			h.settle()
			h.await("the stashes", func() bool { return p.stash.loaded })
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "stash-tab-"+tc.name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
