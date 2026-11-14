package workbench

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/wslpath"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// This file gives a Project tool window row its context menu and the file operations it
// offers: Git actions for a changed file, New File and New Directory on a folder, Rename and
// Delete, and the path and Finder actions. Git facts come from the last Core status; the file
// operations themselves are the platform's own (Go's os package), since Core owns the Git
// rules and not the workspace filesystem. A file with an open tab is saved before it is
// renamed or deleted, and its tab follows the new path or closes with the file.

// treeRevealPath and treeCopyText are the system calls the menu makes. They are variables so a
// test can watch them without the host's Finder and clipboard.
var (
	treeRevealPath = app.RevealPath
	treeCopyText   = app.SetClipboardText
)

// treePromptKind is the dialog a tree row opened.
type treePromptKind uint8

const (
	treePromptNone treePromptKind = iota
	treePromptNewFile
	treePromptNewDirectory
	treePromptRename
)

// treePrompt is the New File, New Directory or Rename dialog of one row. name is its text
// field; err is a name the dialog rejected and shows under the field. Delete has its own dialog
// (treeRemovalDialog in filetree_batch.go).
type treePrompt struct {
	kind treePromptKind
	open bool
	node *treeNode
	name string
	err  string
}

// projectTreeMenu declares the context menu of one row. A row of a folder or the root can make
// files and folders; any row but the root can be renamed or deleted. The Git items appear only
// for a file the last status lists as changed.
func (a *App) projectTreeMenu(c ui.C, p *project, n *treeNode, target ui.Box) {
	language := a.language()
	root := n == p.tree.root
	rowID := ui.ID(c.Key("treectx/" + n.path))
	target.Hit(rowID, n.name)
	if !root {
		p.tree.rememberRow(rowID, n)
		target.DragSource(&a.dnd.tree)
	}
	if n.dir && !root {
		target.DropTarget(&a.dnd.tree, a.treeDragAccept, a.treeDragDrop)
	}
	ui.ContextMenu(c, target, func(menu *ui.MenuItems) {
		menu.WidthRange(200, 280)
		if nodes := p.tree.batchTargets(); len(nodes) > 1 && p.tree.marked[n.path] {
			a.treeBatchMenu(c, p, menu, nodes)
			return
		}
		opened := false
		if !n.dir {
			if menu.Item(i18n.Shared(language, "desktop.files.open")).Clicked() {
				c.After(func() {
					a.performed("workspace.tree.open", surfaceMenu)
					a.activateTreeNode(p, n)
				})
			}
			if menu.Item(i18n.Shared(language, "desktop.files.openWith")).Clicked() {
				file := filepath.Join(p.root, filepath.FromSlash(n.path))
				c.After(func() { a.openTreeFileWith(file) })
			}
			opened = true
		}
		if !n.dir {
			if change, found := p.git.changeAt(n.path); found {
				if opened {
					menu.Separator()
				}
				opened = true
				if menu.Item(i18n.Shared(language, "desktop.files.showDiff")).Clicked() {
					c.After(func() {
						a.performed("git.diff.open", surfaceMenu)
						a.openDiff(p, change)
					})
				}
				if change.CanToggleStaging {
					stage := !change.Staged || change.Worktree
					item := i18n.Shared(language, "desktop.files.stage")
					if !stage {
						item = i18n.Shared(language, "desktop.files.unstage")
					}
					if menu.Item(item).Clicked() {
						c.After(func() {
							a.performed("git.contextMenu.stage", surfaceMenu)
							a.stageChange(p, change)
						})
					}
					if stage && menu.Item(i18n.Shared(language, "desktop.files.stageAndCommit")).Clicked() {
						c.After(func() {
							a.performed("git.contextMenu.stageAndCommit", surfaceMenu)
							a.stageChangeAndShowCommit(p, change)
						})
					}
				}
			}
		}
		if !n.dir && !root {
			a.treeGitMenu(c, p, n, menu)
			if _, ok := a.kernel.(localHistoryKernel); ok && menu.Item(i18n.Shared(language, "desktop.history.show")).Clicked() {
				file := filepath.Join(p.root, filepath.FromSlash(n.path))
				c.After(func() {
					a.performed("localHistory.show", surfaceMenu)
					a.openLocalHistory(p, file)
				})
			}
			opened = true
		}
		if opened {
			menu.Separator()
		}
		// Find in Files searches the whole project from any row, as the IDE's entry does.
		if menu.Item(i18n.Shared(language, "native.findInFiles")).Clicked() {
			c.After(func() {
				a.performed("workspace.search.open", surfaceMenu)
				a.openFindInFiles(p, false)
			})
		}
		if menu.Item(i18n.Shared(language, "desktop.command.replaceInFiles")).Clicked() {
			c.After(func() {
				a.performed("workspace.replace.open", surfaceMenu)
				a.openFindInFiles(p, true)
			})
		}
		if n.dir && !root {
			if p.directoryExcluded(n.path) {
				if menu.Item(i18n.Shared(language, "indexing.cancelExclusion")).Clicked() {
					c.After(func() { a.excludeFromSearch(p, n.path, true) })
				}
			} else if menu.Item(i18n.Shared(language, "desktop.files.excludeFromSearch")).Clicked() {
				c.After(func() { a.excludeFromSearch(p, n.path, false) })
			}
		}
		if root && p.indexing.loaded {
			if on := p.indexing.gitIgnore; menu.Item(i18n.Shared(language, "indexing.autoGit")).Checked(on).Clicked() {
				c.After(func() { a.setGitIgnoreIndexing(p, !on) })
			}
		}
		if n.dir {
			if p.git.isRepository() && menu.Item(i18n.Shared(language, "desktop.files.showRepositoryChanges")).Clicked() {
				c.After(func() {
					a.performed("git.contextMenu.showRepositoryChanges", surfaceMenu)
					a.showRepositoryChangesOf(p, filepath.Join(p.root, filepath.FromSlash(n.path)))
				})
			}
			menu.Sub(i18n.Shared(language, "native.new"), func(sub *ui.MenuItems) {
				if sub.Item(i18n.Shared(language, "desktop.files.newFile")).Clicked() {
					c.After(func() { a.openTreePrompt(p, treePromptNewFile, n) })
				}
				if sub.Item(i18n.Shared(language, "desktop.files.newDirectory")).Clicked() {
					c.After(func() { a.openTreePrompt(p, treePromptNewDirectory, n) })
				}
			})
		}
		if !root {
			if menu.Item(i18n.Shared(language, "desktop.files.cut")).Clicked() {
				c.After(func() { a.treeCut(p, n) })
			}
			if menu.Item(i18n.Shared(language, "desktop.files.copy")).Clicked() {
				c.After(func() { a.treeCopy(p, n) })
			}
		}
		if n.dir && a.treeClipboardHas(p) && menu.Item(i18n.Shared(language, "desktop.files.paste")).Clicked() {
			c.After(func() { a.treePaste(p, n) })
		}
		if !root {
			if menu.Item(i18n.Shared(language, "desktop.files.duplicate")).Clicked() {
				c.After(func() { a.duplicateTreeItem(p, n) })
			}
			if menu.Item(i18n.Shared(language, "desktop.files.rename")).Clicked() {
				c.After(func() { a.openTreePrompt(p, treePromptRename, n) })
			}
			if menu.Item(i18n.Shared(language, "desktop.files.delete")).Clicked() {
				c.After(func() { a.openTreeRemoval(p, []string{n.path}) })
			}
		}
		menu.Separator()
		full := filepath.Join(p.root, filepath.FromSlash(n.path))
		a.copyPathMenu(c, menu, full, !root, "workspace.tree")
		if menu.Item(revealLabel(language)).Clicked() {
			c.After(func() {
				a.performed("workspace.tree.reveal", surfaceMenu)
				a.revealPath(full)
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.files.refresh")).Clicked() {
			c.After(func() {
				a.performed("workspace.tree.refresh", surfaceMenu)
				a.refreshProjectTree(p)
			})
		}
	})
}

// revealLabel is the menu label that shows a path in the platform's file manager.
func revealLabel(language i18n.Language) string {
	if runtime.GOOS == "windows" {
		return i18n.Shared(language, "desktop.files.revealInExplorer")
	}
	return i18n.Shared(language, "desktop.files.revealInFinder")
}

// revealPath shows full in the platform's file manager and says why when it cannot.
func (a *App) revealPath(full string) {
	if err := treeRevealPath(full); err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.revealFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}

// copyPathMenu declares the Copy Path / Reference submenu of a file or folder at full: its
// absolute path and, when relative is set, its path relative to the project. Every menu that
// copies a path uses it, so the two items sit in one submenu everywhere, as in the IDE. surface
// prefixes the performed actions; an empty surface logs none.
func (a *App) copyPathMenu(c ui.C, menu *ui.MenuItems, full string, relative bool, surface string) {
	language := a.language()
	menu.Sub(i18n.Shared(language, "native.copyPathReference"), func(sub *ui.MenuItems) {
		if sub.Item(i18n.Shared(language, "native.copyPath")).Clicked() {
			c.After(func() {
				if surface != "" {
					a.performed(surface+".copyPath", surfaceMenu)
				}
				a.copyTreePath(full, false)
			})
		}
		if relative && sub.Item(i18n.Shared(language, "native.copyRelativePath")).Clicked() {
			c.After(func() {
				if surface != "" {
					a.performed(surface+".copyRelativePath", surfaceMenu)
				}
				a.copyTreePath(full, true)
			})
		}
	})
}

// copyTreePath copies a path to the clipboard, relative to the project when relative is set.
func (a *App) copyTreePath(full string, relative bool) {
	text := full
	if relative {
		if p := a.project; p != nil {
			if rel, err := filepath.Rel(p.root, full); err == nil {
				text = filepath.ToSlash(rel)
			}
		}
	}
	if err := treeCopyText(text); err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.copyFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}

// openTreePrompt opens the dialog of one row with the text the next action starts from.
func (a *App) openTreePrompt(p *project, kind treePromptKind, n *treeNode) {
	p.tree.prompt = treePrompt{kind: kind, open: true, node: n}
	if kind == treePromptRename {
		p.tree.prompt.name = n.name
	}
}

// treePromptDialog declares the open New File, New Directory or Rename dialog. It applies
// nothing on its own: Enter, Create or Rename runs the action once the text is known, and
// closing the dialog cancels.
func (a *App) treePromptDialog(c ui.C, p *project) {
	pr := &p.tree.prompt
	if !pr.open || pr.node == nil {
		return
	}
	language := a.language()
	var title, confirm string
	switch pr.kind {
	case treePromptNewFile:
		title, confirm = i18n.Shared(language, "desktop.files.newFileTitle"), i18n.Shared(language, "desktop.files.create")
	case treePromptNewDirectory:
		title, confirm = i18n.Shared(language, "desktop.files.newDirectoryTitle"), i18n.Shared(language, "desktop.files.create")
	case treePromptRename:
		title, confirm = i18n.Shared(language, "desktop.files.renameTitle"), i18n.Shared(language, "desktop.files.renameAction")
	default:
		pr.open = false
		return
	}
	closed := ui.Modal(c, &pr.open, title, func() {
		submitted := ui.TextField(c, &pr.name, i18n.Shared(language, "desktop.files.name"), i18n.Shared(language, "desktop.files.name")).FillWidth().Submitted()
		if pr.err != "" {
			ui.Text(c, pr.err).FontSize(12).Color(a.colors.Deleted)
		}
		if submitted {
			c.After(func() { a.submitTreePrompt(p) })
		}
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.files.cancel")).Outline().Clicked() {
			pr.open = false
		}
		if ui.Button(c, confirm).Clicked() {
			c.After(func() { a.submitTreePrompt(p) })
		}
	})
	if closed || !pr.open {
		pr.kind, pr.node, pr.err, pr.name = treePromptNone, nil, "", ""
	}
}

// submitTreePrompt checks the typed name and runs the dialog's action. A name that cannot be
// used keeps the dialog open with the reason under the field.
func (a *App) submitTreePrompt(p *project) {
	pr := &p.tree.prompt
	if !pr.open || pr.node == nil {
		return
	}
	switch pr.kind {
	case treePromptNewFile, treePromptNewDirectory:
		a.createTreeItem(p)
	case treePromptRename:
		a.renameTreeItem(p)
	}
}

// treeItemName is the typed name of a new or renamed item, and why it cannot be used.
func (a *App) treeItemName(pr *treePrompt) (string, bool) {
	name := strings.TrimSpace(pr.name)
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) || strings.ContainsRune(name, 0) {
		pr.err = i18n.Shared(a.language(), "desktop.files.invalidName")
		return "", false
	}
	return name, true
}

// createTreeItem makes the file or directory the New File dialog names in the row's folder.
// A created file opens in a tab, as the old client opened it.
func (a *App) createTreeItem(p *project) {
	pr := &p.tree.prompt
	language := a.language()
	name, ok := a.treeItemName(pr)
	if !ok || !pr.node.dir {
		return
	}
	rel := path.Join(pr.node.path, name)
	full := filepath.Join(p.root, filepath.FromSlash(rel))
	if _, err := os.Lstat(full); err == nil {
		pr.err = i18n.Shared(language, "desktop.files.nameExists")
		return
	}
	var err error
	if pr.kind == treePromptNewFile {
		var file *os.File
		if file, err = os.OpenFile(full, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644); err == nil {
			err = file.Close()
		}
	} else {
		err = os.Mkdir(full, 0o755)
	}
	if err != nil {
		a.notifyError(i18n.SharedFormat(language, "desktop.files.createFailed", map[string]string{"reason": treeErrorReason(err)}))
		return
	}
	created := pr.kind == treePromptNewFile
	parent := pr.node.path
	pr.open, pr.kind, pr.node, pr.err, pr.name = false, treePromptNone, nil, "", ""
	a.performed("workspace.file.create", surfaceMenu)
	a.listTree(p, parent)
	if created {
		a.openFile(p, full)
	}
}

// renameTreeItem renames the row's file or folder, and moves the tabs of the open files below
// it to the new paths. The files are saved first, so a rename never loses an edit.
func (a *App) renameTreeItem(p *project) {
	pr := &p.tree.prompt
	language := a.language()
	name, ok := a.treeItemName(pr)
	if !ok {
		return
	}
	node := pr.node
	if node == p.tree.root || name == node.name {
		pr.open = false
		return
	}
	oldRel := node.path
	newRel := path.Join(path.Dir(oldRel), name)
	oldFull := filepath.Join(p.root, filepath.FromSlash(oldRel))
	newFull := filepath.Join(p.root, filepath.FromSlash(newRel))
	if oldInfo, err := os.Lstat(oldFull); err == nil {
		if newInfo, done := os.Lstat(newFull); done == nil && !os.SameFile(oldInfo, newInfo) {
			pr.err = i18n.Shared(language, "desktop.files.nameExists")
			return
		}
	}
	docs := a.documentsUnder(p, oldFull)
	pr.open = false
	a.saveDocumentsThen(p, docs, func() {
		before := readForLocalHistory(oldFull)
		if err := wslpath.CheckMove(oldFull, newFull); err != nil {
			a.notifyError(err.Error())
			return
		}
		if err := os.Rename(oldFull, newFull); err != nil {
			a.notifyError(i18n.SharedFormat(language, "desktop.files.renameFailed", map[string]string{"reason": treeErrorReason(err)}))
			return
		}
		a.renamedLocalHistory(p, oldFull, newFull, before)
		a.performed("workspace.file.rename", surfaceMenu)
		a.moveOpenDocuments(p, oldFull, newFull)
		a.listTree(p, path.Dir(oldRel))
		a.loadGit(p)
	})
}

// documentsUnder is the open files at target and, when target is a folder, below it.
func (a *App) documentsUnder(p *project, target string) []*document {
	prefix := target + string(filepath.Separator)
	var docs []*document
	for _, d := range p.docs.list {
		if d.virtual {
			continue
		}
		if d.path == target || strings.HasPrefix(d.path, prefix) {
			docs = append(docs, d)
		}
	}
	return docs
}

// saveDocumentsThen saves the documents one at a time and runs then when every save landed. A
// failed save or a conflicting disk copy stops the action: it must not be taken on content
// the window could not keep.
func (a *App) saveDocumentsThen(p *project, docs []*document, then func()) {
	for len(docs) > 0 {
		d := docs[0]
		docs = docs[1:]
		if a.project != p || p.docs.find(d.id) != d {
			continue
		}
		a.saveBeforeClose(p, d, func(ok bool) {
			if ok {
				a.saveDocumentsThen(p, docs, then)
			}
		})
		return
	}
	then()
}

// moveOpenDocuments moves the paths of the open files below oldPath to newPath, closes their
// language-server documents at the old URIs and opens them again at the new ones. Watches are
// re-installed for every open file because a watch names the file's directory.
func (a *App) moveOpenDocuments(p *project, oldPath, newPath string) {
	docs := a.documentsUnder(p, oldPath)
	if len(docs) == 0 {
		return
	}
	for _, slot := range p.docs.watches {
		slot.close()
	}
	p.docs.watches = nil
	for _, d := range docs {
		rel, err := filepath.Rel(oldPath, d.path)
		if err != nil {
			continue
		}
		a.closeDocumentInSession(p, d)
		d.path = filepath.Join(newPath, rel)
		d.name = filepath.Base(d.path)
	}
	for _, d := range p.docs.list {
		a.watchDocument(p, d)
	}
	for _, d := range docs {
		a.startDocumentSync(p, d)
		a.refreshGitGutter(p, d)
		a.refreshInlineBlame(p, d)
	}
}

// treeErrorReason is the system's reason for a failed file operation, without the path.
func treeErrorReason(err error) string {
	var pathErr *os.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Err.Error()
	}
	var linkErr *os.LinkError
	if errors.As(err, &linkErr) {
		return linkErr.Err.Error()
	}
	return err.Error()
}
