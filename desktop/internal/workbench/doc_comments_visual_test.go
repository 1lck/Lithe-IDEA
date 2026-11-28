//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

const visualArrayListJava = `package java.util;

/**
 * Resizable-array implementation of the {@code List} interface. Implements
 * all optional list operations, and permits all elements, including
 * {@code null}. In addition to implementing the {@code List} interface,
 * this class provides methods to manipulate the size of the array that is
 * used internally to store the list. (This class is roughly equivalent to
 * {@code Vector}, except that it is unsynchronized.)
 *
 * <p>The {@code size}, {@code isEmpty}, {@code get}, {@code set},
 * {@code iterator}, and {@code listIterator} operations run in constant
 * time. The {@code add} operation runs in <i>amortized constant time</i>,
 * that is, adding n elements requires O(n) time.
 *
 * <p><strong>Note that this implementation is not synchronized.</strong>
 * If multiple threads access an {@code ArrayList} instance concurrently,
 * and at least one of the threads modifies the list structurally, it
 * <i>must</i> be synchronized externally. This is best done at creation
 * time, to prevent accidental unsynchronized access to the list:<pre>
 *   List list = Collections.synchronizedList(new ArrayList(...));</pre>
 *
 * <p id="fail-fast">
 * The iterators returned by this class's {@link #iterator() iterator} and
 * {@link #listIterator(int) listIterator} methods are <em>fail-fast</em>:
 * if the list is structurally modified at any time after the iterator is
 * created, in any way except through the iterator's own
 * {@link ListIterator#remove() remove} or
 * {@link ListIterator#add(Object) add} methods, the iterator will throw a
 * {@link ConcurrentModificationException}. Thus, in the face of
 * concurrent modification, the iterator fails quickly and cleanly, rather
 * than risking arbitrary, non-deterministic behavior at an undetermined
 * time in the future.
 *
 * <p>Note that the fail-fast behavior of an iterator cannot be guaranteed
 * as it is, generally speaking, impossible to make any hard guarantees in the
 * presence of unsynchronized concurrent modification. Fail-fast iterators
 * throw {@code ConcurrentModificationException} on a best-effort basis.
 *
 * <p>This class is a member of the
 * <a href="https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/package-summary.html">
 * Java Collections Framework</a>.
 *
 * @param <E> the type of elements in this list
 * @author Josh Bloch, Neal Gafter
 * @see Collection
 * @see List
 * @see LinkedList
 * @see Vector
 * @since 1.2
 */
public class ArrayList<E> extends AbstractList<E> implements List<E> {
    private static final int DEFAULT_CAPACITY = 10;

    public int size() {
        return 0;
    }
}
`

const visualHoverHTMLPayload = "```java\npublic class ArrayList<E> extends AbstractList<E>\n```\n\n" +
	"<p>Resizable-array implementation of the <code>List</code> interface.</p>\n" +
	"<p>The iterators returned by this class are <em>fail-fast</em> and throw <code>ConcurrentModificationException</code>.</p>\n" +
	"<ul><li><b>Constant time</b>: <code>size</code>, <code>get</code>, <code>set</code></li><li><b>Amortized O(1)</b>: <code>add</code></li></ul>\n" +
	"<pre>List list = Collections.synchronizedList(new ArrayList&lt;&gt;());</pre>"

func TestVisualDocCommentRenderingAndHoverHTML(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name     string
		theme    string
		language string
	}{
		{name: "light-zh", theme: "light", language: "zh-Hans"},
		{name: "dark-zh", theme: "dark", language: "zh-Hans"},
		{name: "light-en", theme: "light", language: "en"},
		{name: "dark-en", theme: "dark", language: "en"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "ArrayList.java")
			if err := os.WriteFile(path, []byte(visualArrayListJava), 0o600); err != nil {
				t.Fatal(err)
			}
			on := true
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme:           themeChoice(tc.theme),
				Language:        tc.language,
				DisableAutoSave: true,
				HideMinimap:     true,
				EditorPreferences: core.EditorStoredPreferences{
					RenderDocComments: &on,
				},
			}); err != nil {
				t.Fatal(err)
			}

			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel:    &testKernel{Client: core.NewClient()},
				Store:     prefs,
				Languages: []string{tc.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 960
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.app.editor.docComments.scanDelay = -1
			h.open(root)
			p := h.app.project
			h.app.openFile(p, path)
			h.await("ArrayList.java rendered doc comment ready", func() bool {
				d := p.docs.byPath(path)
				if d == nil || d.view.ActiveDocBlockCount() != 1 {
					return false
				}
				text, ok := d.view.RenderedDocBlockText(2)
				return ok && strings.Contains(text, "Resizable-array") && strings.Contains(text, "Josh Bloch")
			})
			h.app.invalidator.Invalidate()
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "doc-comments-arraylist-"+tc.name+".png")); err != nil {
				t.Fatal(err)
			}

			// Capture Hover popup with embedded HTML tags on light-en and dark-zh.
			if tc.name == "light-en" || tc.name == "dark-zh" {
				d := p.docs.byPath(path)
				d.view.SetAllDocBlocksRendered(false)
				h.app.invalidator.Invalidate()
				h.settleChain()
				h.app.semantics.project = p
				anchor := gfx.Rect{X: 380, Y: 160, Width: 80, Height: 20}
				h.app.showSemanticHover(p, d, visualHoverHTMLPayload, true, 51, 14, nil, anchor, false)
				h.await("hover code highlighted", func() bool {
					return h.app.semantics.hover.open && h.app.semantics.hover.page != nil && h.app.semantics.hover.page.tokens != nil
				})
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "doc-comments-hover-"+tc.name+".png")); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
