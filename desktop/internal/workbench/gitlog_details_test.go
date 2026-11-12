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
	mailbox := parts[2].text

	// Every text of the details at the body size lies inside the pane's padding and none
	// ends in an ellipsis; the texts are drawn on at least two lines. The email's lines
	// join into the whole email and have no other part on them, and the other parts are
	// drawn whole. The details pane starts after its splitter, is detailWidth wide and as
	// tall as the splitter; the commit details lie below the splitter of the changed files,
	// which this commit, changing none, leaves empty.
	split, files := h.logDetailsSplit(), h.logFilesSplit()
	left, top, bottom := split.Right(), files.Bottom(), split.Bottom()
	contentLeft, contentRight := left+logDetailPad, left+v.detailWidth-logDetailPad
	const slack = 0.5
	var drawn []app.Label
	lines := map[float32]bool{}
	for _, label := range h.driver.Snapshot().Labels {
		if label.FontSize != h.app.theme.Metrics.FontSizeM || label.Bounds.X < left || label.Bounds.Y < top || label.Bounds.Y >= bottom {
			continue
		}
		drawn = append(drawn, label)
		lines[label.Bounds.Y] = true
		if strings.Contains(label.Value, "…") {
			t.Errorf("%q is cut short", label.Value)
		}
		if label.Bounds.X < contentLeft-slack || label.Bounds.Right() > contentRight+slack {
			t.Errorf("%q drawn at %+v, outside the details' %v..%v", label.Value, label.Bounds, contentLeft, contentRight)
		}
	}
	if len(lines) < 2 {
		t.Fatalf("the author line is drawn on %d lines, want at least two; drawn %+v", len(lines), drawn)
	}
	// A label is a piece of the email when its text is part of the email and not another
	// part's whole text, such as the hash.
	isEmail := func(label app.Label) bool {
		return label.Value != "" && strings.Contains(mailbox, label.Value) &&
			!slices.ContainsFunc(parts, func(part logMetaPart) bool { return part.text != mailbox && part.text == label.Value })
	}
	var joined strings.Builder
	mailLines := map[float32]bool{}
	for _, label := range drawn {
		if isEmail(label) {
			joined.WriteString(label.Value)
			mailLines[label.Bounds.Y] = true
		}
	}
	if joined.String() != mailbox {
		t.Errorf("the email's lines are %q, want the whole %q; drawn %+v", joined.String(), mailbox, drawn)
	}
	for _, label := range drawn {
		if !isEmail(label) && mailLines[label.Bounds.Y] {
			t.Errorf("%q shares a line with the email, which has its lines to itself; drawn %+v", label.Value, drawn)
		}
	}
	for i, part := range parts {
		if i == 2 {
			continue
		}
		if !slices.ContainsFunc(drawn, func(label app.Label) bool { return label.Value == part.text }) {
			t.Errorf("%q is not drawn whole; drawn %+v", part.text, drawn)
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
	wide := slices.IndexFunc(chips, func(x core.GraphLabel) bool { return x.Title == long })

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
	const slack = 0.5
	// Each chip's name is found as drawn: whole, but for the chip wider than a line.
	labels := make([]app.Label, len(chips))
	lines := map[float32]bool{}
	for i, chip := range chips {
		at := slices.IndexFunc(drawn, func(d app.Label) bool {
			return d.Value == chip.Title || i == wide && strings.HasPrefix(d.Value, long[:24])
		})
		if at < 0 {
			t.Fatalf("chip %q is not drawn in the details; drawn %+v", chip.Title, drawn)
		}
		label := drawn[at]
		labels[i] = label
		lines[label.Bounds.Y] = true
		if label.Bounds.X-logRefIconSize-logRefChipGap-logRefChipPad < contentLeft-slack ||
			label.Bounds.Right()+logRefChipPad > contentRight+slack {
			t.Errorf("chip %q drawn at %+v, outside the details' %v..%v", chip.Title, label.Bounds, contentLeft, contentRight)
		}
		if i == wide {
			if label.Value == long || !strings.HasSuffix(label.Value, "…") {
				t.Errorf("the chip wider than a line is drawn as %q, want its name cut short and ending in an ellipsis", label.Value)
			}
		} else if label.Value != chip.Title {
			t.Errorf("chip %q is drawn as %q, want its whole name", chip.Title, label.Value)
		}
	}
	for i, label := range labels {
		if i != wide && label.Bounds.Y == labels[wide].Bounds.Y {
			t.Errorf("chip %q shares a line with the chip wider than a line, which has one to itself", chips[i].Title)
		}
	}
	if len(lines) < 2 {
		t.Fatalf("the chips are drawn in %d lines, want at least two", len(lines))
	}
}

// TestLogCommitDetailsWrapMonospacedSubject checks that the subject of the commit details,
// which is monospaced, wraps onto more lines in a narrow pane instead of running past its
// edge: every line of it is drawn inside the details, none ends in an ellipsis, and the
// lines together are the whole subject, wide characters mixed with ASCII ones included.
func TestLogCommitDetailsWrapMonospacedSubject(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	dir := newTestRepository(t)
	subject := strings.TrimRight("修复 detached HEAD 下的提交列表 "+strings.Repeat("宽字符与 ASCII 混排的提交标题 ", 6), " ")
	gitRun(t, dir, "commit", "--allow-empty", "-m", subject)
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

	// The subject is drawn at the log's font size, which is also the body size the author
	// line is drawn at, so the lines are the texts at that size whose characters are part of
	// the subject. The details pane starts after its splitter and is detailWidth wide; the
	// subject lies below the changed files, inside the pane's padding.
	split, files := h.logDetailsSplit(), h.logFilesSplit()
	left, top := split.Right(), files.Bottom()
	contentLeft, contentRight := left+logDetailPad, left+v.detailWidth-logDetailPad
	const slack = 0.5
	compact := func(value string) string { return strings.ReplaceAll(value, " ", "") }
	var joined strings.Builder
	lines := map[float32]bool{}
	for _, label := range h.driver.Snapshot().Labels {
		if label.FontSize != logFontSize || label.Bounds.X < left || label.Bounds.Y < top {
			continue
		}
		if value := compact(label.Value); value == "" || !strings.Contains(compact(subject), value) {
			continue
		}
		joined.WriteString(label.Value)
		lines[label.Bounds.Y] = true
		if strings.Contains(label.Value, "…") {
			t.Errorf("%q is cut short", label.Value)
		}
		if label.Bounds.X < contentLeft-slack || label.Bounds.Right() > contentRight+slack {
			t.Errorf("%q drawn at %+v, outside the details' %v..%v", label.Value, label.Bounds, contentLeft, contentRight)
		}
	}
	if len(lines) < 2 {
		t.Errorf("the subject is drawn on %d lines, want at least two", len(lines))
	}
	if compact(joined.String()) != compact(subject) {
		t.Errorf("the subject's lines are %q, want the whole %q", joined.String(), subject)
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
