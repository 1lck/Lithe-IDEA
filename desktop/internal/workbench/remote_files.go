package workbench

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file wires the Project tool window's file management operations (create file/directory,
// rename, move, duplicate, copy/cut/paste and delete/trash) to the host of a remote workspace
// through the remote filesystem RPCs Core exposes (remote.writeFile, fs.createDir, fs.rename,
// fs.copy, fs.trash and fs.remove). Every host call runs off the window thread and maps its
// failure through remoteDocuments.failed so a closed connection triggers reconnection and no
// host path leaks into logs.

const (
	// remoteFileOpTimeout bounds a single remote filesystem operation (create, rename, copy,
	// remove or trash) from the Project tool window.
	remoteFileOpTimeout = 2 * time.Minute
	// remoteCopyNameLimit bounds how many "<name> copy N" candidates a remote duplicate or paste
	// tries before giving up.
	remoteCopyNameLimit = 1000
)

// remoteFileReason turns a failed remote file operation error into a localized user-facing
// reason, never leaking host paths.
func (a *App) remoteFileReason(err error) string {
	if errors.Is(err, fs.ErrExist) {
		return i18n.Shared(a.language(), "desktop.files.nameExists")
	}
	if reason, ok := a.remoteDocumentReason(err); ok {
		return reason
	}
	return treeErrorReason(err)
}

// copyCandidateName returns "<stem> copy<ext>" for i == 1 and "<stem> copy <i><ext>" for i > 1.
func copyCandidateName(stem, ext string, i int) string {
	if i <= 1 {
		return stem + " copy" + ext
	}
	return stem + " copy " + strconv.Itoa(i) + ext
}

// remoteCreateTreeItem creates a new empty file or directory on the remote host inside pr.node.
func (a *App) remoteCreateTreeItem(p *project, name string) {
	pr := &p.tree.prompt
	if pr.busy {
		return
	}
	r := a.remoteDocuments(p)
	if r == nil {
		return
	}
	kind := pr.kind
	parent := pr.node.path
	rel := path.Join(parent, name)
	full := filepath.Join(p.root, filepath.FromSlash(rel))
	pr.busy, pr.err = true, ""

	a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
		host, session, err := r.writable(full)
		if err == nil {
			if kind == treePromptNewFile {
				var saved bool
				_, saved, err = r.kernel.RemoteWriteFile(ctx, session, host, nil, nil, r.binding.RemoteRoot())
				if err != nil {
					err = r.failed(session, err)
				} else if !saved {
					err = &remoteFileError{reason: fs.ErrExist}
				}
			} else {
				if err = r.kernel.RemoteMakeDirectory(ctx, session, host); err != nil {
					err = r.failed(session, err)
				}
			}
		}
		return func(a *App) {
			if a.project != p || p.remote == nil || p.remote.closed {
				// log-exempt: 用户取消：工作区已关闭，远程创建结果不再应用。
				return
			}
			pr := &p.tree.prompt
			pr.busy = false
			language := a.language()
			if err != nil {
				if errors.Is(err, fs.ErrExist) {
					a.operationRejected("project_tree_create", "already_exists")
					if pr.open && pr.kind == kind {
						pr.err = i18n.Shared(language, "desktop.files.nameExists")
					} else {
						a.notifyError(i18n.Shared(language, "desktop.files.nameExists"))
					}
					return
				}
				a.operationFailed("project_tree_create", remoteLogError(err))
				a.notifyError(i18n.SharedFormat(language, "desktop.files.createFailed", map[string]string{"reason": a.remoteFileReason(err)}))
				return
			}
			pr.open, pr.kind, pr.node, pr.err, pr.name = false, treePromptNone, nil, "", ""
			a.performed("workspace.file.create", surfaceButton)
			a.listTree(p, parent)
			if kind == treePromptNewFile {
				a.openFile(p, full)
			}
		}
	})
}

// remoteRenameTreeItem renames node on the remote host to name, saving any open documents under
// it first and moving their tabs to the new placeholder paths once the host rename succeeds.
func (a *App) remoteRenameTreeItem(p *project, node *treeNode, name string) {
	pr := &p.tree.prompt
	if pr.busy {
		return
	}
	r := a.remoteDocuments(p)
	if r == nil {
		return
	}
	oldRel := node.path
	newRel := path.Join(path.Dir(oldRel), name)
	oldFull := filepath.Join(p.root, filepath.FromSlash(oldRel))
	newFull := filepath.Join(p.root, filepath.FromSlash(newRel))
	docs := a.documentsUnder(p, oldFull)

	run := func(keepDialog bool) {
		a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
			oldHost, session, err := r.writable(oldFull)
			var newHost string
			if err == nil {
				newHost, _, err = r.writable(newFull)
			}
			if err == nil {
				if err = r.kernel.RemoteRename(ctx, session, oldHost, newHost, false); err != nil {
					err = r.failed(session, err)
				}
			}
			return func(a *App) {
				if a.project != p || p.remote == nil || p.remote.closed {
					// log-exempt: 用户取消：工作区已关闭，远程重命名结果不再应用。
					return
				}
				pr := &p.tree.prompt
				pr.busy = false
				language := a.language()
				if err != nil {
					if errors.Is(err, fs.ErrExist) {
						a.operationRejected("project_tree_rename", "already_exists")
						if keepDialog && pr.open && pr.kind == treePromptRename && pr.node == node {
							pr.err = i18n.Shared(language, "desktop.files.nameExists")
						} else {
							a.notifyError(i18n.Shared(language, "desktop.files.nameExists"))
						}
						return
					}
					a.operationFailed("project_tree_rename", remoteLogError(err))
					a.notifyError(i18n.SharedFormat(language, "desktop.files.renameFailed", map[string]string{"reason": a.remoteFileReason(err)}))
					return
				}
				if keepDialog && pr.open && pr.kind == treePromptRename && pr.node == node {
					pr.open, pr.kind, pr.node, pr.err, pr.name = false, treePromptNone, nil, "", ""
				}
				a.performed("workspace.file.rename", surfaceButton)
				a.moveOpenDocuments(p, oldFull, newFull)
				a.listTree(p, path.Dir(oldRel))
				a.loadGit(p)
			}
		})
	}

	if len(docs) == 0 {
		pr.busy, pr.err = true, ""
		run(true)
		return
	}
	pr.open = false
	a.saveDocumentsThen(p, docs, func() { run(false) })
}

// remoteMoveTreeItem moves rel into dir on the remote host, saving open documents below rel
// first and moving their tabs to the new placeholder paths.
func (a *App) remoteMoveTreeItem(p *project, rel, dir string) {
	r := a.remoteDocuments(p)
	if r == nil {
		return
	}
	oldFull := filepath.Join(p.root, filepath.FromSlash(rel))
	newFull := filepath.Join(p.root, filepath.FromSlash(dir), filepath.Base(filepath.FromSlash(rel)))
	docs := a.documentsUnder(p, oldFull)
	a.saveDocumentsThen(p, docs, func() {
		a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
			oldHost, session, err := r.writable(oldFull)
			var newHost string
			if err == nil {
				newHost, _, err = r.writable(newFull)
			}
			if err == nil {
				if err = r.kernel.RemoteRename(ctx, session, oldHost, newHost, false); err != nil {
					err = r.failed(session, err)
				}
			}
			return func(a *App) {
				if a.project != p || p.remote == nil || p.remote.closed {
					// log-exempt: 用户取消：工作区已关闭，远程移动结果不再应用。
					return
				}
				language := a.language()
				if err != nil {
					if errors.Is(err, fs.ErrExist) {
						a.operationRejected("project_tree_move", "already_exists")
						a.notify(i18n.Shared(language, "desktop.files.nameExists"))
						return
					}
					a.operationFailed("project_tree_move", remoteLogError(err))
					a.notifyError(i18n.SharedFormat(language, "desktop.files.moveFailed", map[string]string{"reason": a.remoteFileReason(err)}))
					return
				}
				a.moveOpenDocuments(p, oldFull, newFull)
				a.listTree(p, path.Dir(rel))
				a.listTree(p, dir)
				a.loadGit(p)
			}
		})
	})
}

// remoteDuplicateTreeItem copies n beside itself on the remote host under the first free
// "<name> copy" name.
func (a *App) remoteDuplicateTreeItem(p *project, n *treeNode) {
	r := a.remoteDocuments(p)
	if r == nil || n == nil || n == p.tree.root {
		return
	}
	rel := n.path
	isDir := n.dir
	sourceFull := filepath.Join(p.root, filepath.FromSlash(rel))
	parent := path.Dir(rel)
	a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
		sourceHost, session, err := r.writable(sourceFull)
		if err == nil {
			dirHost, base := path.Split(sourceHost)
			stem, ext := base, ""
			if !isDir {
				ext = path.Ext(base)
				stem = strings.TrimSuffix(base, ext)
			}
			for i := 1; i <= remoteCopyNameLimit; i++ {
				targetHost := path.Join(dirHost, copyCandidateName(stem, ext, i))
				err = r.kernel.RemoteCopy(ctx, session, sourceHost, targetHost, true, false)
				if err == nil {
					break
				}
				err = r.failed(session, err)
				if !errors.Is(err, fs.ErrExist) {
					break
				}
			}
		}
		return func(a *App) {
			if a.project != p || p.remote == nil || p.remote.closed {
				// log-exempt: 用户取消：工作区已关闭，远程创建副本结果不再应用。
				return
			}
			if err != nil {
				a.operationFailed("project_tree_duplicate", remoteLogError(err))
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.duplicateFailed", map[string]string{"reason": a.remoteFileReason(err)}))
				return
			}
			a.performed("workspace.file.duplicate", surfaceContextMenu)
			a.listTree(p, parent)
			a.loadGit(p)
		}
	})
}

// remoteMovedPath records one remote cut-and-paste move so open documents follow it.
type remoteMovedPath struct {
	oldFull string
	newFull string
}

// remoteTreePaste moves (when cut) or copies the tree clipboard items into n's folder on the
// remote host.
func (a *App) remoteTreePaste(p *project, n *treeNode) {
	r := a.remoteDocuments(p)
	if r == nil {
		return
	}
	dir := n.path
	if !n.dir {
		dir = path.Dir(n.path)
	}
	clip := treeClipboard{paths: slices.Clone(p.tree.clip.paths), cut: p.tree.clip.cut}
	if clip.cut {
		p.tree.clip = treeClipboard{}
	}
	run := func() {
		a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
			var moved []remoteMovedPath
			var failed error
			for _, rel := range clip.paths {
				if clip.cut && path.Dir(rel) == dir {
					continue
				}
				srcFull := filepath.Join(p.root, filepath.FromSlash(rel))
				srcHost, session, err := r.writable(srcFull)
				if err != nil {
					failed = err
					continue
				}
				dstDirFull := filepath.Join(p.root, filepath.FromSlash(dir))
				dstDirHost, _, err := r.writable(dstDirFull)
				if err != nil {
					failed = err
					continue
				}
				base := path.Base(rel)
				ext := path.Ext(base)
				stem := strings.TrimSuffix(base, ext)
				var chosenName string
				var opErr error
				for i := 0; i <= remoteCopyNameLimit; i++ {
					candidate := base
					if i > 0 {
						candidate = copyCandidateName(stem, ext, i)
					}
					dstHost := path.Join(dstDirHost, candidate)
					if clip.cut {
						opErr = r.kernel.RemoteRename(ctx, session, srcHost, dstHost, false)
					} else {
						opErr = r.kernel.RemoteCopy(ctx, session, srcHost, dstHost, true, false)
					}
					if opErr == nil {
						chosenName = candidate
						break
					}
					opErr = r.failed(session, opErr)
					if !errors.Is(opErr, fs.ErrExist) {
						break
					}
				}
				if opErr != nil {
					failed = opErr
					continue
				}
				if clip.cut && chosenName != "" {
					moved = append(moved, remoteMovedPath{
						oldFull: srcFull,
						newFull: filepath.Join(dstDirFull, chosenName),
					})
				}
			}
			return func(a *App) {
				if a.project != p || p.remote == nil || p.remote.closed {
					// log-exempt: 用户取消：工作区已关闭，远程粘贴结果不再应用。
					return
				}
				for _, m := range moved {
					a.moveOpenDocuments(p, m.oldFull, m.newFull)
				}
				a.performed("workspace.file.paste", surfaceContextMenu)
				if failed != nil {
					a.operationFailed("project_tree_paste", remoteLogError(failed))
					a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.pasteFailed", map[string]string{"reason": a.remoteFileReason(failed)}))
				}
				a.listTree(p, dir)
				for _, rel := range clip.paths {
					a.listTree(p, path.Dir(rel))
				}
				a.loadGit(p)
			}
		})
	}
	if !clip.cut {
		run()
		return
	}
	var savePaths []string
	for _, rel := range clip.paths {
		if path.Dir(rel) != dir {
			savePaths = append(savePaths, rel)
		}
	}
	_, docs := a.removalPaths(p, savePaths)
	a.saveDocumentsThen(p, docs, run)
}

// remoteRemoveTreeItems moves paths to the remote host's system trash or, when permanent is set,
// deletes them permanently on the host. Open documents under paths are saved and closed first.
func (a *App) remoteRemoveTreeItems(p *project, paths []string, permanent bool) {
	r := a.remoteDocuments(p)
	if r == nil {
		return
	}
	full, docs := a.removalPaths(p, paths)
	parents := treeParents(paths)
	performed, failure := "workspace.file.trash", trashFailedText
	if permanent {
		performed, failure = "workspace.file.delete", deleteFailedText
	}
	if len(paths) > 1 {
		performed += "Batch"
	}
	a.saveDocumentsThen(p, docs, func() {
		a.closeOpenDocuments(p, docs)
		a.background(p, remoteFileOpTimeout, func(ctx context.Context) func(*App) {
			failed := 0
			var reason error
			for _, f := range full {
				host, session, err := r.writable(f)
				if err == nil {
					if permanent {
						err = r.kernel.RemoteRemove(ctx, session, host, true)
					} else {
						err = r.kernel.RemoteTrash(ctx, session, host)
					}
					if err != nil {
						err = r.failed(session, err)
					}
				}
				if err != nil {
					failed++
					reason = err
				}
			}
			return func(a *App) {
				if a.project != p || p.remote == nil || p.remote.closed {
					// log-exempt: 用户取消：工作区已关闭，远程删除结果不再应用。
					return
				}
				p.tree.marked, p.tree.anchor, p.tree.targets = nil, "", nil
				a.performed(performed, surfaceButton)
				if failed > 0 && reason != nil {
					a.operationFailed("project_tree_remove", remoteLogError(reason))
					a.notifyError(failure(a.language(), a.remoteFileReason(reason)))
				}
				for _, dir := range parents {
					a.listTree(p, dir)
				}
				a.loadGit(p)
			}
		})
	})
}
