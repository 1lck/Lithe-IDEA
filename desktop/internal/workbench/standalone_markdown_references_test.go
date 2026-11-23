package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
)

func standaloneMarkdownReferenceHarness(t *testing.T, path string) *harness {
	t.Helper()
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.Languages, options.OpenFile = []string{"en-US"}, path
	return newHarnessWithOptions(t, options)
}

func TestStandaloneMarkdownImagesUseEachDocumentsFolder(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first.md")
	if err := os.WriteFile(first, []byte("# First\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "outside.png"), pngOf(t, 1, 1), 0600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "nested")
	if err := os.Mkdir(nested, 0700); err != nil {
		t.Fatal(err)
	}
	h := standaloneMarkdownReferenceHarness(t, first)
	h.app.openStandaloneFile(first)
	h.await("first standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(first) != nil })
	// The second file is inside the first file's parent; the third is elsewhere.
	// Neither inherits the first document's directory as a workspace root.
	for _, folder := range []string{nested, t.TempDir()} {
		path := filepath.Join(folder, "README.md")
		if err := os.WriteFile(filepath.Join(folder, "local.png"), pngOf(t, 4, 5), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("# Pictures\n\n![local](local.png)\n\n![root](/local.png)\n\n![escape](../outside.png)\n"), 0600); err != nil {
			t.Fatal(err)
		}
		h.app.openFile(h.app.project, path)
		h.await("another standalone Markdown", func() bool { return h.app.project.docs.byPath(path) != nil })
		h.settle()
		d := h.app.project.docs.byPath(path)
		if d.markdown == nil {
			t.Fatal("standalone Markdown has no image preview")
		}
		s := d.markdown
		h.await("standalone image results", func() bool {
			if len(s.images) != 3 {
				return false
			}
			for _, image := range s.images {
				if image.loading {
					return false
				}
			}
			return true
		})
		for _, ref := range []string{"local.png", "/local.png"} {
			image := s.images[ref]
			if image == nil || image.failed || image.bitmap.Width != 4 || image.bitmap.Height != 5 {
				t.Errorf("image %q in %s: %+v", ref, folder, image)
			}
		}
		if image := s.images["../outside.png"]; image == nil || !image.failed {
			t.Errorf("standalone preview read an image outside %s: %+v", folder, image)
		}
	}
}

func TestStandaloneMarkdownWebPreviewKeepsScopeAndLifecycle(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first.md")
	folder := filepath.Join(root, "nested")
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(folder, "README.md")
	for name, data := range map[string][]byte{
		first:                              []byte("# First\n"),
		path:                               []byte("# Safe preview\n\n[Next](/next.md)\n"),
		filepath.Join(folder, "next.md"):   []byte("# Next\n"),
		filepath.Join(root, "next.md"):     []byte("# Wrong document folder\n"),
		filepath.Join(folder, "local.png"): pngOf(t, 4, 5),
		filepath.Join(root, "outside.png"): pngOf(t, 1, 1),
	} {
		if err := os.WriteFile(name, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	h := standaloneMarkdownReferenceHarness(t, first)
	pages := fakePreviews(h)
	h.app.openStandaloneFile(first)
	h.await("first standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(first) != nil })
	p := h.app.project
	h.app.openFile(p, path)
	h.await("nested standalone file", func() bool { return p.docs.byPath(path) != nil })
	h.settle()
	d := p.docs.byPath(path)
	if d.markdown == nil || d.markdown.web == nil {
		t.Fatal("standalone Markdown did not open its web preview")
	}
	s := d.markdown
	page := s.web.entry.view.(*fakePreview)
	if page.config.Page != webpreview.MarkdownPage {
		t.Fatal("standalone Markdown opened a site instead of the sanitized page")
	}
	h.await("Core Markdown HTML", func() bool { return s.web.html != "" })
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	for _, ref := range []string{"local.png", "/local.png"} {
		resolved, err := page.config.Resolve(ctx, ref)
		if err != nil || resolved.Kind != "file" || filepath.Base(resolved.Path) != "local.png" {
			t.Errorf("web image %q: %+v, %v", ref, resolved, err)
		}
	}
	for _, ref := range []string{"../outside.png", "file:///outside.png", "javascript:alert(1)"} {
		resolved, err := page.config.Resolve(ctx, ref)
		if err != nil || resolved.Kind != "none" {
			t.Errorf("web image %q escaped its scope: %+v, %v", ref, resolved, err)
		}
	}
	page.load()
	page.config.Follow("/next.md")
	next := filepath.Join(folder, "next.md")
	wrong := filepath.Join(root, "next.md")
	h.await("linked standalone file", func() bool { return p.docs.byPath(next) != nil || p.docs.byPath(wrong) != nil })
	if p.docs.byPath(next) == nil {
		t.Errorf("root-relative link opened %s instead of %s", wrong, next)
	}
	if h.app.project != p || !p.standalone || h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("following a Markdown link opened a project")
	}
	h.app.closeDocument(p, d.id)
	h.await("standalone Markdown tab close", func() bool { return p.docs.find(d.id) == nil && page.closed })
	h.app.closeProject()
	h.await("standalone session close", func() bool { return h.app.project == nil })
	h.settle()
	for _, page := range *pages {
		if !page.closed {
			t.Fatal("closing the standalone session kept a web preview alive")
		}
	}
}
