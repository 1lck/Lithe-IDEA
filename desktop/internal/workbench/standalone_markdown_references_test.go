package workbench

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/winpath"
)

func standaloneMarkdownReferenceHarness(t *testing.T, path string) *harness {
	t.Helper()
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.Languages, options.OpenFile = []string{"en-US"}, path
	options.PluginRoot = filepath.Join(filepath.Dir(path), "unread-plugins")
	return newHarnessWithOptions(t, options)
}

// Core's canonical path to a served resource may resolve macOS TempDir symlinks (/private/var)
// or use Windows' \\?\ extended-length spelling.
func sameResolvedFile(got, want string) bool {
	if want == "" || !filepath.IsAbs(got) {
		return false
	}
	if got == want || winpath.Equal(got, want) {
		return true
	}
	actual, actualErr := os.Stat(got)
	expected, expectedErr := os.Stat(want)
	return actualErr == nil && expectedErr == nil && os.SameFile(actual, expected)
}

func TestPreviewWorkspaceRootReturnsEmptyOnlyForNilOrStandalone(t *testing.T) {
	var nilProject *project
	if got := nilProject.previewWorkspaceRoot(); got != "" {
		t.Fatalf("nil project workspace root = %q, want empty", got)
	}
	if got := (&project{standalone: true, root: "/tmp/first"}).previewWorkspaceRoot(); got != "" {
		t.Fatalf("standalone workspace root = %q, want empty", got)
	}
	want := filepath.Join(t.TempDir(), "workspace")
	if got := (&project{root: want}).previewWorkspaceRoot(); got != want {
		t.Fatalf("project workspace root = %q, want %q", got, want)
	}
}

func TestStandaloneMarkdownImagesUseEachDocumentsFolder(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first.md")
	if err := os.WriteFile(first, []byte("# First\n\n![local](local.png)\n\n![root](/local.png)\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// Put local.png in the first file's folder with a distinct size (1x1) so nested
	// documents would load the wrong image if p.root leaked as workspaceRoot.
	if err := os.WriteFile(filepath.Join(root, "local.png"), pngOf(t, 1, 1), 0600); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(root, "outside.png")
	if err := os.WriteFile(outside, pngOf(t, 1, 1), 0600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "nested")
	if err := os.Mkdir(nested, 0700); err != nil {
		t.Fatal(err)
	}
	h := standaloneMarkdownReferenceHarness(t, first)
	h.app.openStandaloneFile(first)
	h.await("first standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(first) != nil })
	h.settle()
	firstDoc := h.app.project.docs.byPath(first)
	if firstDoc == nil || firstDoc.markdown == nil {
		t.Fatal("first standalone Markdown has no image preview")
	}
	h.await("first standalone images", func() bool {
		if len(firstDoc.markdown.images) != 2 {
			return false
		}
		for _, image := range firstDoc.markdown.images {
			if image.loading {
				return false
			}
		}
		return true
	})
	for _, ref := range []string{"local.png", "/local.png"} {
		image := firstDoc.markdown.images[ref]
		if image == nil || image.failed || image.bitmap.Width != 1 || image.bitmap.Height != 1 {
			t.Errorf("first image %q: %+v", ref, image)
		}
	}

	// The second file is inside the first file's parent; the third is elsewhere.
	// Neither inherits the first document's directory as a workspace root.
	for _, folder := range []string{nested, t.TempDir()} {
		if err := os.MkdirAll(filepath.Join(folder, "img"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "local.png"), pngOf(t, 4, 5), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "img", "sub.png"), pngOf(t, 2, 3), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "next.md"), []byte("# Next\n"), 0600); err != nil {
			t.Fatal(err)
		}
		source := "# Pictures\n\n![local](local.png)\n\n![root](/local.png)\n\n![sub](img/sub.png)\n\n![parent](../local.png)\n\n![escape](../outside.png)\n"
		wantImages := 5
		if runtime.GOOS != "windows" {
			if err := os.Symlink(outside, filepath.Join(folder, "sym-outside.png")); err != nil {
				t.Fatal(err)
			}
			source += "\n![sym](sym-outside.png)\n"
			wantImages++
		}
		path := filepath.Join(folder, "README.md")
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
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
			if len(s.images) != wantImages {
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
		if sub := s.images["img/sub.png"]; sub == nil || sub.failed || sub.bitmap.Width != 2 || sub.bitmap.Height != 3 {
			t.Errorf("subfolder image in %s: %+v", folder, sub)
		}
		for _, denied := range []string{"../local.png", "../outside.png"} {
			if image := s.images[denied]; image == nil || !image.failed {
				t.Errorf("standalone preview read %q outside %s: %+v", denied, folder, image)
			}
		}
		if runtime.GOOS != "windows" {
			if image := s.images["sym-outside.png"]; image == nil || !image.failed {
				t.Errorf("standalone preview followed symlink outside %s: %+v", folder, image)
			}
		}
		// Native preview links also resolve `/...` from the active document's folder.
		h.app.followMarkdownLink(h.app.project, d, s, "/next.md")
		next := filepath.Join(folder, "next.md")
		h.await("native root-relative link", func() bool { return h.app.project.docs.byPath(next) != nil })
		p := h.app.project
		if !p.standalone || h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
			t.Fatal("standalone preview activated project services")
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
	otherDir := t.TempDir()
	path := filepath.Join(folder, "README.md")
	other := filepath.Join(otherDir, "other.md")
	nestedPNG := pngOf(t, 4, 5)
	otherPNG := pngOf(t, 3, 3)
	for name, data := range map[string][]byte{
		first:                                    []byte("# First\n\n[Nested](nested/README.md)\n"),
		filepath.Join(root, "local.png"):         pngOf(t, 1, 1),
		filepath.Join(root, "outside.png"):       pngOf(t, 1, 1),
		filepath.Join(root, "next.md"):           []byte("# Wrong document folder\n"),
		path:                                     []byte("# Safe preview\n\n[Next](/next.md)\n"),
		filepath.Join(folder, "next.md"):         []byte("# Next\n"),
		filepath.Join(folder, "sub.md"):          []byte("# Sub\n"),
		filepath.Join(folder, "local.png"):       nestedPNG,
		other:                                    []byte("# Other\n\n[OtherNext](/other_next.md)\n"),
		filepath.Join(otherDir, "other_next.md"): []byte("# Other Next\n"),
		filepath.Join(otherDir, "local.png"):     otherPNG,
	} {
		if err := os.WriteFile(name, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	h := standaloneMarkdownReferenceHarness(t, first)
	pages := fakePreviews(h)
	h.app.openStandaloneFile(first)
	h.await("first standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(first) != nil })
	h.settle()
	p := h.app.project
	firstDoc := p.docs.byPath(first)
	if firstDoc.markdown == nil || firstDoc.markdown.web == nil {
		t.Fatal("first standalone Markdown did not open its web preview")
	}
	firstPage := firstDoc.markdown.web.entry.view.(*fakePreview)
	firstPage.load()
	// Follow a link from the first document into a nested folder; it must stay standalone and
	// resolve subsequent references against the nested document's own folder.
	firstPage.config.OnMessage(webpreview.Message{Type: "link", Href: "nested/README.md"})
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
	wantNestedPNG := filepath.Join(folder, "local.png")
	for _, ref := range []string{"local.png", "/local.png"} {
		resolved, err := page.config.Resolve(ctx, ref)
		if err != nil || resolved.Kind != "file" || !sameResolvedFile(resolved.Path, wantNestedPNG) || resolved.MIME != "image/png" {
			t.Errorf("web image %q: %+v, %v (want %s)", ref, resolved, err, wantNestedPNG)
		}
		loaded, mime, err := webpreview.LoadResource(ctx, resolved, nil)
		if err != nil || mime != "image/png" || !bytes.Equal(loaded, nestedPNG) {
			t.Errorf("load resource %q: len=%d mime=%q err=%v", ref, len(loaded), mime, err)
		}
	}
	for _, ref := range []string{"../local.png", "../outside.png", "file:///outside.png", "javascript:alert(1)", "data:image/png;base64,AA==", "C:/local.png"} {
		resolved, err := page.config.Resolve(ctx, ref)
		if err != nil || resolved.Kind != "none" {
			t.Errorf("web image %q escaped its scope: %+v, %v", ref, resolved, err)
		}
	}
	page.load()
	page.config.OnMessage(webpreview.Message{Type: "link", Href: "/next.md"})
	next := filepath.Join(folder, "next.md")
	wrong := filepath.Join(root, "next.md")
	h.await("linked standalone file", func() bool { return p.docs.byPath(next) != nil || p.docs.byPath(wrong) != nil })
	if p.docs.byPath(next) == nil || p.docs.byPath(wrong) != nil {
		t.Errorf("root-relative link opened wrong=%v next=%v", p.docs.byPath(wrong) != nil, p.docs.byPath(next) != nil)
	}
	page.config.Follow("sub.md")
	sub := filepath.Join(folder, "sub.md")
	h.await("relative follow link", func() bool { return p.docs.byPath(sub) != nil })

	// Opening another Markdown outside the first folder keeps its own folder as scope too.
	h.app.openFile(p, other)
	h.await("unrelated standalone file", func() bool { return p.docs.byPath(other) != nil })
	h.settle()
	otherDoc := p.docs.byPath(other)
	if otherDoc.markdown == nil || otherDoc.markdown.web == nil {
		t.Fatal("unrelated standalone Markdown did not open its web preview")
	}
	otherPage := otherDoc.markdown.web.entry.view.(*fakePreview)
	resolvedOther, err := otherPage.config.Resolve(ctx, "/local.png")
	wantOtherPNG := filepath.Join(otherDir, "local.png")
	if err != nil || resolvedOther.Kind != "file" || !sameResolvedFile(resolvedOther.Path, wantOtherPNG) {
		t.Errorf("unrelated web image /local.png: %+v, %v (want %s)", resolvedOther, err, wantOtherPNG)
	}
	otherPage.load()
	otherPage.config.Follow("/other_next.md")
	otherNext := filepath.Join(otherDir, "other_next.md")
	h.await("unrelated linked standalone file", func() bool { return p.docs.byPath(otherNext) != nil })

	if h.app.project != p || !p.standalone || h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("following Markdown links opened a project")
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

func TestProjectMarkdownKeepsWorkspaceRootForNestedDocuments(t *testing.T) {
	outside := t.TempDir()
	root := filepath.Join(outside, "work")
	for _, dir := range []string{filepath.Join(root, "assets"), filepath.Join(root, "nested")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	readme := filepath.Join(root, "README.md")
	nested := filepath.Join(root, "nested", "guide.md")
	logo := filepath.Join(root, "assets", "logo.png")
	for name, data := range map[string][]byte{
		readme:                               []byte("# Root\n"),
		nested:                               []byte("# Nested\n\n![root](/assets/logo.png)\n\n![parent](../assets/logo.png)\n\n![escape](../../secret.png)\n"),
		logo:                                 pngOf(t, 2, 2),
		filepath.Join(outside, "secret.png"): pngOf(t, 1, 1),
	} {
		if err := os.WriteFile(name, data, 0600); err != nil {
			t.Fatal(err)
		}
	}

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	h.open(root)
	p := h.app.project
	if got := p.previewWorkspaceRoot(); got != root {
		t.Fatalf("project previewWorkspaceRoot = %q, want %q", got, root)
	}
	h.app.openFile(p, nested)
	h.await("nested project Markdown", func() bool { return p.docs.byPath(nested) != nil })
	h.settle()
	d := p.docs.byPath(nested)
	if d.markdown == nil || d.markdown.web == nil || len(*pages) != 1 {
		t.Fatalf("project nested Markdown opened %d web pages", len(*pages))
	}
	page := (*pages)[0]
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	for _, ref := range []string{"/assets/logo.png", "../assets/logo.png"} {
		resolved, err := page.config.Resolve(ctx, ref)
		if err != nil || resolved.Kind != "file" || !sameResolvedFile(resolved.Path, logo) || resolved.MIME != "image/png" {
			t.Errorf("project web image %q: %+v, %v (want %s)", ref, resolved, err, logo)
		}
	}
	if secret, err := page.config.Resolve(ctx, "../../secret.png"); err != nil || secret.Kind != "none" {
		t.Errorf("project web image outside workspace: %+v, %v", secret, err)
	}
	page.load()
	page.config.OnMessage(webpreview.Message{Type: "link", Href: "/README.md"})
	h.await("project root-relative link", func() bool {
		shown := p.selectedDocument(p.docs.group)
		return shown != nil && winpath.Equal(filepath.Clean(shown.path), filepath.Clean(readme))
	})
}
