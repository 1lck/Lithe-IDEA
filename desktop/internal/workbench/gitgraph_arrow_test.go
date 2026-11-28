package workbench

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func newGraphArrowRepository(t *testing.T) string {
	t.Helper()
	t.Setenv("GIT_AUTHOR_DATE", "2020-03-04T12:34:00Z")
	t.Setenv("GIT_COMMITTER_DATE", "2020-03-04T12:34:00Z")
	dir := newTestRepository(t)
	root := gitRun(t, dir, "rev-parse", "HEAD")
	for i := 1; i <= 31; i++ {
		gitRun(t, dir, "commit", "--allow-empty", "-m", fmt.Sprintf("step %02d", i))
	}
	// An extra parent at the other end of the history forces a compact graph arrow.
	merge := gitRun(t, dir, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-p", root, "-m", "merge the old history")
	gitRun(t, dir, "update-ref", "HEAD", merge)
	return dir
}

func TestGraphArrowTooltipAndJump(t *testing.T) {
	dir := newGraphArrowRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	testGraphArrowJump(t, h, dir, nil)
}

func TestGraphArrowJumpUsesVisiblePositionAfterFiltering(t *testing.T) {
	dir := newTestRepository(t)
	target := gitRun(t, dir, "rev-parse", "HEAD")
	gitRun(t, dir, "commit", "--allow-empty", "-m", "heading outside filter")
	hidden := gitRun(t, dir, "rev-parse", "HEAD")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	commit, ok := p.log.commit(target)
	if !ok || p.log.visibleRow(target) != 1 {
		t.Fatalf("unfiltered history did not list the target at row 1: %+v", p.log.graph.Rows)
	}
	h.app.logView.search.SetText(commit.Subject)
	if err := h.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	h.await("filtered Git Log", func() bool { return len(p.log.graph.Rows) == 1 })
	if p.log.visibleRow(target) != 0 || p.log.visibleRow(hidden) >= 0 {
		t.Fatalf("filtered projection did not move the target and drop the other commit: %+v", p.log.graph.Rows)
	}
	logger := &opRecordingLog{}
	h.app.logSink = logger
	h.app.jumpLogGraphArrow(p, target)
	if err := h.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	if hit := h.pageHit(commit.Subject); !hit.Selected || h.driver.Snapshot().Focused != hit.ID {
		t.Fatalf("jump did not select and focus the filtered row: %+v", hit)
	}
	h.app.jumpLogGraphArrow(p, hidden)
	if p.log.selected != target {
		t.Fatalf("jump selected a filtered-out commit: %s", p.log.selected)
	}
	if ops := logger.ops("app.action.performed"); len(ops) != 1 || ops[0] == "" {
		t.Fatalf("graph arrow jump operation IDs = %q, want one ID for the visible target", ops)
	}
}

func TestGraphArrowLookupFollowsReorderedProjection(t *testing.T) {
	commits := []core.GitCommit{{Hash: "a"}, {Hash: "b"}, {Hash: "c"}}
	log := gitLogState{byHash: indexCommits(commits)}
	in := logProjection{commits: commits}
	log.setGraph(core.Graph{Rows: []core.GraphRow{{CommitHash: "c"}, {CommitHash: "a"}}})
	log.projectedRows = in.indexProjectedRows(log.graph.Rows, log.byHash)
	if log.visibleRow("c") != 0 || log.visibleRow("a") != 1 || log.visibleRow("b") != -1 {
		t.Fatal("lookup followed loaded commit order instead of the current projection")
	}
	log.setGraph(core.Graph{Rows: []core.GraphRow{{CommitHash: "a"}, {CommitHash: "b"}, {CommitHash: "c"}}})
	if log.visibleRow("b") != 1 || in.indexProjectedRows(log.graph.Rows, log.byHash) != nil {
		t.Fatal("the aligned projection did not reuse the loaded commit index")
	}
}

func TestGraphArrowLookupUsesMergedRepositoryKeys(t *testing.T) {
	in := logProjection{
		commits: []core.GitCommit{{Hash: "same"}, {Hash: "same"}},
		keys:    []string{"same@first", "same@second"},
	}
	log := gitLogState{byHash: map[string]int{"same@first": 0, "same@second": 1}}
	log.setGraph(core.Graph{Rows: []core.GraphRow{{CommitHash: "same@first"}, {CommitHash: "same@second"}}})
	if log.visibleRow("same@first") != 0 || log.visibleRow("same@second") != 1 || in.indexProjectedRows(log.graph.Rows, log.byHash) != nil {
		t.Fatal("the merged projection must use its per-repository commit keys directly")
	}
}

func TestGraphArrowKeyboardJumpKeepsFocusInCommitList(t *testing.T) {
	dir := newGraphArrowRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	root := gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD")
	target, ok := p.log.commit(root)
	if !ok {
		t.Fatal("initial commit is missing")
	}
	if _, visible := h.findPageHit(target.Subject); visible {
		t.Fatal("initial commit is already visible")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	focusGraphArrow(t, h, h.pageHit(label).ID)
	logger := &opRecordingLog{}
	h.app.logSink = logger
	h.key(gfx.KeyEnter)
	h.settleChain()
	revealed := h.pageHit(target.Subject)
	if got := h.driver.Snapshot().Focused; p.log.selected != target.Hash || got != revealed.ID {
		t.Fatalf("jump selected %q and focused %v, want %q and %v", p.log.selected, got, target.Hash, revealed.ID)
	}
	if ops := logger.ops("app.action.performed"); len(ops) != 1 || ops[0] == "" {
		t.Fatalf("keyboard arrow jump operation IDs = %q, want one ID", ops)
	}
	h.key(gfx.KeyUp)
	if previous := h.pageHit("step 01"); !previous.Selected || h.driver.Snapshot().Focused != previous.ID {
		t.Fatalf("Up did not continue navigating the commit list: %+v", previous)
	}
}

func TestGraphArrowKeepsFocusWhenACommitIsPrepended(t *testing.T) {
	dir := newGraphArrowRepository(t)
	kernel := gitKernel{core.NewClient()}
	h := newHarness(t, kernel)
	p := h.openLog(t, dir)
	target, ok := p.log.commit(gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD"))
	if !ok {
		t.Fatal("initial commit is missing")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	before := h.pageHit(label)
	focusGraphArrow(t, h, before.ID)
	gitRun(t, dir, "commit", "--allow-empty", "-m", "prepended commit")
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	page, err := kernel.GitHistoryPage(ctx, dir, "", "", logPageSize, logPageSize)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Commits) != len(p.log.commits)+1 || page.Commits[0].Subject != "prepended commit" {
		t.Fatalf("expected one new commit at the top, got %d commits", len(page.Commits))
	}
	// Apply the refreshed projection without hiding the list while it reloads.
	p.log.commits, p.log.byHash = page.Commits, indexCommits(page.Commits)
	h.app.reproject(p, 0)
	h.await("the refreshed Git Log with a new first commit", func() bool {
		_, visible := h.findPageHit("prepended commit")
		return visible
	})
	after := h.pageHit(label)
	if after.Bounds.Y <= before.Bounds.Y {
		t.Fatalf("the arrow did not move down after the new commit: before %+v, after %+v", before.Bounds, after.Bounds)
	}
	if focused := h.driver.Snapshot().Focused; after.ID != before.ID || focused != after.ID {
		t.Fatalf("after the prepend, arrow changed from %v to %v and focus is %v", before.ID, after.ID, focused)
	}
	h.key(gfx.KeyEnter)
	h.settleChain()
	revealed := h.pageHit(target.Subject)
	if p.log.selected != target.Hash || h.driver.Snapshot().Focused != revealed.ID {
		t.Fatalf("Enter selected %q and focused %v, want %q and %v", p.log.selected, h.driver.Snapshot().Focused, target.Hash, revealed.ID)
	}
}

func TestGraphArrowVariantsDistinguishDirectionsAndTerminalArrows(t *testing.T) {
	seen := [4]bool{}
	for _, direction := range []string{"up", "down"} {
		for _, terminal := range []bool{false, true} {
			edge := core.GraphElement{Direction: direction, IsTerminal: terminal}
			variant := logGraphArrowVariant(edge)
			if variant < 0 || variant >= len(seen) || seen[variant] {
				t.Fatalf("arrow %s (terminal=%t) has invalid or duplicate variant %d", direction, terminal, variant)
			}
			seen[variant] = true
		}
	}
}

func TestGraphArrowHeldClickDoesNotJumpToARecycledTarget(t *testing.T) {
	dir := newGraphArrowRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	rows := p.log.graph.Rows
	oldTarget, ok := p.log.commit(rows[len(rows)-1].CommitHash)
	if !ok {
		t.Fatal("the original arrow target is missing")
	}
	newTarget, ok := p.log.commit(rows[len(rows)-2].CommitHash)
	if !ok {
		t.Fatal("the replacement arrow target is missing")
	}
	label := func(commit core.GitCommit) string {
		return i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
			"subject": commit.Subject,
			"author":  commit.AuthorName,
			"date":    h.app.logView.date(commit),
		})
	}
	before := h.pageHit(label(oldTarget))
	at := center(before.Bounds)
	source := slices.IndexFunc(rows, func(row core.GraphRow) bool {
		return slices.ContainsFunc(row.PrintElements, func(edge core.GraphElement) bool {
			return edge.HasArrow && edge.TargetHash == oldTarget.Hash
		})
	})
	if source < 0 {
		t.Fatal("the source row of the original arrow is missing")
	}
	if err := h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	selected := p.log.selected
	// Two history projections arrive before the mouse is released. A gap of
	// three frames leaves the old virtual hit slot available for the new arrow.
	elements := rows[source].PrintElements
	rows[source].PrintElements = nil
	for range 3 {
		if err := h.driver.Paint(); err != nil {
			t.Fatal(err)
		}
	}
	for i := range elements {
		if elements[i].HasArrow && elements[i].TargetHash == oldTarget.Hash {
			elements[i].TargetHash = newTarget.Hash
		}
	}
	rows[source].PrintElements = elements
	if err := h.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	after := h.pageHit(label(newTarget))
	if after.ID != before.ID || after.Bounds != before.Bounds {
		t.Fatalf("replacement arrow did not reuse the held hit: before %+v, after %+v", before, after)
	}
	if err := h.driver.Release(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	if p.log.selected != selected {
		t.Fatalf("release selected %q through a recycled hit, want %q", p.log.selected, selected)
	}
	h.sendClick(at)
	h.settleChain()
	if p.log.selected != newTarget.Hash {
		t.Fatalf("fresh click selected %q, want %q", p.log.selected, newTarget.Hash)
	}
}

func TestGraphArrowDiscardsPressWhenLogIsHidden(t *testing.T) {
	dir := newGraphArrowRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	target, ok := p.log.commit(gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD"))
	if !ok {
		t.Fatal("the initial commit is missing")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	at := center(h.pageHit(label).Bounds)
	if err := h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if h.app.logView.pressedGraphArrow == (logGraphArrowPress{}) {
		t.Fatal("the visible arrow did not record the press")
	}
	h.app.layout.gitTab = gitTabConsole
	if err := h.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	if _, visible := h.findPageHit(label); visible {
		t.Fatal("the arrow is still visible after switching Git tabs")
	}
	if h.app.logView.pressedGraphArrow != (logGraphArrowPress{}) {
		t.Fatal("the hidden log still holds the arrow press")
	}
	if err := h.driver.Release(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
}

func TestMergedLogArrowKeepsFocusAndPressWhenPageQualifiesCommitKeys(t *testing.T) {
	dir := newGraphArrowRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	h.settleChain()
	l := &p.log
	targetHash := gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD")
	target, ok := l.commit(targetHash)
	if !ok {
		t.Fatal("the initial commit is missing")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	graph := l.graph
	source := slices.IndexFunc(graph.Rows, func(row core.GraphRow) bool {
		return slices.ContainsFunc(row.PrintElements, func(edge core.GraphElement) bool {
			return edge.HasArrow && edge.TargetHash == targetHash
		})
	})
	if source < 0 {
		t.Fatal("the graph has no arrow toward the initial commit")
	}
	repo := p.logRepoID()
	l.walks = []logWalk{{id: repo, root: dir, complete: true}, {id: "copy", root: dir, complete: true}}
	origins := make([]logOrigin, len(l.commits))
	for i, commit := range l.commits {
		origins[i] = logOrigin{walk: 0, key: commit.Hash}
	}
	l.setMerged(l.commits, origins, nil)
	before := h.pageHit(label)
	focusGraphArrow(t, h, before.ID)
	at := center(before.Bounds)
	if err := h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	// The next page finds the same commits in the other repository. In the
	// published graph both endpoints keep their positions but gain a qualifier.
	sourceHash := graph.Rows[source].CommitHash
	graph.Rows = slices.Clone(graph.Rows)
	commits := slices.Clone(l.commits)
	for i := range origins {
		hash := origins[i].key
		if hash != sourceHash && hash != targetHash {
			continue
		}
		origins[i].key = hash + "@" + repo
		graph.Rows[i].CommitHash = origins[i].key
		origins = append(origins, logOrigin{walk: 1, key: hash + "@copy"})
		commits = append(commits, commits[i])
		graph.Rows = append(graph.Rows, core.GraphRow{CommitHash: hash + "@copy"})
	}
	qualifiedTarget := targetHash + "@" + repo
	graph.Rows[source].PrintElements = slices.Clone(graph.Rows[source].PrintElements)
	for i := range graph.Rows[source].PrintElements {
		edge := &graph.Rows[source].PrintElements[i]
		if edge.TargetHash == targetHash {
			edge.TargetHash = qualifiedTarget
		}
	}
	l.setMerged(commits, origins, nil)
	l.setGraph(graph)
	if err := h.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	after := h.pageHit(label)
	if focused := h.driver.Snapshot().Focused; after.ID != before.ID || focused != after.ID {
		t.Fatalf("paging changed arrow %v to %v and focus is %v", before.ID, after.ID, focused)
	}
	if err := h.driver.Release(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	if l.selected != qualifiedTarget {
		t.Fatalf("the held click selected %q, want %q", l.selected, qualifiedTarget)
	}
}

type graphDiscoveryGate struct {
	gitKernel
	release <-chan struct{}
}

func (k graphDiscoveryGate) DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error) {
	select {
	case <-k.release:
		return k.gitKernel.DiscoverWorkspaceRepositories(ctx, root)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func TestGraphKeepsSelectionFocusAndPressWhenParentRepositoryIsDiscovered(t *testing.T) {
	dir := newGraphArrowRepository(t)
	child := filepath.Join(dir, "subfolder")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	gate := make(chan struct{})
	release := sync.OnceFunc(func() { close(gate) })
	h := newHarness(t, graphDiscoveryGate{gitKernel{core.NewClient()}, gate})
	t.Cleanup(release)
	h.app.delays = logDelays{}
	h.app.layout.gitTab = gitTabLog
	h.app.openProject(child)
	h.await("history before workspace repository discovery", func() bool {
		p := h.app.project
		return p != nil && p.git.isRepository() && len(p.log.graph.Rows) > 2
	})
	p := h.app.project
	if p.ownID() != "." {
		t.Fatalf("parent repository was already discovered as %q", p.ownID())
	}
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.sendClick(center(h.button(itemGit)))
	}
	h.sendNamed("merge the old history")
	if err := h.driver.Key(gfx.KeyDown, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	list := &h.app.logView.commits
	if !list.Chosen(0) || !list.Chosen(1) {
		t.Fatal("the first two commits were not selected before discovery")
	}
	targetHash := gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD")
	target, ok := p.log.commit(targetHash)
	if !ok {
		t.Fatal("the initial commit is missing")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	before := h.pageHit(label)
	focusGraphArrow(t, h, before.ID)
	at := center(before.Bounds)
	if err := h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	release()
	h.await("parent repository discovery", func() bool { return p.ownID() == ".." })
	after := h.pageHit(label)
	if focused := h.driver.Snapshot().Focused; after.ID != before.ID || focused != after.ID {
		t.Errorf("discovery changed arrow %v to %v and focus is %v", before.ID, after.ID, focused)
	}
	if !list.Chosen(0) || !list.Chosen(1) {
		t.Error("parent repository discovery dropped the multi-selection")
	}
	if err := h.driver.Release(at.X, at.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	if p.log.selected != targetHash {
		t.Fatalf("the held click selected %q, want %q", p.log.selected, targetHash)
	}
}

func TestGraphArrowFocusRequiresVisibleWingInViewport(t *testing.T) {
	repo := newGraphArrowRepository(t)
	client := core.NewClient()
	ctx, cancel := context.WithTimeout(t.Context(), gitTimeout)
	defer cancel()
	page, err := client.GitHistoryPage(ctx, repo, "", "", 100, 100)
	if err != nil {
		t.Fatal(err)
	}
	graph, err := client.GitGraph(ctx, core.GraphRequest{Commits: graphCommits(page.Commits)})
	if err != nil {
		t.Fatal(err)
	}
	m := newGraphMetrics(1)
	p := &project{log: newGitLogState()}
	p.log.commits, p.log.byHash = page.Commits, indexCommits(page.Commits)
	p.log.setGraph(graph)
	for _, direction := range []string{"down", "up"} {
		t.Run(direction, func(t *testing.T) {
			var edge core.GraphElement
			var target core.GitCommit
			for _, row := range graph.Rows {
				for _, candidate := range row.PrintElements {
					if candidate.Direction == direction && candidate.HasArrow && candidate.IsTerminal && p.log.visibleRow(candidate.TargetHash) >= 0 {
						edge = candidate
						target, _ = p.log.commit(edge.TargetHash)
						break
					}
				}
				if edge.HasArrow {
					break
				}
			}
			if !edge.HasArrow {
				t.Fatalf("real compact graph has no navigable terminal %s arrow", direction)
			}
			a := &App{project: p, theme: ui.LightTheme()}
			sample := core.GraphRow{CommitHash: "source", Lane: 0, PrintElements: []core.GraphElement{edge}}
			var list ui.ListState
			var area ui.Box
			screen := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
				area = ui.List(c, &list, 3, func(row ui.ListRow) {
					row.Element.Height(logRowHeight).FillWidth()
					if row.Index == 0 {
						row.Element.Draw(func(d *ui.DrawContext) {
							a.paintGraphRow(d.Canvas, m, d.Rect, sample, func(int32) gfx.Color { return gfx.RGB(255, 100, 100) })
						})
						a.drawLogGraphArrows(p, row, sample, func(*ui.MenuItems) {})
					}
				}).Fill()
			}})
			_, label := a.logGraphArrowTip(p, target, edge)
			var canvas gfx.Canvas
			canvas.SetPixelScale(1)
			viewport := gfx.Size{Width: 600, Height: logRowHeight}
			assertFocusable := func(visible bool) {
				t.Helper()
				canvas.Reset()
				screen.Paint(&canvas, viewport)
				var present, focusable bool
				for _, hit := range canvas.Hits() {
					if hit.Label == label {
						present, focusable = true, hit.Focusable
						break
					}
				}
				if present != visible || focusable != visible {
					t.Fatalf("arrow hit = %t and focus = %t, want both %t", present, focusable, visible)
				}
			}
			assertFocusable(true)
			tip, wings := graphArrowPoints(m, edge)
			strokeTop := min(tip.Y, wings[0].Y, wings[1].Y) - m.lineWidth/2
			strokeBottom := max(tip.Y, wings[0].Y, wings[1].Y) + m.lineWidth/2
			if direction == "down" {
				viewport.Height = float32(math.Ceil(float64(strokeTop))) + 1
				assertFocusable(true)
				viewport.Height = float32(math.Floor(float64(strokeTop)))
			} else {
				area.ScrollState().Offset = float32(math.Floor(float64(strokeBottom))) - 1
				assertFocusable(true)
				area.ScrollState().Offset = float32(math.Ceil(float64(strokeBottom)))
			}
			assertFocusable(false)

			// Clip the graph column through the left wing. At the near corner,
			// both clip edges can intersect the hit box while missing the stroke.
			leftWing := min(wings[0].X, wings[1].X)
			viewport.Width = a.logView.metadataWidth(&canvas) + float32(math.Ceil(float64(leftWing))) + 1
			if direction == "down" {
				viewport.Height = logRowHeight
				area.ScrollState().Offset = float32(math.Ceil(float64(strokeTop)))
				assertFocusable(true)
				area.ScrollState().Offset += 4
			} else {
				area.ScrollState().Offset = 0
				viewport.Height = float32(math.Floor(float64(strokeBottom)))
				assertFocusable(true)
				viewport.Height -= 4
			}
			assertFocusable(false)
		})
	}
}

func TestGraphArrowPaintersReuseWarmSlots(t *testing.T) {
	var painters logGraphArrowPainters
	take := func(count int) {
		for range count {
			painters.painter(graphArrowShape{}, gfx.ID{}, "target")
		}
		painters.endFrame()
	}
	take(logRowSlots + 1)
	if len(painters.slots) != logRowSlots || painters.used != 0 {
		t.Fatalf("ending a crowded frame kept %d painter slots with %d in use", len(painters.slots), painters.used)
	}
	for _, slot := range painters.slots {
		if slot.tip != "" {
			t.Fatal("the painter slot retained a tooltip after the frame")
		}
	}
	if got := testing.AllocsPerRun(100, func() { take(logRowSlots) }); got != 0 {
		t.Fatalf("reusing the warm arrow painters took %v allocations", got)
	}
}

func focusGraphArrow(t *testing.T, h *harness, arrow gfx.ID) {
	t.Helper()
	for range len(h.driver.Snapshot().Hits) {
		h.key(gfx.KeyTab)
		if h.driver.Snapshot().Focused == arrow {
			return
		}
	}
	t.Fatal("Tab did not reach the graph arrow")
}

func TestGraphArrowLosesHoverWhenScrolledAwayFromStationaryPointer(t *testing.T) {
	dir := newGraphArrowRepository(t)
	// Give the arrow one row of room to move without leaving the viewport.
	gitRun(t, dir, "commit", "--allow-empty", "-m", "after the merge")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	root := gitRun(t, dir, "rev-list", "--max-parents=0", "HEAD")
	target, ok := p.log.commit(root)
	if !ok {
		t.Fatalf("the initial commit %q was missing from the log", root)
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  target.AuthorName,
		"date":    h.app.logView.date(target),
	})
	arrow := h.pageHit(label)
	if shown, _ := h.restForTip(arrow.Bounds); shown != label {
		t.Fatalf("the arrow tooltip showed %q, want %q", shown, label)
	}
	if frame := h.driver.Snapshot(); frame.Hovered != arrow.ID || frame.Cursor != app.CursorHand {
		t.Fatalf("hover before scrolling = %v, cursor = %v, want %v and a hand", frame.Hovered, frame.Cursor, arrow.ID)
	}
	at := center(arrow.Bounds)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: at.X, Y: at.Y, DeltaY: logRowHeight, Precise: true}); err != nil {
		t.Fatal(err)
	}
	moved := h.pageHit(label)
	if moved.ID != arrow.ID || moved.Bounds.Bottom() > at.Y {
		t.Fatalf("scroll should move the same arrow above the pointer at %+v, got %+v", at, moved)
	}
	if frame := h.driver.Snapshot(); frame.Hovered == arrow.ID || frame.Cursor == app.CursorHand {
		t.Errorf("the old arrow kept the hover or hand cursor after scrolling: hover = %v, cursor = %v", frame.Hovered, frame.Cursor)
	}
	if tips := h.tooltips(); len(tips) != 0 {
		t.Errorf("the tooltip stayed visible after scrolling: %q", tips[0].Value)
	}
	if shown, _ := h.restForTip(moved.Bounds); shown != label {
		t.Errorf("the arrow tooltip at its new position showed %q, want %q", shown, label)
	}
}

func testGraphArrowJump(t *testing.T, h *harness, dir string, capture func(gfx.Hit, bool)) {
	t.Helper()
	p := h.openLog(t, dir)
	rows := p.log.graph.Rows
	if len(rows) != 33 {
		t.Fatalf("log has %d rows, want 33", len(rows))
	}
	target, ok := p.log.commit(rows[len(rows)-1].CommitHash)
	if !ok || target.Subject != "initial" {
		t.Fatalf("last commit = %+v, want initial", target)
	}
	if _, visible := h.findPageHit(target.Subject); visible {
		t.Fatal("the target was already in view")
	}
	label := i18n.SharedFormat(h.app.language(), "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": target.Subject,
		"author":  "Lithe Test",
		"date":    h.app.logView.date(target),
	})
	arrow := h.pageHit(label)
	if arrow.Role != gfx.RoleButton || arrow.Cursor != gfx.PointerCursorHand {
		t.Fatalf("expected a clickable arrow, got %+v", arrow)
	}
	if capture != nil {
		capture(arrow, false)
	}
	shown, bounds := h.restForTip(arrow.Bounds)
	if !strings.Contains(shown, target.Subject) || !strings.Contains(shown, "Lithe Test") || !strings.Contains(shown, h.app.logView.date(target)) || bounds.X < arrow.Bounds.Right() {
		t.Fatalf("arrow tooltip %q was shown at %+v, expected target metadata to the right of %+v", shown, bounds, arrow.Bounds)
	}
	if capture != nil {
		capture(arrow, true)
	}
	h.rightClickAt(arrow.Bounds)
	if _, shown := h.findPageHit(h.shared("git.log.copyCommitHash")); !shown {
		t.Fatal("the commit context menu did not open on an arrow's secondary click")
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.sendClick(center(arrow.Bounds))
	h.settleChain()
	if p.log.selected != target.Hash {
		t.Fatalf("selected %q after clicking the arrow, want %q", p.log.selected, target.Hash)
	}
	if revealed, visible := h.findPageHit(target.Subject); !visible || !revealed.Selected {
		t.Fatalf("target commit after arrow click was not scrolled into view and selected: %+v", revealed)
	}
}
