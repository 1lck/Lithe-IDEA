package workbench

import (
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	// testsRunID is the Tests tool window's run/re-run button.
	testsRunID = tree.ID(shellPage, "tests-run")
	// testsStopID stops the current test run.
	testsStopID = tree.ID(shellPage, "tests-stop")
	// testsListID is the scrolling result tree.
	testsListID = tree.ID(shellPage, "tests-list")
	// testOutputID is the scrolling console of a run that failed before results.
	testOutputID = tree.ID(shellPage, "test-output")
	// testsRows identifies the flattened result rows.
	testsRows = tree.Sub(shellPage, tree.Name("tests-rows"))
)

const (
	// testRowHeight is the height of a suite header and of a case row. Both use
	// the same height so the visible window is computed without measuring rows.
	testRowHeight = 24
	// testOverscan declares a few rows outside the viewport so scrolling does
	// not show an empty strip before the next frame.
	testOverscan = 3
)

// drawTestsPanel declares the Tests tool window: one workspace test run, its
// bounded result tree and the failure location each decoded case carries.
func (a *App) drawTestsPanel(f *ui.Frame, p *project) {
	if p == nil {
		return
	}
	t := a.text.Tests
	s := &p.tests
	if !p.build.loaded && !p.build.loading {
		a.loadBuildSystems(p)
	}
	instance := p.testInstance()
	f.Column().Fill().Background(a.colors.Editor).Children(func() {
		f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			label := t.Run
			if s.hasResults || s.failed != "" {
				label = t.Rerun
			}
			if f.Button(testsRunID, label).Disabled(s.running || instance == nil).Clicked() {
				a.runTests(p)
			}
			if s.operation != nil {
				if f.Button(testsStopID, t.Stop).Outline().Disabled(s.stopping).Clicked() {
					a.stopTests(p)
				}
			}
			f.Spacer()
			if s.status != "" {
				f.Text(s.status).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
		})
		f.Divider()
		if instance == nil {
			a.testMessage(f, t.NoSystems, a.colors.Subtle)
			return
		}
		if s.failed != "" {
			f.Column().Shrink(0).PadX(shellContentPad).PadY(6).Children(func() {
				f.Paragraph(s.failed, 3).Color(a.theme.Danger)
			})
			a.drawTestOutput(f, p)
			return
		}
		if s.hasResults {
			a.drawTestSummary(f, s)
		} else if s.running {
			a.testMessage(f, t.Running, a.colors.Subtle)
			return
		} else {
			a.testMessage(f, t.Empty, a.colors.Subtle)
			return
		}
		a.drawTestTree(f, p, s)
	})
}

// testMessage declares a centered empty or progress message.
func (a *App) testMessage(f *ui.Frame, message string, color gfx.Color) {
	f.Row().Fill().Center().PadX(shellContentPad).Children(func() {
		f.Paragraph(message, 3).Grow(1).TextCenter().Color(color)
	})
}

// drawTestSummary is the one-line outcome Core derived, with the counts the
// decoded report reported. It never invents a duration or a total.
func (a *App) drawTestSummary(f *ui.Frame, s *testState) {
	color := a.colors.Subtle
	switch s.verdict.Outcome {
	case "passed":
		color = a.colors.Success
	case "testsFailed", "exitedWithError":
		color = a.theme.Danger
	}
	f.Row().Height(28).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		f.Text(s.status).Grow(1).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(color).Ellipsis()
		summary := s.results.Summary
		f.Text(a.text.Tests.Summary(summary.Passed, summary.Failed, summary.Skipped)).
			Shrink(0).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
	f.Divider()
}

// drawTestTree declares the virtualized, grouped result rows.
func (a *App) drawTestTree(f *ui.Frame, p *project, s *testState) {
	scroll := a.view.ScrollState(testsListID)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(scroll.Offset/testRowHeight)-testOverscan)
	last := min(len(s.rows), int((scroll.Offset+height)/testRowHeight)+testOverscan)
	first = min(first, last)
	f.ScrollArea(testsListID).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		if first > 0 {
			f.Row().Height(float32(first) * testRowHeight).Shrink(0)
		}
		for row := first; row < last; row++ {
			a.drawTestRow(f, p, s, row)
		}
		if rest := len(s.rows) - last; rest > 0 {
			f.Row().Height(float32(rest) * testRowHeight).Shrink(0)
		}
	})
}

// drawTestRow declares one suite header or case. A case with a decoded failure
// location opens that document when clicked; a case without one stays a label.
func (a *App) drawTestRow(f *ui.Frame, p *project, s *testState, row int) {
	spec := s.rows[row]
	if spec.header {
		name := spec.suite
		if name == "" {
			name = spec.project
		} else if spec.project != "" {
			name = spec.project + " / " + name
		}
		f.Row().FillWidth().Height(testRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).Children(func() {
			f.Text(name).Grow(1).Shrink(1).FontSize(12.5).Bold().Color(a.colors.Text).Ellipsis()
		})
		return
	}
	if spec.index < 0 || spec.index >= len(s.results.Tests) {
		return
	}
	test := s.results.Tests[spec.index]
	icon, tint := a.testStatusMark(test.Status)
	position := ""
	if test.Path != "" {
		position = test.Path
		if test.Line != nil {
			position += ":" + strconv.Itoa(*test.Line)
		}
	}
	rowBox := f.Row().FillWidth().Height(testRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).
		Hover(ui.Look{}.Background(a.colors.Hover))
	if test.Path != "" {
		rowBox = rowBox.HitWith(testsRows.At(row), test.Case, gfx.HitOptions{
			Role:   gfx.RoleButton,
			Cursor: gfx.PointerCursorHand,
			Hint:   a.text.Tests.OpenLocation,
		})
	}
	rowBox.Children(func() {
		f.Icon(icon).Size(14, 14).Shrink(0).Color(tint)
		f.Text(test.Case).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		if test.Message != "" {
			f.Text(test.Message).Shrink(1).FontSize(11.5).Color(a.theme.Danger).Ellipsis().MaxWidth(320)
		}
		if test.DurationMillis != nil {
			f.Text(formatTestDuration(int(*test.DurationMillis))).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		}
		if position != "" {
			f.Text(position).Shrink(1).FontSize(11.5).Color(a.colors.Subtle).Ellipsis().MaxWidth(220)
		}
	})
	if test.Path != "" && rowBox.Clicked() {
		a.performed("workspace.tests.open", surfaceButton)
		line := 0
		if test.Line != nil && *test.Line > 0 {
			line = *test.Line - 1
		}
		a.openFileAtPosition(p, filepath.Join(p.root, filepath.FromSlash(test.Path)), line, 0)
	}
}

// testStatusMark is the icon and tint of a normalized case status.
func (a *App) testStatusMark(status string) (gfx.Icon, gfx.Color) {
	switch status {
	case "passed":
		return icons.CircleCheck, a.colors.Success
	case "failed":
		return icons.CircleX, a.theme.Danger
	case "error":
		return icons.CircleAlert, a.theme.Danger
	default:
		return icons.Minus, a.colors.Subtle
	}
}

// drawTestOutput shows the tail of a run that failed before reporting results,
// bounded to the same console budget the run kept.
func (a *App) drawTestOutput(f *ui.Frame, p *project) {
	if len(p.tests.output) == 0 {
		return
	}
	lines := p.tests.output
	if len(lines) > 12 {
		lines = lines[len(lines)-12:]
	}
	f.Divider()
	f.ScrollArea(testOutputID).Height(140).Shrink(0).Pad(8).Children(func() {
		a.drawLinkedOutput(f, p, outputScopeTest, testOutputLinks, lines)
	})
}
