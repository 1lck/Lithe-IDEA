package i18n

import "strconv"

// WorktreeMessages are the words of the Git tool window's Worktrees tab: the list of the
// repository's worktrees, the details of one, and the dialogs that create and remove them.
type WorktreeMessages struct {
	// The list pane.
	Search string
	New    string
	// Refresh reloads the list from Git.
	Refresh string
	// Count says how many worktrees the repository has.
	Count         func(count int) string
	Loading       string
	LoadingHint   string
	Unavailable   string
	NoMatches     string
	NoMatchesHint string
	Empty         string
	EmptyHint     string
	Select        string
	SelectHint    string
	// Stale says how many registrations have lost their checkout.
	Stale     func(count int) string
	StaleHint string
	Prune     string
	Repair    string

	// The status label of a worktree, most important first.
	PathMissing string
	Locked      string
	Modified    string
	Current     string
	Available   string

	// BranchOf names the branch a worktree has checked out.
	BranchOf func(name string) string
	Detached string
	Bare     string

	// The tabs of the details pane.
	Overview string
	Changes  string
	History  string

	// The overview's basic information card.
	BasicInformation string
	Path             string
	Branch           string
	Head             string
	Role             string
	Primary          string
	Linked           string

	// The overview's status card.
	Status       string
	Worktree     string
	Registration string
	Valid        string
	StaleRecord  string
	Protection   string
	Unlocked     string
	// LockedBecause is the protection of a worktree locked with a reason.
	LockedBecause  func(reason string) string
	LocalChanges   string
	ChangesLoading string
	NoChanges      string
	ChangedFiles   func(count int) string

	// The actions of the selected worktree.
	OpenCurrent string
	Reveal      string
	CopyPath    string
	Lock        string
	Unlock      string
	Remove      string
	// Why an action is unavailable for the selected worktree.
	RemovePrimary  string
	RemoveCurrent  string
	RemoveLocked   string
	RemovePrunable string
	LockPrimary    string
	LockPrunable   string
	// The card shown instead of the status of a worktree whose checkout is gone.
	MissingTitle string
	MissingHint  string

	// The Changes tab.
	RefreshChanges string
	Clean          string
	ChangesFailed  string

	// The History tab.
	SearchCommits     string
	CommitsLoading    string
	NoMatchingCommits string
	NoCommits         string
	MoreFailed        string
	RefreshHistory    string
	HistoryFailed     func(reason string) string

	// The confirmations.
	RemoveTitle  string
	RemovePrompt func(name string) string
	RemoveButton string
	ForceTitle   string
	ForcePrompt  func(name string) string
	ForceButton  string
	// ReviewForce offers the force removal after Git refused to remove a changed worktree.
	ReviewForce string
	PruneTitle  string
	PrunePrompt string
	Cancel      string

	// The New Worktree dialog.
	CreateTitle         string
	Mode                string
	NewBranch           string
	ExistingBranch      string
	DetachedMode        string
	Reference           string
	BranchName          string
	Revision            string
	RevisionHint        string
	Destination         string
	DestinationAbsolute string
	NoCheckout          string
	NoCheckoutHint      string
	DetachedHint        string
	// NoFreeBranch says every local branch is already checked out by a worktree.
	NoFreeBranch      string
	AfterCreate       string
	Stay              string
	OpenAfter         string
	Create            string
	ReferencesLoading string
	// The reference groups of the dialog's reference list.
	LocalBranches  string
	RemoteBranches string
	Tags           string

	// The results of the operations.
	Created  func(name string) string
	Removed  func(name string) string
	Pruned   string
	Repaired string
	Failed   func(reason string) string
}

func worktreeMessages(language Language) WorktreeMessages {
	return WorktreeMessages{
		Search:  Shared(language, "native.searchWorktreeOrPath"),
		New:     Shared(language, "git.newWorktree"),
		Refresh: Shared(language, "native.refreshWorktrees"),
		Count: func(count int) string {
			if count == 1 {
				return SharedFormat(language, "git.worktreeCount", map[string]string{"count": strconv.Itoa(count)})
			}
			return SharedFormat(language, "git.worktreesCount", map[string]string{"count": strconv.Itoa(count)})
		},
		Loading:       Shared(language, "native.loadingWorktrees"),
		LoadingHint:   Shared(language, "native.readingRegisteredCheckouts"),
		Unavailable:   Shared(language, "native.worktreesAreUnavailable"),
		NoMatches:     Shared(language, "native.noMatches"),
		NoMatchesHint: Shared(language, "native.tryABranchNameOrCheckoutPath"),
		Empty:         Shared(language, "native.noWorktrees"),
		EmptyHint:     Shared(language, "native.createACheckoutToGetStarted"),
		Select:        Shared(language, "native.selectAWorktree"),
		SelectHint:    Shared(language, "native.itsDetailsAndActionsWillAppearHere"),
		Stale: func(count int) string {
			return SharedFormat(language, "native.lldWorktreeRecordsNeedAttention", map[string]string{"arg1": strconv.Itoa(count)})
		},
		StaleHint: Shared(language, "native.aMissingCheckoutCanMakeTheWorktreeListInaccurate"),
		Prune:     Shared(language, "native.pruneStaleRecords"),
		Repair:    Shared(language, "native.repairWorktreeRecords"),

		PathMissing: Shared(language, "native.pathMissing"),
		Locked:      Shared(language, "native.locked"),
		Modified:    Shared(language, "native.modified"),
		Current:     Shared(language, "native.current"),
		Available:   Shared(language, "native.available"),

		BranchOf: func(name string) string {
			return SharedFormat(language, "native.branch.variant3", map[string]string{"arg1": name})
		},
		Detached: Shared(language, "git.detachedHead"),
		Bare:     Shared(language, "git.worktreeDialog.bare"),

		Overview: Shared(language, "native.overview"),
		Changes:  Shared(language, "native.changes"),
		History:  Shared(language, "native.commitHistory"),

		BasicInformation: Shared(language, "native.basicInformation"),
		Path:             Shared(language, "native.path"),
		Branch:           Shared(language, "native.branch"),
		Head:             Shared(language, "native.head"),
		Role:             Shared(language, "native.role"),
		Primary:          Shared(language, "native.primaryWorktree"),
		Linked:           Shared(language, "native.linkedWorktree"),

		Status:       Shared(language, "native.status"),
		Worktree:     Shared(language, "native.worktree"),
		Registration: Shared(language, "native.registration"),
		Valid:        Shared(language, "native.valid"),
		StaleRecord:  Shared(language, "native.staleRecord"),
		Protection:   Shared(language, "native.protection"),
		Unlocked:     Shared(language, "native.unlocked"),
		LockedBecause: func(reason string) string {
			return SharedFormat(language, "desktop.git.worktrees.lockedBecause", map[string]string{"reason": reason})
		},
		LocalChanges:   Shared(language, "native.localChanges.variant2"),
		ChangesLoading: Shared(language, "native.loading"),
		NoChanges:      Shared(language, "native.noChanges"),
		ChangedFiles: func(count int) string {
			return SharedFormat(language, "native.lldChangedFiles", map[string]string{"arg1": strconv.Itoa(count)})
		},

		OpenCurrent:    Shared(language, "native.openInCurrentWindow"),
		Reveal:         Shared(language, "desktop.welcome.menuReveal"),
		CopyPath:       Shared(language, "native.copyPath"),
		Lock:           Shared(language, "native.lockWorktree"),
		Unlock:         Shared(language, "native.unlockWorktree"),
		Remove:         Shared(language, "native.removeWorktree"),
		RemovePrimary:  Shared(language, "native.thePrimaryWorktreeCannotBeRemoved"),
		RemoveCurrent:  Shared(language, "native.theCurrentWorktreeCannotBeRemovedHere"),
		RemoveLocked:   Shared(language, "native.unlockTheWorktreeBeforeRemovingIt"),
		RemovePrunable: Shared(language, "native.pruneTheStaleRecordInstead"),
		LockPrimary:    Shared(language, "native.thePrimaryWorktreeCannotBeLocked"),
		LockPrunable:   Shared(language, "native.repairOrPruneTheMissingCheckoutBeforeChangingItsLock"),
		MissingTitle:   Shared(language, "native.checkoutPathMissing"),
		MissingHint:    Shared(language, "native.theCheckoutDirectoryNoLongerExistsRepairMovedWorktreeMetadataOrPruneTheStaleGitRecord"),

		RefreshChanges: Shared(language, "desktop.commit.refresh"),
		Clean:          Shared(language, "native.thisWorktreeHasNoUncommittedChanges"),
		ChangesFailed:  Shared(language, "native.couldNotInspectThisWorktree"),

		SearchCommits:     Shared(language, "native.searchCommits"),
		CommitsLoading:    Shared(language, "git.log.loadingCommits"),
		NoMatchingCommits: Shared(language, "native.noMatchingCommitsInTheLoadedHistory"),
		NoCommits:         Shared(language, "native.noCommitsWereFoundForThisBranch"),
		MoreFailed:        Shared(language, "desktop.git.loadMoreFailed"),
		RefreshHistory:    Shared(language, "native.refreshHistory"),
		HistoryFailed: func(reason string) string {
			return SharedFormat(language, "desktop.git.failed", map[string]string{"reason": reason})
		},

		RemoveTitle: Shared(language, "native.removeWorktree.variant2"),
		RemovePrompt: func(name string) string {
			return SharedFormat(language, "native.removeAndItsCheckoutDirectoryTheBranchIsKeptIfGitRefusesBecauseFilesHaveChanged2b6784d33", map[string]string{"arg1": name})
		},
		RemoveButton: Shared(language, "git.worktreeDialog.remove"),
		ForceTitle:   Shared(language, "native.forceRemoveWorktree"),
		ForcePrompt: func(name string) string {
			return SharedFormat(language, "native.thisPermanentlyDeletesUncommittedAndUntrackedFilesInTheBranchItselfIsKept", map[string]string{"arg1": name})
		},
		ForceButton: Shared(language, "native.forceRemove"),
		ReviewForce: Shared(language, "native.reviewForceRemove"),
		PruneTitle:  Shared(language, "native.pruneStaleWorktreeRecords"),
		PrunePrompt: Shared(language, "native.thisRemovesGitRegistrationsWhoseCheckoutDirectoriesNoLongerExistItDoesNotDeleteBranches"),
		Cancel:      Shared(language, "desktop.git.cancel"),

		CreateTitle:         Shared(language, "git.newWorktree"),
		Mode:                Shared(language, "git.worktreeDialog.mode"),
		NewBranch:           Shared(language, "git.worktreeDialog.mode.newBranch"),
		ExistingBranch:      Shared(language, "git.worktreeDialog.mode.existingBranch"),
		DetachedMode:        Shared(language, "git.worktreeDialog.mode.detached"),
		Reference:           Shared(language, "git.worktreeDialog.reference"),
		BranchName:          Shared(language, "git.worktreeDialog.branchName"),
		Revision:            Shared(language, "git.worktreeDialog.revision"),
		RevisionHint:        Shared(language, "git.worktreeDialog.revisionHint"),
		Destination:         Shared(language, "git.worktreeDialog.destination"),
		DestinationAbsolute: Shared(language, "desktop.git.worktrees.destinationAbsolute"),
		NoCheckout:          Shared(language, "git.worktreeDialog.noCheckout"),
		NoCheckoutHint:      Shared(language, "native.registersTheWorktreeAndPreparesItsHEADWhileLeavingItsFilesUncheckedOut"),
		DetachedHint:        Shared(language, "native.theWorktreeWillPointDirectlyToACommitCreateABranchThereBeforeKeepingNewCommits"),
		NoFreeBranch:        Shared(language, "native.noAvailableLocalBranchBranchesAlreadyCheckedOutInAnotherWorktreeCannotBeReused"),
		AfterCreate:         Shared(language, "git.worktreeDialog.afterCreate"),
		Stay:                Shared(language, "git.worktreeDialog.after.stay"),
		OpenAfter:           Shared(language, "git.worktreeDialog.after.currentWindow"),
		Create:              Shared(language, "git.create"),
		ReferencesLoading:   Shared(language, "desktop.git.loading"),
		LocalBranches:       Shared(language, "git.log.local"),
		RemoteBranches:      Shared(language, "git.log.remote"),
		Tags:                Shared(language, "git.log.tags"),

		Created: func(name string) string {
			return SharedFormat(language, "native.createdWorktreeFor", map[string]string{"arg1": name})
		},
		Removed: func(name string) string {
			return SharedFormat(language, "desktop.git.worktrees.removed", map[string]string{"name": name})
		},
		Pruned:   Shared(language, "native.prunedStaleWorktreeRecords"),
		Repaired: Shared(language, "native.repairedWorktreeRecords"),
		Failed: func(reason string) string {
			return SharedFormat(language, "desktop.git.worktrees.failed", map[string]string{"reason": reason})
		},
	}
}
