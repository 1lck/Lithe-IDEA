package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type highlightGestureKernel struct {
	*testKernel
	requests chan core.EditorFindRequest
}

func (k *highlightGestureKernel) FindEditorText(ctx context.Context, source []byte, input core.EditorFindRequest) (core.EditorFindResult, error) {
	select {
	case k.requests <- input:
	default:
	}
	return k.Client.FindEditorText(ctx, source, input)
}

func openHighlightGestureDocument(t *testing.T, name, source string, vim bool) (*harness, *document, *highlightGestureKernel) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]any{"theme": "dark", "vimMode": vim}); err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	kernel := &highlightGestureKernel{testKernel: &testKernel{Client: client}, requests: make(chan core.EditorFindRequest, 8)}
	options := DesktopOptions(client, prefs, "test")
	options.Kernel, options.OpenFile = kernel, path
	options.PluginRoot = filepath.Join(root, "unread-plugins")
	h := newHarnessWithOptions(t, options)
	h.app.semantics.symbolHighlightDelay = -1
	h.app.openStandaloneFile(path)
	h.await("standalone editor", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
	h.settle()
	return h, h.app.project.docs.byPath(path), kernel
}

func requireHighlightGestureQuery(t *testing.T, h *harness, k *highlightGestureKernel, want string) {
	t.Helper()
	h.await("selection highlight request", func() bool {
		for len(k.requests) > 0 {
			got := <-k.requests
			if got.Query == want && got.WholeIdentifier && got.CaseSensitive {
				return true
			}
		}
		return false
	})
}

func TestSymbolHighlightsDoubleClickSelectsCompleteCodeIdentifier(t *testing.T) {
	for _, tc := range []struct{ file, identifier, want string }{
		{"example.ts", "$name", "$name"},
		{"example.py", "a\u203fb", "a\u203fb"},
		{"decomposed.py", "a\u0301b", "a\u0301b"},
		{"unicode-start.ts", "℘foo", "℘foo"},
		{"unicode-continuation.ts", "a·b", "a·b"},
		{"prose.txt", "$name", "name"},
	} {
		t.Run(tc.file, func(t *testing.T) {
			h, d, kernel := openHighlightGestureDocument(t, tc.file, tc.identifier+" = "+tc.identifier+"\n", false)
			_, firstRuneBytes := utf8.DecodeRuneInString(tc.identifier)
			d.view.SetSelection(firstRuneBytes, firstRuneBytes)
			h.settle()
			point, ok := d.view.CaretRect()
			if !ok {
				t.Fatal("editor has no caret geometry")
			}
			if err := h.driver.DoubleClick(point.X+1, point.Y+point.Height/2); err != nil {
				t.Fatal(err)
			}
			if got := d.view.SelectedText(); got != tc.want {
				t.Fatalf("double click selected %q, want %q", got, tc.want)
			}
			if tc.file != "prose.txt" {
				requireHighlightGestureQuery(t, h, kernel, tc.want)
			}
		})
	}
}

func TestSelectedWordHighlightsIgnoreUnicodeIdentifierSuffix(t *testing.T) {
	const source = "foo ℘foo foo"
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result, err := core.NewClient().FindEditorText(ctx, []byte(source), core.EditorFindRequest{
		Query: "foo", CaseSensitive: true, WholeIdentifier: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	end := strings.LastIndex(source, "foo")
	want := []editorview.Range{{Start: end, End: end + len("foo")}}
	if got := selectedIdentifierHighlights(result.Matches, 0, len("foo")); !slices.Equal(got, want) {
		t.Fatalf("identifier ranges = %+v, want %+v", got, want)
	}
}

func TestSymbolHighlightsUseVimVisualSelectionFromTextInput(t *testing.T) {
	h, d, kernel := openHighlightGestureDocument(t, "example.ts", "name = name\n", true)
	if err := h.driver.Type("ve"); err != nil {
		t.Fatal(err)
	}
	if got := d.view.SelectedText(); got != "name" {
		t.Fatalf("Vim visual selection = %q, want name", got)
	}
	requireHighlightGestureQuery(t, h, kernel, "name")
}

func TestSymbolHighlightsUseDocumentHighlightAndDiscardOldAnswer(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(3, 0)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending.operation != ""
	})
	first := a.semantics.symbolHighlights.pending
	req := f.kernel.request(0)
	if req.Operation != pluginSemanticDocumentHighlight || req.URI != f.d.sync.uri || req.Position == nil || *req.Position != (core.PluginDocumentPosition{}) {
		t.Fatalf("selection did not ask for document highlights at its start: %#v", req)
	}

	f.d.view.SetSelection(2, 2)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("new caret highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending != first && pending.operation != ""
	})
	second := a.semantics.symbolHighlights.pending
	if a.hasPending(first) {
		t.Fatal("old caret is still registered for highlights")
	}
	result := json.RawMessage(`{"ranges":[{"start":{"line":0,"utf16Column":0},"end":{"line":0,"utf16Column":3}}]}`)
	f.deliver(t, first.operation, pluginMethodDocumentHighlight, result)
	if a.semantics.symbolHighlights.pending != second {
		t.Fatal("old caret's answer settled the new request")
	}
	f.deliver(t, second.operation, pluginMethodDocumentHighlight, result)
	f.h.await("current highlight ranges projected into the document", func() bool {
		s := &a.semantics.symbolHighlights
		return s.pending == nil && s.cancel == nil
	})
}

func TestSelectedWordHighlightsUseCoreIdentifierMatching(t *testing.T) {
	const source = "😀 $task $$task task other_task Task $task$ task tasking $tasking $task"
	for _, tc := range []struct{ query, selected, repeated, partial string }{
		{"task", "task other_task", "task tasking", "tasking"},
		{"$task", "$task $$task", "$task", "$tasking"},
	} {
		t.Run(tc.query, func(t *testing.T) {
			start := strings.Index(source, tc.selected)
			end := start + len(tc.query)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			result, err := core.NewClient().FindEditorText(ctx, []byte(source), core.EditorFindRequest{
				Query: tc.query, CaseSensitive: true, WholeIdentifier: true, Caret: start,
			})
			if err != nil {
				t.Fatal(err)
			}
			second := strings.LastIndex(source, tc.repeated)
			want := []editorview.Range{{Start: second, End: second + len(tc.query)}}
			if got := selectedIdentifierHighlights(result.Matches, start, end); !slices.Equal(got, want) {
				t.Fatalf("identifier ranges = %+v, want %+v", got, want)
			}
			partial := strings.Index(source, tc.partial)
			if got := selectedIdentifierHighlights(result.Matches, partial, partial+len(tc.query)); len(got) != 0 {
				t.Fatalf("partial identifier selection displayed %v", got)
			}
		})
	}
}

func TestSymbolHighlightsKeepValidRangesFromMixedResponse(t *testing.T) {
	text := rope.FromString("😀task\r\ntask")
	positionRange := func(line, start, end int) core.PluginDocumentRange {
		return core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: line, UTF16Column: start},
			End:   core.PluginDocumentPosition{Line: line, UTF16Column: end},
		}
	}
	reported := []core.PluginDocumentRange{
		positionRange(0, 2, 6),
		positionRange(0, 1, 6), // Inside the emoji's surrogate pair.
		positionRange(1, 0, 5), // Past the end of the line.
		positionRange(1, 0, 4),
	}
	got, err := projectSymbolHighlightRanges(context.Background(), text, reported)
	want := []editorview.Range{{Start: 4, End: 8}, {Start: 10, End: 14}}
	if !errors.Is(err, editorview.ErrPosition) || !slices.Equal(got, want) {
		t.Fatalf("projected ranges = %+v, error = %v, want valid siblings %+v", got, err, want)
	}
}
