package workbench

import (
	"os"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// noticeTexts are the texts of the notification history, newest first, for failure messages.
func noticeTexts(a *App) []string {
	texts := make([]string, 0, len(a.notifications.list))
	for _, entry := range a.notifications.list {
		texts = append(texts, entry.text)
	}
	return texts
}

// TestOpenInBrowserGivesTheFileToTheDefaultBrowser: Open in Browser on the bar of an HTML file's
// page saves the edit the file has, then hands the file on disk to the default web browser,
// through Viva's checks. It is neither the file's own association, which is often an editor, nor
// a file:// address, which Viva refuses since a web address is http, https or mailto.
func TestOpenInBrowserGivesTheFileToTheDefaultBrowser(t *testing.T) {
	heldHTMLWaits(t)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	fakePreviews(h)
	d := openHTML(t, h, testHTML)
	button := i18n.Shared(h.app.language(), "desktop.editorMenu.openInBrowser")

	h.app.post(func(a *App) { a.insertForTest(d, "<!-- edit -->") })
	h.settle()
	h.click(center(h.hitLabeled(button)))
	h.await("the file to be opened or refused", func() bool {
		_, opened := h.driver.LastOpenedInBrowser()
		return opened || len(h.app.notifications.list) > 0
	})
	if path, ok := h.driver.LastOpenedInBrowser(); !ok || path != d.path {
		t.Fatalf("Open in Browser gave the browser %q (%v), want the file %q; notices %q", path, ok, d.path, noticeTexts(h.app))
	}
	if path, ok := h.driver.LastOpenedPath(); ok {
		t.Fatalf("Open in Browser also opened %q with its file association", path)
	}
	if address, ok := h.driver.LastOpenedURL(); ok {
		t.Fatalf("Open in Browser also opened the address %q", address)
	}
	if len(h.app.notifications.list) != 0 {
		t.Fatalf("Open in Browser told %q", noticeTexts(h.app))
	}
	saved, err := os.ReadFile(d.path)
	if err != nil || !strings.Contains(string(saved), "<!-- edit -->") {
		t.Fatalf("the edit was not saved before the file opened: %q (%v)", saved, err)
	}
}
