package workbench

import (
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
)

// TestLogCommitDetailsWrapReferenceChips checks that the reference chips under the author
// line of the commit details wrap onto more lines in a narrow pane instead of running past
// its edge: every chip is drawn inside the details, a chip that fits a line is drawn whole,
// and a chip wider than a line has one to itself and is cut short.
func TestLogCommitDetailsWrapReferenceChips(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	dir := newTestRepository(t)
	head := gitRun(t, dir, "rev-parse", "HEAD")
	long := "a-tag-far-wider-than-the-commit-details-" + strings.Repeat("x", 160)
	tags := []string{"v1.0.0", "release-candidate", "nightly-build", "stable", long}
	for _, tag := range tags {
		gitRun(t, dir, "tag", tag)
	}
	h.app.delays = logDelays{}
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	v := &h.app.logView
	// The details at their least width are the narrow pane. A tall bottom area and short
	// changed files leave the commit details room for every line of chips, so none is
	// scrolled out of the frame.
	v.detailWidth = logDetailsMin
	v.filesSplit.Pos = logFilesMin
	h.app.layout.bottom = 10000
	h.app.layout.gitTab = 0
	h.settle()
	if !p.log.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	h.app.selectCommit(p, head)
	h.settle()
	h.settle()
	if p.log.detail == nil {
		t.Fatalf("no details of %q: files %v", head, p.log.filesState)
	}

	// The chips are the commit's labels but HEAD, in the order the details draw them.
	var chips []core.GraphLabel
	for _, row := range p.log.graph.Rows {
		if row.CommitHash == head {
			chips = slices.DeleteFunc(slices.Clone(row.Labels), func(x core.GraphLabel) bool { return x.Kind == "head" })
			break
		}
	}
	for _, tag := range tags {
		if !slices.ContainsFunc(chips, func(x core.GraphLabel) bool { return x.Title == tag }) {
			t.Fatalf("no chip for the tag %q among %+v", tag, chips)
		}
	}
	if len(v.refWidths) != len(chips) || len(v.refStarts) < 2 {
		t.Fatalf("%d chips measured %v and wrapped at %v, want all %d in at least two lines", len(v.refWidths), v.refWidths, v.refStarts, len(chips))
	}
	wide := slices.IndexFunc(chips, func(x core.GraphLabel) bool { return x.Title == long })
	if line := slices.Index(v.refStarts, wide); line < 0 || line+1 < len(v.refStarts) && v.refStarts[line+1] != wide+1 {
		t.Fatalf("the chip wider than a line, %d, shares a line: lines start at %v", wide, v.refStarts)
	}

	// The details pane starts after its splitter and is detailWidth wide; the chips lie
	// below the changed files, inside the pane's padding.
	split := h.hit(logSplitDetails)
	left, top := split.Right(), v.fileScroll.Area.Bottom()
	contentLeft, contentRight := left+logDetailPad, left+v.detailWidth-logDetailPad
	var drawn []app.Label
	for _, label := range h.driver.Snapshot().Labels {
		if label.FontSize == h.app.theme.Metrics.FontSizeS && label.Bounds.X >= left && label.Bounds.Y >= top {
			drawn = append(drawn, label)
		}
	}
	const chrome = 2*logRefChipPad + logRefIconSize + logRefChipGap
	const slack = 0.5
	lines := map[float32]bool{}
	for i, chip := range chips {
		var label app.Label
		found := false
		for _, d := range drawn {
			if d.Value == chip.Title || i == wide && strings.HasPrefix(d.Value, long[:24]) {
				label, found = d, true
				break
			}
		}
		if !found {
			t.Fatalf("chip %q is not drawn in the details; drawn %+v", chip.Title, drawn)
		}
		lines[label.Bounds.Y] = true
		if label.Bounds.X-logRefIconSize-logRefChipGap-logRefChipPad < contentLeft-slack ||
			label.Bounds.Right()+logRefChipPad > contentRight+slack {
			t.Errorf("chip %q drawn at %+v, outside the details' %v..%v", chip.Title, label.Bounds, contentLeft, contentRight)
		}
		text := v.refWidths[i] - chrome
		if i == wide {
			if label.Bounds.Width >= text {
				t.Errorf("the chip wider than a line kept its name %v wide, want it cut short of %v", label.Bounds.Width, text)
			}
		} else if label.Bounds.Width < text-slack {
			t.Errorf("chip %q is %v wide, want its whole name %v", chip.Title, label.Bounds.Width, text)
		}
	}
	if len(lines) < 2 {
		t.Fatalf("the chips are drawn in %d lines, want at least two", len(lines))
	}
}
