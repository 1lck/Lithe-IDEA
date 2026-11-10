package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// outputLinkManifest is a plugin that only declares a matcher: no backend, no
// language, no server. Core resolves a match to workspace files itself.
const outputLinkManifest = `{
  "schemaVersion": 2,
  "id": "dev.lithe.test.output-links",
  "displayName": "Output Link Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 4,
  "requires": {"outputLinkMatchers": 1},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": [],
  "activationEvents": [],
  "languages": [],
  "outputLinkMatchers": [{"id": "frame", "pattern": "at (?P<path>[\\w/.]+\\.txt):(?P<line>\\d+):(?P<column>\\d+)", "scope": "run"}]
}`

// startRunConsole shows a plugin-started run whose output is text, as the run
// host's events would.
func (h *harness) startRunConsole(root, text string) {
	h.t.Helper()
	h.app.applyRunEvent(pluginservice.RunEvent{Type: pluginservice.RunStarted, RunID: "run-test", PluginID: "dev.lithe.test.output-links", Label: "Test run", Workspace: root})
	h.app.applyRunEvent(pluginservice.RunEvent{Type: pluginservice.RunOutput, RunID: "run-test", Text: text})
}

func TestSplitUTF16CutsAtCodeUnitOffsets(t *testing.T) {
	cases := []struct {
		line                string
		from, start, length int
		before, linked      string
		ok                  bool
	}{
		{"ab at x.txt:3 end", 0, 3, 10, "ab ", "at x.txt:3", true},
		{"😀 at x.txt:3", 0, 3, 10, "😀 ", "at x.txt:3", true},
		{"😀 at x.txt:3", 2, 3, 10, " ", "at x.txt:3", true},
		{"abc", 0, 1, 5, "", "", false},
		{"abc", 2, 1, 1, "", "", false},
		{"abc", 0, 0, 0, "", "", false},
		{"abc", 0, 0, 3, "", "abc", true},
	}
	for _, c := range cases {
		before, linked, ok := splitUTF16(c.line, c.from, c.start, c.length)
		if before != c.before || linked != c.linked || ok != c.ok {
			t.Errorf("splitUTF16(%q,%d,%d,%d) = %q,%q,%v want %q,%q,%v", c.line, c.from, c.start, c.length, before, linked, ok, c.before, c.linked, c.ok)
		}
	}
	if got := utf16Tail("😀 ab", 3); got != "ab" {
		t.Errorf("utf16Tail = %q", got)
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
	link := h.hit(runOutputLinks.At(0))
	h.click(center(link))
	awaitStateWithin(t, h, 20*time.Second, "the linked file to open", func() bool {
		d := p.docs.byPath(target)
		if d == nil {
			return false
		}
		line, column := d.view.Caret()
		return line == 2 && column == 1
	})
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
	h.click(center(h.hit(runOutputLinks.At(0))))
	for range 4 {
		h.settle()
	}
	if len(p.docs.list) != 0 {
		t.Fatal("a link to a missing file opened a document")
	}
}
