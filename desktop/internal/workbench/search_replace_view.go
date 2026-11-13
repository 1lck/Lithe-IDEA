package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// searchReplaceID names the replace field so the toggle can move the keyboard to it.
var searchReplaceID = tree.ID(shellPage, "project-search-replace")

// searchReplaceToggle is the search bar button that shows the Replace row.
func (a *App) searchReplaceToggle(c ui.C) {
	v := &a.searchView
	t := a.text.Search
	button := ui.Button(c.Key("replace-toggle"), t.ReplaceToggle).Icon(icons.ArrowLeftRight).IconOnly().Tooltip(t.ReplaceToggle)
	if !v.replaceOpen {
		button = button.Ghost()
	}
	if button.Clicked() {
		v.replaceOpen = !v.replaceOpen
		if v.replaceOpen {
			c.Canvas().RequestFocus(searchReplaceID)
		}
	}
}

// searchReplaceRow is the replacement field and its Replace All button, under the query.
func (a *App) searchReplaceRow(c ui.C, query searchQuery) {
	v, p := &a.searchView, a.project
	if !v.replaceOpen || p == nil {
		return
	}
	t := a.text.Search
	ui.Row(c.Key("replace-row")).FillWidth().PadSides(0, 10, 6, 10).Items(ui.Center).Gap(6).Children(func() {
		ui.TextFieldID(c, searchReplaceID, &v.replace, t.Replace, t.ReplacePlaceholder).Grow(1).MinWidth(0)
		disabled := strings.TrimSpace(query.text) == "" || p.replace.loading || p.replace.applying
		if ui.Button(c.Key("replace-all"), t.ReplaceAll).Small().Disabled(disabled).Clicked() {
			replacement := v.replace.Text()
			c.After(func() { a.previewProjectReplace(p, query, replacement) })
		}
	})
}

// drawProjectReplace declares the Replace in Files preview: every file that changes
// with a box to leave it out, its changed lines on demand, and the confirmation.
func (a *App) drawProjectReplace(c ui.C, p *project) {
	r := &p.replace
	if p == nil || !r.open {
		return
	}
	t := a.text.Search
	open := true
	files, occurrences := r.replaceCounts()
	description := ""
	if !r.loading && r.failure == "" {
		description = t.ReplaceSummary(strconv.Itoa(occurrences), strconv.Itoa(files))
	}
	closed := ui.ModalWith(c, &open, t.PreviewTitle, ui.ModalSpec{Width: 620, Description: description}, func() {
		ui.Column(c.Part("replace-preview")).FillWidth().Gap(4).Children(func() {
			switch {
			case r.loading:
				ui.Text(c, t.Previewing).Muted()
			case r.failure != "":
				ui.Paragraph(c, r.failure, 4).Color(a.theme.Danger)
			case len(r.files) == 0:
				ui.Text(c, t.NoReplacements).Muted()
			default:
				ui.Scroll(c.Part("replace-files")).FillWidth().MaxHeight(360).Children(func() {
					for i := range r.files {
						a.replacePreviewFile(c.KeyInt(i), p, i)
					}
				})
			}
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Disabled(r.applying).Clicked() {
			c.After(func() { a.closeProjectReplace(p) })
		}
		if ui.Button(c, t.ReplaceAll).Disabled(r.loading || r.applying || files == 0).Clicked() {
			c.After(func() { a.applyProjectReplace(p) })
		}
	})
	if closed {
		c.After(func() { a.closeProjectReplace(p) })
	}
}

// replacePreviewFile is one file of the preview: a box that keeps it in the
// replacement, its path and count, and its changed lines when expanded.
func (a *App) replacePreviewFile(c ui.C, p *project, index int) {
	r := &p.replace
	file := &r.files[index]
	path := file.Path
	count := 0
	for _, match := range file.Matches {
		count += match.OccurrenceCount
	}
	ui.Column(c).FillWidth().Gap(2).Children(func() {
		fk := c.Part("file")
		fileRow := ui.Row(fk).FillWidth().Items(ui.Center).Gap(6).
			HitWith(ui.ID(fk), i18n.Shared(a.language(), "desktop.search.replaceFile"), gfx.HitOptions{Value: path, SkipFocus: true})
		fileRow.Children(func() {
			ui.Checkbox(c.Key("include"), &r.include[index], path)
			ui.Spacer(c)
			ui.Text(c, strconv.Itoa(count)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			label := i18n.Shared(a.language(), "desktop.search.expandFile")
			if r.expanded[path] {
				label = i18n.Shared(a.language(), "desktop.search.collapseFile")
			}
			if ui.Button(c.Key("expand"), label).Ghost().Small().Clicked() {
				r.expanded[path] = !r.expanded[path]
			}
		})
		// The file opens at its first changed line, as the earlier client's preview rows did;
		// the preview is modal, so opening the file closes it first.
		result := core.WorkspaceSearchMatch{Path: path}
		if len(file.Matches) > 0 {
			line := file.Matches[0].Line
			result.Line = &line
		}
		a.searchResultMenu(fk, fileRow, p, result, a.language(), "workspace.replace", func() { a.closeProjectReplace(p) })
		if !r.expanded[path] {
			return
		}
		for i, match := range file.Matches {
			if i >= 50 {
				break
			}
			ui.Column(c.KeyInt(i)).FillWidth().PadX(22).Children(func() {
				line := strconv.Itoa(match.Line) + "  "
				ui.Text(c.Key("before"), line+"- "+match.Before).Mono().FontSize(11.5).Color(a.theme.Danger).Ellipsis()
				ui.Text(c.Key("after"), line+"+ "+match.After).Mono().FontSize(11.5).Color(a.theme.Success).Ellipsis()
			})
		}
	})
}
