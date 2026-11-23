package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// Note: 隔离边界见 .agents/notes/implemented/feature/2026-11-20-cli-and-standalone-editor.md
// A standalone session borrows document ownership and editor layout, but never
// enters the project-open pipeline. In particular its parent is not indexed,
// watched as a workspace, restored, trusted or handed to a plugin.
func (a *App) openStandaloneFile(path string) {
	a.requestCloseProject(func() {
		ctx, cancel := context.WithCancel(context.Background())
		p := &project{standalone: true, root: filepath.Dir(path), name: filepath.Base(path), ctx: ctx, cancel: cancel}
		a.project = p
		a.openFile(p, path)
	})
}

func (a *App) standaloneWorkbench(c ui.C) {
	a.syncWindowTitle()
	a.layout.capture()
	a.layout.insetW, a.layout.insetH = 0, titleBarHeight+statusBarHeight+a.sessions.stripHeight()
	// Use the existing bottom panel and splitter without restoring any project panels.
	open := [slotCount]int{-1, -1, -1, -1, -1, -1}
	terminalIndex := catalogIndex[itemTerminal]
	if a.project != nil && a.chrome.isOpen(terminalIndex) {
		open[slotBottomLeft] = terminalIndex
	}
	plan := a.layout.arrange(c.Bounds(), open)
	hidden := slotCount
	language := a.language()
	leading, trailing := c.TitlebarInsets()
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).FillWidth().Height(titleBarHeight).Shrink(0).Items(ui.Center).Gap(8).
			PadSides(0, trailing+chromeEdge, 0, leading+chromeEdge).MovesWindow().Children(func() {
			a.compactMenuButton(c)
			name := i18n.Shared(language, "desktop.singleFile.mode")
			if a.project != nil {
				name = a.project.name
			}
			if d := a.selectedEditorDocument(); d != nil {
				name = d.name
			}
			ui.Text(c, name).Bold().Ellipsis().Color(a.colors.Text)
			ui.Text(c, i18n.Shared(language, "desktop.singleFile.mode")).FontSize(11).Color(a.colors.Subtle)
			a.drawRunOptionHelp(c, i18n.Shared(language, "desktop.singleFile.help"))
			ui.Spacer(c)
			if ui.Button(c, a.text.Tools.Terminal).Icon(icons.SquareTerminal).IconOnly().Ghost().Disabled(a.project == nil).Tooltip(a.text.Tools.Terminal).Clicked() {
				c.After(func() {
					a.performed("terminal.toggle", surfaceButton)
					a.toggleStandaloneTerminal()
				})
			}
			if ui.Button(c, i18n.Shared(language, "desktop.singleFile.openFolder")).Disabled(a.selectedEditorDocument() == nil).Outline().Tooltip(i18n.Shared(language, "desktop.singleFile.openFolderHelp")).Clicked() {
				c.After(func() {
					a.performed("workspace.singleFile.openFolder", surfaceButton)
					if d := a.selectedEditorDocument(); d != nil {
						a.openProjectInNewWindow(filepath.Dir(d.path))
					}
				})
			}
			if ui.Button(c, i18n.Shared(language, "desktop.singleFile.openFile")).Icon(icons.Folder).Ghost().Clicked() {
				c.After(a.chooseStandaloneFile)
			}
			if ui.Button(c, a.text.Settings.Title).Icon(icons.Settings).IconOnly().Ghost().Tooltip(a.text.Settings.Title).Clicked() {
				c.After(func() { a.openSettingsPage(surfaceButton, settingsHome) })
			}
		})
		a.projectTabs(c)
		a.shellMain(c, plan, open, &hidden)
		ui.Row(c).FillWidth().Height(statusBarHeight).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			if d := a.selectedEditorDocument(); d != nil {
				ui.Text(c, d.path).Ellipsis().Grow(1).MinWidth(0).Color(a.colors.Subtle)
			}
			for _, id := range []string{itemCaret, itemIndent, itemEOL, itemEncoding, itemLock} {
				if i := slices.IndexFunc(a.chrome.catalog, func(it item) bool { return it.id == id }); i >= 0 && a.chromeStatusItem(c, i) {
					index := i
					c.After(func() { a.activate(index) })
				}
			}
		})
	})
	if hidden != slotCount {
		c.After(func() {
			a.performed("workbench.toolWindow.hide", surfaceButton)
			a.reduceChrome(core.SetChromeOpen(itemTerminal, false))
			a.invalidator.Invalidate()
		})
	}
}

func (a *App) toggleStandaloneTerminal() {
	index := catalogIndex[itemTerminal]
	if a.chrome.isOpen(index) {
		a.reduceChrome(core.SetChromeOpen(itemTerminal, false))
		a.invalidator.Invalidate()
		return
	}
	if len(a.project.terms.list) == 0 {
		a.openToolTerminal("")
		return
	}
	a.reduceChrome(core.SetChromeOpen(itemTerminal, true))
	a.invalidator.Invalidate()
}

// Keep the normal editor commands while omitting project tools from menus and
// shortcuts. Their UI is absent from a standalone window too.
func (a *App) sessionCommands(list []command) []command {
	if !a.documentOnly {
		return list
	}
	return slices.DeleteFunc(list, func(cmd command) bool { return !a.documentCommands[cmd.id] })
}

func (a *App) chooseStandaloneFile() {
	language := a.language()
	a.performed("editor.singleFile.open", surfaceButton)
	a.background(nil, 0, func(context.Context) func(*App) {
		paths, err := app.OpenFiles(app.OpenFileOptions{Title: i18n.Shared(language, "desktop.singleFile.openFile")})
		return func(a *App) {
			// log-exempt: 用户取消：关闭文件选择器不改变打开的文档。
			if errors.Is(err, app.ErrCanceled) {
				return
			}
			if err != nil {
				a.operationFailed("single_file_dialog", err)
				a.notifyError(a.text.Errors.OpenFailed(err.Error()))
				return
			}
			for _, path := range paths {
				if a.project == nil {
					a.openStandaloneFile(path)
				} else {
					a.openFile(a.project, path)
				}
			}
		}
	})
}
