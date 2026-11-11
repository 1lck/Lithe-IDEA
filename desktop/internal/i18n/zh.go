package i18n

import "strconv"

var chinese = Messages{
	App:     appMessages(Chinese),
	Welcome: welcomeMessages(Chinese),
	Title:   titleMessages(Chinese),
	Window:  windowMessages(Chinese),
	Tools:   toolMessages(Chinese),
	Dock:    dockMessages(Chinese),
	Panel:   panelMessages(Chinese),
	Editor:  editorMessages(Chinese),
	Project: projectMessages(Chinese),
	Git: GitMessages{
		Log:       Shared(Chinese, "desktop.git.log"),
		Worktrees: Shared(Chinese, "git.worktrees"),
		Console:   Shared(Chinese, "git.console.title"),
		LogTab: func(reference string) string {
			return SharedFormat(Chinese, "desktop.git.logTab", map[string]string{"reference": reference})
		},
		AllReferences:        Shared(Chinese, "desktop.git.allReferences"),
		ShowAll:              Shared(Chinese, "desktop.git.showAll"),
		Actions:              Shared(Chinese, "desktop.git.actions"),
		FetchAll:             Shared(Chinese, "desktop.git.fetchAll"),
		FetchOptions:         Shared(Chinese, "desktop.git.fetchOptions"),
		UpdateBranch:         Shared(Chinese, "desktop.git.updateBranch"),
		RefreshLog:           Shared(Chinese, "desktop.git.refreshLog"),
		ShowChanges:          Shared(Chinese, "desktop.git.showChanges"),
		Branches:             Shared(Chinese, "git.branches"),
		HideBranches:         Shared(Chinese, "desktop.git.hideBranches"),
		ShowBranches:         Shared(Chinese, "desktop.git.showBranches"),
		NewBranch:            Shared(Chinese, "git.log.toolbar.newBranch"),
		DeleteBranch:         Shared(Chinese, "desktop.git.deleteBranch"),
		CompareWorkingTree:   Shared(Chinese, "desktop.git.compareWorkingTree"),
		CompareWithCurrent:   Shared(Chinese, "desktop.git.compareWithCurrent"),
		FindBranch:           Shared(Chinese, "desktop.git.findBranch"),
		Fetch:                Shared(Chinese, "git.contextMenu.fetch"),
		LocateBranch:         Shared(Chinese, "desktop.git.locateBranch"),
		BranchSettings:       Shared(Chinese, "desktop.git.branchSettings"),
		ExpandAll:            Shared(Chinese, "desktop.git.expandAll"),
		CollapseAll:          Shared(Chinese, "desktop.git.collapseAll"),
		BranchSearch:         Shared(Chinese, "desktop.git.branchSearch"),
		HeadRow:              Shared(Chinese, "git.log.headCurrentBranch"),
		LocalGroup:           Shared(Chinese, "git.log.local"),
		RemoteGroup:          Shared(Chinese, "git.log.remote"),
		TagGroup:             Shared(Chinese, "git.log.tags"),
		NoMatchingReferences: Shared(Chinese, "desktop.git.noMatchingReferences"),
		TextOrHash:           Shared(Chinese, "desktop.git.textOrHash"),
		FilterBranch:         Shared(Chinese, "git.log.filterBranch"),
		FilterUser:           Shared(Chinese, "desktop.git.filterUser"),
		FilterDate:           Shared(Chinese, "desktop.git.filterDate"),
		FilterPaths:          Shared(Chinese, "desktop.git.filterPaths"),
		ClearFilter:          Shared(Chinese, "desktop.git.clearFilter"),
		CompareBranch:        Shared(Chinese, "desktop.git.compareBranch"),
		ShowDetails:          Shared(Chinese, "desktop.git.showDetails"),
		Decorations:          Shared(Chinese, "desktop.git.decorations"),
		FindInLog:            Shared(Chinese, "desktop.git.findInLog"),
		LongEdges:            Shared(Chinese, "desktop.git.longEdges"),
		PathTitle:            Shared(Chinese, "desktop.git.pathTitle"),
		PathPlaceholder:      Shared(Chinese, "desktop.git.pathPlaceholder"),
		Clear:                Shared(Chinese, "desktop.git.clear"),
		Cancel:               Shared(Chinese, "desktop.git.cancel"),
		Apply:                Shared(Chinese, "desktop.git.apply"),
		SearchUsers:          Shared(Chinese, "desktop.git.searchUsers"),
		NoMatchingUsers:      Shared(Chinese, "desktop.git.noMatchingUsers"),
		AnyTime:              Shared(Chinese, "desktop.git.anyTime"),
		Today:                Shared(Chinese, "desktop.git.today"),
		Yesterday:            Shared(Chinese, "desktop.git.yesterday"),
		Last7Days:            Shared(Chinese, "desktop.git.last7Days"),
		Last30Days:           Shared(Chinese, "desktop.git.last30Days"),
		OlderOutside:         Shared(Chinese, "desktop.git.olderOutside"),
		FilterValue: func(filter, value string) string {
			return SharedFormat(Chinese, "desktop.git.filterValue", map[string]string{"filter": filter, "value": value})
		},
		Loading:        Shared(Chinese, "desktop.git.loading"),
		NotRepository:  Shared(Chinese, "desktop.git.notRepository"),
		NoCommits:      Shared(Chinese, "desktop.git.noCommits"),
		NoMatches:      Shared(Chinese, "git.noMatchingCommits"),
		LoadMore:       Shared(Chinese, "git.log.loadMore"),
		LoadingCommits: Shared(Chinese, "git.log.loadingCommits"),
		LoadMoreFailed: Shared(Chinese, "desktop.git.loadMoreFailed"),
		SelectCommit:   Shared(Chinese, "git.log.selectCommit"),
		LoadingFiles:   Shared(Chinese, "git.log.loadingChangedFiles"),
		FilesFailed:    Shared(Chinese, "desktop.git.filesFailed"),
		Retry:          Shared(Chinese, "git.log.retry"),
		NoChangedFiles: Shared(Chinese, "git.log.noChangedFiles"),
		CommitDetails:  Shared(Chinese, "git.log.commitDetails"),
		CompareChanges: Shared(Chinese, "desktop.git.compareChanges"),
		FileHistory:    Shared(Chinese, "desktop.git.fileHistory"),
		On: func(date string) string {
			return SharedFormat(Chinese, "desktop.git.on", map[string]string{"date": date})
		},
		Failed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.git.failed", map[string]string{"reason": reason})
		},
	},
	Commit: CommitMessages{
		Refresh:    Shared(Chinese, "desktop.commit.refresh"),
		StageAll:   Shared(Chinese, "desktop.commit.stageAll"),
		UnstageAll: Shared(Chinese, "git.unstageAllChanges"),
		ChangeList: Shared(Chinese, "git.changelists.default"),
		Files:      func(count int) string { return commitFiles(Chinese, count) },
		StageFile: func(path string) string {
			return SharedFormat(Chinese, "desktop.commit.stageFile", map[string]string{"path": path})
		},
		UnstageFile: func(path string) string {
			return SharedFormat(Chinese, "desktop.commit.unstageFile", map[string]string{"path": path})
		},
		StagedState:        Shared(Chinese, "git.staged"),
		PartlyStagedState:  Shared(Chinese, "desktop.commit.partlyStagedState"),
		UnstagedState:      Shared(Chinese, "git.unstaged"),
		Clean:              Shared(Chinese, "desktop.commit.clean"),
		Amend:              Shared(Chinese, "git.amend"),
		Staged:             func(count int) string { return commitStaged(Chinese, count) },
		MessageLabel:       Shared(Chinese, "git.log.commitMessage"),
		MessagePlaceholder: Shared(Chinese, "git.commitMessagePlaceholder"),
		Commit:             Shared(Chinese, "git.commit"),
		CommitAndPush:      Shared(Chinese, "desktop.commit.commitAndPush"),
		Committing:         Shared(Chinese, "desktop.commit.committing"),
		Options:            Shared(Chinese, "desktop.commit.options"),
		SignOff:            Shared(Chinese, "desktop.commit.signOff"),
		SignOffHelp:        Shared(Chinese, "desktop.commit.signOffHelp"),
		Author:             Shared(Chinese, "desktop.commit.author"),
		AuthorPlaceholder:  Shared(Chinese, "desktop.commit.authorPlaceholder"),
		AuthorHelp:         Shared(Chinese, "desktop.commit.authorHelp"),
		AuthorInvalid:      Shared(Chinese, "desktop.commit.authorInvalid"),
		Result: func(repository, status string) string {
			return SharedFormat(Chinese, "desktop.commit.result", map[string]string{"repository": repository, "status": status})
		},
		Dismiss:         Shared(Chinese, "desktop.commit.dismiss"),
		Retry:           Shared(Chinese, "desktop.commit.retry"),
		ReviewTitle:     Shared(Chinese, "desktop.commit.reviewTitle"),
		ReviewPushTitle: Shared(Chinese, "desktop.commit.reviewPushTitle"),
		ReviewRetry:     Shared(Chinese, "desktop.commit.reviewRetry"),
		Order:           Shared(Chinese, "desktop.commit.order"),
		MessageLine: func(message string) string {
			return SharedFormat(Chinese, "desktop.commit.messageLine", map[string]string{"message": message})
		},
		AmendNote: Shared(Chinese, "desktop.commit.amendNote"),
		AuthorLine: func(author string) string {
			return SharedFormat(Chinese, "desktop.commit.authorLine", map[string]string{"author": author})
		},
		SignOffNote:  Shared(Chinese, "desktop.commit.signOffNote"),
		Step:         func(n int, action, repository string) string { return commitStep(Chinese, n, action, repository) },
		StepCommit:   Shared(Chinese, "git.commit"),
		StepPush:     Shared(Chinese, "desktop.commit.stepPush"),
		StepPushOnly: Shared(Chinese, "desktop.commit.stepPushOnly"),
		Where: func(branch, head string) string {
			return SharedFormat(Chinese, "desktop.commit.where", map[string]string{"branch": branch, "head": head})
		},
		DetachedHead: Shared(Chinese, "git.detachedHead"),
		NoCommits:    Shared(Chinese, "desktop.commit.noCommits"),
		TracksDifferent: func(local, upstream string) string {
			return SharedFormat(Chinese, "desktop.commit.tracksDifferent", map[string]string{"local": local, "upstream": upstream})
		},
		PublishTo: func(remote, branch string) string {
			return SharedFormat(Chinese, "git.pushDialog.publishSameName", map[string]string{"remote": remote, "branch": branch})
		},
		PushTo: func(upstream string) string {
			return SharedFormat(Chinese, "desktop.commit.pushTo", map[string]string{"upstream": upstream})
		},
		Continue:             Shared(Chinese, "git.execution.continue"),
		Cancel:               Shared(Chinese, "agent.state.cancel"),
		Pending:              Shared(Chinese, "git.workspaceCommit.pending"),
		NotIncluded:          Shared(Chinese, "git.workspaceCommit.notIncluded"),
		Committed:            Shared(Chinese, "git.workspaceCommit.committed"),
		CommittedPushPending: Shared(Chinese, "git.workspaceCommit.committedPushPending"),
		CommittedAndPushed:   Shared(Chinese, "git.workspaceCommit.committedAndPushed"),
		CommitFailed:         Shared(Chinese, "desktop.commit.commitFailed"),
		HeadAdvanced:         Shared(Chinese, "git.workspaceCommit.headAdvanced"),
		OutcomeUnknown:       Shared(Chinese, "git.workspaceCommit.outcomeUnknown"),
		PushFailed:           Shared(Chinese, "git.workspaceCommit.pushFailed"),
		ReviewRequired:       Shared(Chinese, "desktop.commit.reviewRequired"),
		WaitingForSubmodule:  Shared(Chinese, "git.workspaceCommit.waitingForSubmodule"),
		EnterMessage:         Shared(Chinese, "desktop.commit.enterMessage"),
		ChooseTarget:         Shared(Chinese, "desktop.commit.chooseTarget"),
		PlanChanged:          Shared(Chinese, "git.workspaceCommit.changed"),
		Done:                 Shared(Chinese, "git.changesCommitted"),
		Pushed:               Shared(Chinese, "git.changesPushed"),
		NeedsAttention:       Shared(Chinese, "git.workspaceCommit.attention"),
		StageFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.commit.stageFailed", map[string]string{"reason": reason})
		},
		UnstageFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.commit.unstageFailed", map[string]string{"reason": reason})
		},
		Failed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.commit.failed", map[string]string{"reason": reason})
		},
	},
	Branch: BranchMessages{
		Popup:            Shared(Chinese, "git.branches"),
		Search:           Shared(Chinese, "desktop.branch.search"),
		NewBranch:        Shared(Chinese, "git.contextMenu.newBranch"),
		CheckoutRevision: Shared(Chinese, "desktop.branch.checkoutRevision"),
		Recent:           Shared(Chinese, "desktop.branch.recent"),
		Local:            Shared(Chinese, "git.log.local"),
		Remote:           Shared(Chinese, "git.log.remote"),
		Tags:             Shared(Chinese, "git.log.tags"),
		Loading:          Shared(Chinese, "desktop.branch.loading"),
		NoMatches:        Shared(Chinese, "git.noMatchingBranches"),
		LoadFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.branch.loadFailed", map[string]string{"reason": reason})
		},
		Current: Shared(Chinese, "desktop.branch.current"),
		RowMenu: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.rowMenu", map[string]string{"name": name})
		},
		NewBranchFrom: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.newBranchFrom", map[string]string{"name": name})
		},
		Checkout:       Shared(Chinese, "git.checkout"),
		Rename:         Shared(Chinese, "desktop.branch.rename"),
		Delete:         Shared(Chinese, "git.delete"),
		NewBranchTitle: Shared(Chinese, "git.log.toolbar.newBranch"),
		CreateFrom: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.createFrom", map[string]string{"name": name})
		},
		BranchName:    Shared(Chinese, "desktop.branch.branchName"),
		CheckoutAfter: Shared(Chinese, "desktop.branch.checkoutAfter"),
		Create:        Shared(Chinese, "git.create"),
		RenameTitle:   Shared(Chinese, "desktop.branch.renameTitle"),
		RenameFrom: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.renameFrom", map[string]string{"name": name})
		},
		RenameButton: Shared(Chinese, "desktop.branch.renameButton"),
		Cancel:       Shared(Chinese, "agent.state.cancel"),
		NameEmpty:    Shared(Chinese, "git.log.branchNameEmpty"),
		NameHead:     Shared(Chinese, "git.log.branchNameHead"),
		NameRemote: func(name string) string {
			return SharedFormat(Chinese, "git.log.branchNameClashesWithRemote", map[string]string{"name": name})
		},
		NameDirectory: func(name string) string {
			return SharedFormat(Chinese, "git.log.branchNameClashesWithDirectory", map[string]string{"name": name})
		},
		NameExists: func(name string) string {
			return SharedFormat(Chinese, "git.log.branchNameAlreadyExists", map[string]string{"name": name})
		},
		NamePrefix: func(name, branch string) string {
			return SharedFormat(Chinese, "git.log.branchNameClashesWithBranchPrefix", map[string]string{"name": name, "branch": branch})
		},
		RevisionTitle:  Shared(Chinese, "desktop.branch.revisionTitle"),
		RevisionPrompt: Shared(Chinese, "desktop.branch.revisionPrompt"),
		Revision:       Shared(Chinese, "desktop.branch.revision"),
		DetachedNote:   Shared(Chinese, "desktop.branch.detachedNote"),
		ConflictTitle:  Shared(Chinese, "desktop.branch.conflictTitle"),
		ConflictPrompt: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.conflictPrompt", map[string]string{"name": name})
		},
		ConflictHint:  Shared(Chinese, "desktop.branch.conflictHint"),
		SmartCheckout: Shared(Chinese, "desktop.branch.smartCheckout"),
		ForceCheckout: Shared(Chinese, "desktop.branch.forceCheckout"),
		DeleteTitle:   Shared(Chinese, "desktop.branch.deleteTitle"),
		DeletePrompt: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.deletePrompt", map[string]string{"name": name})
		},
		DeleteButton: Shared(Chinese, "git.deleteBranch"),
		AlreadyOn: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.alreadyOn", map[string]string{"name": name})
		},
		CheckedOut: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.checkedOut", map[string]string{"name": name})
		},
		Detached: func(revision string) string {
			return SharedFormat(Chinese, "desktop.branch.detached", map[string]string{"revision": revision})
		},
		Created: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.created", map[string]string{"name": name})
		},
		Renamed: func(name string) string {
			return SharedFormat(Chinese, "desktop.branch.renamed", map[string]string{"name": name})
		},
		Deleted: func(name, target string) string {
			return SharedFormat(Chinese, "desktop.branch.deleted", map[string]string{"name": name, "target": target})
		},
		CheckoutFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.branch.checkoutFailed", map[string]string{"reason": reason})
		},
		CreateFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.branch.createFailed", map[string]string{"reason": reason})
		},
		RenameFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.branch.renameFailed", map[string]string{"reason": reason})
		},
		DeleteFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.branch.deleteFailed", map[string]string{"reason": reason})
		},
	},
	Terminal: TerminalMessages{
		Label:              Shared(Chinese, "desktop.terminal.label"),
		ScrollbarLabel:     Shared(Chinese, "desktop.terminal.scrollbarLabel"),
		SessionEnded:       Shared(Chinese, "desktop.terminal.sessionEnded"),
		SessionEndedStatus: func(status int) string { return terminalEndedStatus(Chinese, status) },
		RestartHint:        Shared(Chinese, "desktop.terminal.restartHint"),
		StartFailed:        func(reason string) string { return terminalStartFailed(Chinese, reason) },
		Tab:                func(n int) string { return terminalTab(Chinese, n) },
		NewTab:             Shared(Chinese, "terminal.newTerminal"),
		CloseTab:           Shared(Chinese, "terminal.contextClose"),
		NoTerminals:        Shared(Chinese, "desktop.terminal.noTerminals"),
		Find:               Shared(Chinese, "desktop.terminal.find"),
		FindNone:           Shared(Chinese, "desktop.terminal.findNone"),
		FindPrevious:       Shared(Chinese, "desktop.terminal.findPrevious"),
		FindNext:           Shared(Chinese, "desktop.terminal.findNext"),
		FindClose:          Shared(Chinese, "desktop.terminal.findClose"),
		FindCount: func(current, total string) string {
			return SharedFormat(Chinese, "desktop.terminal.findCount", map[string]string{"current": current, "total": total})
		},
		OpenLinkFailed: func(reason string) string {
			return SharedFormat(Chinese, "desktop.terminal.openLinkFailed", map[string]string{"reason": reason})
		},
		ShellMenu:       Shared(Chinese, "native.newTerminalWithShell"),
		DetectingShells: Shared(Chinese, "terminal.detectingShells"),
		NoShells:        Shared(Chinese, "native.shellNotFound"),
		ShellWithPath:   func(name, path string) string { return terminalShellWithPath(Chinese, name, path) },
		Settings:        Shared(Chinese, "menu.settings"),
	},

	Agent: agentMessages(Chinese),

	Status: StatusMessages{
		Path:           Shared(Chinese, "desktop.status.path"),
		Caret:          Shared(Chinese, "desktop.status.caret"),
		Writable:       Shared(Chinese, "desktop.status.writable"),
		ReadOnly:       Shared(Chinese, "desktop.status.readOnly"),
		LSPNotStarted:  Shared(Chinese, "desktop.status.lSPNotStarted"),
		Vim:            Shared(Chinese, "desktop.status.vim"),
		Encoding:       Shared(Chinese, "desktop.status.encoding"),
		Problems:       func(count int) string { return statusProblems(Chinese, count) },
		Memory:         Shared(Chinese, "desktop.status.memory"),
		MemoryValue:    func(megabytes int) string { return statusMemory(Chinese, megabytes) },
		FPS:            Shared(Chinese, "desktop.status.fPS"),
		FPSValue:       func(fps int) string { return statusFPS(Chinese, fps) },
		NoChanges:      Shared(Chinese, "desktop.status.noChanges"),
		Changes:        func(count int) string { return statusChanges(Chinese, count) },
		Healthy:        Shared(Chinese, "desktop.status.healthy"),
		Indent:         Shared(Chinese, "desktop.status.indent"),
		IndentSpaces:   func(count int) string { return statusIndentSpaces(Chinese, count) },
		IndentTab:      func(width int) string { return statusIndentTab(Chinese, width) },
		LineEnding:     Shared(Chinese, "desktop.status.lineEnding"),
		LineEndingLF:   Shared(Chinese, "desktop.status.lineEndingLF"),
		LineEndingCRLF: Shared(Chinese, "desktop.status.lineEndingCRLF"),
	},
	Settings: settingsMessages(Chinese),
	Logs: LogMessages{
		Logs:              Shared(Chinese, "desktop.logs.logs"),
		FilterPlaceholder: Shared(Chinese, "logs.window.filterServerJdtlsLevelWarnEventLspTraceReceivedRegexOpC0ffee"),
		FilterHelp:        Shared(Chinese, "logs.window.filterHelp"),
		FilterError: func(start, end int, reason string) string {
			return SharedFormat(Chinese, "logs.window.filterErrorAtLldLld", map[string]string{"start": strconv.Itoa(start), "end": strconv.Itoa(end), "reason": reason})
		},
		Filter: LogFilterMessages{
			EmptyValue:        Shared(Chinese, "logs.filter.emptyValue"),
			ExpressionTooLong: Shared(Chinese, "logs.filter.expressionTooLong"),
			InvalidEscape:     Shared(Chinese, "logs.filter.invalidEscape"),
			InvalidLevel:      Shared(Chinese, "logs.filter.invalidLevel"),
			InvalidOperator:   Shared(Chinese, "logs.filter.invalidOperator"),
			InvalidQuote:      Shared(Chinese, "logs.filter.invalidQuote"),
			InvalidRegex:      Shared(Chinese, "logs.filter.invalidRegex"),
			RegexTooLong:      Shared(Chinese, "logs.filter.regexTooLong"),
			UnterminatedQuote: Shared(Chinese, "logs.filter.unterminatedQuote"),
			UnterminatedRegex: Shared(Chinese, "logs.filter.unterminatedRegex"),
		},
		SessionCurrent:    Shared(Chinese, "logs.window.sessionCurrent"),
		SessionPrevious:   Shared(Chinese, "logs.window.sessionPrevious"),
		SessionAll:        Shared(Chinese, "logs.window.sessionAll"),
		TimeRange:         Shared(Chinese, "logs.window.timeRange"),
		StartTime:         Shared(Chinese, "logs.window.startTime"),
		EndTime:           Shared(Chinese, "logs.window.endTime"),
		ClearTimeRange:    Shared(Chinese, "logs.window.clearTimeRange"),
		ReversedTime:      Shared(Chinese, "logs.window.reversedTime"),
		InvalidTime:       Shared(Chinese, "desktop.logs.invalidTime"),
		TimeHelp:          Shared(Chinese, "logs.window.timeHelp"),
		SavedFilters:      Shared(Chinese, "logs.window.savedFilters"),
		NoSavedFilters:    Shared(Chinese, "logs.window.noSavedFilters"),
		SaveCurrentFilter: Shared(Chinese, "logs.window.saveCurrentFilter"),
		NameForFilter:     Shared(Chinese, "logs.window.nameForThisFilter"),
		Columns:           Shared(Chinese, "logs.window.columns"),
		Export:            Shared(Chinese, "logs.window.export"),
		ExportLabel:       Shared(Chinese, "logs.window.exportAccessibility"),
		CollapseRepeats:   Shared(Chinese, "logs.window.collapseRepeats"),
		AbsoluteTime:      Shared(Chinese, "logs.window.absoluteTime"),
		RelativePrevious:  Shared(Chinese, "logs.window.previous"),
		RelativeSelected:  Shared(Chinese, "logs.window.selected"),
		LiveFollow:        Shared(Chinese, "logs.window.liveFollow"),
		Paused:            Shared(Chinese, "desktop.logs.paused"),
		FollowHelp:        Shared(Chinese, "logs.window.followHelp"),
		ClearView:         Shared(Chinese, "logs.window.clearView"),
		ClearViewHelp:     Shared(Chinese, "logs.window.clearOnlyTheDisplayLogFilesAreKept"),
		Maintenance:       Shared(Chinese, "logs.window.maintenance"),
		RevealDirectory:   Shared(Chinese, "logs.window.revealDirectory"),
		ChangeDirectory:   Shared(Chinese, "logs.window.changeDirectory"),
		ChooseDirectory:   Shared(Chinese, "desktop.logs.chooseDirectory"),
		LogDirectory:      Shared(Chinese, "desktop.logs.logDirectory"),
		ClearSearch:       Shared(Chinese, "desktop.logs.clearSearch"),
		Choose:            Shared(Chinese, "desktop.logs.choose"),
		RestoreDirectory:  Shared(Chinese, "logs.window.restoreDirectory"),
		ClearStorage: func(size string) string {
			return SharedFormat(Chinese, "logs.window.clearStorage", map[string]string{"size": size})
		},
		ClearTitle:   Shared(Chinese, "desktop.logs.clearTitle"),
		ClearAction:  Shared(Chinese, "desktop.logs.clearAction"),
		ClearMessage: Shared(Chinese, "desktop.logs.clearMessage"),
		Cancel:       Shared(Chinese, "agent.state.cancel"),
		Save:         Shared(Chinese, "ui.save"),
		Apply:        Shared(Chinese, "desktop.logs.apply"),
		Delete:       Shared(Chinese, "ui.delete"),
		Retry:        Shared(Chinese, "git.log.retry"),
		LoadFailed:   Shared(Chinese, "logs.window.couldNotLoadLogsTryAgain"),
		ViewCleared:  Shared(Chinese, "logs.window.viewClearedFilesOnDiskAreUntouchedNewRecordsWillAppearHere"),
		NoMatches:    Shared(Chinese, "logs.window.noMatchesTryAnotherLevelOrChannel"),
		NewLogs: func(count int) string {
			return SharedFormat(Chinese, "desktop.logs.newLogs", map[string]string{"count": strconv.Itoa(count)})
		},
		EventsOverTime: Shared(Chinese, "logs.window.eventsOverTime"),
		HistogramHint:  Shared(Chinese, "logs.window.clickToJumpDragForTimeRange"),
		HistogramTooltip: func(time string, errors, warnings, other int) string {
			return SharedFormat(Chinese, "desktop.logs.histogramTooltip", map[string]string{"time": time, "errors": strconv.Itoa(errors), "warnings": strconv.Itoa(warnings), "other": strconv.Itoa(other)})
		},
		AllChannels:       Shared(Chinese, "logs.window.allChannels"),
		SelectSeveral:     Shared(Chinese, "logs.window.clickToSelectSeveral"),
		ChannelHelp:       Shared(Chinese, "logs.window.channelHelp"),
		UnreadErrors:      Shared(Chinese, "logs.window.unreadErrors"),
		Diagnostics:       Shared(Chinese, "desktop.logs.diagnostics"),
		DiagnosticsHelp:   Shared(Chinese, "logs.exportV2.diagnosticHint"),
		EnableDiagnostics: Shared(Chinese, "logs.window.enableDiagnostics"),
		DiagnosticsOn:     Shared(Chinese, "logs.window.verboseDiagnosticsOn"),
		Category: func(category string) string {
			return SharedFormat(Chinese, "logs.window.category", map[string]string{"category": category})
		},
		AutoOff: func(remaining string) string {
			return SharedFormat(Chinese, "logs.window.autoOffIn", map[string]string{"remaining": remaining})
		},
		StopDiagnostics: Shared(Chinese, "logs.window.disableDiagnostics"),
		Detail:          Shared(Chinese, "logs.window.detail"),
		CallChain:       Shared(Chinese, "logs.window.callChain"),
		TraceHelp:       Shared(Chinese, "logs.window.traceHelp"),
		CopyJSON:        Shared(Chinese, "logs.window.copyAsJSON"),
		CopyMarkdown:    Shared(Chinese, "logs.window.copyAsMarkdown"),
		FilterChannel:   Shared(Chinese, "logs.window.filterChannel"),
		TraceOperation:  Shared(Chinese, "logs.window.traceOperation"),
		RevealInFinder:  Shared(Chinese, "desktop.logs.revealInFinder"),
		ExportBundle:    Shared(Chinese, "logs.window.bundle"),
		RedactedNote:    Shared(Chinese, "logs.window.redactedValuesWereMaskedByCoreTheWindowAndExportsNeverShowTheOriginal"),
		SourceLine: func(line int) string {
			return SharedFormat(Chinese, "desktop.logs.sourceLine", map[string]string{"line": strconv.Itoa(line)})
		},
		NoOperation: Shared(Chinese, "logs.window.thisRecordHasNoOpId"),
		Operation: func(op string, count int, duration string) string {
			return SharedFormat(Chinese, "desktop.logs.operation", map[string]string{"op": op, "count": strconv.Itoa(count), "duration": duration})
		},
		Tailing:          Shared(Chinese, "logs.window.tailing"),
		PausedScrolledUp: Shared(Chinese, "logs.window.pausedScrolledUp"),
		VisibleCount: func(visible, total, line string) string {
			return SharedFormat(Chinese, "logs.window.visibleCount", map[string]string{"visible": visible, "total": total, "line": line})
		},
		Dropped: func(count int) string {
			return SharedFormat(Chinese, "desktop.logs.dropped", map[string]string{"count": strconv.Itoa(count)})
		},
		WriteFailures: func(count int) string {
			return SharedFormat(Chinese, "desktop.logs.writeFailures", map[string]string{"count": strconv.Itoa(count)})
		},
		Time:    Shared(Chinese, "logs.window.time"),
		Level:   Shared(Chinese, "logs.window.level"),
		Channel: Shared(Chinese, "logs.window.channel"),
		Event:   Shared(Chinese, "logs.window.event"),
		Message: Shared(Chinese, "logs.window.message"),
		Fields:  Shared(Chinese, "logs.window.fields"),
		Repeated: func(count int, last string) string {
			return SharedFormat(Chinese, "desktop.logs.repeated", map[string]string{"count": strconv.Itoa(count), "last": last})
		},
		CopyLine:              Shared(Chinese, "logs.window.copyLine"),
		CopySelectionMarkdown: Shared(Chinese, "logs.window.copySelectionAsMarkdown"),
		ShowOnlyEvent:         Shared(Chinese, "logs.window.showOnlyThisEvent"),
		HideEvent:             Shared(Chinese, "logs.window.hideThisEvent"),
		ShowOnlyChannel:       Shared(Chinese, "logs.window.showOnlyThisChannel"),
		TraceThisOperation:    Shared(Chinese, "logs.window.traceThisOperation"),
		CopyFieldValue:        Shared(Chinese, "logs.window.copyFieldValue"),
		ExportDialog: LogExportMessages{
			Subtitle:           Shared(Chinese, "logs.exportV2.subtitle"),
			Range:              Shared(Chinese, "logs.exportV2.range"),
			CurrentSession:     Shared(Chinese, "desktop.logs.exportDialog.currentSession"),
			RecentSessions:     Shared(Chinese, "logs.exportV2.recentSessions"),
			RecentSessionsHint: Shared(Chinese, "logs.exportV2.recentSessionsHint"),
			Last24Hours:        Shared(Chinese, "logs.exportV2.last24Hours"),
			Channels:           Shared(Chinese, "logs.exportV2.channels"),
			CurrentFilter:      Shared(Chinese, "logs.exportV2.currentFilter"),
			Privacy:            Shared(Chinese, "logs.exportV2.privacy"),
			RedactionNote:      Shared(Chinese, "logs.exportV2.redactionNote"),
			Environment:        Shared(Chinese, "logs.exportV2.environment"),
			EnvironmentHint: func(osName string) string {
				return SharedFormat(Chinese, "desktop.logs.environmentHint", map[string]string{"osName": osName})
			},
			Contents: Shared(Chinese, "logs.exportV2.contents"),
			Packing:  Shared(Chinese, "logs.exportV2.packing"),
			SavedTo: func(path string) string {
				return SharedFormat(Chinese, "desktop.logs.savedTo", map[string]string{"path": path})
			},
			Size: func(size string, count int) string {
				return SharedFormat(Chinese, "logs.exportV2.size", map[string]string{"size": size, "count": strconv.Itoa(count)})
			},
			Export:        Shared(Chinese, "desktop.logs.exportDialog.export"),
			PrepareFailed: Shared(Chinese, "logs.exportV2.prepareFailed"),
			ExportFailed:  Shared(Chinese, "logs.exportV2.exportFailed"),
		},
	},
	Errors:    errorMessages(Chinese),
	Build:     buildMessages(Chinese),
	Tests:     testMessages(Chinese),
	Debug:     debugMessages(Chinese),
	Run:       runMessages(Chinese),
	AI:        aiMessages(Chinese),
	MCP:       mcpMessages(Chinese),
	IDEAPI:    ideAPIMessages(Chinese),
	Sync:      syncMessages(Chinese),
	Worktrees: worktreeMessages(Chinese),
	Search:    searchMessages(Chinese),
	History:   historyMessages(Chinese),
	Keymap:    keymapMessages(Chinese),
	Updates:   updatesMessages(Chinese),
	Commands:  commandMessages(Chinese),
	Console:   consoleMessages(Chinese),
}
