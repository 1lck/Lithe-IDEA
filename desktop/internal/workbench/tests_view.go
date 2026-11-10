package workbench

import (
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// testRowHeight is the height of a suite header and of a case row.
const testRowHeight = 24

// drawTestsPanel puts the Tests tool window, a Page, into the tool window area.
func (a *App) drawTestsPanel(f *ui.Frame, p *project) {
	if p == nil {
		return
	}
	a.embedPage(f, a.testsPage(p), func(c ui.C) { a.testsView(c, p) })
}

// testsView declares the Tests tool window: one workspace test run, its bounded
// result tree and the failure location each decoded case carries.
func (a *App) testsView(c ui.C, p *project) {
	t := a.text.Tests
	s := &p.tests
	if !p.build.loaded && !p.build.loading {
		a.loadBuildSystems(p)
	}
	instance := p.testInstance()
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			label := t.Run
			if s.hasResults || s.failed != "" {
				label = t.Rerun
			}
			if ui.Button(c, label).Disabled(s.running || instance == nil).Clicked() {
				a.runTests(p)
			}
			if s.operation != nil {
				if ui.Button(c, t.Stop).Outline().Disabled(s.stopping).Clicked() {
					a.stopTests(p)
				}
			}
			ui.Spacer(c)
			if s.status != "" {
				ui.Text(c, s.status).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
		})
		ui.Divider(c)
		if instance == nil {
			a.panelMessage(c, t.NoSystems, a.colors.Subtle)
			return
		}
		if s.failed != "" {
			ui.Column(c).FillWidth().Shrink(0).PadX(shellContentPad).PadY(6).Children(func() {
				ui.Paragraph(c, s.failed, 3).Color(a.theme.Danger)
			})
			a.testOutput(c, p)
			return
		}
		if s.hasResults {
			a.testSummary(c, s)
		} else if s.running {
			a.panelMessage(c, t.Running, a.colors.Subtle)
			return
		} else {
			a.panelMessage(c, t.Empty, a.colors.Subtle)
			return
		}
		a.testTree(c, p, s)
	})
}

// testSummary is the one-line outcome Core derived, with the counts the decoded
// report reported. It never invents a duration or a total.
func (a *App) testSummary(c ui.C, s *testState) {
	color := a.colors.Subtle
	switch s.verdict.Outcome {
	case "passed":
		color = a.colors.Success
	case "testsFailed", "exitedWithError":
		color = a.theme.Danger
	}
	ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		ui.Text(c, s.status).Grow(1).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(color).Ellipsis()
		summary := s.results.Summary
		ui.Text(c, a.text.Tests.Summary(summary.Passed, summary.Failed, summary.Skipped)).
			Shrink(0).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
	ui.Divider(c)
}

// testRowName is the heading of a suite row: its suite, under its project.
func testRowName(spec testRow) string {
	name := spec.suite
	if name == "" {
		name = spec.project
	} else if spec.project != "" {
		name = spec.project + " / " + name
	}
	return name
}

// testTree declares the grouped result rows as a list that holds only the rows
// on screen. A suite heading stays at the top while its cases scroll under it.
func (a *App) testTree(c ui.C, p *project, s *testState) {
	list := &p.panels.testResults
	list.Header = func(i int) bool { return s.rows[i].header }
	list.Label = func(i int) string {
		spec := s.rows[i]
		if spec.header {
			return testRowName(spec)
		}
		if spec.index < 0 || spec.index >= len(s.results.Tests) {
			return ""
		}
		return s.results.Tests[spec.index].Case
	}
	ui.List(c, list, len(s.rows), func(row ui.ListRow) {
		a.testRow(row, p, s)
	}).Label(a.text.Tests.Summary(s.results.Summary.Passed, s.results.Summary.Failed, s.results.Summary.Skipped)).
		FillWidth().Grow(1).Shrink(1).MinHeight(0)
}

// testRow declares one suite header or case. A case with a decoded failure
// location opens that document when clicked; a case without one stays a label.
func (a *App) testRow(row ui.ListRow, p *project, s *testState) {
	c := row.C
	spec := s.rows[row.Index]
	if spec.header {
		row.Element.Height(testRowHeight).PadX(10).Items(ui.Center).Gap(6).Background(a.colors.Editor)
		ui.Text(c, testRowName(spec)).Grow(1).Shrink(1).FontSize(12.5).Bold().Color(a.colors.Text).Ellipsis()
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
	element := row.Element.Height(testRowHeight).PadX(10).Items(ui.Center).Gap(6).Hover(ui.Look{}.Background(a.colors.Hover))
	if test.Path != "" {
		element.Tooltip(a.text.Tests.OpenLocation)
	}
	ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(tint)
	ui.Text(c, test.Case).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
	if test.Message != "" {
		ui.Text(c, test.Message).Shrink(1).FontSize(11.5).Color(a.theme.Danger).Ellipsis().MaxWidth(320)
	}
	if test.DurationMillis != nil {
		ui.Text(c, formatTestDuration(int(*test.DurationMillis))).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	}
	if position != "" {
		ui.Text(c, position).Shrink(1).FontSize(11.5).Color(a.colors.Subtle).Ellipsis().MaxWidth(220)
	}
	if test.Path != "" && element.Clicked() {
		a.performed("workspace.tests.open", surfaceButton)
		line := 0
		if test.Line != nil && *test.Line > 0 {
			line = *test.Line - 1
		}
		path := filepath.Join(p.root, filepath.FromSlash(test.Path))
		c.After(func() { a.openFileAtPosition(p, path, line, 0) })
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

// testOutput shows the tail of a run that failed before reporting results,
// bounded to the same console budget the run kept.
func (a *App) testOutput(c ui.C, p *project) {
	if len(p.tests.output) == 0 {
		return
	}
	lines := p.tests.output
	if len(lines) > 12 {
		lines = lines[len(lines)-12:]
	}
	ui.Divider(c)
	a.outputList(c, p, &p.panels.testOutput, outputScopeTest, a.text.Build.Output, lines).Height(140).Shrink(0)
}
