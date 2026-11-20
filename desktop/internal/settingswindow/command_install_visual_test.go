//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/headless"
)

// TestVisualCommandInstall renders a capability card whose command is missing, with its
// Install button, and the install dialog it opens, for a tool installer and for a download
// installer, whose download is also shown under way. Opt in with -tags 'vivahead lithevisual'
// and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualCommandInstall(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the command install dialog")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
		download bool
	}{{"dark", i18n.Chinese, false}, {"light", i18n.English, false}, {"dark", i18n.Chinese, true}, {"light", i18n.English, true}} {
		name := look.theme
		if look.download {
			name = "download-" + look.theme
		}
		t.Run(name, func(t *testing.T) {
			f := newFakeCommandInstaller()
			f.download = look.download
			t.Cleanup(func() {
				select {
				case <-f.release:
				default:
					close(f.release)
				}
			})
			facts := []PluginFacts{{
				ID: "dev.lithe.test.commands", Name: "Commands Fixture", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk,
				Permissions:  []string{"commands.install", "languageServer.launch"},
				Capabilities: []PluginCapability{{Kind: CapabilityLanguageServer, ID: "fixture", Title: "fixture-ls", Commands: []string{"fixture-ls"}}},
			}}
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				Marketplace:      func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
				InstalledPlugins: func() []PluginFacts { return facts },
				PluginState:      func(string) PluginState { return PluginState{Installed: true, Version: "1.0.0", Enabled: true} },
				CommandInstalls:  f,
			}), Values{Theme: look.theme, Language: look.language.Code()})
			w.sess.page = pagePlugins
			w.installed.tab = installedFeatures
			session, err := headless.Open(w.config(), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			missing := i18n.SharedFormat(look.language, "desktop.plugins.commandMissing", map[string]string{"commands": "fixture-ls"})
			d.until("the card to report the missing command", func() bool { return d.text(missing) })
			if !look.download {
				if err := session.Screenshot(filepath.Join(out, "command-install-card-"+name+".png")); err != nil {
					t.Fatal(err)
				}
			}
			d.click(i18n.Shared(look.language, "desktop.marketplace.install"))
			prompt := i18n.SharedFormat(look.language, "desktop.plugins.commandInstallPrompt", map[string]string{"tool": "Builder", "commands": "fixture-ls"})
			if look.download {
				prompt = i18n.SharedFormat(look.language, "desktop.plugins.commandInstallDownloadPrompt", map[string]string{"commands": "fixture-ls", "version": "1.2.3"})
			}
			d.until("the install offer", func() bool { return d.text(prompt) })
			// The dialog fades in; move the frame clock past it.
			if err := session.Advance(time.Second); err != nil {
				t.Fatal(err)
			}
			if err := session.Screenshot(filepath.Join(out, "command-install-dialog-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			if !look.download {
				return
			}
			d.click(i18n.Shared(look.language, "desktop.marketplace.install"))
			waitClosed(t, "the download to start", f.printed)
			downloading := i18n.SharedFormat(look.language, "desktop.marketplace.runtimeDownloading", map[string]string{"dependency": "fixture-ls", "received": "0.5", "total": "1.0"})
			d.until("the download's progress", func() bool { return d.text(downloading) })
			if err := session.Screenshot(filepath.Join(out, "command-install-progress-"+name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
