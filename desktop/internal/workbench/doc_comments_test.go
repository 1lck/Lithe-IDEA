package workbench

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const sampleArrayListJava = `package java.util;

/**
 * Resizable-array implementation of the {@code List} interface. Implements
 * all optional list operations, and permits all elements, including
 * {@code null}.
 *
 * <p><strong>Note that this implementation is not synchronized.</strong>
 * If multiple threads access an {@code ArrayList} instance concurrently,
 * it <i>must</i> be synchronized externally:
 * <pre>
 *   List list = Collections.synchronizedList(new ArrayList(...));
 * </pre>
 *
 * <p id="fail-fast">
 * The iterators returned by this class's {@link #iterator() iterator} and
 * {@link #listIterator(int) listIterator} methods are <em>fail-fast</em>:
 * if the list is structurally modified, the iterator will throw a
 * {@link ConcurrentModificationException}.
 *
 * <p>Note that the fail-fast behavior of an iterator cannot be guaranteed.
 * Fail-fast iterators throw {@code ConcurrentModificationException} on a
 * best-effort basis.
 *
 * @param <E> the type of elements in this list
 * @author Josh Bloch
 * @author Neal Gafter
 * @see Collection
 * @see List
 * @since 1.2
 */
public class ArrayList<E> {
    public int size() {
        return 0;
    }
}
`

const sampleRustDocFile = `/// Computes the next value.
///
/// <p>Handles <em>embedded HTML</em> alongside <strong>Markdown</strong>.</p>
///
/// ` + "```rust" + `
/// let x = compute(42);
/// ` + "```" + `
pub fn compute(v: i32) -> i32 {
    v + 1
}
`

func TestDocCommentRenderingEndToEndArrayListReadOnlyAndLocalized(t *testing.T) {
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{
		Theme:           themeLight,
		Language:        "zh-Hans",
		DisableAutoSave: true,
	}); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     prefs,
		Languages: []string{"zh-Hans"},
	})
	h.app.editor.docComments.scanDelay = -1

	root := t.TempDir()
	h.open(root)
	p := h.app.project

	// Open as a virtual read-only external source (e.g., JDK ArrayList.java):
	// RenderDocCommentsInReadOnly defaults to true so it renders automatically.
	content := editorview.Prepare([]byte(sampleArrayListJava))
	grammar := h.app.syntaxRegistry().Syntax("java")
	if grammar == nil {
		t.Fatal("java bundled grammar missing")
	}
	h.app.placeDocumentAs(p, "jar:///jdk/java/util/ArrayList.java", "ArrayList.java", content, grammar, "java", true)
	h.settleChain()
	d := p.docs.byPath("jar:///jdk/java/util/ArrayList.java")
	if d == nil {
		t.Fatal("virtual java document did not open")
	}
	if !d.view.ReadOnly() {
		t.Fatal("virtual document should be read-only")
	}

	h.await("ArrayList Javadoc rendered natively", func() bool {
		return d.view.DocBlockCount() == 1 && d.view.ActiveDocBlockCount() == 1
	})

	rendered, ok := d.view.RenderedDocBlockText(2)
	if !ok {
		t.Fatal("expected rendered doc block starting at line 2")
	}
	for _, want := range []string{
		"Resizable-array implementation",
		"fail-fast",
		"ConcurrentModificationException",
		"Collections.synchronizedList",
		"Josh Bloch",
		"自:",
		"请参阅:",
		"作者:",
		"类型形参:",
	} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("rendered Javadoc missing %q:\n%s", want, rendered)
		}
	}
	for _, raw := range []string{"<p", "<em>", "<strong>", "<pre>", "{@code", "{@link", "@since", "@author"} {
		if strings.Contains(rendered, raw) {
			t.Fatalf("rendered Javadoc leaked raw tag %q:\n%s", raw, rendered)
		}
	}

	// Copy rendered comment text writes clean rendered prose to clipboard.
	h.app.copyRenderedDocComment(d, 2)
	if clip := h.driver.Clipboard(); !strings.Contains(clip, "Resizable-array implementation") || strings.Contains(clip, "<p") {
		t.Fatalf("unexpected copied rendered doc text: %q", clip)
	}

	// Local anchor jump succeeds cleanly; symbol and non-web links are safe no-ops.
	h.app.handleDocCommentLink(d, "anchor:fail-fast")
	h.app.handleDocCommentLink(d, "symbol:#iterator()")
	h.app.handleDocCommentLink(d, "external:javascript:alert(1)")

	// Switching UI language to English re-renders localized section labels.
	h.app.setLanguage("en")
	h.settleChain()
	h.await("ArrayList Javadoc re-rendered in English", func() bool {
		text, ok := d.view.RenderedDocBlockText(2)
		return ok && strings.Contains(text, "Since:") && strings.Contains(text, "See also:")
	})
}

func TestDocCommentToggleReadOnlyEditInvalidationAndCommands(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.editor.docComments.scanDelay = -1
	root := t.TempDir()
	h.open(root)
	path := filepath.Join(root, "ArrayList.java")
	if err := os.WriteFile(path, []byte(sampleArrayListJava), 0o600); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("document did not open")
	}

	// Writable file opens in source mode by default (RenderDocComments=false),
	// with the doc comment candidate already discovered.
	h.await("doc comment candidate discovered", func() bool {
		return d.view.DocBlockCount() == 1
	})
	if d.view.ActiveDocBlockCount() != 0 {
		t.Fatalf("writable file should default to source mode, got %d active", d.view.ActiveDocBlockCount())
	}

	// Toggling ReadOnly on activates Reader Mode auto-rendering; toggling off restores source.
	h.app.toggleReadOnly(d)
	h.settleChain()
	h.await("read-only mode auto-renders doc comment", func() bool {
		return d.view.ActiveDocBlockCount() == 1
	})
	h.app.toggleReadOnly(d)
	h.settleChain()
	if d.view.ActiveDocBlockCount() != 0 {
		t.Fatalf("leaving read-only mode should restore source mode, got %d active", d.view.ActiveDocBlockCount())
	}

	// Command palette exposes render-all and toggle actions.
	d.view.GoToLine(4) // 1-based line inside the Javadoc
	cmds := h.app.commands()
	var renderAll, toggleOne, editAll *command
	for i := range cmds {
		switch cmds[i].id {
		case "editor.renderAllDocComments":
			renderAll = &cmds[i]
		case "editor.toggleRenderedDocComment":
			toggleOne = &cmds[i]
		case "editor.editAllDocComments":
			editAll = &cmds[i]
		}
	}
	if renderAll == nil || !renderAll.runnable() {
		t.Fatal("editor.renderAllDocComments command should be runnable")
	}
	if toggleOne == nil || !toggleOne.runnable() {
		t.Fatal("editor.toggleRenderedDocComment command should be runnable on doc comment line")
	}
	if editAll == nil || editAll.runnable() {
		t.Fatal("editor.editAllDocComments should be disabled while no blocks are rendered")
	}

	// Run render-all command and verify rendered output.
	h.app.startCommand(*renderAll, surfacePalette)
	h.settleChain()
	h.await("renderAllDocComments activates block", func() bool {
		return d.view.ActiveDocBlockCount() == 1
	})

	// Toggle back to source, edit inside comment, then render again and confirm new content appears.
	h.app.toggleDocCommentAtLine(d, 2)
	h.settleChain()
	if d.view.ActiveDocBlockCount() != 0 {
		t.Fatal("toggleDocCommentAtLine did not switch block back to source")
	}
	idx := strings.Index(sampleArrayListJava, "Resizable-array")
	if idx < 0 {
		t.Fatal("sample text marker missing")
	}
	if err := d.view.ApplyEdits([]editorview.TextEdit{{
		Range: editorview.Range{Start: idx, End: idx + len("Resizable-array")},
		Text:  "Updated-dynamic-array",
	}}); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	h.await("edited doc comment rescanned", func() bool {
		return d.docComments.scannedRevision == d.view.Revision() && !d.docComments.scanning
	})
	h.app.toggleDocCommentAtLine(d, 2)
	h.settleChain()
	h.await("re-rendered edited doc comment", func() bool {
		text, ok := d.view.RenderedDocBlockText(2)
		return ok && strings.Contains(text, "Updated-dynamic-array")
	})

	// Closing document cancels and clears doc comment state cleanly.
	h.app.removeDocument(p, d)
	if d.view.DocBlockCount() != 0 || d.docComments.scanning {
		t.Fatal("removeDocument did not clear doc comment state")
	}
}

func TestDocCommentRenderingSupportsRustSlashDocComments(t *testing.T) {
	on := true
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{
		Theme:           themeDark,
		Language:        "en",
		DisableAutoSave: true,
		EditorPreferences: core.EditorStoredPreferences{
			RenderDocComments: &on,
		},
	}); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     prefs,
		Languages: []string{"en"},
	})
	h.app.editor.docComments.scanDelay = -1

	root := t.TempDir()
	h.open(root)
	path := filepath.Join(root, "lib.rs")
	if err := os.WriteFile(path, []byte(sampleRustDocFile), 0o600); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("rust document did not open")
	}

	h.await("Rust /// doc comment rendered natively", func() bool {
		return d.view.DocBlockCount() == 1 && d.view.ActiveDocBlockCount() == 1
	})
	rendered, ok := d.view.RenderedDocBlockText(0)
	if !ok {
		t.Fatal("expected rendered Rust doc block at line 0")
	}
	if !strings.Contains(rendered, "embedded HTML") || !strings.Contains(rendered, "compute(42)") {
		t.Fatalf("unexpected Rust rendered doc text: %q", rendered)
	}
	if strings.Contains(rendered, "<p>") || strings.Contains(rendered, "<em>") {
		t.Fatalf("Rust rendered doc leaked raw HTML tags: %q", rendered)
	}
}

func TestDocCommentReadOnlyPrefPreservesWritableChoiceAndOffScreenRenderAllCancel(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.editor.docComments.scanDelay = -1

	root := t.TempDir()
	h.open(root)
	var longSrc strings.Builder
	longSrc.WriteString("/**\n * Top class docs.\n */\npublic class LongDemo {\n")
	for i := range 120 {
		fmt.Fprintf(&longSrc, "    int field%d = %d;\n", i, i)
	}
	longSrc.WriteString("}\n")

	path := filepath.Join(root, "LongDemo.java")
	if err := os.WriteFile(path, []byte(longSrc.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("LongDemo.java did not open")
	}
	h.await("doc comment candidate discovered", func() bool {
		return d.view.DocBlockCount() == 1
	})

	// 1. Manually render the comment in a writable file, then disable read-only
	// auto-rendering: writable file's effective default did not change, so its
	// manual choice must be preserved.
	h.app.toggleDocCommentAtLine(d, 0)
	h.settleChain()
	h.await("manual toggle renders comment", func() bool {
		return d.view.ActiveDocBlockCount() == 1
	})
	prefs := h.app.editorPreferences
	prefs.RenderDocCommentsInReadOnly = false
	h.app.editorPreferences = prefs
	h.app.applyDocCommentPreferences()
	h.settleChain()
	if d.view.ActiveDocBlockCount() != 1 || d.view.RequestedDocBlockCount() != 1 {
		t.Fatalf("changing read-only preference reset writable file manual choice: active=%d requested=%d",
			d.view.ActiveDocBlockCount(), d.view.RequestedDocBlockCount())
	}

	// 2. Switch back to source, jump far off-screen from line 0, run Render All:
	// even while ActiveDocBlockCount == 0 (off-screen), Show Source for All must
	// become enabled and cancel the queued render.
	h.app.setAllDocCommentsRendered(d, false)
	h.settleChain()
	d.view.GoToLine(110)
	h.settleChain()
	h.app.setAllDocCommentsRendered(d, true)
	h.settleChain()
	if d.view.RequestedDocBlockCount() != 1 {
		t.Fatalf("RequestedDocBlockCount = %d, want 1 after off-screen Render All", d.view.RequestedDocBlockCount())
	}
	var editAll *command
	for _, cmd := range h.app.commands() {
		if cmd.id == "editor.editAllDocComments" {
			c := cmd
			editAll = &c
			break
		}
	}
	if editAll == nil || !editAll.runnable() {
		t.Fatal("editor.editAllDocComments must be runnable after off-screen Render All")
	}
	h.app.startCommand(*editAll, surfacePalette)
	h.settleChain()
	if d.view.RequestedDocBlockCount() != 0 {
		t.Fatalf("RequestedDocBlockCount = %d after Show Source for All, want 0", d.view.RequestedDocBlockCount())
	}

	// 3. Render All followed by Fold All (which collapses the fold starting on
	// /** without clearing wantRendered): Render All must remain available and
	// running it unfolds the same-start fold so the comment renders again.
	d.view.GoToLine(1)
	h.app.setAllDocCommentsRendered(d, true)
	h.settleChain()
	h.await("comment rendered before Fold All", func() bool {
		return d.view.ActiveDocBlockCount() == 1
	})
	d.view.FoldAll()
	h.settleChain()
	if !d.view.CanRenderAllDocBlocks() {
		t.Fatal("CanRenderAllDocBlocks() = false after FoldAll collapsed same-start doc comment fold, want true")
	}
	var renderAll *command
	for _, cmd := range h.app.commands() {
		if cmd.id == "editor.renderAllDocComments" {
			c := cmd
			renderAll = &c
			break
		}
	}
	if renderAll == nil || !renderAll.runnable() {
		t.Fatal("editor.renderAllDocComments must remain runnable after FoldAll collapses a doc comment")
	}
	h.app.startCommand(*renderAll, surfacePalette)
	h.settleChain()
	h.await("Render All reopens same-start fold and renders comment", func() bool {
		return d.view.ActiveDocBlockCount() == 1 && !d.view.CanRenderAllDocBlocks()
	})
}
