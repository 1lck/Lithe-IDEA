//go:build vivahead

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualUpdatesPage captures the update card of Settings > About: a stable build that found
// 0.8.0 with a patch, the dialog that asks before switching it to AutoBuild, an AutoBuild
// build's way back to stable with the settings kept of it, and a feed of its own. Opt in with
// -tags vivahead and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualUpdatesPage(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	checked := time.Date(2026, 11, 16, 9, 30, 0, 0, time.Local)
	for _, scene := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		for _, state := range []string{"available", "to-autobuild", "to-stable", "custom-source"} {
			name := "settings-updates-" + state + "-" + scene.theme + "-" + scene.language.Code()
			t.Run(name, func(t *testing.T) {
				language := scene.language
				version, status := "0.7.0", UpdateStatus{
					Configured: true, Installed: buildinfo.ChannelStable, LastChecked: checked,
				}
				switch state {
				case "available":
					status.Available, status.NotesURL = "0.8.0", "https://github.com/1lck/Lithe-IDEA/releases/tag/desktop-v0.8.0"
					status.Delta, status.DeltaSize, status.FullSize = true, 3_400_000, 96_000_000
				case "to-stable":
					version = "0.8.0-autobuild.20261116093000"
					status.Installed, status.UpToDate = buildinfo.ChannelAutoBuild, true
					status.Restorable = []string{buildinfo.ChannelStable}
				default:
					status.UpToDate = true
				}
				status.Channel = status.Installed
				for _, channel := range buildinfo.Channels {
					source := UpdateSource{Channel: channel, URL: buildinfo.DefaultFeedURL(channel)}
					if state == "custom-source" && channel == buildinfo.ChannelStable {
						source.URL, source.Custom = "https://updates.example.com/lithe/stable.json", true
					}
					status.Sources = append(status.Sources, source)
				}
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, Version: version, SystemDark: func() bool { return scene.theme == "dark" },
					UpdateStatus:     func() UpdateStatus { return status },
					SetUpdateChannel: func(string, bool, bool) {}, SetUpdateSource: func(string, string) {},
					UpdateNow: func() {}, ShowUpdate: func() {},
				}), Values{Theme: scene.theme, Language: language.Code()})
				w.sess.page = pageAbout
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				pick := func(channel string) {
					d.click(i18n.Shared(language, "desktop.settings.updates.channel"))
					d.click(ChannelName(language, channel))
					d.pump()
				}
				switch state {
				case "to-autobuild":
					pick(buildinfo.ChannelAutoBuild)
					d.until("the dialog about AutoBuild", func() bool {
						return d.text(i18n.Shared(language, "desktop.settings.updates.toAutoBuild.title"))
					})
				case "to-stable":
					pick(buildinfo.ChannelStable)
					d.until("the dialog about stable", func() bool {
						return d.has(i18n.Shared(language, "desktop.settings.updates.toStable.now"))
					})
				}
				// A dialog fades in; the capture shows it once it is in, on the driver's clock.
				for step := 0; step < 40 && d.driver.Transitioning(); step++ {
					if err := d.driver.Advance(50 * time.Millisecond); err != nil {
						t.Fatal(err)
					}
				}
				if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
