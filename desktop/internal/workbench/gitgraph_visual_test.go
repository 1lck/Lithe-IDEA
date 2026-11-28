//go:build vivahead && lithevisual

package workbench

import (
	"fmt"
	"image"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// Each visual case owns its repository and window so its setup, capture, and
// cleanup are measured together.
func TestVisualGitGraphLogDark100(t *testing.T) {
	testVisualGitGraph(t, "git-log", "dark", 1)
}

func TestVisualGitGraphEmptyFilterPagination(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		t.Run(theme, func(t *testing.T) {
			dir, kernel := newFilteredLogPagingFixture(t)
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: "en"}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{"en"}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 1050
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1.25})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			openLogWithUnmatchedPage(t, h, dir)
			h.pageHit(h.app.text.Git.LoadMore)
			if err := session.Screenshot(filepath.Join(out, "git-log-empty-filter-"+theme+"-1.25x.png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestVisualGitGraphLogDark125(t *testing.T) {
	testVisualGitGraph(t, "git-log", "dark", 1.25)
}

func TestVisualGitGraphLogDark150(t *testing.T) {
	testVisualGitGraph(t, "git-log", "dark", 1.5)
}

func TestVisualGitGraphLogDark200(t *testing.T) {
	testVisualGitGraph(t, "git-log", "dark", 2)
}

func TestVisualGitGraphLogLight100(t *testing.T) {
	testVisualGitGraph(t, "git-log", "light", 1)
}

func TestVisualGitGraphLogLight125(t *testing.T) {
	testVisualGitGraph(t, "git-log", "light", 1.25)
}

func TestVisualGitGraphLogLight150(t *testing.T) {
	testVisualGitGraph(t, "git-log", "light", 1.5)
}

func TestVisualGitGraphLogLight200(t *testing.T) {
	testVisualGitGraph(t, "git-log", "light", 2)
}

func TestVisualGitGraphWorktreeDark100(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "dark", 1)
}

func TestVisualGitGraphWorktreeDark125(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "dark", 1.25)
}

func TestVisualGitGraphWorktreeDark150(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "dark", 1.5)
}

func TestVisualGitGraphWorktreeDark200(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "dark", 2)
}

func TestVisualGitGraphWorktreeLight100(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "light", 1)
}

func TestVisualGitGraphWorktreeLight125(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "light", 1.25)
}

func TestVisualGitGraphWorktreeLight150(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "light", 1.5)
}

func TestVisualGitGraphWorktreeLight200(t *testing.T) {
	testVisualGitGraph(t, "worktree-history", "light", 2)
}

// testVisualGitGraph captures a clipped history list with a merge, a passing
// lane, and HEAD.
func testVisualGitGraph(t *testing.T, view, theme string, scale float64) {
	t.Helper()
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	dir, linked := newWorktreeRepository(t)
	gitRun(t, linked, "branch", "side")
	// Keep the side commits together in date order as well as topological order.
	t.Setenv("GIT_COMMITTER_DATE", "2020-01-01T12:00:00Z")
	gitRun(t, linked, "commit", "--allow-empty", "-m", "feature work")
	gitRun(t, linked, "switch", "side")
	t.Setenv("GIT_COMMITTER_DATE", "2020-01-02T12:00:00Z")
	sideSubjects := make(map[string]string)
	for i := 1; i <= 4; i++ {
		subject := fmt.Sprintf("side step %d", i)
		gitRun(t, linked, "commit", "--allow-empty", "-m", subject)
		sideSubjects[gitRun(t, linked, "rev-parse", "HEAD")] = subject
	}
	gitRun(t, linked, "switch", "feature")
	t.Setenv("GIT_COMMITTER_DATE", "2020-01-03T12:00:00Z")
	gitRun(t, linked, "merge", "--no-ff", "-m", "merge side", "side")
	for i := 1; i <= 5; i++ {
		gitRun(t, linked, "commit", "--allow-empty", "-m", fmt.Sprintf("feature step %d", i))
	}
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: "en", DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	h := newHarnessWithDriver(t, Options{Kernel: gitKernel{core.NewClient()}, Store: prefs, Languages: []string{"en"}}, func(config app.Config) (*app.Driver, func(), error) {
		config.Width, config.Height = 1200, 1050
		var err error
		session, err = headless.Open(config, nil, headless.Options{Scale: scale})
		if err != nil {
			return nil, nil, err
		}
		return session.Driver(), session.Close, nil
	})
	var rows []core.GraphRow
	if view == "git-log" {
		p := h.openLog(t, linked)
		rows = p.log.graph.Rows
	} else {
		h.openWorktrees(t, dir)
		h.selectWorktreeAt(t, linked)
		h.clickNamed(h.app.text.Worktrees.History)
		history := &h.app.project.worktrees.history
		h.await("the selected checkout's history and graph", func() bool {
			return history.loaded && !history.loading && len(history.graph.Rows) == len(history.commits)
		})
		if !h.app.worktreeView.graphed || len(history.graph.Rows) != 12 {
			t.Fatalf("worktree history graph has %d rows; drawn=%t", len(history.graph.Rows), h.app.worktreeView.graphed)
		}
		rows = history.graph.Rows
	}
	h.settleChain()
	img, err := session.Image()
	if err != nil {
		t.Fatal(err)
	}
	if err := session.Screenshot(filepath.Join(out, fmt.Sprintf("%s-%s-%gx.png", view, theme, scale))); err != nil {
		t.Fatal(err)
	}
	m := newGraphMetrics(float32(scale))
	row := h.pageHit("feature step 4").Bounds
	y := row.Y + m.rowCenter
	assertGraphStrokeUniform(t, img, row.X+m.laneCenter, y+m.nodeRadius+2, y+logRowHeight-m.nodeRadius-2, m.lineWidth, scale)
	assertPassingGraphStrokeUniform(t, h, img, rows, sideSubjects, m, scale)
	if view == "git-log" && theme == "dark" && scale == 1.25 {
		h.clickNamed("feature step 4")
		h.settleChain()
		if h.app.project.log.selected != h.app.project.log.graph.Rows[1].CommitHash {
			t.Fatal("the older commit was not selected")
		}
		head := h.pageHit("feature step 5").Bounds
		if err := h.driver.Move(head.X+head.Width/2, head.Y+head.Height/2); err != nil {
			t.Fatal(err)
		}
		h.settleChain()
		if err := session.Screenshot(filepath.Join(out, "git-log-selected-hover-dark-1.25x.png")); err != nil {
			t.Fatal(err)
		}
	}
}

// assertPassingGraphStrokeUniform checks a solid lane through unrelated commits.
// Unlike the lane with nodes, nothing covers its joins at the row centers.
func assertPassingGraphStrokeUniform(t *testing.T, h *harness, img *image.RGBA, rows []core.GraphRow, subjects map[string]string, m graphMetrics, scale float64) {
	t.Helper()
	for i := 0; i+1 < len(rows); i++ {
		first, next := rows[i], rows[i+1]
		if subjects[first.CommitHash] == "" || subjects[next.CommitHash] == "" {
			continue
		}
		for _, edge := range first.PrintElements {
			if edge.Direction != "down" || !straightPassingEdge(first, edge, edge.Position) ||
				!hasStraightGraphEdge(first, edge.Position, edge.ColorID, "up") ||
				!hasStraightGraphEdge(next, edge.Position, edge.ColorID, "up") ||
				!hasStraightGraphEdge(next, edge.Position, edge.ColorID, "down") {
				continue
			}
			top, topVisible := h.findPageHit(subjects[first.CommitHash])
			bottom, bottomVisible := h.findPageHit(subjects[next.CommitHash])
			if !topVisible || !bottomVisible || top.Bounds.Height < logRowHeight || bottom.Bounds.Height < logRowHeight {
				continue
			}
			x := top.Bounds.X + m.laneCenter + float32(edge.Position)*m.laneSpacing
			// Sample both halves of both rows, including their centers and shared edge.
			assertGraphStrokeUniform(t, img, x, top.Bounds.Y+3, bottom.Bounds.Y+logRowHeight-3, m.lineWidth, scale)
			return
		}
	}
	t.Fatal("no visible solid lane passes two unrelated commit rows")
}

func hasStraightGraphEdge(row core.GraphRow, lane int, color int32, direction string) bool {
	for _, edge := range row.PrintElements {
		if edge.Direction == direction && edge.ColorID == color && straightPassingEdge(row, edge, lane) {
			return true
		}
	}
	return false
}

func straightPassingEdge(row core.GraphRow, edge core.GraphElement, lane int) bool {
	return lane != row.Lane && edge.Position == lane && edge.AdjacentPosition == lane &&
		!edge.IsDotted && !edge.IsTerminal && !edge.HasArrow
}

// assertGraphStrokeUniform checks both the body and antialiased fringe against
// the first sample so that local color changes in the rendered line fail.
func assertGraphStrokeUniform(t *testing.T, img *image.RGBA, x, top, bottom, width float32, scale float64) {
	t.Helper()
	start := int(math.Ceil(float64(top) * scale))
	end := int(math.Floor(float64(bottom) * scale))
	left := int(math.Floor(float64(x-width-1) * scale))
	right := int(math.Ceil(float64(x+width+1) * scale))
	if start >= end || !image.Rect(left, start, right, end).In(img.Bounds()) {
		t.Fatalf("graph sampling band is outside screenshot: (%d,%d)-(%d,%d)", left, start, right, end)
	}
	background := img.RGBAAt(left, start)
	ink := false
	for px := left; px < right; px++ {
		want := img.RGBAAt(px, start)
		ink = ink || want != background
		for py := start + 1; py < end; py++ {
			if got := img.RGBAAt(px, py); got != want {
				t.Fatalf("graph stroke changes color at (%d,%d): got %v, want %v at y=%d", px, py, got, want, start)
			}
		}
	}
	if !ink {
		t.Fatal("graph sampling band contains no line")
	}
}
