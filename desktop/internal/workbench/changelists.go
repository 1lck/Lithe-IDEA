package workbench

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/ui"
)

// This file keeps the project's local ChangeLists (matrix id git-local-changelists): named
// groups of the changed files, one of them active. Core reduces them (git.changelists): it
// validates every action, decides which list each changed file belongs to, and builds the
// scope a commit of the active list passes to git.workspaceCommitPrepare. The window stores
// the lists, one file per repository root in the client's store, reads that file again
// before every change so another window's newer lists are never overwritten, and drops an
// answer a newer status made stale. A list that cannot be read or reduced turns staging all,
// committing and generating a message off instead of falling back to every staged file.
// What the Commit tool window shows of the lists is in changelists_view.go.

const (
	// changeListDefaultID is the list every file belongs to until it is moved; Core keeps it
	// first and it cannot be renamed or removed.
	changeListDefaultID = "default"
	// changeListsVersion is the version of the stored file.
	changeListsVersion = 1
	// changeListRetries bounds how often a job starts over when another window stored the
	// lists while it ran.
	changeListRetries = 3
)

// changeListKernel is the part of the kernel the lists use. *core.Client implements it; a
// kernel that does not (a test double) hides the lists, and every change is in the default.
type changeListKernel interface {
	ReduceChangeLists(ctx context.Context, request core.ChangeListRequest) (core.ChangeListResult, error)
}

// changeListDialog is the dialog of the lists that is open.
type changeListDialog uint8

const (
	changeListNoDialog changeListDialog = iota
	changeListCreate
	changeListRename
	changeListDelete
)

// changeListState is what a project keeps of its lists.
type changeListState struct {
	// read is set once the stored lists of root were read and reduced without a failure.
	read bool
	root string
	// failed is why the stored lists or Core's answer could not be used; while it is set,
	// staging all, committing and generating a message stay off.
	failed error
	state  core.ChangeListState
	// members is the list of each change of the status shown, by path; a path it lacks is in
	// the default list. scope is the restriction a commit of the active list passes, nil
	// while only the default list exists.
	members map[string]string
	scope   *core.ChangeListScope
	// statusGen counts the statuses the project read; projected is the one members and scope
	// were computed for.
	statusGen, projected int
	// queue holds the jobs waiting while one runs; running is set while one does.
	queue   []changeListJob
	running bool
	// pick is the value of the list picker; a pick that differs from the active list
	// activates the list picked.
	pick string
	// dialog is the dialog that is open, target the list it renames or removes, name its
	// text field and nameError why Core refused the name.
	dialog changeListDialog
	// selected are the paths of the changes a Ctrl, Cmd or Shift click picked for a batch move;
	// anchor is the path a Shift click extends from (changelists_select.go).
	selected  map[string]bool
	anchor    string
	target    string
	name      ui.Field
	nameError string
	// move are the files a list being created takes once it exists.
	move []core.ChangeListFile
}

// changeListJob is one reduction of the stored lists: an action, or none to only work out
// where the changes of the status belong. then runs on the window thread afterwards.
type changeListJob struct {
	action *core.ChangeListAction
	// follow is a second action run on the state the first one left, as the move of the
	// files a new list takes.
	follow  func(core.ChangeListState) *core.ChangeListAction
	then    func(a *App, err error)
	retries int
}

// changeListAnswer is what a job found: the lists after it, and the list of each file and
// the commit scope when lists other than the default exist.
type changeListAnswer struct {
	state   core.ChangeListState
	members []string
	scope   *core.ChangeListScope
}

// storedChangeLists is the file the lists of one repository root are kept in.
type storedChangeLists struct {
	Version int                  `json:"version"`
	Root    string               `json:"root"`
	State   core.ChangeListState `json:"state"`
}

// errChangeListsMoved reports that another window stored the lists while a job ran.
var errChangeListsMoved = errors.New("the changelists were stored by another window")

// changeListsFile is the name of the file the lists of root are kept in.
func changeListsFile(root string) string {
	sum := sha256.Sum256([]byte(root))
	return "git-changelists-" + hex.EncodeToString(sum[:8]) + ".json"
}

// defaultChangeLists are the lists of a repository that has none stored: the default alone.
func defaultChangeLists() core.ChangeListState {
	return core.ChangeListState{
		Lists:       []core.ChangeList{{ID: changeListDefaultID}},
		ActiveID:    changeListDefaultID,
		Assignments: map[string]map[string]string{},
	}
}

// loadChangeLists reads the stored lists of root.
func loadChangeLists(s *store.Store, root string) (core.ChangeListState, error) {
	var stored storedChangeLists
	found, err := s.Load(changeListsFile(root), &stored)
	switch {
	case err != nil:
		return core.ChangeListState{}, err
	case !found:
		return defaultChangeLists(), nil
	case stored.Version != changeListsVersion:
		return core.ChangeListState{}, fmt.Errorf("changelists file version %d is not supported", stored.Version)
	case stored.Root != root:
		return core.ChangeListState{}, errors.New("changelists file belongs to another repository")
	}
	return stored.State, nil
}

// sameChangeLists reports that two states are the same lists, active list and assignments.
func sameChangeLists(a, b core.ChangeListState) bool {
	x, errX := json.Marshal(a)
	y, errY := json.Marshal(b)
	return errX == nil && errY == nil && string(x) == string(y)
}

// changeListsInUse reports that lists other than the default exist.
func changeListsInUse(state core.ChangeListState) bool { return len(state.Lists) > 1 }

// changeListFiles are the changes as Core's list files of the repository at root.
func changeListFiles(root string, changes []core.GitChange) []core.ChangeListFile {
	files := make([]core.ChangeListFile, 0, len(changes))
	for _, change := range changes {
		files = append(files, core.ChangeListFile{
			Root: root, Path: change.Path, OriginalPath: change.OriginalPath, IsCopy: isCopyStatus(change.Status),
		})
	}
	return files
}

// isCopyStatus reports that a porcelain status is a copy, whose source keeps its own list.
func isCopyStatus(status string) bool {
	for _, r := range status {
		if r == 'C' {
			return true
		}
	}
	return false
}

// reduceStoredChangeLists reads the stored lists of root, has Core apply action (or only
// place files when action is nil) and stores the result when it changed, unless another
// window stored the lists in between. It runs off the window thread.
func reduceStoredChangeLists(ctx context.Context, s *store.Store, kernel changeListKernel, root string, files []core.ChangeListFile, job changeListJob) (changeListAnswer, error) {
	stored, err := loadChangeLists(s, root)
	if err != nil {
		return changeListAnswer{}, err
	}
	if job.action == nil && !changeListsInUse(stored) {
		return changeListAnswer{state: stored}, nil
	}
	repositories := []core.WorkspaceCommitRepository{{ID: commitRepositoryID, Root: root}}
	reduce := func(state core.ChangeListState, action *core.ChangeListAction) (core.ChangeListResult, error) {
		if action == nil {
			// Placing the files also records the renames, so a renamed file keeps its list.
			action = &core.ChangeListAction{Type: "rememberRenames"}
		}
		return kernel.ReduceChangeLists(ctx, core.ChangeListRequest{State: state, Files: files, Repositories: repositories, Action: action})
	}
	result, err := reduce(stored, job.action)
	if err == nil && job.follow != nil {
		if next := job.follow(result.State); next != nil {
			result, err = reduce(result.State, next)
		}
	}
	if err != nil {
		return changeListAnswer{}, err
	}
	if !sameChangeLists(stored, result.State) {
		again, err := loadChangeLists(s, root)
		if err != nil {
			return changeListAnswer{}, err
		}
		if !sameChangeLists(again, stored) {
			return changeListAnswer{}, errChangeListsMoved
		}
		if err := s.Save(changeListsFile(root), storedChangeLists{Version: changeListsVersion, Root: root, State: result.State}); err != nil {
			return changeListAnswer{}, err
		}
	}
	answer := changeListAnswer{state: result.State}
	if changeListsInUse(result.State) {
		scope := result.Scope
		answer.members, answer.scope = result.Members, &scope
	}
	return answer, nil
}

// setGit shows a status the project read and works out again where its changes belong.
func (a *App) setGit(p *project, g gitState) {
	p.git = g
	p.lists.statusGen++
	a.queueChangeLists(p, changeListJob{})
}

// queueChangeLists runs job after the jobs already waiting. A placement waiting already
// stands for a second one: it reads the status when it starts.
func (a *App) queueChangeLists(p *project, job changeListJob) {
	l := &p.lists
	if job.action == nil && job.then == nil {
		for _, waiting := range l.queue {
			if waiting.action == nil && waiting.then == nil {
				return
			}
		}
	}
	l.queue = append(l.queue, job)
	a.nextChangeListJob(p)
}

// nextChangeListJob starts the first waiting job unless one runs.
func (a *App) nextChangeListJob(p *project) {
	l := &p.lists
	if l.running || len(l.queue) == 0 {
		return
	}
	job := l.queue[0]
	l.queue = l.queue[1:]
	kernel, ok := a.kernel.(changeListKernel)
	if !ok || !p.git.isRepository() {
		l.members, l.scope, l.projected = nil, nil, l.statusGen
		if !ok {
			l.read, l.state = true, defaultChangeLists()
		}
		if job.then != nil {
			job.then(a, nil)
		}
		a.nextChangeListJob(p)
		return
	}
	root := p.git.repositoryRoot(p.root)
	files := changeListFiles(root, p.git.status.Changes)
	statusGen, s := l.statusGen, a.store
	l.running = true
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		answer, err := reduceStoredChangeLists(ctx, s, kernel, root, files, job)
		return func(a *App) {
			l.running = false
			if errors.Is(err, errChangeListsMoved) && job.retries < changeListRetries {
				job.retries++
				l.queue = append([]changeListJob{job}, l.queue...)
				a.nextChangeListJob(p)
				return
			}
			a.applyChangeLists(p, root, statusGen, job, answer, err)
			if job.then != nil {
				job.then(a, err)
			}
			a.nextChangeListJob(p)
		}
	})
}

// applyChangeLists keeps what a job found. A placement that failed turns the commit off; an
// action that failed leaves the lists as they were, and its caller reports it.
func (a *App) applyChangeLists(p *project, root string, statusGen int, job changeListJob, answer changeListAnswer, err error) {
	l := &p.lists
	if err != nil {
		if job.action == nil {
			l.failed, l.members, l.scope = err, nil, nil
			a.gitOperationFailed("git_changelists", err)
		}
		return
	}
	l.read, l.root, l.failed, l.state = true, root, nil, answer.state
	l.pick = l.activeID()
	if statusGen != l.statusGen || root != p.git.repositoryRoot(p.root) {
		return // the placement queued for the newer status fills members
	}
	l.members, l.scope, l.projected = nil, answer.scope, statusGen
	if len(answer.members) == len(p.git.status.Changes) {
		l.members = make(map[string]string, len(answer.members))
		for i, change := range p.git.status.Changes {
			l.members[change.Path] = answer.members[i]
		}
	}
}

// activeID is the active list.
func (l *changeListState) activeID() string {
	if l.state.ActiveID == "" {
		return changeListDefaultID
	}
	return l.state.ActiveID
}

// inUse reports that lists other than the default exist, so the changes are grouped and a
// commit takes only the active list.
func (l *changeListState) inUse() bool { return changeListsInUse(l.state) }

// list is the list with id.
func (l *changeListState) list(id string) (core.ChangeList, bool) {
	for _, list := range l.state.Lists {
		if list.ID == id {
			return list, true
		}
	}
	return core.ChangeList{}, false
}

// listsReady reports that the lists were read and placed for the status shown, so staging
// all and committing know which changes belong to the active list. A kernel without lists
// puts every change in the default list, which is ready at once.
func (p *project) listsReady() bool {
	l := &p.lists
	return l.read && l.failed == nil && (!l.inUse() || l.projected == l.statusGen)
}

// changeListOf is the list change belongs to.
func (p *project) changeListOf(change core.GitChange) string {
	if id, ok := p.lists.members[change.Path]; ok && p.lists.inUse() {
		return id
	}
	return changeListDefaultID
}

// listChanges are the changes of the status that belong to the list id.
func (p *project) listChanges(id string) []core.GitChange {
	var changes []core.GitChange
	for _, change := range p.git.status.Changes {
		if p.changeListOf(change) == id {
			changes = append(changes, change)
		}
	}
	return changes
}

// activeChanges are the changes a stage all and a commit take: the active list's, or every
// change while only the default list exists.
func (p *project) activeChanges() []core.GitChange {
	if !p.lists.inUse() {
		return p.git.status.Changes
	}
	return p.listChanges(p.lists.activeID())
}

// activeStagedCount is the number of the active list's changes that have something staged.
func (p *project) activeStagedCount() int {
	n := 0
	for _, change := range p.activeChanges() {
		if change.Staged {
			n++
		}
	}
	return n
}

// otherStaged reports that a change of another list than the active one is staged, which a
// commit of the active list would refuse to take.
func (p *project) otherStaged() bool {
	if !p.lists.inUse() {
		return false
	}
	active := p.lists.activeID()
	for _, change := range p.git.status.Changes {
		if change.Staged && p.changeListOf(change) != active {
			return true
		}
	}
	return false
}

// commitScope is the scope a commit of the active list passes, nil while only the default
// list exists.
func (p *project) commitScope() *core.ChangeListScope {
	if !p.lists.inUse() || p.lists.scope == nil {
		return nil
	}
	scope := *p.lists.scope
	return &scope
}

// newChangeListID is the ID of a list being created.
func newChangeListID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err) // crypto/rand does not fail on supported platforms
	}
	return hex.EncodeToString(b[:])
}

// changeListAction queues action and reports how it ended to done, which may be nil.
func (a *App) changeListAction(p *project, operation string, action core.ChangeListAction, follow func(core.ChangeListState) *core.ChangeListAction, done func(a *App, err error)) {
	a.performed(operation, surfaceButton)
	a.queueChangeLists(p, changeListJob{action: &action, follow: follow, then: func(a *App, err error) {
		if err != nil && done == nil {
			a.changeListFailed(err)
		}
		if done != nil {
			done(a, err)
		}
	}})
}

// changeListFailed tells the user that a list action failed and logs it.
func (a *App) changeListFailed(err error) {
	a.notifyError(a.text.Commit.Failed(err.Error()))
	a.gitOperationFailed("git_changelists", err)
}

// activateChangeList makes the list id the one stage all and commit take.
func (a *App) activateChangeList(p *project, id string) {
	if id == p.lists.activeID() {
		return
	}
	// Results read for the list that was active belong to it: the selection, a generation
	// that is still running and a message waiting to be confirmed are dropped.
	a.discardListResults(p)
	a.changeListAction(p, "git.changelists.activate", core.ChangeListAction{Type: "activate", ID: id}, nil, nil)
}

// moveToChangeList moves changes to the list id.
func (a *App) moveToChangeList(p *project, changes []core.GitChange, id string) {
	p.lists.selected, p.lists.anchor = nil, ""
	files := changeListFiles(p.git.repositoryRoot(p.root), changes)
	a.changeListAction(p, "git.changelists.move", core.ChangeListAction{Type: "move", ID: id, Files: &files}, nil, nil)
}

// openChangeListDialog opens the dialog that creates, renames or removes a list. move are the
// files a list being created takes.
func (a *App) openChangeListDialog(p *project, dialog changeListDialog, move []core.GitChange) {
	l := &p.lists
	l.dialog, l.nameError, l.move = dialog, "", nil
	l.target = l.activeID()
	l.name.SetText("")
	switch dialog {
	case changeListCreate:
		if len(move) > 0 {
			l.move = changeListFiles(p.git.repositoryRoot(p.root), move)
		}
	case changeListRename:
		if list, ok := l.list(l.target); ok {
			l.name.SetText(list.Name)
		}
	}
}

// closeChangeListDialog closes the dialog of the lists.
func (a *App) closeChangeListDialog(p *project) {
	l := &p.lists
	l.dialog, l.nameError, l.move = changeListNoDialog, "", nil
}

// submitChangeListName creates or renames a list with the typed name. Core decides whether
// the name can be used; the dialog stays open with the reason when it cannot.
func (a *App) submitChangeListName(p *project) {
	l := &p.lists
	name := l.name.Text()
	done := func(a *App, err error) {
		var kernelErr *core.Error
		switch {
		case err == nil:
			a.closeChangeListDialog(p)
		case errors.As(err, &kernelErr) && kernelErr.Code == core.CodeInvalidRequest:
			l.nameError = i18n.Shared(a.language(), "git.changelists.invalidName")
		default:
			l.nameError = err.Error()
			a.gitOperationFailed("git_changelists", err)
		}
	}
	if l.dialog == changeListRename {
		a.changeListAction(p, "git.changelists.rename", core.ChangeListAction{Type: "rename", ID: l.target, Name: name}, nil, done)
		return
	}
	id, move := newChangeListID(), l.move
	var follow func(core.ChangeListState) *core.ChangeListAction
	if len(move) > 0 {
		follow = func(core.ChangeListState) *core.ChangeListAction {
			files := move
			return &core.ChangeListAction{Type: "move", ID: id, Files: &files}
		}
	}
	a.changeListAction(p, "git.changelists.create", core.ChangeListAction{Type: "create", ID: id, Name: name}, follow, done)
}

// removeChangeList removes the list the delete dialog is open for; its files return to the
// default list and their staging is left as it is.
func (a *App) removeChangeList(p *project) {
	l := &p.lists
	a.changeListAction(p, "git.changelists.remove", core.ChangeListAction{Type: "remove", ID: l.target}, nil, func(a *App, err error) {
		a.closeChangeListDialog(p)
		if err != nil {
			a.changeListFailed(err)
		}
	})
}
