package workbench

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/ui"
)

// This file holds the state and the actions of the Commit tool window's Shelf tab, as the macOS
// Commit window had it: the shelves Lithe keeps of the repository, the files the selected one
// saved, and the actions that shelve the local changes, restore a shelf and drop one. The tab is
// declared in shelf_view.go.
//
// Core captures the local changes as patches, cleans them from the checkout and applies them
// again, each step guarded against a repository that changed meanwhile (git.shelf). The host
// owns the shelves: each is one JSON file, format shelfFormat, under the client's configuration
// directory, <store>/Shelves/<hash of the repository root>/<id>.json, never in the repository
// or the installed application. A shelf is written before the checkout is cleaned and removed
// only once every layer was restored, or when the user drops it, so a step that fails leaves
// the changes in the checkout or in the shelf, never in neither.

// shelfKernel is the part of Core the Shelf tab uses.
type shelfKernel interface {
	GitShelfCapture(ctx context.Context, root string) (core.GitShelfSnapshot, error)
	GitShelfPlan(ctx context.Context, root, phase string) ([]string, error)
	GitShelfClean(ctx context.Context, root, layer string, snapshot core.GitShelfSnapshot) error
	GitShelfRestore(ctx context.Context, root, layer string, snapshot core.GitShelfSnapshot) error
	GitParsePatch(ctx context.Context, root, patch string) ([]core.GitDiffFile, error)
}

// shelfFormat is the version of the shelf files this client reads and writes; a file of
// another version is not listed.
const shelfFormat = 1

// shelfRecord is one shelf as its file holds it.
type shelfRecord struct {
	FormatVersion int       `json:"formatVersion"`
	ID            string    `json:"id"`
	Message       string    `json:"message"`
	CreatedAt     time.Time `json:"createdAt"`
	core.GitShelfSnapshot
}

// errNothingToShelve is the failure of shelving a checkout without local changes.
var errNothingToShelve = errors.New("nothing to shelve")

// shelfState is the Shelf tab of a project.
type shelfState struct {
	// loaded says the list was read since the tab was asked to read it again, and loading that
	// a read is running; gen counts the reads, and the answer of an older one is dropped.
	loaded, loading bool
	gen             int
	// err is why the last read failed, writeErr why the last shelve, restore or drop did.
	err, writeErr string
	// busy is set while a shelf is made, restored or dropped.
	busy bool
	list []shelfRecord

	// selected is the identity of the selected shelf, "" for none; tree lists what it saved,
	// one layer for each of layers, the layers Core's patches are of.
	selected string
	layers   []string
	tree     savedFiles
	// filesLoading says the selected shelf's files are being read, and filesGen counts the
	// reads; filesErr is why the last one failed.
	filesLoading bool
	filesGen     int
	filesErr     string

	// shelveOpen says the dialog that shelves the local changes is open, and message is the
	// shelf's name.
	shelveOpen bool
	message    ui.Field
	// dropping is the shelf waiting for the user to confirm dropping it, nil for none.
	dropping *shelfRecord

	shelves ui.ListState
	split   ui.SplitterState
}

// selectedShelf is the selected shelf.
func (s *shelfState) selectedShelf() (shelfRecord, bool) {
	i := slices.IndexFunc(s.list, func(r shelfRecord) bool { return r.ID == s.selected })
	if i < 0 {
		return shelfRecord{}, false
	}
	return s.list[i], true
}

// clearSelection forgets the selected shelf and what it saved.
func (s *shelfState) clearSelection() {
	s.selected, s.layers, s.filesErr = "", nil, ""
	s.filesLoading, s.filesGen = false, s.filesGen+1
	s.tree.reset()
}

// shelfKernel is the window's kernel when it has the Shelf commands.
func (a *App) shelfKernel() (shelfKernel, bool) {
	k, ok := a.kernel.(shelfKernel)
	return k, ok
}

// shelfDirectory is the folder the shelves of the repository at root are kept in, and false
// when the client has no configuration directory to keep them in.
func (a *App) shelfDirectory(root string) (string, bool) {
	if a.store == nil {
		return "", false
	}
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return filepath.Join(a.store.Dir(), "Shelves", hex.EncodeToString(sum[:8])), true
}

// readShelves reads the shelves kept in dir, newest first. A file that does not decode, is of
// another format or does not name itself is skipped and reported in skipped.
func readShelves(dir string) (shelves []shelfRecord, skipped error, err error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".json")
		if !ok || !entry.Type().IsRegular() || !validShelfID(id) {
			continue
		}
		var record shelfRecord
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err == nil {
			err = json.Unmarshal(data, &record)
		}
		if err == nil && (record.FormatVersion != shelfFormat || record.ID != id) {
			err = errors.New("unsupported shelf file " + entry.Name())
		}
		if err != nil {
			skipped = errors.Join(skipped, err)
			continue
		}
		record.Paths = slices.Clip(record.Paths)
		shelves = append(shelves, record)
	}
	slices.SortStableFunc(shelves, func(x, y shelfRecord) int {
		if c := y.CreatedAt.Compare(x.CreatedAt); c != 0 {
			return c
		}
		return strings.Compare(x.ID, y.ID)
	})
	return shelves, skipped, nil
}

// newShelfID is a fresh random identity, which also names the shelf's file.
func newShelfID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// validShelfID says id is an identity newShelfID makes, so it names a file inside the shelf
// folder and nothing else.
func validShelfID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// removeShelf removes the file of the shelf id from dir; a shelf already gone is removed.
func removeShelf(dir, id string) error {
	if !validShelfID(id) {
		return errors.New("invalid shelf identity")
	}
	if err := os.Remove(filepath.Join(dir, id+".json")); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// shelfReason words a failed shelf step for the tab: Core's guards and the empty checkout in
// the words the user acts on, anything else as Core or the system said it.
func (a *App) shelfReason(err error) string {
	lang := a.language()
	var e *core.Error
	switch {
	case errors.Is(err, errNothingToShelve):
		return i18n.Shared(lang, "git.saved.noChanges")
	case errors.As(err, &e) && e.Message == core.GitShelfChanged:
		return i18n.Shared(lang, "git.saved.changed")
	case errors.As(err, &e) && e.Message == core.GitShelfConflicts:
		return i18n.Shared(lang, "git.saved.conflicts")
	}
	return reviewReason(err)
}

// showShelves shows the Commit tool window on its Shelf tab and reads the shelves again.
func (a *App) showShelves() {
	a.performed("git.shelves.show", surfaceMenu)
	a.layout.commitTab = commitTabShelf
	if !a.chrome.isOpen(catalogIndex[itemCommit]) {
		a.reduceChrome(core.SetChromeOpen(itemCommit, true))
	}
	if p := a.project; p != nil {
		p.shelf.loaded = false
	}
}

// loadShelves reads the repository's shelves. A selected shelf that is gone is no longer
// selected; one that is still there keeps its files.
func (a *App) loadShelves(p *project) {
	s := &p.shelf
	dir, ok := a.shelfDirectory(p.git.repositoryRoot(p.root))
	if !ok || !p.git.isRepository() {
		return
	}
	s.loading, s.gen = true, s.gen+1
	gen := s.gen
	a.background(p, reviewTimeout, func(context.Context) func(*App) {
		list, skipped, err := readShelves(dir)
		return func(a *App) {
			s := &p.shelf
			if s.gen != gen {
				return
			}
			s.loading, s.loaded = false, true
			if skipped != nil {
				a.gitOperationFailed("git_shelf_read", skipped)
			}
			if err != nil {
				s.err = err.Error()
				a.gitOperationFailed("git_shelf_list", err)
				return
			}
			s.err, s.list = "", list
			if _, ok := s.selectedShelf(); !ok && s.selected != "" {
				s.clearSelection()
			}
		}
	})
}

// selectShelf selects the shelf id and reads the files it saved from its patches. Selecting
// the selected shelf again reads them again only when the last read failed.
func (a *App) selectShelf(p *project, id string) {
	kernel, ok := a.shelfKernel()
	s := &p.shelf
	if !ok || (s.selected == id && s.filesErr == "") {
		return
	}
	s.clearSelection()
	s.selected = id
	shelf, found := s.selectedShelf()
	if !found {
		s.selected = ""
		return
	}
	s.filesLoading = true
	gen, root := s.filesGen, p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		var (
			kinds []string
			files [][]core.GitDiffFile
			err   error
		)
		for _, layer := range []struct{ kind, patch string }{{core.GitShelfStaged, shelf.StagedPatch}, {core.GitShelfWorking, shelf.WorkingPatch}} {
			if layer.patch == "" {
				continue
			}
			var parsed []core.GitDiffFile
			if parsed, err = kernel.GitParsePatch(ctx, root, layer.patch); err != nil {
				break
			}
			kinds, files = append(kinds, layer.kind), append(files, parsed)
		}
		return func(a *App) {
			s := &p.shelf
			if s.filesGen != gen || s.selected != id {
				return
			}
			s.filesLoading = false
			if err != nil {
				s.filesErr = i18n.Shared(a.language(), "native.couldNotLoadSavedChanges") + ": " + reviewReason(err)
				a.gitOperationFailed("git_shelf_diff", err)
				return
			}
			layers := make([]savedLayer, len(kinds))
			for i, kind := range kinds {
				layers[i] = newSavedLayer(a.shelfLayerLabel(kind), files[i])
			}
			s.layers = kinds
			s.tree.reset(layers...)
		}
	})
}

// shelfLayerLabel names a layer of a shelf: its staged changes or its working tree's.
func (a *App) shelfLayerLabel(kind string) string {
	if kind == core.GitShelfStaged {
		return i18n.Shared(a.language(), "git.saved.staged")
	}
	return i18n.Shared(a.language(), "git.saved.worktree")
}

// shelfFileCount is the number of files a shelf touches.
func shelfFileCount(shelf shelfRecord) int { return len(shelf.Paths) }

// openShelfFile opens the Diff tab of a file the selected shelf saved, in the layer it was
// saved from: HEAD against the index for a staged change, the index against the working tree
// for the others.
func (a *App) openShelfFile(p *project, file savedPath) {
	s := &p.shelf
	if file.path == "" || file.layer < 0 || file.layer >= len(s.layers) || file.layer >= len(s.tree.layers) {
		return
	}
	files := s.tree.layers[file.layer].files
	i := slices.IndexFunc(files, func(f core.GitDiffFile) bool { return f.Path == file.path })
	if i < 0 {
		return
	}
	lang := a.language()
	head, index, worktree := i18n.Shared(lang, "native.head"), i18n.Shared(lang, "git.diff.indexVersion"), i18n.Shared(lang, "git.saved.worktree")
	source := &savedSource{before: index, after: worktree, files: files}
	if s.layers[file.layer] == core.GitShelfStaged {
		source.before, source.after = head, index
	}
	changes := make([]core.GitChange, len(files))
	for j, f := range files {
		changes[j] = core.GitChange{Path: f.Path, OriginalPath: f.OriginalPath, Status: f.Status}
	}
	key := "shelf:" + s.selected + ":" + s.layers[file.layer]
	if a.showDiff(p, p.git.repositoryRoot(p.root), key, changes[i], changes, diffOrigin{saved: source}) != nil {
		a.performed("git.diff.openShelf", surfaceButton)
	}
}

// unsavedInRepository says a file of the repository at root has edits that are not saved, which
// a shelf would neither capture nor keep from being overwritten.
func (p *project) unsavedInRepository(root string) bool {
	for _, d := range p.docs.list {
		if _, inside := projectRelative(root, d.path); inside && !d.virtual && d.dirty() {
			return true
		}
	}
	return false
}

// shelfWrite runs one write of the Shelf tab in the background, then reads the status, the
// shelves and the open diffs of the working tree again whatever the outcome. The failure is
// shown in the tab. A shelve or restore waits until the repository's files are saved.
func (a *App) shelfWrite(p *project, operation string, checkout bool, write func(ctx context.Context, kernel shelfKernel, root, dir string) error) {
	kernel, ok := a.shelfKernel()
	s := &p.shelf
	root := p.git.repositoryRoot(p.root)
	dir, stored := a.shelfDirectory(root)
	if !ok || !stored || s.busy {
		return
	}
	s.writeErr, s.dropping = "", nil
	if checkout && p.unsavedInRepository(root) {
		s.writeErr = i18n.Shared(a.language(), "git.saved.unsaved")
		return
	}
	s.busy = true
	a.performed("git."+operation, surfaceButton)
	if checkout {
		a.showGitConsole(itemCommit)
	}
	a.background(p, syncTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root, dir)
		return func(a *App) {
			s := &p.shelf
			s.busy = false
			if checkout {
				a.loadGit(p)
				a.reloadDiffs(p, root)
			}
			a.loadShelves(p)
			if err != nil {
				s.writeErr = a.shelfReason(err)
				a.gitOperationFailed(operation, err)
			}
		}
	})
}

// openShelve opens the dialog that shelves the local changes.
func (a *App) openShelve(p *project) {
	s := &p.shelf
	s.shelveOpen, s.writeErr = true, ""
	s.message.SetText("")
}

// shelveChanges shelves the local changes under the typed name and closes the dialog: Core
// captures them, the shelf is written, and Core cleans each layer from the checkout. A layer
// that changed meanwhile stops the clean with the shelf kept.
func (a *App) shelveChanges(p *project) {
	s := &p.shelf
	message := strings.TrimSpace(s.message.Text())
	if message == "" {
		return
	}
	s.shelveOpen = false
	created := a.now().UTC()
	a.shelfWrite(p, "git_shelf_shelve", true, func(ctx context.Context, k shelfKernel, root, dir string) error {
		snapshot, err := k.GitShelfCapture(ctx, root)
		if err != nil {
			return err
		}
		if snapshot.Empty() {
			return errNothingToShelve
		}
		record := shelfRecord{FormatVersion: shelfFormat, ID: newShelfID(), Message: message, CreatedAt: created, GitShelfSnapshot: snapshot}
		if err := store.At(dir).Save(record.ID+".json", record); err != nil {
			return err
		}
		layers, err := k.GitShelfPlan(ctx, root, core.GitShelfClean)
		if err != nil {
			return err
		}
		for _, layer := range layers {
			if err := k.GitShelfClean(ctx, root, layer, snapshot); err != nil {
				return err
			}
		}
		return nil
	})
	s.message.SetText("")
}

// restoreShelf applies shelf to the checkout again, layer by layer in the order Core plans, and
// removes it once every layer applied. A restore that stopped keeps the shelf and can be
// repeated: Core passes over a layer an earlier attempt already applied.
func (a *App) restoreShelf(p *project, shelf shelfRecord) {
	a.shelfWrite(p, "git_shelf_restore", true, func(ctx context.Context, k shelfKernel, root, dir string) error {
		layers, err := k.GitShelfPlan(ctx, root, core.GitShelfRestore)
		if err != nil {
			return err
		}
		for _, layer := range layers {
			if err := k.GitShelfRestore(ctx, root, layer, shelf.GitShelfSnapshot); err != nil {
				return err
			}
		}
		return removeShelf(dir, shelf.ID)
	})
}

// confirmDropShelf asks the user to confirm dropping shelf.
func (s *shelfState) confirmDropShelf(shelf shelfRecord) {
	s.dropping = &shelf
}

// dropShelf removes the shelf the user confirmed dropping, leaving the checkout as it is.
func (a *App) dropShelf(p *project) {
	s := &p.shelf
	if s.dropping == nil {
		return
	}
	id := s.dropping.ID
	a.shelfWrite(p, "git_shelf_drop", false, func(_ context.Context, _ shelfKernel, _, dir string) error {
		return removeShelf(dir, id)
	})
}
