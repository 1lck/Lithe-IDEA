package settingswindow

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/encodingname"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// consoleTestEncodings uses the production resolver, with Windows compatibility enabled,
// to exercise the same catalog on every test host.
func consoleTestEncodings(t *testing.T) ConsoleEncodings {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveOutputEncoding(ctx, core.OutputEncodingPolicy{Windows: true})
	if err != nil {
		t.Fatal(err)
	}
	view := ConsoleEncodings{}
	choice := func(id string) ConsoleEncoding {
		return ConsoleEncoding{ID: id, Label: encodingname.DisplayName(id)}
	}
	for _, id := range resolved.Candidates {
		view.Automatic = append(view.Automatic, choice(id))
	}
	for _, id := range resolved.Encodings {
		view.Choices = append(view.Choices, choice(id))
	}
	return view
}

func TestConsoleEncodingPageAppliesAndRestores(t *testing.T) {
	encodings := consoleTestEncodings(t)
	var changes []string
	w := newWindow(NewController(Options{
		ConsoleEncodings:   func() (ConsoleEncodings, bool) { return encodings, true },
		SetConsoleEncoding: func(value string) { changes = append(changes, value) },
	}), Values{})
	w.sess.page = pageConsole
	d := openWindow(t, w)
	title := i18n.Shared(i18n.English, "desktop.consoleSettings.encoding")
	automatic := i18n.SharedFormat(i18n.English, "desktop.consoleSettings.automatic", map[string]string{"encodings": "UTF-8, otherwise GBK"})
	if len(changes) != 0 || d.hit(title).Value != automatic {
		t.Fatalf("opening changed settings or missed automatic candidates: %v, %+v", changes, d.hit(title))
	}
	d.click(title)
	d.click("GBK")
	if !slices.Equal(changes, []string{"gbk"}) || d.hit(title).Value != "GBK" {
		t.Fatalf("selection = %v, control = %+v", changes, d.hit(title))
	}
	d.click(w.text.Settings.RestoreDefaults)
	if !slices.Equal(changes, []string{"gbk", ""}) || d.hit(title).Value != automatic {
		t.Fatalf("restore = %v, control = %+v", changes, d.hit(title))
	}
	d.click(w.text.Settings.Cancel)
	w.setConsoleEncoding("big5", false)
	if !slices.Equal(changes, []string{"gbk", ""}) {
		t.Fatalf("a closed window wrote again: %v", changes)
	}
}

func TestConsoleEncodingPageReflectsCatalogArrivalAndFailure(t *testing.T) {
	encodings, known := ConsoleEncodings{}, false
	w := newWindow(NewController(Options{
		ConsoleEncodings: func() (ConsoleEncodings, bool) { return encodings, known },
	}), Values{})
	w.sess.page = pageConsole
	d := openWindow(t, w)
	title := i18n.Shared(i18n.English, "desktop.consoleSettings.encoding")
	if hit := d.hit(title); !hit.Disabled || hit.Value != i18n.Shared(i18n.English, "desktop.consoleSettings.automaticPending") {
		t.Fatalf("pending = %+v", hit)
	}
	encodings, known = consoleTestEncodings(t), true
	w.inv.Invalidate()
	d.pump()
	if hit := d.hit(title); hit.Disabled || hit.Value == i18n.Shared(i18n.English, "desktop.consoleSettings.automaticPending") {
		t.Fatalf("resolved = %+v", hit)
	}
	encodings = ConsoleEncodings{Error: i18n.Shared(i18n.English, "desktop.consoleSettings.readFailed")}
	w.inv.Invalidate()
	d.pump()
	if hit := d.hit(title); !hit.Disabled || hit.Value != i18n.Shared(i18n.English, "desktop.consoleSettings.automaticFailed") || !d.text(encodings.Error) {
		t.Fatalf("failed = %+v", hit)
	}
}

func TestConsoleEncodingPageBelongsToToolsAndMatchesSearch(t *testing.T) {
	if parents[pageConsole] != pageTools {
		t.Fatal("Console is not under Tools")
	}
	w := newWindow(NewController(Options{SettingsNavigation: core.NewClient().SettingsNavigation}), Values{})
	d := openWindow(t, w)
	w.searchField.SetText("GBK")
	w.inv.Invalidate()
	d.pump()
	var found row
	d.until("Console in the Core-projected encoding search", func() bool {
		for _, r := range w.rows {
			if r.page == pageConsole {
				found = r
				return true
			}
		}
		return false
	})
	w.chooseRow(found)
	if w.sess.page != pageConsole || !w.sess.open[pageTools] {
		t.Fatalf("choosing the match opened page %v with Tools open %v", w.sess.page, w.sess.open[pageTools])
	}
}
