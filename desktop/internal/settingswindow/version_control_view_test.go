package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TestVersionControlPageListsGitAndOpensIt keeps Version Control a directory like Languages &
// Frameworks: its row opens the group's own page, which lists the Git page with what it holds
// and none of its switches; the Git row opens the Git page with the switches, and the
// breadcrumb above it leads back.
func TestVersionControlPageListsGitAndOpensIt(t *testing.T) {
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, Language: func() i18n.Language { return i18n.English },
	}), Values{})
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	title := titleOf(&w.text.Settings, pageVersionControl)
	d.until("the Version Control row", func() bool { return d.has(title) })
	d.clickHit(d.sidebarRowHit(title))
	d.until("the Version Control page", func() bool {
		return w.sess.page == pageVersionControl && d.wrapped(text("desktop.versionControlSettings.intro"))
	})
	if !w.sess.open[pageVersionControl] {
		t.Fatal("choosing the Version Control row did not expand it")
	}
	if !d.text(text("desktop.versionControlSettings.directoryGit")) {
		t.Fatal("the Version Control page does not say what the Git page holds")
	}
	if d.has(text("desktop.git.settings.gutter")) {
		t.Fatal("the Version Control page still shows the Git switches")
	}

	d.clickHit(d.contentHit(titleOf(&w.text.Settings, pageGit)))
	d.until("the Git page", func() bool {
		return w.sess.page == pageGit && d.has(text("desktop.git.settings.gutter")) && d.has(text("desktop.git.settings.blame"))
	})
	crumbs := w.appendCrumbs(nil)
	if len(crumbs) != 2 || crumbs[0].page != pageVersionControl || !crumbs[0].link || crumbs[1].page != pageGit {
		t.Fatalf("breadcrumb above the Git page = %+v, want Version Control as a link, then Git", crumbs)
	}
	d.clickHit(d.contentHit(title))
	d.until("the Version Control page again", func() bool {
		return w.sess.page == pageVersionControl && d.text(text("desktop.versionControlSettings.directoryGit"))
	})
}

// TestBuildDirectoryListsOnlyItsOwnPages keeps the Build page to the pages under Build,
// Execution, Deployment: Console and Trusted Locations are under Tools now.
func TestBuildDirectoryListsOnlyItsOwnPages(t *testing.T) {
	loader := &fakeLocationsLoader{}
	loader.set(savedFolder)
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	openWindow(t, w)
	for _, entry := range w.directoryEntries(i18n.English) {
		if entry.key != "toolchains" && entry.key != "debuggers" {
			t.Errorf("the Build directory lists %q", entry.key)
		}
	}
}
