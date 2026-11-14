package settingswindow

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/vivaui/viva/gfx"
)

func TestMarketplaceInitialConfirmationApprovesInstallation(t *testing.T) {
	var feedback PluginInstallFeedback
	w := newWindow(NewController(Options{InstallPlugin: func(_ core.MarketplacePlugin, value PluginInstallFeedback) { feedback = value }}), Values{})
	w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}})
	d := openWindow(t, w)
	d.click(i18n.Shared(i18n.English, "native.downloadAndInstall"))
	decision := make(chan bool, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		decision <- feedback.Review("1.0.0", plugintrust.Review{Permissions: []string{"example.read"}}, false)
	}()
	t.Cleanup(func() {
		w.dismissPluginInstall()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("installation feedback did not finish after cancellation")
		}
	})
	select {
	case approved := <-decision:
		if !approved {
			t.Fatal("the initial confirmation did not authorize installation")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the installation requested a second confirmation")
	}
	d.pump()
	if d.text("example.read") || !d.text(i18n.Shared(i18n.English, "settings.general.installing")) {
		t.Fatal("the package did not proceed directly to installation")
	}
	feedback.Finish(false)
	d.pump()
	if w.install != nil {
		t.Fatal("the completed installation left its dialog open")
	}
}

func TestMarketplaceCancelBeforeVerificationDoesNotInstall(t *testing.T) {
	for _, action := range []string{"cancel", "escape", "close"} {
		t.Run(action, func(t *testing.T) {
			var feedback PluginInstallFeedback
			w := newWindow(NewController(Options{InstallPlugin: func(_ core.MarketplacePlugin, value PluginInstallFeedback) { feedback = value }}), Values{})
			w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}})
			d := openWindow(t, w)
			d.click(i18n.Shared(i18n.English, "native.downloadAndInstall"))
			switch action {
			case "cancel":
				d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
			case "escape":
				d.key(gfx.KeyEscape)
			case "close":
				d.driver.Close()
			}
			d.pump()
			if feedback.Review("1.0.0", plugintrust.Review{}, false) {
				t.Fatal("a cancelled installation consumed the earlier consent")
			}
		})
	}
}

func TestLocalPackageStillWaitsForInstallConfirmation(t *testing.T) {
	for _, action := range []string{"install", "cancel", "escape", "close"} {
		t.Run(action, func(t *testing.T) {
			w := newWindow(NewController(Options{}), Values{})
			feedback := w.startPluginInstall("Local Example", false)
			d := openWindow(t, w)
			decision := make(chan bool, 1)
			done := make(chan struct{})
			go func() {
				defer close(done)
				decision <- feedback.Review("1.0.0", plugintrust.Review{Permissions: []string{"example.local.read"}}, false)
			}()
			t.Cleanup(func() {
				w.dismissPluginInstall()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Error("local review worker did not finish")
				}
			})
			d.until("the local package review", func() bool { return d.text("example.local.read") })
			select {
			case <-decision:
				t.Fatal("a local package installed without confirmation")
			default:
			}
			switch action {
			case "install":
				d.click(i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall"))
			case "cancel":
				d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
			case "escape":
				d.key(gfx.KeyEscape)
			case "close":
				d.driver.Close()
			}
			d.pump()
			select {
			case approved := <-decision:
				if approved != (action == "install") {
					t.Fatalf("local approval = %v", approved)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("local review did not receive the decision")
			}
		})
	}
}

func TestMarketplaceAsksBeforeDownloading(t *testing.T) {
	for _, action := range []string{"download", "cancel", "escape", "close"} {
		t.Run(action, func(t *testing.T) {
			calls := 0
			w := newWindow(NewController(Options{InstallPlugin: func(core.MarketplacePlugin, PluginInstallFeedback) { calls++ }}), Values{})
			w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}})
			d := openWindow(t, w)
			if calls != 0 {
				t.Fatal("a download started before confirmation")
			}
			if !d.text(i18n.Shared(i18n.English, "desktop.marketplace.downloadTitle")) || !d.showsHelp(i18n.Shared(i18n.English, "desktop.marketplace.downloadPrompt")) {
				t.Fatal("the download confirmation is missing")
			}
			switch action {
			case "download":
				d.click(i18n.Shared(i18n.English, "native.downloadAndInstall"))
			case "cancel":
				d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
			case "escape":
				d.key(gfx.KeyEscape)
			case "close":
				d.driver.Close()
			}
			d.pump()
			want := 0
			if action == "download" {
				want = 1
			}
			if calls != want {
				t.Fatalf("%s started %d downloads, want %d", action, calls, want)
			}
		})
	}
}

func TestPluginInstallShowsTransferBytesAndLocalVerification(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	feedback := w.startPluginInstall("Example", true)
	d := openWindow(t, w)
	feedback.Progress(marketplace.ArchiveProgress{Received: 12 << 20, Total: 251 << 20})
	d.pump()
	if !d.text(i18n.SharedFormat(i18n.English, "desktop.marketplace.downloadProgress", map[string]string{"received": "12.0", "total": "251.0"})) {
		t.Fatal("downloaded and total bytes are missing")
	}
	feedback.Progress(marketplace.ArchiveProgress{Received: 13 << 20, Total: -1})
	d.pump()
	if !d.text(i18n.SharedFormat(i18n.English, "desktop.marketplace.downloadReceived", map[string]string{"received": "13.0"})) {
		t.Fatal("unknown-size transfer hides received bytes")
	}
	feedback.Preparing()
	d.pump()
	if !d.text(i18n.Shared(i18n.English, "desktop.marketplace.verifying")) {
		t.Fatal("local verification is still presented as downloading")
	}
}

func TestPluginInstallReviewScrollsLongDetails(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	w.startPluginInstall("Example Support", false)
	review := &pluginInstallReview{
		version: "1.2.0",
		programs: []string{
			fmt.Sprintf(`{"kind":"packagedBackend","path":"%s","command":"last-review-command"}`, strings.Repeat("backend-", 36)),
		},
	}
	for index := range 30 {
		review.permissions = append(review.permissions, fmt.Sprintf("example.permission.%02d", index))
	}
	w.install.review.Store(review)
	d := openWindow(t, w)
	if err := d.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}

	installWord := i18n.Shared(i18n.English, "desktop.marketplace.confirmInstall")
	cancelWord := i18n.Shared(i18n.English, "desktop.marketplace.cancel")
	title := i18n.Shared(i18n.English, "desktop.marketplace.reviewTitle")
	install := d.hit(installWord)
	cancel := d.hit(cancelWord)
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value == title && install.Bounds.Y-label.Bounds.Y > 460 {
			t.Fatal("long review fills the settings window")
		}
	}
	if !d.text(review.permissions[0]) || d.textContaining("last-review-command") {
		t.Fatal("the review should start with the first permissions in view")
	}
	for range 8 {
		if d.textContaining("last-review-command") {
			break
		}
		if err := d.driver.Scroll(gfx.ScrollEvent{X: 430, Y: 320, DeltaY: 240, Precise: true}); err != nil {
			t.Fatal(err)
		}
		d.pump()
	}
	if !d.textContaining("last-review-command") {
		t.Fatal("scrolling the review did not reveal the end of the program declaration")
	}
	if d.hit(installWord).Bounds != install.Bounds || d.hit(cancelWord).Bounds != cancel.Bounds {
		t.Fatal("review buttons moved while scrolling")
	}
}

func TestMarketplaceInstallCompletesAfterInitialConfirmation(t *testing.T) {
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	for _, name := range []string{"install from list", "update from list", "update from details", "close settings", "download failure"} {
		t.Run(name, func(t *testing.T) {
			var feedback PluginInstallFeedback
			plugin := core.MarketplacePlugin{
				ID: "dev.example.go", Name: "Go Support",
				Availability: core.MarketplaceAvailability{Status: "available", Version: "2.0.0"},
				Versions:     []core.MarketplaceVersion{{Version: "2.0.0"}, {Version: "1.0.0"}},
			}
			w := newWindow(NewController(Options{
				Marketplace: func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
				PluginState: func(string) PluginState {
					if name == "update from list" || name == "update from details" {
						return PluginState{Installed: true, Version: "1.0.0"}
					}
					return PluginState{}
				},
				InstallPlugin: func(selected core.MarketplacePlugin, install PluginInstallFeedback) {
					if selected.ID != plugin.ID {
						t.Errorf("requested plugin = %q, want %q", selected.ID, plugin.ID)
					}
					feedback = install
				},
			}), Values{})
			w.sess.page = pagePlugins
			w.pluginTab = pluginTabMarketplace
			w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{plugin}}}, nil)
			d := openWindow(t, w)
			var button gfx.Hit
			switch name {
			case "update from list":
				button = d.hit(words("native.update"))
			case "update from details":
				button = d.hit(i18n.SharedFormat(i18n.English, "native.updateTo.variant2", map[string]string{"arg1": "2.0.0"}))
			default:
				button = d.hit(words("desktop.marketplace.install"))
				for _, hit := range d.driver.Snapshot().Hits {
					if hit.Label == button.Label && !hit.IsLabel && hit.Bounds.X < button.Bounds.X {
						button = hit
					}
				}
			}
			d.clickHit(button)
			if err := d.driver.Advance(time.Second); err != nil {
				t.Fatal(err)
			}
			d.pump()
			if feedback.Context != nil {
				t.Fatal("the package started downloading before confirmation")
			}
			d.click(words("native.downloadAndInstall"))
			d.pump()
			if feedback.Context == nil || !d.text(words("native.downloadingAndVerifyingPlugin")) {
				t.Fatal("Settings did not show download progress")
			}
			if name == "download failure" {
				feedback.Finish(true)
				d.pump()
				if !d.text(words("desktop.marketplace.installFailed")) {
					t.Fatal("Settings did not show the download error")
				}
				return
			}

			if name == "close settings" {
				d.driver.Close()
			}
			approved := feedback.Review("2.0.0", plugintrust.Review{Permissions: []string{"example.read"}}, false)
			if approved != (name != "close settings") {
				t.Fatalf("approval after initial confirmation = %v", approved)
			}
			if name == "close settings" {
				return
			}
			d.pump()
			if d.text("example.read") || !d.text(words("settings.general.installing")) {
				t.Fatal("Settings requested another install confirmation")
			}
			feedback.Finish(false)
			d.pump()
			if w.install != nil {
				t.Fatal("successful installation did not close the progress dialog")
			}

		})
	}
}
