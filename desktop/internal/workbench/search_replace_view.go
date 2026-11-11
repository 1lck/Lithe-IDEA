package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// searchReplaceID names the replace field so the toggle can move the keyboard to it.
var searchReplaceID = tree.ID(shellPage, "project-search-replace")

// searchReplaceToggle is the search bar button that shows the Replace row.
func (a *App) searchReplaceToggle(c ui.C) {
	v := &a.searchView
	t := a.text.Search
	button := ui.Button(c.Key("replace-toggle"), t.ReplaceToggle).Icon(icons.ArrowLeftRight).IconOnly()
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
						a.replacePreviewFile(c.KeyInt(i), r, i)
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
func (a *App) replacePreviewFile(c ui.C, r *projectReplace, index int) {
	file := &r.files[index]
	path := file.Path
	count := 0
	for _, match := range file.Matches {
		count += match.OccurrenceCount
	}
	ui.Column(c).FillWidth().Gap(2).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			ui.Checkbox(c.Key("include"), &r.include[index], path)
			ui.Spacer(c)
			ui.Text(c, strconv.Itoa(count)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			label := a.text.Agent.Activity.Expand
			if r.expanded[path] {
				label = a.text.Agent.Activity.Collapse
			}
			if ui.Button(c.Key("expand"), label).Ghost().Small().Clicked() {
				r.expanded[path] = !r.expanded[path]
			}
		})
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
