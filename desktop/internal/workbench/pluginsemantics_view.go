package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// semanticPopups declares the open rename dialog or the definition, completion
// or hover popup. The popups are placed at the caret and never take the
// keyboard: the editor keeps it, and pluginSemanticsKey moves their selection.
// Lists lay out only the visible window, so a large server answer costs a
// constant number of views.
func (a *App) semanticPopups(c ui.C) {
	state := &a.semantics
	if a.project == nil || state.project != a.project {
		return
	}
	switch {
	case state.rename.open:
		a.renameDialog(c)
	case state.definition.open:
		a.definitionPopup(c)
	case state.completion.open:
		a.completionPopup(c)
	case state.hover.open:
		a.hoverPopup(c)
	}
}

// semanticPopup declares a popup panel at x, y over the window. The panel is
// named so a press on it does not reach the editor behind it, and takes no focus.
func (a *App) semanticPopup(c ui.C, x, y, width, maxHeight float32, label string, pad float32, body func()) {
	ui.Stack(c).Fill().Children(func() {
		ui.Column(c).Absolute().Left(x).Top(y).Width(width).MaxHeight(maxHeight).Pad(pad).
			Background(a.theme.Popover).Border(1, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
			Children(body)
	})
}

// semanticRow declares one choice of a popup and reports whether it was clicked.
func (a *App) semanticRow(c ui.C, index int, label string, selected bool, content func(c ui.C)) bool {
	rc := c.KeyInt(index)
	row := ui.Row(rc).FillWidth().Height(semanticRowHeight).Items(ui.Center).PadX(8).Gap(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(rc), label, gfx.HitOptions{Role: gfx.RoleOption, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	if selected {
		row = row.Background(a.colors.Active)
	}
	row.Children(func() { content(rc) })
	return row.Clicked()
}

func (a *App) definitionPopup(c ui.C) {
	state := &a.semantics.definition
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision {
		a.closeSemanticDefinition()
		return
	}
	anchor, ok := d.view.CaretRect()
	if !ok {
		a.closeSemanticDefinition()
		return
	}
	first, last := semanticWindow(state.selected, len(state.targets))
	x, y := popupOrigin(anchor.X, anchor.Y+anchor.Height+2, semanticDefinitionWidth, c.Bounds())
	chosen := -1
	a.semanticPopup(c, x, y, semanticDefinitionWidth, float32(visibleSemanticRows)*semanticRowHeight+2*semanticPopupPad,
		a.definitionPopupTitle(state.references), semanticPopupPad, func() {
			ui.Column(c).FillWidth().Gap(1).Children(func() {
				for i := first; i < last; i++ {
					label := a.definitionLabel(state.targets[i])
					if a.semanticRow(c, i, label, i == state.selected, func(rc ui.C) {
						ui.Text(rc, label).FontSize(12).Ellipsis()
					}) {
						chosen = i
					}
				}
			})
		})
	if chosen >= 0 {
		c.After(func() { a.choosePluginDefinition(chosen) })
	}
}

func (a *App) completionPopup(c ui.C) {
	state := &a.semantics.completion
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision {
		a.closeSemanticCompletion()
		return
	}
	anchor, ok := d.view.CaretRect()
	if !ok {
		a.closeSemanticCompletion()
		return
	}
	first, last := semanticWindow(state.selected, len(state.items))
	x, y := popupOrigin(anchor.X, anchor.Y+anchor.Height+2, semanticPopupWidth, c.Bounds())
	chosen := -1
	a.semanticPopup(c, x, y, semanticPopupWidth, float32(visibleSemanticRows)*semanticRowHeight+2*semanticPopupPad,
		i18n.Shared(a.language(), "desktop.semantics.completion"), semanticPopupPad, func() {
			ui.Column(c).FillWidth().Gap(1).Children(func() {
				for i := first; i < last; i++ {
					item := state.items[i]
					if a.semanticRow(c, i, item.Label, i == state.selected, func(rc ui.C) {
						ui.Text(rc, item.Label).FontSize(12).Ellipsis()
						if item.Detail != "" {
							ui.Text(rc, item.Detail).FontSize(11).Color(a.colors.Subtle).Ellipsis().Grow(1)
						}
					}) {
						chosen = i
					}
				}
			})
		})
	if chosen >= 0 {
		c.After(func() { a.acceptPluginCompletion(chosen) })
	}
}

func (a *App) hoverPopup(c ui.C) {
	state := &a.semantics.hover
	x, y := popupOrigin(state.anchor.X, state.anchor.Y, semanticHoverWidth, c.Bounds())
	a.semanticPopup(c, x, y, semanticHoverWidth, semanticHoverMaxHeight,
		i18n.Shared(a.language(), "desktop.semantics.hover"), 10, func() {
			ui.Scroll(c).FillWidth().MaxHeight(semanticHoverMaxHeight - 20).Children(func() {
				ui.Wrap(c, state.contents).FontSize(12).Mono()
			})
		})
}

// renameDialog is the thin view over renameState: it shows the name field and
// reports confirm or cancel to the rename logic.
func (a *App) renameDialog(c ui.C) {
	state := &a.semantics.rename
	language := a.language()
	label := i18n.Shared(language, "desktop.semantics.renameName")
	submitted, cancelled, confirmed := false, false, false
	closed := ui.ModalWith(c, &state.open, i18n.Shared(language, "desktop.semantics.renameTitle"),
		ui.ModalSpec{Description: i18n.Shared(language, "desktop.semantics.renameDescription"), Width: 420}, func() {
			submitted = ui.TextField(c, &state.name, label, label).FillWidth().Disabled(state.busy).Submitted()
		}, func() {
			cancelled = ui.Button(c, i18n.Shared(language, "desktop.semantics.renameCancel")).Outline().Clicked()
			confirmed = ui.Button(c, i18n.Shared(language, "desktop.semantics.renameButton")).Disabled(!a.renameReady()).Clicked()
		})
	switch {
	case closed || cancelled:
		state.open = true
		c.After(a.cancelPluginRename)
	case confirmed || submitted:
		c.After(a.confirmPluginRename)
	}
}
