package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestStandaloneEditsWithBundledSyntaxWithoutProjectServices(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "hello.go")
	original := "package main\n\nfunc main() {}\n"
	if err := os.WriteFile(path, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.Languages = []string{"en-US"}
	options.OpenFile = path
	options.PluginRoot = filepath.Join(root, "unread-plugins")
	h := newHarnessWithOptions(t, options)
	if h.app.plugins != nil || h.app.aiKernel != nil {
		t.Fatal("standalone assembled plugin or AI services")
	}
	h.app.openStandaloneFile(path)
	h.await("standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	if d.grammar == nil || d.languageID != "go" {
		t.Fatalf("bundled highlighting absent: %q %v", d.languageID, d.grammar)
	}
	if !p.standalone || len(p.terms.list) != 0 || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("standalone started project services")
	}
	for _, cmd := range h.app.commands() {
		if cmd.id == "search.files" || cmd.id == "debug.start" || cmd.id == "plugins.open" || cmd.id == "project.new" {
			t.Fatalf("project command exposed: %s", cmd.id)
		}
	}
	h.app.openEverywhere(p)
	h.app.updateEverywhere(p, "sibling secret", 0)
	if h.app.everywhereView.scope != everywhereScopeActions || p.everywhere.loading || p.search.watch != nil {
		t.Fatal("standalone search entered parent workspace")
	}
	h.app.closeEverywhere(p)
	d.view.SetSelection(d.view.TextSnapshot().Len(), d.view.TextSnapshot().Len())
	h.app.insertForTest(d, "// saved\n")
	h.app.saveDocument(p, d.id)
	h.await("standalone save", func() bool { return !d.saving && !d.dirty() })
	data, err := os.ReadFile(path)
	if err != nil || string(data) != original+"// saved\n" {
		t.Fatalf("saved: %q %v", data, err)
	}
	for _, name := range []string{recentFile, editorSessionFile, recentFilesName(root)} {
		if _, err := os.Stat(filepath.Join(prefs.Dir(), name)); !os.IsNotExist(err) {
			t.Fatalf("standalone persisted project state %s: %v", name, err)
		}
	}
	h.app.closeProject()
	h.settle()
	for _, cmd := range h.app.commands() {
		if cmd.id == "plugins.open" || cmd.id == "project.new" {
			t.Fatalf("empty standalone exposed %s", cmd.id)
		}
	}
}

// TestStandaloneMarkdownShowsItsPage: a Markdown file opened alone has the page, the view
// switch and the Contents button it has in a project (#2324), still without project services.
// The page loads an image beside the file, but not one outside the file's folder.
func TestStandaloneMarkdownShowsItsPage(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "notes")
	if err := os.MkdirAll(filepath.Join(root, "img"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "img", "local.png"), pngOf(t, 4, 5), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parent, "outside.png"), pngOf(t, 2, 2), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "notes.md")
	source := "# Title\n\nSome **bold** text.\n\n![local](img/local.png)\n\n![escape](../outside.png)\n\n## Second part\n\nmore\n"
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.Languages, options.OpenFile = []string{"en-US"}, path
	options.PluginRoot = filepath.Join(root, "unread-plugins")
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("standalone Markdown file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	language := h.app.language()
	text := func(id string) string { return i18n.Shared(language, id) }
	for _, id := range []string{"editor.markdownSourceView", "editor.markdownSplitView", "editor.markdownPreviewView", "desktop.markdown.contents"} {
		if !controlShown(h, text(id)) {
			t.Fatalf("the strip of a Markdown file opened alone has no %q", text(id))
		}
	}
	page := text("desktop.markdown.preview")
	if !controlShown(h, page) || editorRect(h, d).Width == 0 {
		t.Fatal("a Markdown file opened alone does not show its source beside its page")
	}
	s := d.markdown
	awaitStateWithin(t, h, 10*time.Second, "the page's images", func() bool {
		if len(s.images) != 2 {
			return false
		}
		for _, image := range s.images {
			if image.loading {
				return false
			}
		}
		return true
	})
	if local := s.images["img/local.png"]; local == nil || local.failed || local.bitmap.Width != 4 {
		t.Fatalf("the image beside the file is %+v", local)
	}
	if escape := s.images["../outside.png"]; escape == nil || !escape.failed {
		t.Fatalf("the image outside the file's folder is %+v, want failed", escape)
	}
	h.click(center(h.hitLabeled(text("editor.markdownPreviewView"))))
	if editorRect(h, d).Width != 0 || !controlShown(h, page) {
		t.Fatal("Preview did not show the page alone")
	}
	if h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("showing the page started project services")
	}
}

func TestStandaloneTerminalStartsOnDemandInSelectedFileFolder(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native /bin/sh PTY workflow; Windows needs its local guest")
	}
	root := t.TempDir()
	path := filepath.Join(root, "first.go")
	secondDir := filepath.Join(root, "nested")
	if err := os.Mkdir(secondDir, 0700); err != nil {
		t.Fatal(err)
	}
	second := filepath.Join(secondDir, "second.go")
	for _, file := range []string{path, second} {
		if err := os.WriteFile(file, []byte("package main\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.Languages, options.OpenFile = []string{"en-US"}, path
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("first file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	h.app.openFile(p, second)
	h.await("second file", func() bool {
		return h.app.selectedEditorDocument() != nil && h.app.selectedEditorDocument().path == second
	})
	h.settle()
	if len(p.terms.list) != 0 || h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		t.Fatal("standalone created or restored a terminal before a user action")
	}
	h.app.settings.TerminalShell = "/bin/sh"
	h.clickNamed(h.app.text.Tools.Terminal)
	h.settle()
	if len(p.terms.list) != 1 || p.terms.list[0].hit.IsZero() {
		t.Fatal("terminal command did not show the integrated terminal")
	}
	term := p.terms.list[0]
	// The real shell writes its actual working directory; its output is not supplied by the test.
	if !term.view.SendLine("printf '\\nLITHE_CWD='; pwd -P") {
		t.Fatal("terminal rejected command")
	}
	realDir, err := filepath.EvalSymlinks(secondDir)
	if err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 5*time.Second, "shell working directory", func() bool {
		term.view.Pump()
		return strings.Contains(term.view.RetainedText(1<<16), "LITHE_CWD="+realDir)
	})
	if h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("opening a terminal activated project services")
	}
	if _, err := os.Stat(filepath.Join(prefs.Dir(), layoutFile)); !os.IsNotExist(err) {
		t.Fatalf("standalone terminal modified project layout: %v", err)
	}
	h.clickNamed(h.app.text.Tools.Terminal)
	h.settle()
	if len(p.terms.list) != 1 {
		t.Fatal("hiding the panel discarded its shell")
	}
	h.clickNamed(h.app.text.Tools.Terminal)
	h.settle()
	if len(p.terms.list) != 1 || p.terms.list[0] != term {
		t.Fatal("showing the panel created a duplicate shell")
	}
	h.app.closeTerminal(p, term.id)
	h.settle()
	if len(p.terms.list) != 0 || h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		t.Fatal("closing the last terminal did not release the panel")
	}
}
