package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vivaui/viva/gfx"
)

// clangdSemanticsDocument opens a real C fixture through the workbench and
// returns the document plus the byte position of needle, so a test drives the
// same editor paths a user does.
func clangdSemanticsDocument(t *testing.T, h *harness, root, content, needle string) (*project, *document, int, int) {
	t.Helper()
	h.open(root)
	p, d, _ := openClangdDocument(t, h, root, content)
	index := strings.Index(content, needle)
	if index < 0 {
		t.Fatalf("fixture does not contain %q", needle)
	}
	before := content[:index]
	line := strings.Count(before, "\n")
	column := index - strings.LastIndex(before, "\n") - 1
	if !d.view.GoToNavigation(line, column, false) {
		t.Fatal("could not place the caret")
	}
	return p, d, line, column
}

func TestClangdDefinitionJumpsToHeader(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	header := filepath.Join(root, "lib.h")
	if err := os.WriteFile(header, []byte("int add(int left, int right);\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	content := "#include \"lib.h\"\nint main(void) { return add(1, 2); }\n"
	clangdSemanticsDocument(t, h, root, content, "add(1")
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyF12, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 15*time.Second, "clangd definition", func() bool {
		return documentNamed(h.app.project, "lib.h") != nil
	})
	p := h.app.project
	target := documentNamed(p, "lib.h")
	if target == nil {
		t.Fatal("the definition target did not open")
	}
	line, _ := target.view.CaretUTF16()
	text, _ := target.view.Text()
	lines := strings.Split(string(text), "\n")
	if line < 0 || line >= len(lines) || !strings.Contains(lines[line], "add") {
		t.Fatalf("caret line %d does not contain the definition: %q", line, lines)
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
}

func TestClangdHoverShowsNormalisedContents(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	content := "int add(int left, int right) { return left + right; }\nint main(void) { return add(1, 2); }\n"
	clangdSemanticsDocument(t, h, root, content, "add(1")
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyF1, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 30*time.Second, "clangd hover", func() bool {
		return h.app.semantics.hover.open
	})
	if !strings.Contains(h.app.semantics.hover.contents, "add") {
		t.Fatalf("hover contents = %q", h.app.semantics.hover.contents)
	}
	if !h.shows("add") {
		t.Fatalf("hover contents are not painted: %v", h.driver.Snapshot().Labels)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.semantics.hover.open {
		t.Fatal("Escape did not close the hover popup")
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
}

func TestClangdExplicitCompletionAcceptsItem(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	header := filepath.Join(root, "lib.h")
	if err := os.WriteFile(header, []byte("int add(int left, int right);\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	content := "int add(int left, int right) { return left + right; }\nint main(void) { return ad; }\n"
	_, d, line, column := clangdSemanticsDocument(t, h, root, content, "ad;")
	if !d.view.GoToNavigation(line, column+2, false) {
		t.Fatal("could not place the caret after the prefix")
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 10*time.Second, "clangd completion", func() bool {
		return len(h.app.semantics.completion.items) > 0
	})
	items := h.app.semantics.completion.items
	index := -1
	for i, item := range items {
		if strings.TrimSpace(item.Label) == "add" {
			index = i
			break
		}
	}
	if index < 0 {
		t.Fatalf("clangd completion did not offer add: %+v", items)
	}
	if items[index].TextEdit == nil {
		t.Fatalf("clangd completion for add has no text edit: %+v", items[index])
	}
	h.app.semantics.completion.selected = index
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the accepted completion text", func() bool {
		data, _ := d.view.Text()
		return strings.Contains(string(data), "add") && !strings.Contains(string(data), "adadd")
	})
	data, _ := d.view.Text()
	if !strings.Contains(string(data), "add") || strings.Contains(string(data), "adadd") {
		t.Fatalf("text after accepting add = %q", string(data))
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
}

func documentNamed(p *project, name string) *document {
	if p == nil {
		return nil
	}
	for _, d := range p.docs.list {
		if filepath.Base(d.path) == name {
			return d
		}
	}
	return nil
}

func TestClangdFindReferencesListsUses(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	content := "int add(int left, int right) { return left + right; }\nint main(void) { return add(1, 2) + add(3, 4); }\n"
	clangdSemanticsDocument(t, h, root, content, "add(1")
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyF12, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 30*time.Second, "clangd references", func() bool {
		return h.app.semantics.definition.open
	})
	if got := len(h.app.semantics.definition.targets); got < 3 {
		t.Fatalf("references = %d, want declaration and two uses", got)
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
}

func TestClangdRenameEditsEveryOccurrence(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	content := "int add(int left, int right) { return left + right; }\nint main(void) { return add(1, 2); }\n"
	_, d, _, _ := clangdSemanticsDocument(t, h, root, content, "add(1")
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyF2, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.semantics.rename.name.Text() != "add" {
		t.Fatalf("prefill = %q", h.app.semantics.rename.name.Text())
	}
	h.app.semantics.rename.name.SetText("sum")
	h.app.confirmPluginRename()
	awaitStateWithin(t, h, 30*time.Second, "clangd rename", func() bool {
		data, _ := d.view.Text()
		return strings.Count(string(data), "sum") == 2
	})
	data, _ := d.view.Text()
	if strings.Contains(string(data), "add") {
		t.Fatalf("text after rename = %q", data)
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
}
