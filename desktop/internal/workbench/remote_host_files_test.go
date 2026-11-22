package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/vivaui/viva/gfx"
)

// remoteHostRowNames are the names of the rows Open File on Host shows, a folder's with its "/".
func remoteHostRowNames(f *remoteHostFiles) []string {
	names := make([]string, 0, len(f.rows))
	for _, at := range f.rows {
		entry := f.entries[at]
		name := entry.name
		if entry.folder {
			name += "/"
		}
		names = append(names, name)
	}
	return names
}

// openHostFilesFromMenu opens Open File on Host from the connection's menu and waits for the
// listing of the folder its field names.
func (h *harness) openHostFilesFromMenu(t *testing.T, p *project) *remoteHostFiles {
	t.Helper()
	lang := h.app.language()
	h.clickFront(i18n.Shared(lang, "desktop.remote.status.label"))
	h.settle()
	h.clickFront(i18n.Shared(lang, "desktop.remote.status.openHostFile"))
	f := &p.remote.hostFiles
	h.awaitHostListing(t, f)
	return f
}

// awaitHostListing waits for the popup's listing to finish and paints its rows.
func (h *harness) awaitHostListing(t *testing.T, f *remoteHostFiles) {
	t.Helper()
	h.redraw()
	h.await("the host folder's listing", func() bool { return f.open && !f.loading })
	h.settle()
}

// Open File on Host lists the folder its field names, filtering by what follows the last "/",
// folders first and hidden entries only once "." is typed. Enter enters a folder and opens a
// file. A file in the workspace's folder opens for editing; one outside it opens read-only,
// stays so, cannot be saved, and the status bar names its host path. A path that is not
// absolute says what to type. Neither the host nor its paths are logged.
func TestRemoteOpenFileOnHost(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.put(remoteTestReadme, "# Project\n")
	k.put(remoteTestHome+"/notes.txt", "host notes\n")
	p := h.openRemoteTestProject(t)

	f := h.openHostFilesFromMenu(t, p)
	if got := f.query.Text(); got != "~/" {
		t.Fatalf("the field starts with %q, want the home directory", got)
	}
	if got, want := remoteHostRowNames(f), []string{"linked/", "project/", "notes.txt"}; !slices.Equal(got, want) {
		t.Fatalf("rows %q, want the home folder's entries without hidden ones, folders first", got)
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.hostFile.readOnlyNote")) {
		t.Fatal("the popup does not say files outside the folder open read-only")
	}
	h.typeText(".")
	if got := remoteHostRowNames(f); !slices.Equal(got, []string{".cache/"}) {
		t.Fatalf("rows %q for \".\", want the hidden folder", got)
	}
	f.query.SetText("~/PRO")
	h.redraw()
	if got := remoteHostRowNames(f); !slices.Equal(got, []string{"project/"}) {
		t.Fatalf("rows %q for \"PRO\", want the folder whose name starts with it, ignoring case", got)
	}

	h.key(gfx.KeyEnter)
	h.awaitHostListing(t, f)
	if got := f.query.Text(); got != "~/project/" || f.dir != remoteTestHome+"/project" {
		t.Fatalf("field %q: Enter did not enter the folder", got)
	}
	if got := remoteHostRowNames(f); !slices.Equal(got, []string{"src/", "README.md"}) {
		t.Fatalf("rows %q, want the project folder's entries", got)
	}
	h.typeText("R")
	h.key(gfx.KeyTab)
	h.redraw()
	if got := f.query.Text(); got != "~/project/README.md" {
		t.Fatalf("field %q: Tab did not complete the name", got)
	}
	h.key(gfx.KeyEnter)
	inside := filepath.Join(p.root, "README.md")
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(inside) != nil })
	h.settle()
	if f.open {
		t.Fatal("opening a file did not close the popup")
	}
	if d := p.docs.byPath(inside); d.hostOutside || d.view.ReadOnly() {
		t.Fatal("a file of the workspace's folder opened read-only")
	}

	f = h.openHostFilesFromMenu(t, p)
	h.typeText("notes")
	h.key(gfx.KeyEnter)
	outside := filepath.Join(p.root+remoteplaceholder.HostSuffix, "home", "dev", "notes.txt")
	awaitDocumentState(t, h, func() bool { _, opening := p.docs.opening[outside]; return p.docs.byPath(outside) != nil && !opening })
	h.settle()
	d := p.docs.byPath(outside)
	if text, _ := d.view.Text(); string(text) != "host notes\n" {
		t.Fatalf("opened %q, want the host file's text", text)
	}
	if !d.hostOutside || !d.view.ReadOnly() {
		t.Fatal("a host file outside the workspace's folder opened editable")
	}
	h.app.toggleReadOnly(d)
	if !d.view.ReadOnly() || !h.notified(i18n.Shared(lang, "desktop.remote.hostFile.readOnly")) {
		t.Fatal("the file outside the folder could be made editable")
	}
	if crumbs := h.app.statusFileCrumbs(p, d.path, d.name); crumbs.name != "~/notes.txt" || crumbs.rel != "" {
		t.Fatalf("the status bar names the file %+v, want its host path under ~", crumbs)
	}
	docs := h.app.remoteDocuments(p)
	var refused *remoteFileError
	if err := docs.save(context.Background(), outside, []byte("changed"), []byte("host notes\n")); !errors.As(err, &refused) || !errors.Is(refused.reason, errRemoteReadOnly) {
		t.Fatalf("saving the file outside the folder ended with %v, want it refused", err)
	}
	if err := docs.create(context.Background(), outside+".new", []byte("new")); !errors.As(err, &refused) || !errors.Is(refused.reason, errRemoteReadOnly) {
		t.Fatalf("creating a file outside the folder ended with %v, want it refused", err)
	}
	if got, _ := k.file(remoteTestHome + "/notes.txt"); got != "host notes\n" {
		t.Fatalf("host file %q: the file outside the folder was written", got)
	}
	if _, ok := k.file(remoteTestHome + "/notes.txt.new"); ok {
		t.Fatal("a file outside the folder was created on the host")
	}
	if _, err := os.Lstat(outside); err == nil {
		t.Fatal("the file was read from or written below the placeholder")
	}

	f = h.openHostFilesFromMenu(t, p)
	f.query.SetText("notes.txt")
	h.redraw()
	h.key(gfx.KeyEnter)
	if !f.open || f.readErr != i18n.Shared(lang, "desktop.remote.hostFile.pathHint") {
		t.Fatalf("a path that is not absolute shows %q, want what to type", f.readErr)
	}
	h.key(gfx.KeyEscape)
	h.redraw()
	if f.open {
		t.Fatal("Escape did not close the popup")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome, "notes", "README"); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}
