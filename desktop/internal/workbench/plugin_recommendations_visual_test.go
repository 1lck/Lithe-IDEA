//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualPluginWorkspaceRecommendations captures dark/light and Chinese/English frames of
// workspace plugin recommendations in the floating toast and the notification history popover.
func TestVisualPluginWorkspaceRecommendations(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}

	const recCatalog = `{
		"schemaVersion": 0,
		"recommendations": [
			{ "pluginID": "io.example.demo-build", "markers": ["demo.toml"] },
			{ "pluginID": "io.example.demo-lang", "extensions": ["demo"] }
		]
	}`

	for _, look := range []struct{ theme, language, langTag string }{
		{"dark", "zh-Hans", "zh"},
		{"light", "zh-Hans", "zh"},
		{"dark", "en", "en"},
		{"light", "en", "en"},
	} {
		t.Run(look.theme+"-"+look.langTag, func(t *testing.T) {
			workspace := t.TempDir()
			if err := os.WriteFile(filepath.Join(workspace, "demo.toml"), []byte("[build]\nname = \"demo\"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(workspace, "src"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(workspace, "src", "main.demo"), []byte("fn main() {}\n"), 0o644); err != nil {
				t.Fatal(err)
			}

			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme:           themeChoice(look.theme),
				Language:        look.language,
				DisableAutoSave: true,
			}); err != nil {
				t.Fatal(err)
			}

			catalog := syntheticRecommendationCatalog(t, recCatalog)
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel:    &testKernel{Client: core.NewClient()},
				Store:     prefs,
				Languages: []string{look.language},
				PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
					return []core.MarketplaceRecommendationCatalog{catalog}, nil
				},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.app.now = func() time.Time { return time.Date(2026, 11, 20, 14, 30, 0, 0, time.Local) }
			h.open(workspace)

			want := i18n.SharedFormat(h.app.language(), "desktop.marketplace.recommendedPlugins", map[string]string{
				"plugins": separatorJoinedDemo(h.app.language()),
			})
			awaitStateWithin(t, h, 5*time.Second, "recommendation notice", func() bool {
				return h.app.notice == want && len(h.app.notifications.list) == 1
			})
			h.settleChain()
			if (look.theme == "dark" && look.langTag == "zh") || (look.theme == "light" && look.langTag == "en") {
				if err := session.Screenshot(filepath.Join(out, "toast-"+look.theme+"-"+look.langTag+".png")); err != nil {
					t.Fatal(err)
				}
			}

			for _, entry := range h.app.notifications.list {
				h.app.overlay.toaster.Close(entry.toast)
			}
			h.app.invalidator.Invalidate()
			h.settleChain()
			bell := i18n.SharedFormat(h.app.language(), "desktop.notifications.unread", map[string]string{"count": "1"})
			h.clickNamed(bell)
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "notifications-popover-"+look.theme+"-"+look.langTag+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func separatorJoinedDemo(lang i18n.Language) string {
	if lang.Code() == "zh-Hans" || lang.Code() == "zh-CN" {
		return "Demo Build、Demo Lang"
	}
	return "Demo Build, Demo Lang"
}
