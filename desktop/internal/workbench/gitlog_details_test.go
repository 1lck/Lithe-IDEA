package workbench

import (
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// TestLogCommitDetailsShowWholeAuthorLine checks that the author line of the commit details
// is never cut short in a narrow pane: the short hash, the author, the email and the date
// wrap onto more lines, each drawn whole inside the details, and an email wider than a line
// has one to itself and breaks inside it, its lines together the whole email.
func TestLogCommitDetailsShowWholeAuthorLine(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	dir := newTestRepository(t)
	author := "Lithe Test Author With A Long Name"
	email := "a-mailbox-far-wider-than-the-commit-details-" + strings.Repeat("x", 80) + "@example.invalid"
	gitRun(t, dir, "commit", "--allow-empty", "--author", author+" <"+email+">", "-m", "long author")
	head := gitRun(t, dir, "rev-parse", "HEAD")
	h.app.delays = logDelays{}
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	v := &h.app.logView
	// The details at their least width are the narrow pane; a tall bottom area and short
	// changed files leave the commit details room for every line.
	v.detailWidth = logDetailsMin
	v.filesSplit.Pos = logFilesMin
	h.app.layout.bottom = 10000
	h.app.layout.gitTab = gitTabLog
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

	parts := v.metaParts
	if len(parts) != 4 || parts[1].text != author || parts[2].text != "<"+email+">" {
		t.Fatalf("the author line is %+v, want the hash, %q, <%s> and the date", parts, author, email)
	}
	if len(v.metaWidths) != len(parts) || len(v.metaStarts) < 2 {
		t.Fatalf("%d parts measured %v and wrapped at %v, want all in at least two lines", len(parts), v.metaWidths, v.metaStarts)
	}
	if line := slices.Index(v.metaStarts, 2); line < 0 || line+1 >= len(v.metaStarts) || v.metaStarts[line+1] != 3 {
		t.Fatalf("the email wider than a line does not have one to itself: lines start at %v", v.metaStarts)
	}

	// Every text of the details at the body size lies inside the pane's padding and none
	// ends in an ellipsis; the email's lines join into the whole email, and the other parts
	// are drawn whole. The details pane starts after its splitter, is detailWidth wide and
	// as tall as the splitter; the commit details lie below the splitter of the changed
	// files, which this commit, changing none, leaves empty.
	split, files := h.logDetailsSplit(), h.logFilesSplit()
	left, top, bottom := split.Right(), files.Bottom(), split.Bottom()
	contentLeft, contentRight := left+logDetailPad, left+v.detailWidth-logDetailPad
	const slack = 0.5
	var drawn []app.Label
	var joined strings.Builder
	for _, label := range h.driver.Snapshot().Labels {
		if label.FontSize != h.app.theme.Metrics.FontSizeM || label.Bounds.X < left || label.Bounds.Y < top || label.Bounds.Y >= bottom {
			continue
		}
		drawn = append(drawn, label)
		joined.WriteString(label.Value)
		if strings.Contains(label.Value, "…") {
			t.Errorf("%q is cut short", label.Value)
		}
		if label.Bounds.X < contentLeft-slack || label.Bounds.Right() > contentRight+slack {
			t.Errorf("%q drawn at %+v, outside the details' %v..%v", label.Value, label.Bounds, contentLeft, contentRight)
		}
	}
	if !strings.Contains(joined.String(), parts[2].text) {
		t.Errorf("the email is not drawn whole across its lines; drawn %+v", drawn)
	}
	for i, part := range parts {
		if i == 2 {
			continue
		}
		at := slices.IndexFunc(drawn, func(label app.Label) bool { return label.Value == part.text })
		if at < 0 {
			t.Errorf("%q is not drawn whole; drawn %+v", part.text, drawn)
		} else if drawn[at].Bounds.Width < v.metaWidths[i]-1 {
			t.Errorf("%q is %v wide, want its whole %v", part.text, drawn[at].Bounds.Width, v.metaWidths[i])
		}
	}
}

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
	h.app.layout.gitTab = gitTabLog
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
	split, files := h.logDetailsSplit(), h.logFilesSplit()
	left, top := split.Right(), files.Bottom()
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

// logSplitHit is the bounds of the splitter of the log tab nearest to x or y, a vertical bar
// (as wide as a splitter is thick) when vertical is set and a horizontal one otherwise. The
// page names its splitters by place, so a test finds them by where the layout puts them.
func (h *harness) logSplitHit(vertical bool, near float32) gfx.Rect {
	h.t.Helper()
	var found gfx.Rect
	best := float32(-1)
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role != gfx.RoleSlider || hit.Label != h.app.text.Panel.Resize {
			continue
		}
		b := hit.Bounds
		if vertical != (b.Width == shellSplitter && b.Height > shellSplitter) {
			continue
		}
		d := b.X - near
		if d < 0 {
			d = -d
		}
		if best < 0 || d < best {
			best, found = d, b
		}
	}
	if best < 0 {
		h.t.Fatalf("no splitter of the log tab near %v", near)
	}
	return found
}

// logDetailsSplit is the splitter between the commit list and the details.
func (h *harness) logDetailsSplit() gfx.Rect {
	v := &h.app.logView
	return h.logSplitHit(true, v.bodyRect.Right()-v.detailWidth-shellSplitter)
}

// logFilesSplit is the splitter between the changed files and the commit details.
func (h *harness) logFilesSplit() gfx.Rect {
	v := &h.app.logView
	return h.logSplitHit(false, v.bodyRect.Right()-v.detailWidth)
}
