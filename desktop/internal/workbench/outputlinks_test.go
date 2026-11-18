package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// outputLinkManifest is a plugin that only declares a matcher: no backend, no
// language, no server. Core resolves a match to workspace files itself.
const outputLinkManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.output-links",
  "displayName": "Output Link Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"outputLinkMatchers": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": [],
  "activationEvents": [],
  "languages": [],
  "outputLinkMatchers": [{"id": "frame", "pattern": "at (?P<path>[\\w/.]+\\.txt):(?P<line>\\d+):(?P<column>\\d+)", "scope": "run"}]
}`

// startRunConsole shows a plugin-started run whose output is text, decoded as the run
// host's observer decodes it.
func (h *harness) startRunConsole(root, text string) {
	h.t.Helper()
	h.app.applyRunEvent(pluginservice.RunEvent{Type: pluginservice.RunStarted, RunID: "run-test", PluginID: "dev.lithe.test.output-links", Label: "Test run", Workspace: root})
	chunk, err := newOutputDecoder(h.app.kernel).decode(text)
	if err != nil {
		h.t.Fatal(err)
	}
	h.app.applyRunOutput("run-test", chunk)
}

// A wrapping console breaks its lines again only when the revision changed, so every change to
// what the buffer shows must change it: an open line that grows keeps the row count, and a
// trim keeps it too once the buffer is full.
func TestOutputBufferRevisionChangesWithEveryChangeItShows(t *testing.T) {
	b := newOutputBuffer(2, 1<<20)
	seen := map[uint64]bool{b.revision: true}
	step := func(what string, change func()) {
		t.Helper()
		change()
		if seen[b.revision] {
			t.Fatalf("%s left the revision at %d, which it had before", what, b.revision)
		}
		seen[b.revision] = true
	}
	step("an open line", func() { b.apply(outputChunk{open: styledLine{text: "par"}}) })
	step("the open line growing", func() { b.apply(outputChunk{open: styledLine{text: "partial"}}) })
	step("two finished lines", func() {
		b.apply(outputChunk{lines: []styledLine{{text: "one"}, {text: "two"}}})
	})
	count := b.count()
	step("a line that pushes the oldest out", func() { b.apply(outputChunk{lines: []styledLine{{text: "three"}}}) })
	if b.count() != count || b.row(0).text != "two" {
		t.Fatalf("rows = %d from %q, want %d from \"two\"", b.count(), b.row(0).text, count)
	}
	step("sealing the open line", func() {
		b.apply(outputChunk{open: styledLine{text: "tail"}})
		b.seal()
	})
	step("clearing", b.clear)
}

func TestOutputSegmentsCutAtStyleAndLinkBoundaries(t *testing.T) {
	bold := core.OutputStyle{Bold: true}
	// 😀 is two UTF-16 units, so "at" starts at unit 3.
	line := styledLine{text: "😀 at x.txt:3 ok", spans: []core.OutputSpan{{Start: 0, Length: 5, Style: bold}}}
	links := []core.OutputLink{
		{Start: 14, Length: 9}, // runs past the line
		{Start: 3, Length: 10},
		{Start: 5, Length: 2}, // overlaps the link before it
	}
	segments := outputSegments(line, links)
	want := []struct {
		text   string
		bold   bool
		linked bool
	}{{"😀 ", true, false}, {"at", true, true}, {" x.txt:3", false, true}, {" ok", false, false}}
	if len(segments) != len(want) {
		t.Fatalf("segments = %+v, want %d", segments, len(want))
	}
	for index, segment := range segments {
		w := want[index]
		if segment.text != w.text || segment.style.Bold != w.bold || (segment.link != nil) != w.linked {
			t.Errorf("segment %d = %q bold=%v link=%v, want %q bold=%v link=%v", index, segment.text, segment.style.Bold, segment.link != nil, w.text, w.bold, w.linked)
		}
		if segment.link != nil && segment.link.Start != 3 {
			t.Errorf("segment %d links %+v, want the link at 3", index, *segment.link)
		}
	}
	// An offset inside a character moves to its end, so no piece splits the character.
	split := outputSegments(styledLine{text: "😀a", spans: []core.OutputSpan{{Start: 1, Length: 2, Style: bold}}}, nil)
	if len(split) != 2 || split[0].text != "😀" || split[0].style.Bold || split[1].text != "a" || !split[1].style.Bold {
		t.Fatalf("segments = %+v, want the whole emoji plain and a bold", split)
	}
}

func TestOutputInkResolvesPaletteBrightBoldAndRGB(t *testing.T) {
	var ink outputInk
	for index := range ink.ansi {
		ink.ansi[index] = [3]uint8{uint8(index), 0, 0}
	}
	blue := 4
	if got, ok := ink.color(&core.OutputColor{Index: &blue}, true); !ok || got != rgbColor(12, 0, 0) {
		t.Fatalf("bold blue = %+v %v, want the bright entry 12", got, ok)
	}
	if got, ok := ink.color(&core.OutputColor{Index: &blue}, false); !ok || got != rgbColor(4, 0, 0) {
		t.Fatalf("blue = %+v %v, want entry 4", got, ok)
	}
	if got, ok := ink.color(&core.OutputColor{RGB: "#0a141e"}, false); !ok || got != rgbColor(10, 20, 30) {
		t.Fatalf("rgb = %+v %v", got, ok)
	}
	for _, color := range []*core.OutputColor{nil, {RGB: "0a141e"}, {RGB: "#zzzzzz"}} {
		if _, ok := ink.color(color, false); ok {
			t.Fatalf("color %+v resolved, want the console's own", color)
		}
	}
}

func TestRunOutputLinkOpensTheFileAtItsLineAndColumn(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.output-links", outputLinkManifest, false)
	root := t.TempDir()
	target := filepath.Join(root, "src", "main.txt")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("one\ntwo\nthree\nfour\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	p := h.app.project
	// A line the matcher recognizes and one it does not.
	h.startRunConsole(root, "boot ok\nerror at src/main.txt:3:2 failed\n")
	for range 6 {
		h.settle()
	}
	if len(p.links.sources) != 1 {
		t.Fatalf("sources = %+v, want the one plugin matcher", p.links.sources)
	}
	h.clickNamed("at src/main.txt:3:2")
	d := awaitLinkedFile(t, h, p, target)
	if line, column := d.view.Caret(); line != 2 || column != 1 {
		t.Fatalf("caret = %d:%d, want the link's 2:1", line, column)
	}
}

func TestOutputLinkToAMissingFileOnlyNotifies(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.output-links", outputLinkManifest, false)
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	p := h.app.project
	h.startRunConsole(root, "error at missing.txt:1:1\n")
	for range 6 {
		h.settle()
	}
	h.clickNamed("at missing.txt:1:1")
	for range 4 {
		h.settle()
	}
	if len(p.docs.list) != 0 {
		t.Fatal("a link to a missing file opened a document")
	}
}

// A web address a run prints opens in the browser when clicked, with no plugin
// declaring a matcher (#1822): Core links addresses itself, so the window asks it
// even without plugins. The trailing period is not part of the address.
func TestRunOutputWebAddressOpensInTheBrowser(t *testing.T) {
	var opened []string
	previous := openURL
	openURL = func(url string) error {
		opened = append(opened, url)
		return nil
	}
	t.Cleanup(func() { openURL = previous })
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	p := h.app.project
	h.startRunConsole(root, "boot ok\nTomcat started on http://localhost:8080/.\n")
	for range 6 {
		h.settle()
	}
	if links := p.links.links[outputLinkKey(outputScopeRun, "boot ok")]; len(links) != 0 {
		t.Fatalf("a line without an address has links %+v", links)
	}
	h.clickNamed("http://localhost:8080/")
	h.settle()
	if len(opened) != 1 || opened[0] != "http://localhost:8080/" {
		t.Fatalf("opened %q, want the address", opened)
	}
}
