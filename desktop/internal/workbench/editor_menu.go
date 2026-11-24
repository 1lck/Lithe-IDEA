package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// editorMenuItems declares the editor's context menu for document d: the language actions
// (definition, usages, rename, reformat), the line actions and navigation. Each item does what
// its chord does, through the same functions, so the two never differ. c is the page's C, and
// the actions run after the paint, when the menu has closed.
func (a *App) editorMenuItems(c ui.C, p *project, d *document) func(*ui.MenuItems) {
	language := a.language()
	primary := primaryModifier()
	return func(menu *ui.MenuItems) {
		menu.WidthRange(240, 280)
		a.editorActionMenuItems(c, p, d, menu)
		readOnly := d.view.ReadOnly()
		if menu.Item(a.text.Commands.Find).Clicked() {
			c.After(func() { a.selectDocument(p, d.id); a.openEditorFind(false, surfaceContextMenu) })
		}
		if menu.Item(a.text.Commands.Replace).Disabled(readOnly).Clicked() {
			c.After(func() { a.selectDocument(p, d.id); a.openEditorFind(true, surfaceContextMenu) })
		}
		if !p.standalone {
			menu.Separator()
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.goToDefinition")).Keys(primary, "b").Clicked() {
				c.After(func() {
					line, column := d.view.CaretUTF16()
					a.startPluginDefinition(p, d, line, column, true)
				})
			}
			line, _ := d.view.CaretUTF16()
			_, implementations := a.editorServer(d, featureImplementation)
			hasDownAction := len(editorActionChoices(d.actions, line, "navigate-down")) > 0
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.goToImplementation")).Keys(primary|gfx.ModifierAlt, "b").Disabled(!implementations && !hasDownAction).Clicked() {
				c.After(func() {
					line, column := d.view.CaretUTF16()
					a.startPluginImplementation(p, d, line, column, true)
				})
			}
			hasUpAction := len(editorActionChoices(d.actions, line, "navigate-up")) > 0
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.goToSuper")).Keys(primary, "u").Disabled(!hasUpAction).Clicked() {
				c.After(func() { a.triggerGoToSuper(p, d) })
			}
			// A right click outside the selection has put the caret on the word clicked, so the
			// usages are of that word.
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.findUsages")).Keys(gfx.ModifierShift, "f12").Clicked() {
				c.After(func() {
					line, column := d.view.CaretUTF16()
					a.startPluginReferences(p, d, line, column)
				})
			}
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.rename")).Keys(0, "f2").Disabled(readOnly).Clicked() {
				c.After(func() { a.openPluginRename(p, d) })
			}
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.reformat")).Disabled(readOnly).Clicked() {
				c.After(func() { a.startPluginFormattingAtSelection(p, d) })
			}
			_, codeActions := a.editorServer(d, featureCodeActions)
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.codeActions")).Keys(gfx.ModifierAlt, "enter").Disabled(readOnly || !codeActions).Clicked() {
				c.After(func() { a.startPluginCodeActions(p, d, nil, surfaceContextMenu) })
			}
			_, parameterInfo := a.editorServer(d, featureSignatureHelp)
			if menu.Item(i18n.Shared(language, "desktop.semantics.signatureHelp")).Keys(primary, "p").Disabled(!parameterInfo).Clicked() {
				c.After(func() {
					line, column := d.view.CaretUTF16()
					a.startPluginSignatureHelp(p, d, line, column, surfaceContextMenu)
				})
			}
		}
		if browserPreviewable(d) {
			if menu.Item(i18n.Shared(language, "desktop.editorMenu.openInBrowser")).Clicked() {
				c.After(func() { a.openInBrowser(p, d, surfaceContextMenu) })
			}
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "native.copySourceLocation")).Clicked() {
			c.After(func() { a.copyReferenceLocation(p, d) })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.toggleComment")).Keys(primary, "/").Disabled(readOnly).Clicked() {
			c.After(func() { a.runLineOperation(p, d, core.ToggleLineComment) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.duplicateLine")).Keys(gfx.ModifierAlt|gfx.ModifierShift, "down").Disabled(readOnly).Clicked() {
			c.After(func() { a.runLineOperation(p, d, core.DuplicateLine) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.deleteLine")).Keys(primary|gfx.ModifierShift, "k").Disabled(readOnly).Clicked() {
			c.After(func() { a.runLineOperation(p, d, core.DeleteLine) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.moveLineUp")).Keys(gfx.ModifierAlt, "up").Disabled(readOnly).Clicked() {
			c.After(func() { a.runLineOperation(p, d, core.MoveLineUp) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.moveLineDown")).Keys(gfx.ModifierAlt, "down").Disabled(readOnly).Clicked() {
			c.After(func() { a.runLineOperation(p, d, core.MoveLineDown) })
		}
		menu.Separator()
		if p.git.isRepository() && menu.Item(i18n.Shared(language, "desktop.editorMenu.lineHistory")).Clicked() {
			c.After(func() { a.startLineHistory(p, d, surfaceContextMenu) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.goToLine")).Clicked() {
			c.After(func() { a.openNavigation(p) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.back")).Keys(gfx.ModifierControl|gfx.ModifierAlt, "left").Clicked() {
			c.After(func() { a.stepNavigation(p, false) })
		}
		if menu.Item(i18n.Shared(language, "desktop.editorMenu.forward")).Keys(gfx.ModifierControl|gfx.ModifierAlt, "right").Clicked() {
			c.After(func() { a.stepNavigation(p, true) })
		}
	}
}
