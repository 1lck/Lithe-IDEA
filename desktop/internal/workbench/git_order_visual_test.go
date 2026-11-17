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

// TestVisualGitStatusRequestOrder renders the latest branch and count after an older
// request completes. The controlled requests use the real workbench and Core reducers.
func TestVisualGitStatusRequestOrder(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				pref := t.TempDir()
				if err := os.WriteFile(filepath.Join(pref, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0600); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(pref), Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				root := filepath.Join(t.TempDir(), "Git-order-demo")
				if err := os.Mkdir(root, 0755); err != nil {
					t.Fatal(err)
				}
				h.open(root)
				p := h.app.project
				k := &gitStatusGate{Kernel: h.app.kernel, requests: make(chan chan gitStatusAnswer, 4)}
				h.app.kernel = k
				t.Cleanup(p.cancel)
				h.app.loadGit(p)
				older := k.next(t)
				h.app.loadGit(p)
				newer := k.next(t)
				newer <- gitStatusAnswer{status: gitOrderStatus(p, "latest-branch", 2)}
				h.await("latest branch", func() bool { return p.git.branch() == "latest-branch" })
				older <- gitStatusAnswer{status: gitOrderStatus(p, "stale-branch", 1)}
				h.settle()
				assertGitOrder(t, p, "latest-branch", 2)
				if !h.shows("latest-branch") {
					t.Fatal("latest branch missing from rendered workbench")
				}
				if err := session.Screenshot(filepath.Join(out, "git-order-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
