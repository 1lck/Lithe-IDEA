//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualInstalledPermissions renders the Permissions & Programs tab of a plugin that holds
// every permission of the linked plugin contract, in Chinese on the dark theme and in English
// on the light theme, so each description can be read beside its permission's name. Opt in
// with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualInstalledPermissions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Permissions & Programs tab")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	permissions := contractPermissions(t)
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			w, _, _ := detailFixture(look.language, func(opts *Options) {
				installed := opts.InstalledPlugins
				opts.InstalledPlugins = func() []PluginFacts {
					facts := installed()
					facts[0].Permissions = permissions
					return facts
				}
			})
			w.sess.values.Theme = look.theme
			config := w.config()
			config.Width, config.Height = 1100, 1760
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the marketplace index", func() bool { return w.market.status == marketReady })
			w.installed.tab = installedPermissions
			w.inv.Invalidate()
			last := permissions[len(permissions)-1]
			d.until("the last permission", func() bool { return d.text(last) })
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "installed-permissions-all-"+look.language.Code()+"-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestVisualAgentPermissions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture agent permissions")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	permissions := []string{"agents.run", "agents.native", "agents.sessions.read", "agents.usage.read"}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			w, fact, _ := detailFixture(look.language, func(opts *Options) {
				installed := opts.InstalledPlugins
				opts.InstalledPlugins = func() []PluginFacts {
					facts := installed()
					facts[0].Permissions = permissions
					return facts
				}
			})
			w.sess.values.Theme = look.theme
			config := w.config()
			config.Width, config.Height = 1100, 820
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("marketplace ready", func() bool { return w.market.status == marketReady })
			w.installed.tab = installedPermissions
			w.inv.Invalidate()
			for _, surface := range []string{"installed", "install-review"} {
				if surface == "install-review" {
					// The dialog must supply its own permission labels.
					w.installed.tab = installedVersions
					w.startPluginInstall(fact.Name, false)
					w.install.review.Store(&pluginInstallReview{version: fact.Version, permissions: permissions})
					w.inv.Invalidate()
					d.until("install confirmation", func() bool { return d.text(i18n.Shared(look.language, "desktop.marketplace.confirmInstall")) })
				}
				d.pump()
				d.until("agent usage permission", func() bool { return d.text("agents.usage.read") })
				// The snapshot exposes dialog controls even at the start of its fade-in.
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				labels := session.Driver().Snapshot().Labels
				var layer uint16
				if surface == "install-review" {
					layer = d.hit(i18n.Shared(look.language, "desktop.marketplace.confirmInstall")).Layer
				} else {
					for _, label := range labels {
						if label.Value == permissions[0] {
							layer = label.Layer
							break
						}
					}
				}
				// Wrapping splits a description into labels, including within Chinese words.
				var text strings.Builder
				for _, label := range labels {
					if label.Layer == layer {
						text.WriteString(strings.Join(strings.Fields(label.Value), ""))
					}
				}
				for _, id := range permissions {
					desc := permissionDescription(look.language, id)
					if desc == "" || desc == id || !d.text(id) {
						t.Fatalf("%s: missing permission or translation for %s", surface, id)
					}
					if !strings.Contains(text.String(), strings.Join(strings.Fields(desc), "")) {
						t.Fatalf("%s: missing visible description %q for %s", surface, desc, id)
					}
				}
				if err := session.Screenshot(filepath.Join(out, "agent-permissions-"+surface+"-"+look.language.Code()+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
