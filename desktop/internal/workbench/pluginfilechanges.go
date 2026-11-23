package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// This file is the window side of API-11 (pluginservice/hostfilechanges.go): a plugin saves,
// saves as and closes documents, and creates, renames, copies and trashes files. A save goes
// through the document's own save, so an open document keeps its undo history and language
// session. Core makes every file change (core/file_changes.go): it resolves the plugin's path
// below the root, never follows the last component and never replaces an entry. The window
// keeps what only it owns: saving the open documents under an entry first, moving them with
// their files, the system trash, local history and the project tree. None of them asks the user
// anything: a save that needs the user's choice (a disk conflict, a hard link) is refused with
// a code, and the editor keeps offering the user that choice. Failures are logged here and
// returned to the plugin, without a notice of their own.

var _ pluginservice.FileChangeHost = pluginWorkbench{}

// onWindowAsync runs start on the window thread and waits until it, or work it started that
// ends later on the window thread, calls finish, or until ctx ends. Work that already started
// is not undone by a cancellation.
func onWindowAsync[T any](a *App, ctx context.Context, start func(a *App, finish func(T, error))) (T, error) {
	type outcome struct {
		value T
		err   error
	}
	done := make(chan outcome, 1)
	var once sync.Once
	finish := func(value T, err error) {
		once.Do(func() { done <- outcome{value, err} })
	}
	a.post(func(a *App) {
		if err := ctx.Err(); err != nil {
			var zero T
			finish(zero, err)
			return
		}
		start(a, finish)
	})
	select {
	case result := <-done:
		return result.value, result.err
	case <-ctx.Done():
		var zero T
		return zero, ctx.Err()
	}
}

// localProjectAt is projectAt for a change. Plugin contexts are only opened for local
// projects, so a remote one means the window changed under the request.
func (a *App) localProjectAt(root string) (*project, error) {
	p, err := a.projectAt(root)
	if err != nil {
		return nil, err
	}
	if p.remote != nil {
		return nil, hostError("plugin.host.authorityUnsupported", "The workspace is not on this computer.")
	}
	return p, nil
}

// finishSaveWaiters tells the plugin saves waiting on d how the last write went.
func (a *App) finishSaveWaiters(d *document, err error) {
	waiters := d.saveWaiters
	d.saveWaiters = nil
	for _, done := range waiters {
		done(err)
	}
}

// pluginSave writes d's current text the way the user's Save does, with the edits made while a
// save ran, and calls done when d is clean or the save failed. It never asks the user: an
// untitled or virtual document, a disk conflict and an input-method composition are refused
// before anything is written.
func (a *App) pluginSave(p *project, d *document, done func(error)) {
	switch {
	case d.virtual:
		done(hostError(pluginservice.CodePreconditionFailed, "The document has no file to save."))
	case d.scratch:
		done(hostError(pluginservice.CodePreconditionFailed, "An untitled document is saved with documents/saveAs."))
	case d.recoveredConflict || d.conflicted || d.recreateMissing:
		done(hostError(pluginservice.CodeDiskChanged, "The file changed on disk; the user chooses which version to keep."))
	case d.view.IsComposing():
		done(hostError(pluginservice.CodeBusy, "An input method composition is active."))
	case !d.saving && !d.dirty():
		done(nil)
	default:
		d.saveWaiters = append(d.saveWaiters, func(err error) { done(pluginSaveError(err)) })
		if !d.saving {
			a.saveDocumentMode(p, d.id, savePlugin)
		}
	}
}

// pluginSaveError is the contract's error for a failed save. The user also sees the editor's
// own save-failed notice, except for a hard link, whose choice the editor offers on the user's
// next Save.
func pluginSaveError(err error) error {
	var required *documentio.HardLinkRequired
	switch {
	case err == nil:
		return nil
	case errors.As(err, &required), errors.Is(err, documentio.ErrHardLink):
		return hostError(pluginservice.CodePreconditionFailed, "The file has hard links; the user chooses how it is saved.")
	case errors.Is(err, documentio.ErrConflict):
		return hostError(pluginservice.CodeDiskChanged, "The file changed on disk; the user chooses which version to keep.")
	case errors.Is(err, errComposing):
		return hostError(pluginservice.CodeBusy, "An input method composition is active.")
	}
	return hostError(pluginservice.CodeFailed, "The save failed: "+err.Error())
}

// pluginSaveAll saves docs one at a time and stops at the first failure.
func (a *App) pluginSaveAll(p *project, docs []*document, done func(error)) {
	for len(docs) > 0 {
		d := docs[0]
		docs = docs[1:]
		if a.project != p || p.docs.find(d.id) != d {
			continue
		}
		a.pluginSave(p, d, func(err error) {
			if err != nil {
				done(err)
				return
			}
			a.pluginSaveAll(p, docs, done)
		})
		return
	}
	done(nil)
}

func documentNotOpen() error {
	return hostError(pluginservice.CodeNotFound, "The document is not open.")
}

func (w pluginWorkbench) SaveDocument(ctx context.Context, root, id string, expectedVersion *int) (pluginservice.DocumentSummary, error) {
	return onWindowAsync(w.app, ctx, func(a *App, finish func(pluginservice.DocumentSummary, error)) {
		p, err := a.localProjectAt(root)
		if err != nil {
			finish(pluginservice.DocumentSummary{}, err)
			return
		}
		d := p.publicDocument(id)
		if d == nil {
			finish(pluginservice.DocumentSummary{}, documentNotOpen())
			return
		}
		if current := d.view.Revision(); expectedVersion != nil && *expectedVersion != current {
			finish(pluginservice.DocumentSummary{}, &pluginservice.HostError{Code: pluginservice.CodeVersionConflict,
				Message: "The document changed since the plugin read it.", Details: map[string]any{"currentVersion": current}})
			return
		}
		a.pluginSave(p, d, func(err error) {
			if err != nil {
				finish(pluginservice.DocumentSummary{}, err)
				return
			}
			finish(summarize(p, d), nil)
		})
	})
}

// SaveDocumentAs has Core create target, which must not exist, with the document's text, then
// opens and selects the new file. An untitled document whose text did not change during the
// write closes, as it does for the user's Save As; any other document stays as it was.
func (w pluginWorkbench) SaveDocumentAs(ctx context.Context, root, id, target string) (pluginservice.DocumentSummary, error) {
	return onWindowAsync(w.app, ctx, func(a *App, finish func(pluginservice.DocumentSummary, error)) {
		fail := func(err error) { finish(pluginservice.DocumentSummary{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			fail(err)
			return
		}
		d := p.publicDocument(id)
		switch {
		case d == nil:
			fail(documentNotOpen())
			return
		case d.view.IsComposing():
			fail(hostError(pluginservice.CodeBusy, "An input method composition is active."))
			return
		case d.scratch && d.saving:
			// An untitled document has one Save As at a time; a document with a file writes a
			// copy of its text, which its own save does not change.
			fail(hostError(pluginservice.CodeBusy, "A save of the document is running."))
			return
		}
		before := d.view.TextSnapshot()
		text := string(before.Bytes())
		scratch := d.scratch
		if scratch {
			d.saving = true
		}
		creation := core.WorkspaceEntryCreation{Root: p.root, Path: target, Kind: "file", Text: &text}
		a.kernelChange(p, "plugin_document_save_as", func(ctx context.Context, kernel Kernel) (core.WorkspaceEntry, error) {
			return kernel.CreateWorkspaceEntry(ctx, creation)
		}, func(entry core.WorkspaceEntry, err error) {
			if scratch {
				d.saving = false
				waiters := d.closeWaiters
				d.closeWaiters = nil
				for _, done := range waiters {
					done(err == nil) // As for the user's Save As, a failure keeps the tab open.
				}
			}
			if err != nil {
				fail(err)
				return
			}
			if scratch && p.docs.find(d.id) == d && d.view.TextSnapshot().Same(before) {
				a.removeDocument(p, d)
				a.flushCheckpoint(p, d, true)
			}
			a.listTree(p, treeDir(p, entry.FullPath))
			a.openForPlugin(p, entry.FullPath, func(opened *document, err error) {
				if err != nil || opened == nil {
					fail(hostError(pluginservice.CodeFailed, "The file was written but could not be opened."))
					return
				}
				finish(summarize(p, opened), nil)
			})
		})
	})
}

// openForPlugin opens and selects the file at path and calls done with its document. A file
// the window shows in a viewer has no document.
func (a *App) openForPlugin(p *project, path string, done func(*document, error)) {
	path = filepath.Clean(path)
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		done(d, nil)
		return
	}
	if _, viewer := viewerKindOf(path); viewer && !p.standalone {
		a.openFile(p, path)
		done(nil, errors.New("the file opens in a viewer"))
		return
	}
	if p.docs.openWaiters == nil {
		p.docs.openWaiters = make(map[string][]func(*document, error))
	}
	p.docs.openWaiters[path] = append(p.docs.openWaiters[path], done)
	a.openFile(p, path)
}

// CloseDocument closes the tab after the document's text is on disk and the disk copy matches
// it. A virtual document closes at once, and an untitled one keeps its draft.
func (w pluginWorkbench) CloseDocument(ctx context.Context, root, id string) error {
	_, err := onWindowAsync(w.app, ctx, func(a *App, finish func(struct{}, error)) {
		end := func(err error) { finish(struct{}{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			end(err)
			return
		}
		d := p.publicDocument(id)
		if d == nil {
			end(documentNotOpen())
			return
		}
		closeTab := func() {
			if a.project == p && p.docs.find(d.id) == d {
				a.removeDocument(p, d)
			}
			end(nil)
		}
		switch {
		case d.virtual:
			closeTab()
			return
		case d.scratch && d.saving:
			end(hostError(pluginservice.CodeBusy, "A save of the document is running."))
			return
		case d.scratch:
			closeTab()
			return
		}
		a.pluginSave(p, d, func(err error) {
			if err != nil {
				end(err)
				return
			}
			a.checkBeforeClose(p, d, func(ok bool) {
				if !ok {
					end(hostError(pluginservice.CodeDiskChanged, "The file on disk differs from the document."))
					return
				}
				closeTab()
			})
		})
	})
	return err
}

// treeDir is the project-relative folder holding full, as the tree names it ("" for the root).
func treeDir(p *project, full string) string {
	rel, err := filepath.Rel(p.root, filepath.Dir(full))
	if err != nil || rel == "." {
		return ""
	}
	return filepath.ToSlash(rel)
}

// kernelChange runs change, one Core file change, off the window thread and calls done on the
// window thread with the entry it named, or with the contract's error for its failure, which it
// logged. When p is no longer the window's project by then, done gets contextExpired, since
// nothing of p is left to update; the change itself is not undone.
func (a *App) kernelChange(p *project, operation string, change func(context.Context, Kernel) (core.WorkspaceEntry, error), done func(core.WorkspaceEntry, error)) {
	kernel := a.kernel
	if kernel == nil {
		done(core.WorkspaceEntry{}, hostError(pluginservice.CodeFailed, "The window has no kernel."))
		return
	}
	a.background(p, 0, func(ctx context.Context) func(*App) {
		entry, err := change(ctx, kernel)
		return func(a *App) {
			switch {
			case err != nil:
				done(entry, a.changeFailed(operation, err))
			case a.project != p:
				done(entry, hostError(pluginservice.CodeContextExpired, "The workspace is no longer open."))
			default:
				done(entry, nil)
			}
		}
	})
}

// changeFailed logs a failed change and returns the contract's error for it. Core refusing the
// request (the entry exists or is missing, or the path is not one of the root's) is a rejection;
// anything else failed.
func (a *App) changeFailed(operation string, err error) error {
	mapped := pluginservice.ChangeError(err)
	var refusal *pluginservice.HostError
	if errors.As(mapped, &refusal) && refusal.Code != pluginservice.CodeFailed {
		a.operationRejected(operation, strings.TrimPrefix(refusal.Code, "plugin.host."))
	} else {
		a.operationFailed(operation, documentLogError(err))
	}
	return mapped
}

// CreateEntry has Core create the file, directory or symbolic link at entry.Path, which it never
// replaces, and shows it in the project tree.
func (w pluginWorkbench) CreateEntry(ctx context.Context, root string, entry pluginservice.EntryCreation) error {
	_, err := onWindowAsync(w.app, ctx, func(a *App, finish func(struct{}, error)) {
		end := func(err error) { finish(struct{}{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			end(err)
			return
		}
		creation := core.WorkspaceEntryCreation{Root: p.root, Path: entry.Path, Kind: entry.Kind, Text: entry.Text, LinkTarget: entry.LinkTarget}
		a.kernelChange(p, "plugin_file_create", func(ctx context.Context, kernel Kernel) (core.WorkspaceEntry, error) {
			return kernel.CreateWorkspaceEntry(ctx, creation)
		}, func(created core.WorkspaceEntry, err error) {
			if err != nil {
				end(err)
				return
			}
			a.performed("workspace.file.create", surfacePlugin)
			a.listTree(p, treeDir(p, created.FullPath))
			end(nil)
		})
	})
	return err
}

// resolveForPlugin has Core name the existing entry at path below p's root, without following
// it, and calls found with it on the window thread, or end with the contract's error.
func (a *App) resolveForPlugin(p *project, operation, path string, end func(error), found func(core.WorkspaceEntry)) {
	a.kernelChange(p, operation, func(ctx context.Context, kernel Kernel) (core.WorkspaceEntry, error) {
		return kernel.ResolveWorkspaceEntry(ctx, p.root, path)
	}, func(entry core.WorkspaceEntry, err error) {
		if err != nil {
			end(err)
			return
		}
		found(entry)
	})
}

// RenameEntry saves the open documents at or below from, then has Core move from to to as the
// project tree's Rename does: local history follows, and the open documents follow their files.
// A target that exists is refused by Core after the saves, which keep what they wrote.
func (w pluginWorkbench) RenameEntry(ctx context.Context, root, from, to string) error {
	_, err := onWindowAsync(w.app, ctx, func(a *App, finish func(struct{}, error)) {
		end := func(err error) { finish(struct{}{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			end(err)
			return
		}
		a.resolveForPlugin(p, "plugin_file_rename", from, end, func(source core.WorkspaceEntry) {
			a.pluginSaveAll(p, a.documentsUnder(p, source.FullPath), func(err error) {
				if err != nil {
					end(err)
					return
				}
				var before []byte
				a.kernelChange(p, "plugin_file_rename", func(ctx context.Context, kernel Kernel) (core.WorkspaceEntry, error) {
					if source.Kind == "file" {
						before = readForLocalHistory(source.FullPath)
					}
					return kernel.RenameWorkspaceEntry(ctx, p.root, from, to)
				}, func(target core.WorkspaceEntry, err error) {
					if err != nil {
						end(err)
						return
					}
					a.renamedLocalHistory(p, source.FullPath, target.FullPath, before)
					a.performed("workspace.file.rename", surfacePlugin)
					a.moveOpenDocuments(p, source.FullPath, target.FullPath)
					a.listTree(p, treeDir(p, source.FullPath), treeDir(p, target.FullPath))
					a.loadGit(p)
					end(nil)
				})
			})
		})
	})
	return err
}

// CopyEntry has Core copy from to to: a file with its mode, a directory with everything in it,
// and a symbolic link as the same link.
func (w pluginWorkbench) CopyEntry(ctx context.Context, root, from, to string) error {
	_, err := onWindowAsync(w.app, ctx, func(a *App, finish func(struct{}, error)) {
		end := func(err error) { finish(struct{}{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			end(err)
			return
		}
		a.kernelChange(p, "plugin_file_copy", func(ctx context.Context, kernel Kernel) (core.WorkspaceEntry, error) {
			return kernel.CopyWorkspaceEntry(ctx, p.root, from, to)
		}, func(copied core.WorkspaceEntry, err error) {
			if err != nil {
				end(err)
				return
			}
			a.performed("workspace.file.copy", surfacePlugin)
			a.listTree(p, treeDir(p, copied.FullPath))
			a.loadGit(p)
			end(nil)
		})
	})
	return err
}

// TrashEntry saves the open documents at or below path, closes their tabs and moves the entry
// Core named to the system trash, from which the user restores it.
func (w pluginWorkbench) TrashEntry(ctx context.Context, root, path string) error {
	_, err := onWindowAsync(w.app, ctx, func(a *App, finish func(struct{}, error)) {
		end := func(err error) { finish(struct{}{}, err) }
		p, err := a.localProjectAt(root)
		if err != nil {
			end(err)
			return
		}
		a.resolveForPlugin(p, "plugin_file_trash", path, end, func(entry core.WorkspaceEntry) {
			docs := a.documentsUnder(p, entry.FullPath)
			a.pluginSaveAll(p, docs, func(err error) {
				if err != nil {
					end(err)
					return
				}
				a.closeOpenDocuments(p, docs)
				trash := treeMoveToTrash
				a.background(p, 0, func(context.Context) func(*App) {
					err := trash(entry.FullPath)
					return func(a *App) {
						if err != nil {
							a.operationFailed("plugin_file_trash", documentLogError(err))
							end(hostError(pluginservice.CodeFailed, "The system trash refused the entry: "+err.Error()))
							return
						}
						a.performed("workspace.file.trash", surfacePlugin)
						if a.project == p {
							// The marks may name the row that went away.
							p.tree.marked, p.tree.anchor, p.tree.targets = nil, "", nil
							a.listTree(p, treeDir(p, entry.FullPath))
							a.loadGit(p)
						}
						end(nil)
					}
				})
			})
		})
	})
	return err
}
