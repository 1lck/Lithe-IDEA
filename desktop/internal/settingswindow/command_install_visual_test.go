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
// Install button, and the install dialog it opens. Opt in with -tags 'vivahead lithevisual'
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
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			f := newFakeCommandInstaller()
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
			if err := session.Screenshot(filepath.Join(out, "command-install-card-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
			d.click(i18n.Shared(look.language, "desktop.marketplace.install"))
			prompt := i18n.SharedFormat(look.language, "desktop.plugins.commandInstallPrompt", map[string]string{"tool": "Builder", "commands": "fixture-ls"})
			d.until("the install offer", func() bool { return d.text(prompt) })
			// The dialog fades in; move the frame clock past it.
			if err := session.Advance(time.Second); err != nil {
				t.Fatal(err)
			}
			if err := session.Screenshot(filepath.Join(out, "command-install-dialog-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
