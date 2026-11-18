//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/vivaui/viva/headless"
)

// TestVisualManagedRuntimeInstall captures the actual production modal using inert dependency
// facts. It exercises every changed user-visible state without network or a concrete plugin.
func TestVisualManagedRuntimeInstall(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture runtime installation")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"dark", "light"} {
			for _, phase := range []string{"checking", "downloading", "repairing", "failed"} {
				t.Run(language.Code()+"/"+theme+"/"+phase, func(t *testing.T) {
					w := newWindow(NewController(Options{
						Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
						SystemLanguage: language, SystemDark: func() bool { return theme == "dark" },
						Marketplace: func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
					}), Values{Theme: theme, Language: language.Code()})
					w.sess.page = pagePlugins
					feedback := w.startPluginInstall("Example Support", true)
					t.Cleanup(w.dismissPluginInstall)
					feedback.Review("2.0.0", plugintrust.Review{}, true)
					feedback.RuntimeProgress(pluginruntime.Progress{ID: "engine", Phase: phase, Received: 48 << 20, Total: 192 << 20})
					if phase == "failed" {
						w.install.retry = func() {}
						feedback.Failure(errors.New("offline fixture"))
						feedback.Finish(true)
					}
					session, err := headless.Open(w.config(), nil, headless.Options{})
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(session.Close)
					driver := &windowDriver{t: t, w: w, driver: session.Driver()}
					driver.until("the runtime installation modal", func() bool { return driver.text("Example Support") })
					// Complete the modal's fade using the deterministic frame clock.
					if err := session.Advance(time.Second); err != nil {
						t.Fatal(err)
					}
					if err := session.Screenshot(filepath.Join(out, "runtime-"+phase+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				})
			}
		}
	}
}
