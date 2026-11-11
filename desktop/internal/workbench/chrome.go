package workbench

import (
	"context"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// gearMenuWidth is the width of the settings button's menu, which holds five short items
// and their shortcuts.
const gearMenuWidth = 224

const (
	// chromeIconButton is the side of a title bar icon button and the height of the
	// other title bar controls; chromeToolButton is the side of a stripe button. Both
	// are even and fit their bar with a whole pixel above and below, so nothing is
	// laid out on a half pixel.
	chromeIconButton = 28
	chromeToolButton = 32
	chromeIconSize   = 16
	// chromeMarkSize is the size of a chevron or a status glyph.
	chromeMarkSize = 12
	chromeGap      = 4
	chromeEdge     = 8
	// chromeLineHeight is the height of a line of text in the chrome. The default is
	// the font size plus seven, which is odd for the 13 point body text, and an odd
	// line in an even button would sit on a half pixel.
	chromeLineHeight = 16
	chromeStatusItem = 20
	// chromeProjectMax and chromeBranchMax cap the width of the names in the title bar,
	// which are cut with an ellipsis beyond it.
	chromeProjectMax = 240
	chromeBranchMax  = 160
	// chromeDot is the status mark of the language server.
	chromeDot = 8
	// chromeAvatarTitle is the side of the project's badge in the title bar, and
	// chromeTitleGap the space between that badge, the name and the chevron, a little wider
	// than the space between the bar's controls.
	chromeAvatarTitle = 20
	chromeTitleGap    = 6

	// The project menu is chromeMenuWidth wide, hangs chromeMenuOffset under its button and is
	// at most chromeMenuMaxHeight tall: a longer list scrolls inside it. It lists at most
	// chromeMenuRecents recent projects besides the open one.
	chromeMenuWidth     = 320
	chromeMenuMaxHeight = 520
	chromeMenuRadius    = 8
	chromeMenuOffset    = 4
	chromeMenuRecents   = 10
	// chromeMenuAvatar is the side of a project's badge in the menu, chromeMenuProject the
	// least height of a project's row and chromeMenuRowPad the room above and below its
	// text. A row with a branch line is taller than the least.
	chromeMenuAvatar  = 28
	chromeMenuProject = 46
	chromeMenuRowPad  = 6
	// chromeMenuTitle is the height of the line that names a section of the menu, and
	// chromeMenuClosing the side of the button that closes the open project.
	chromeMenuTitle   = 24
	chromeMenuClosing = 20
	// chromeMenuGap is the space between the parts of a row, and chromeMenuItems the space
	// between the rows.
	chromeMenuGap   = 8
	chromeMenuItems = 2
	// The project menu's padding and the height of its actions.
	chromeMenuPadding = 4
	chromeMenuRow     = 32

	// chromeDragDim is the opacity the source of a drag keeps while its ghost follows
	// the pointer.
	chromeDragDim = 0.4
)

// titleState is what the title bar remembers between frames. The zero value is a title
// bar with its menus closed.
type titleState struct {
	// projectOpen says the project menu is open.
	projectOpen bool
	// gearOpen says the settings button's menu is open.
	gearOpen bool
	// menuOpen says the compact menu of the title bar is open (compact_menu.go).
	menuOpen bool
	// branches is the branch of each recent project the project menu has read, by path. The
	// empty string stands for a folder that is not a repository or whose status could not be
	// read. The map is allocated when the first answer arrives, and is dropped with the rest
	// of the state when the project closes.
	branches map[string]string
	// reading holds the paths whose status is being read, so a menu opened again while an
	// answer is on its way does not ask a second time.
	reading map[string]bool
}

// chromeStatusText is the reading a status item shows, empty for the items that are only
// a glyph. The drag shows the same words on the ghost of the item.
func (a *App) chromeStatusText(i int) string {
	switch a.chrome.catalog[i].id {
	case itemCaret:
		if a.project != nil {
			if doc := a.project.selectedDocument(a.project.docs.group); doc != nil {
				line, column := doc.view.CaretUTF16()
				return fmt.Sprintf("%d:%d", line+1, column+1)
			}
		}
		return "1:1"
	case itemEncoding:
		if a.project != nil {
			if doc := a.project.selectedDocument(a.project.docs.group); doc != nil {
				return encodingLabel(doc.encodingID())
			}
		}
		return encodingLabel("utf-8")
	case itemIndent:
		if doc := a.selectedEditorDocument(); doc != nil {
			size, spaces := doc.view.IndentSettings()
			if spaces {
				return a.text.Status.IndentSpaces(size)
			}
			return a.text.Status.IndentTab(size)
		}
		return ""
	case itemEOL:
		if doc := a.selectedEditorDocument(); doc != nil {
			if doc.view.LineEnding() == "crlf" {
				return a.text.Status.LineEndingCRLF
			}
			return a.text.Status.LineEndingLF
		}
		return ""
	case itemVim:
		return a.vimStatusText()
	case itemLSP:
		// The count replaces the "not started" text only while a server has reported
		// something: an empty count would read as a problem of its own.
		if text := a.lspStatusText(); text != "" {
			return text
		}
		return a.text.Status.LSPNotStarted
	case itemMemory:
		if memoryShowsIcon() {
			return a.memoryTooltip()
		}
		return a.memoryStatusText()
	case itemFPS:
		return a.text.Status.FPSValue(a.status.fps)
	case itemChanges:
		if a.project != nil {
			if count, ok := a.project.git.changeCount(); ok && count > 0 {
				return a.text.Status.Changes(count)
			}
		}
		return a.text.Status.NoChanges
	}
	return ""
}

// selectedEditorDocument is the document the editor shows, or nil when no file is open.
func (a *App) selectedEditorDocument() *document {
	if a.project == nil {
		return nil
	}
	return a.project.selectedDocument(a.project.docs.group)
}

// openProjectMenu opens the project menu and asks for the branch of each recent project it
// lists. The branches are read again on every opening, because a project's branch changes
// while the menu is shut; the ones read before are shown until the new answer arrives.
func (a *App) openProjectMenu() {
	a.title.projectOpen = true
	a.closeBranches()
	var buf [chromeMenuRecents]int
	for _, i := range a.menuRecents(&buf) {
		// A folder that is gone has no branch to read, and the menu shows it faded.
		if path := a.recent[i].Path; !a.missing[path] {
			a.loadMenuBranch(path)
		}
	}
}

// loadMenuBranch reads the branch of the project at path in the background and keeps it
// in the title state for the menu to show. A path whose answer is still on its way is not
// asked for again.
func (a *App) loadMenuBranch(path string) {
	if a.title.reading[path] {
		return
	}
	if a.title.reading == nil {
		a.title.reading = make(map[string]bool, chromeMenuRecents)
	}
	a.title.reading[path] = true
	kernel := a.kernel
	// The read belongs to the open project, so an answer that arrives after the project was
	// closed or replaced is dropped with the state it would have been written to.
	a.background(a.project, kernelCallTimeout, func(ctx context.Context) func(*App) {
		branch := ""
		// The read is of another project, so the Git console of the open one does not keep it.
		ctx = core.WithGitConsole(ctx, nil, "")
		// Outside a repository there is no branch, as on the project the title bar shows.
		if status, err := kernel.GitStatus(ctx, path); err == nil && status.RepositoryRoot != "" {
			branch = status.Branch
		}
		return func(a *App) {
			delete(a.title.reading, path)
			if a.title.branches == nil {
				a.title.branches = make(map[string]string, chromeMenuRecents)
			}
			a.title.branches[path] = branch
		}
	})
}

// menuRecents returns the indexes into a.recent of the projects the menu lists under the
// recent ones: every recent project but the open one, at most chromeMenuRecents of them.
// The result lives in buf, so a frame allocates nothing for it.
func (a *App) menuRecents(buf *[chromeMenuRecents]int) []int {
	n := 0
	for i := range a.recent {
		if n == len(buf) {
			break
		}
		if a.recent[i].Path != a.project.root {
			buf[n] = i
			n++
		}
	}
	return buf[:n]
}
