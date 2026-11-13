package settingswindow

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TestNetworkPageChecksTheDraftAndSaysWhatItFound walks the Network page's connection check:
// it sends the unsaved draft off the window thread and says so while it runs, then shows the
// time an answer took, the status of an answer that is not one, or why none came, followed by
// the exclusion entries Core ignored. A draft
// without a server is answered at once without a request, Revert forgets the outcome, and only
// a custom server offers the check.
func TestNetworkPageChecksTheDraftAndSaysWhatItFound(t *testing.T) {
	var mu sync.Mutex
	var drafts []NetworkSettings
	var passwords []*string
	next := NetworkCheck{Status: 204, Elapsed: 42 * time.Millisecond}
	release := make(chan struct{})
	w := newWindow(NewController(Options{
		SetNetwork: func(NetworkSettings, *string) {},
		CheckNetwork: func(ctx context.Context, draft NetworkSettings, password *string) NetworkCheck {
			mu.Lock()
			drafts, passwords = append(drafts, draft), append(passwords, password)
			outcome, first := next, len(drafts) == 1
			mu.Unlock()
			if first {
				select {
				case <-release:
				case <-ctx.Done():
					return NetworkCheck{Err: ctx.Err()}
				}
			}
			return outcome
		},
	}), Values{Network: NetworkSettings{Mode: "custom", Host: "proxy.example.com", Port: 8080, Username: "ada", HasPassword: true}})
	w.sess.page = pageNetwork
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	format := func(id, value string) string {
		return i18n.SharedFormat(i18n.English, id, map[string]string{"arg1": value})
	}
	calls := func() int {
		mu.Lock()
		defer mu.Unlock()
		return len(drafts)
	}
	set := func(outcome NetworkCheck) {
		mu.Lock()
		next = outcome
		mu.Unlock()
	}

	d.click(text("settings.network.testConnection"))
	d.until("the running check", func() bool { return d.has(text("settings.network.testing")) })
	close(release)
	succeeded := format("settings.network.connectionSucceeded", "42")
	d.until("the answer's time", func() bool { return d.text(succeeded) })
	mu.Lock()
	if drafts[0].Host != "proxy.example.com" || drafts[0].Port != 8080 || drafts[0].Username != "ada" || passwords[0] != nil {
		t.Fatalf("the check was handed %+v with password %v, want the draft keeping the saved password", drafts[0], passwords[0])
	}
	mu.Unlock()

	set(NetworkCheck{Status: 407, Elapsed: time.Millisecond})
	d.click(text("settings.network.testConnection"))
	d.until("the proxy's status", func() bool { return d.text(format("settings.network.proxyAnsweredWithHTTP", "407")) })

	set(NetworkCheck{Status: 204, Elapsed: 42 * time.Millisecond, IgnoredExclusions: []string{"*", "a..b"}})
	d.click(text("settings.network.testConnection"))
	ignored := succeeded + " " + i18n.SharedFormat(i18n.English, "desktop.settings.network.ignoredExclusions", map[string]string{"entries": "*, a..b"})
	d.until("the ignored exclusions", func() bool { return d.text(ignored) })

	set(NetworkCheck{Err: errors.New("connection refused")})
	d.click(text("settings.network.testConnection"))
	d.until("the cause", func() bool { return d.text(text("settings.network.checkFailed") + " connection refused") })

	d.click(text("desktop.settings.network.revert"))
	d.pump()
	if d.text(text("settings.network.checkFailed") + " connection refused") {
		t.Fatal("Revert kept the outcome of the draft it threw away")
	}

	w.network.host.SetText("")
	d.pump()
	before := calls()
	d.click(text("settings.network.testConnection"))
	d.pump()
	if !d.text(text("settings.network.enterAddressAndPort")) || calls() != before {
		t.Fatalf("a draft without a server: shown %v, checks %d → %d", d.text(text("settings.network.enterAddressAndPort")), before, calls())
	}

	w.network.mode = "direct"
	d.until("the page without a custom server", func() bool { return !d.has(text("desktop.settings.network.host")) })
	if d.has(text("settings.network.testConnection")) || d.text(text("settings.network.enterAddressAndPort")) {
		t.Fatal("the check is offered without a custom server")
	}
}
