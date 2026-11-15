package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
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

func TestMarketplaceRequiresApprovalOfVerifiedDeclarations(t *testing.T) {
	for _, action := range []string{"install", "cancel", "escape", "close"} {
		t.Run(action, func(t *testing.T) {
			var feedback PluginInstallFeedback
			w := newWindow(NewController(Options{InstallPlugin: func(_ core.MarketplacePlugin, value PluginInstallFeedback) { feedback = value }}), Values{})
			w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example", Availability: core.MarketplaceAvailability{Status: "available", Version: "2.0.0"}})
			d := openWindow(t, w)
			d.click(i18n.Shared(i18n.English, "native.download"))

			const program = `{"kind":"packagedBackend","path":"bin/example","arguments":["--serve"]}`
			review := plugintrust.Review{
				Permissions: []string{"example.read", "example.write"},
				Programs:    []json.RawMessage{json.RawMessage(program)},
			}
			decision := pluginReviewDecision(t, w, feedback, review, false)
			d.until("verified permissions and complete program declaration", func() bool {
				select {
				case accepted := <-decision:
					t.Fatalf("review returned %v before showing the declarations", accepted)
				default:
				}
				return d.text("example.read") && d.text("example.write")
			})
			if d.text(program) {
				t.Fatal("technical details were expanded by default")
			}
			d.click(i18n.SharedFormat(i18n.English, "desktop.marketplace.programDetails", map[string]string{"count": "1"}))
			d.pump()
			if !d.text(program) {
				t.Fatal("complete declaration is missing after expansion")
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
			expectPluginDecision(t, decision, action == "install")
			if action == "install" {
				d.pump()
				if !d.text(i18n.Shared(i18n.English, "settings.general.installing")) {
					t.Fatal("confirmed review did not enter installation")
				}
			}
		})
	}
}

func TestMarketplaceReusesVerifiedApproval(t *testing.T) {
	var feedback PluginInstallFeedback
	w := newWindow(NewController(Options{InstallPlugin: func(_ core.MarketplacePlugin, value PluginInstallFeedback) { feedback = value }}), Values{})
	w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}})
	d := openWindow(t, w)
	d.click(i18n.Shared(i18n.English, "native.download"))
	decision := make(chan bool, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		decision <- feedback.Review("1.0.0", plugintrust.Review{Permissions: []string{"example.read"}}, true)
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
			t.Fatal("the verified prior approval did not authorize installation")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the installation asked again despite matching approval")
	}
	d.pump()
	if d.text("example.read") || !d.text(i18n.Shared(i18n.English, "settings.general.installing")) {
		t.Fatal("the package did not proceed directly to installation")
	}
	feedback.Finish(false)
	d.pump()
	if !d.showsHelp(i18n.Shared(i18n.English, "desktop.marketplace.installCompleteHelp")) {
		t.Fatal("missing completion feedback")
	}
	d.click(i18n.Shared(i18n.English, "ui.done"))
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
			d.click(i18n.Shared(i18n.English, "native.download"))
			switch action {
			case "cancel":
				d.click(i18n.Shared(i18n.English, "desktop.marketplace.cancel"))
			case "escape":
				d.key(gfx.KeyEscape)
			case "close":
				d.driver.Close()
			}
			d.pump()
			expectPluginDecision(t, pluginReviewDecision(t, w, feedback, plugintrust.Review{}, action == "close"), false)
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

func pluginReviewDecision(t *testing.T, w *window, feedback PluginInstallFeedback, review plugintrust.Review, reused bool) <-chan bool {
	t.Helper()
	decision := make(chan bool, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		decision <- feedback.Review("2.0.0", review, reused)
	}()
	t.Cleanup(func() {
		w.dismissPluginInstall()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("review worker did not finish after cancellation")
		}
	})
	return decision
}

func expectPluginDecision(t *testing.T, decision <-chan bool, want bool) {
	t.Helper()
	select {
	case approved := <-decision:
		if approved != want {
			t.Fatalf("approval = %v, want %v", approved, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("review did not receive the decision")
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
				d.click(i18n.Shared(i18n.English, "native.download"))
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
	d.click(i18n.SharedFormat(i18n.English, "desktop.marketplace.programDetails", map[string]string{"count": "1"}))
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

func TestMarketplaceInstallEntryPointsShowProgressAndReview(t *testing.T) {
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
			d.click(words("native.download"))
			d.pump()
			if feedback.Context == nil || !d.text(words("desktop.marketplace.connecting")) {
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
				expectPluginDecision(t, pluginReviewDecision(t, w, feedback, plugintrust.Review{}, false), false)
				return
			}
			decision := pluginReviewDecision(t, w, feedback, plugintrust.Review{Permissions: []string{"example.read"}}, false)
			d.until("marketplace permissions", func() bool { return d.text("example.read") })
			d.click(words("desktop.marketplace.confirmInstall"))
			expectPluginDecision(t, decision, true)
			d.pump()
			feedback.Finish(false)
			d.pump()
			d.click(words("ui.done"))
			if w.install != nil {
				t.Fatal("successful installation did not close the progress dialog")
			}
		})
	}
}

func TestMarketplaceFailureOffersRetryInCurrentWindow(t *testing.T) {
	var feedback PluginInstallFeedback
	calls := 0
	w := newWindow(NewController(Options{InstallPlugin: func(_ core.MarketplacePlugin, value PluginInstallFeedback) { calls++; feedback = value }}), Values{})
	w.startMarketplaceInstall(core.MarketplacePlugin{Name: "Example"})
	d := openWindow(t, w)
	d.click(i18n.Shared(i18n.English, "native.download"))
	feedback.Finish(true)
	d.pump()
	if !d.has(i18n.Shared(i18n.English, "ui.retry")) {
		t.Fatal("failed download has no retry action")
	}
	d.click(i18n.Shared(i18n.English, "ui.retry"))
	if calls != 2 {
		t.Fatalf("retry started %d installs, want 2", calls)
	}
}

func TestInstallFailureGuidanceHidesNativeSecrets(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	feedback := w.startPluginInstall("Example", true)
	d := openWindow(t, w)
	feedback.Failure(errors.New("https://private.invalid/?token=secret"))
	feedback.Finish(true)
	d.pump()
	if !d.showsHelp(i18n.Shared(i18n.English, "desktop.marketplace.failureHelp")) || d.textContaining("secret") {
		t.Fatal("missing or unsafe failure guidance")
	}
}
