package i18n

import "strconv"

var english = Messages{
	App:     appMessages(English),
	Welcome: welcomeMessages(English),
	Title:   titleMessages(English),
	Window:  windowMessages(English),
	Tools:   toolMessages(English),
	Dock:    dockMessages(English),
	Panel:   panelMessages(English),
	Editor:  editorMessages(English),
	Project: projectMessages(English),
	Git: GitMessages{
		Log:       Shared(English, "desktop.git.log"),
		Worktrees: Shared(English, "git.worktrees"),
		Console:   Shared(English, "git.console.title"),
		LogTab: func(reference string) string {
			return SharedFormat(English, "desktop.git.logTab", map[string]string{"reference": reference})
		},
		AllReferences:        Shared(English, "desktop.git.allReferences"),
		ShowAll:              Shared(English, "desktop.git.showAll"),
		Actions:              Shared(English, "desktop.git.actions"),
		FetchAll:             Shared(English, "desktop.git.fetchAll"),
		FetchOptions:         Shared(English, "desktop.git.fetchOptions"),
		UpdateBranch:         Shared(English, "desktop.git.updateBranch"),
		RefreshLog:           Shared(English, "desktop.git.refreshLog"),
		ShowChanges:          Shared(English, "desktop.git.showChanges"),
		Branches:             Shared(English, "git.branches"),
		HideBranches:         Shared(English, "desktop.git.hideBranches"),
		ShowBranches:         Shared(English, "desktop.git.showBranches"),
		NewBranch:            Shared(English, "git.log.toolbar.newBranch"),
		DeleteBranch:         Shared(English, "desktop.git.deleteBranch"),
		CompareWorkingTree:   Shared(English, "desktop.git.compareWorkingTree"),
		CompareWithCurrent:   Shared(English, "desktop.git.compareWithCurrent"),
		FindBranch:           Shared(English, "desktop.git.findBranch"),
		Fetch:                Shared(English, "git.contextMenu.fetch"),
		LocateBranch:         Shared(English, "desktop.git.locateBranch"),
		BranchSettings:       Shared(English, "desktop.git.branchSettings"),
		ExpandAll:            Shared(English, "desktop.git.expandAll"),
		CollapseAll:          Shared(English, "desktop.git.collapseAll"),
		BranchSearch:         Shared(English, "desktop.git.branchSearch"),
		HeadRow:              Shared(English, "git.log.headCurrentBranch"),
		LocalGroup:           Shared(English, "git.log.local"),
		RemoteGroup:          Shared(English, "git.log.remote"),
		TagGroup:             Shared(English, "git.log.tags"),
		NoMatchingReferences: Shared(English, "desktop.git.noMatchingReferences"),
		TextOrHash:           Shared(English, "desktop.git.textOrHash"),
		FilterBranch:         Shared(English, "git.log.filterBranch"),
		FilterUser:           Shared(English, "desktop.git.filterUser"),
		FilterDate:           Shared(English, "desktop.git.filterDate"),
		FilterPaths:          Shared(English, "desktop.git.filterPaths"),
		ClearFilter:          Shared(English, "desktop.git.clearFilter"),
		CompareBranch:        Shared(English, "desktop.git.compareBranch"),
		ShowDetails:          Shared(English, "desktop.git.showDetails"),
		Decorations:          Shared(English, "desktop.git.decorations"),
		FindInLog:            Shared(English, "desktop.git.findInLog"),
		LongEdges:            Shared(English, "desktop.git.longEdges"),
		PathTitle:            Shared(English, "desktop.git.pathTitle"),
		PathPlaceholder:      Shared(English, "desktop.git.pathPlaceholder"),
		Clear:                Shared(English, "desktop.git.clear"),
		Cancel:               Shared(English, "desktop.git.cancel"),
		Apply:                Shared(English, "desktop.git.apply"),
		SearchUsers:          Shared(English, "desktop.git.searchUsers"),
		NoMatchingUsers:      Shared(English, "desktop.git.noMatchingUsers"),
		AnyTime:              Shared(English, "desktop.git.anyTime"),
		Today:                Shared(English, "desktop.git.today"),
		Yesterday:            Shared(English, "desktop.git.yesterday"),
		Last7Days:            Shared(English, "desktop.git.last7Days"),
		Last30Days:           Shared(English, "desktop.git.last30Days"),
		OlderOutside:         Shared(English, "desktop.git.olderOutside"),
		FilterValue: func(filter, value string) string {
			return SharedFormat(English, "desktop.git.filterValue", map[string]string{"filter": filter, "value": value})
		},
		Loading:        Shared(English, "desktop.git.loading"),
		NotRepository:  Shared(English, "desktop.git.notRepository"),
		NoCommits:      Shared(English, "desktop.git.noCommits"),
		NoMatches:      Shared(English, "git.noMatchingCommits"),
		LoadMore:       Shared(English, "git.log.loadMore"),
		LoadingCommits: Shared(English, "git.log.loadingCommits"),
		LoadMoreFailed: Shared(English, "desktop.git.loadMoreFailed"),
		SelectCommit:   Shared(English, "git.log.selectCommit"),
		LoadingFiles:   Shared(English, "git.log.loadingChangedFiles"),
		FilesFailed:    Shared(English, "desktop.git.filesFailed"),
		Retry:          Shared(English, "git.log.retry"),
		NoChangedFiles: Shared(English, "git.log.noChangedFiles"),
		CommitDetails:  Shared(English, "git.log.commitDetails"),
		CompareChanges: Shared(English, "desktop.git.compareChanges"),
		FileHistory:    Shared(English, "desktop.git.fileHistory"),
		On: func(date string) string {
			return SharedFormat(English, "desktop.git.on", map[string]string{"date": date})
		},
		Failed: func(reason string) string {
			return SharedFormat(English, "desktop.git.failed", map[string]string{"reason": reason})
		},
	},
	Commit: CommitMessages{
		Refresh:    Shared(English, "desktop.commit.refresh"),
		StageAll:   Shared(English, "desktop.commit.stageAll"),
		UnstageAll: Shared(English, "git.unstageAllChanges"),
		ChangeList: Shared(English, "git.changelists.default"),
		Files:      func(count int) string { return commitFiles(English, count) },
		StageFile: func(path string) string {
			return SharedFormat(English, "desktop.commit.stageFile", map[string]string{"path": path})
		},
		UnstageFile: func(path string) string {
			return SharedFormat(English, "desktop.commit.unstageFile", map[string]string{"path": path})
		},
		StagedState:        Shared(English, "git.staged"),
		PartlyStagedState:  Shared(English, "desktop.commit.partlyStagedState"),
		UnstagedState:      Shared(English, "git.unstaged"),
		Clean:              Shared(English, "desktop.commit.clean"),
		Amend:              Shared(English, "git.amend"),
		Staged:             func(count int) string { return commitStaged(English, count) },
		MessageLabel:       Shared(English, "git.log.commitMessage"),
		MessagePlaceholder: Shared(English, "git.commitMessagePlaceholder"),
		Commit:             Shared(English, "git.commit"),
		CommitAndPush:      Shared(English, "desktop.commit.commitAndPush"),
		Committing:         Shared(English, "desktop.commit.committing"),
		Options:            Shared(English, "desktop.commit.options"),
		SignOff:            Shared(English, "desktop.commit.signOff"),
		SignOffHelp:        Shared(English, "desktop.commit.signOffHelp"),
		Author:             Shared(English, "desktop.commit.author"),
		AuthorPlaceholder:  Shared(English, "desktop.commit.authorPlaceholder"),
		AuthorHelp:         Shared(English, "desktop.commit.authorHelp"),
		AuthorInvalid:      Shared(English, "desktop.commit.authorInvalid"),
		Result: func(repository, status string) string {
			return SharedFormat(English, "desktop.commit.result", map[string]string{"repository": repository, "status": status})
		},
		Dismiss:         Shared(English, "desktop.commit.dismiss"),
		Retry:           Shared(English, "desktop.commit.retry"),
		ReviewTitle:     Shared(English, "desktop.commit.reviewTitle"),
		ReviewPushTitle: Shared(English, "desktop.commit.reviewPushTitle"),
		ReviewRetry:     Shared(English, "desktop.commit.reviewRetry"),
		Order:           Shared(English, "desktop.commit.order"),
		MessageLine: func(message string) string {
			return SharedFormat(English, "desktop.commit.messageLine", map[string]string{"message": message})
		},
		AmendNote: Shared(English, "desktop.commit.amendNote"),
		AuthorLine: func(author string) string {
			return SharedFormat(English, "desktop.commit.authorLine", map[string]string{"author": author})
		},
		SignOffNote:  Shared(English, "desktop.commit.signOffNote"),
		Step:         func(n int, action, repository string) string { return commitStep(English, n, action, repository) },
		StepCommit:   Shared(English, "git.commit"),
		StepPush:     Shared(English, "desktop.commit.stepPush"),
		StepPushOnly: Shared(English, "desktop.commit.stepPushOnly"),
		Where: func(branch, head string) string {
			return SharedFormat(English, "desktop.commit.where", map[string]string{"branch": branch, "head": head})
		},
		DetachedHead: Shared(English, "git.detachedHead"),
		NoCommits:    Shared(English, "desktop.commit.noCommits"),
		TracksDifferent: func(local, upstream string) string {
			return SharedFormat(English, "desktop.commit.tracksDifferent", map[string]string{"local": local, "upstream": upstream})
		},
		PublishTo: func(remote, branch string) string {
			return SharedFormat(English, "git.pushDialog.publishSameName", map[string]string{"remote": remote, "branch": branch})
		},
		PushTo: func(upstream string) string {
			return SharedFormat(English, "desktop.commit.pushTo", map[string]string{"upstream": upstream})
		},
		Continue:             Shared(English, "git.execution.continue"),
		Cancel:               Shared(English, "agent.state.cancel"),
		Pending:              Shared(English, "git.workspaceCommit.pending"),
		NotIncluded:          Shared(English, "git.workspaceCommit.notIncluded"),
		Committed:            Shared(English, "git.workspaceCommit.committed"),
		CommittedPushPending: Shared(English, "git.workspaceCommit.committedPushPending"),
		CommittedAndPushed:   Shared(English, "git.workspaceCommit.committedAndPushed"),
		CommitFailed:         Shared(English, "desktop.commit.commitFailed"),
		HeadAdvanced:         Shared(English, "git.workspaceCommit.headAdvanced"),
		OutcomeUnknown:       Shared(English, "git.workspaceCommit.outcomeUnknown"),
		PushFailed:           Shared(English, "git.workspaceCommit.pushFailed"),
		ReviewRequired:       Shared(English, "desktop.commit.reviewRequired"),
		WaitingForSubmodule:  Shared(English, "git.workspaceCommit.waitingForSubmodule"),
		EnterMessage:         Shared(English, "desktop.commit.enterMessage"),
		ChooseTarget:         Shared(English, "desktop.commit.chooseTarget"),
		PlanChanged:          Shared(English, "git.workspaceCommit.changed"),
		Done:                 Shared(English, "git.changesCommitted"),
		Pushed:               Shared(English, "git.changesPushed"),
		NeedsAttention:       Shared(English, "git.workspaceCommit.attention"),
		StageFailed: func(reason string) string {
			return SharedFormat(English, "desktop.commit.stageFailed", map[string]string{"reason": reason})
		},
		UnstageFailed: func(reason string) string {
			return SharedFormat(English, "desktop.commit.unstageFailed", map[string]string{"reason": reason})
		},
		Failed: func(reason string) string {
			return SharedFormat(English, "desktop.commit.failed", map[string]string{"reason": reason})
		},
	},
	Branch: BranchMessages{
		Popup:            Shared(English, "git.branches"),
		Search:           Shared(English, "desktop.branch.search"),
		NewBranch:        Shared(English, "git.contextMenu.newBranch"),
		CheckoutRevision: Shared(English, "desktop.branch.checkoutRevision"),
		Recent:           Shared(English, "desktop.branch.recent"),
		Local:            Shared(English, "git.log.local"),
		Remote:           Shared(English, "git.log.remote"),
		Tags:             Shared(English, "git.log.tags"),
		Loading:          Shared(English, "desktop.branch.loading"),
		NoMatches:        Shared(English, "git.noMatchingBranches"),
		LoadFailed: func(reason string) string {
			return SharedFormat(English, "desktop.branch.loadFailed", map[string]string{"reason": reason})
		},
		Current: Shared(English, "desktop.branch.current"),
		RowMenu: func(name string) string {
			return SharedFormat(English, "desktop.branch.rowMenu", map[string]string{"name": name})
		},
		NewBranchFrom: func(name string) string {
			return SharedFormat(English, "desktop.branch.newBranchFrom", map[string]string{"name": name})
		},
		Checkout:       Shared(English, "git.checkout"),
		Rename:         Shared(English, "desktop.branch.rename"),
		Delete:         Shared(English, "git.delete"),
		NewBranchTitle: Shared(English, "git.log.toolbar.newBranch"),
		CreateFrom: func(name string) string {
			return SharedFormat(English, "desktop.branch.createFrom", map[string]string{"name": name})
		},
		BranchName:    Shared(English, "desktop.branch.branchName"),
		CheckoutAfter: Shared(English, "desktop.branch.checkoutAfter"),
		Create:        Shared(English, "git.create"),
		RenameTitle:   Shared(English, "desktop.branch.renameTitle"),
		RenameFrom: func(name string) string {
			return SharedFormat(English, "desktop.branch.renameFrom", map[string]string{"name": name})
		},
		RenameButton: Shared(English, "desktop.branch.renameButton"),
		Cancel:       Shared(English, "agent.state.cancel"),
		NameEmpty:    Shared(English, "git.log.branchNameEmpty"),
		NameHead:     Shared(English, "git.log.branchNameHead"),
		NameRemote: func(name string) string {
			return SharedFormat(English, "git.log.branchNameClashesWithRemote", map[string]string{"name": name})
		},
		NameDirectory: func(name string) string {
			return SharedFormat(English, "git.log.branchNameClashesWithDirectory", map[string]string{"name": name})
		},
		NameExists: func(name string) string {
			return SharedFormat(English, "git.log.branchNameAlreadyExists", map[string]string{"name": name})
		},
		NamePrefix: func(name, branch string) string {
			return SharedFormat(English, "git.log.branchNameClashesWithBranchPrefix", map[string]string{"name": name, "branch": branch})
		},
		RevisionTitle:  Shared(English, "desktop.branch.revisionTitle"),
		RevisionPrompt: Shared(English, "desktop.branch.revisionPrompt"),
		Revision:       Shared(English, "desktop.branch.revision"),
		DetachedNote:   Shared(English, "desktop.branch.detachedNote"),
		ConflictTitle:  Shared(English, "desktop.branch.conflictTitle"),
		ConflictPrompt: func(name string) string {
			return SharedFormat(English, "desktop.branch.conflictPrompt", map[string]string{"name": name})
		},
		ConflictHint:  Shared(English, "desktop.branch.conflictHint"),
		SmartCheckout: Shared(English, "desktop.branch.smartCheckout"),
		ForceCheckout: Shared(English, "desktop.branch.forceCheckout"),
		DeleteTitle:   Shared(English, "desktop.branch.deleteTitle"),
		DeletePrompt: func(name string) string {
			return SharedFormat(English, "desktop.branch.deletePrompt", map[string]string{"name": name})
		},
		DeleteButton: Shared(English, "git.deleteBranch"),
		AlreadyOn: func(name string) string {
			return SharedFormat(English, "desktop.branch.alreadyOn", map[string]string{"name": name})
		},
		CheckedOut: func(name string) string {
			return SharedFormat(English, "desktop.branch.checkedOut", map[string]string{"name": name})
		},
		Detached: func(revision string) string {
			return SharedFormat(English, "desktop.branch.detached", map[string]string{"revision": revision})
		},
		Created: func(name string) string {
			return SharedFormat(English, "desktop.branch.created", map[string]string{"name": name})
		},
		Renamed: func(name string) string {
			return SharedFormat(English, "desktop.branch.renamed", map[string]string{"name": name})
		},
		Deleted: func(name, target string) string {
			return SharedFormat(English, "desktop.branch.deleted", map[string]string{"name": name, "target": target})
		},
		CheckoutFailed: func(reason string) string {
			return SharedFormat(English, "desktop.branch.checkoutFailed", map[string]string{"reason": reason})
		},
		CreateFailed: func(reason string) string {
			return SharedFormat(English, "desktop.branch.createFailed", map[string]string{"reason": reason})
		},
		RenameFailed: func(reason string) string {
			return SharedFormat(English, "desktop.branch.renameFailed", map[string]string{"reason": reason})
		},
		DeleteFailed: func(reason string) string {
			return SharedFormat(English, "desktop.branch.deleteFailed", map[string]string{"reason": reason})
		},
	},
	Terminal: TerminalMessages{
		Label:              Shared(English, "desktop.terminal.label"),
		ScrollbarLabel:     Shared(English, "desktop.terminal.scrollbarLabel"),
		SessionEnded:       Shared(English, "desktop.terminal.sessionEnded"),
		SessionEndedStatus: func(status int) string { return terminalEndedStatus(English, status) },
		RestartHint:        Shared(English, "desktop.terminal.restartHint"),
		StartFailed:        func(reason string) string { return terminalStartFailed(English, reason) },
		Tab:                func(n int) string { return terminalTab(English, n) },
		NewTab:             Shared(English, "terminal.newTerminal"),
		CloseTab:           Shared(English, "terminal.contextClose"),
		NoTerminals:        Shared(English, "desktop.terminal.noTerminals"),
		Find:               Shared(English, "desktop.terminal.find"),
		FindNone:           Shared(English, "desktop.terminal.findNone"),
		FindPrevious:       Shared(English, "desktop.terminal.findPrevious"),
		FindNext:           Shared(English, "desktop.terminal.findNext"),
		FindClose:          Shared(English, "desktop.terminal.findClose"),
		FindCount: func(current, total string) string {
			return SharedFormat(English, "desktop.terminal.findCount", map[string]string{"current": current, "total": total})
		},
		OpenLinkFailed: func(reason string) string {
			return SharedFormat(English, "desktop.terminal.openLinkFailed", map[string]string{"reason": reason})
		},
		ShellMenu:       Shared(English, "native.newTerminalWithShell"),
		DetectingShells: Shared(English, "terminal.detectingShells"),
		NoShells:        Shared(English, "native.shellNotFound"),
		ShellWithPath:   func(name, path string) string { return terminalShellWithPath(English, name, path) },
		Settings:        Shared(English, "menu.settings"),
	},

	Agent: agentMessages(English),

	Status: StatusMessages{
		Path:          Shared(English, "desktop.status.path"),
		Caret:         Shared(English, "desktop.status.caret"),
		Writable:      Shared(English, "desktop.status.writable"),
		ReadOnly:      Shared(English, "desktop.status.readOnly"),
		LSPNotStarted: Shared(English, "desktop.status.lSPNotStarted"),
		Vim:           Shared(English, "desktop.status.vim"),
		Encoding:      Shared(English, "desktop.status.encoding"),
		Problems:      func(count int) string { return statusProblems(English, count) },
		Memory:        Shared(English, "desktop.status.memory"),
		MemoryValue:   func(megabytes int) string { return statusMemory(English, megabytes) },
		FPS:           Shared(English, "desktop.status.fPS"),
		FPSValue:      func(fps int) string { return statusFPS(English, fps) },
		NoChanges:     Shared(English, "desktop.status.noChanges"),
		Changes:       func(count int) string { return statusChanges(English, count) },
		Healthy:       Shared(English, "desktop.status.healthy"),
	},
	Settings: settingsMessages(English),
	Logs: LogMessages{
		Logs:              Shared(English, "desktop.logs.logs"),
		FilterPlaceholder: Shared(English, "logs.window.filterServerJdtlsLevelWarnEventLspTraceReceivedRegexOpC0ffee"),
		FilterHelp:        Shared(English, "logs.window.filterHelp"),
		FilterError: func(start, end int, reason string) string {
			return SharedFormat(English, "logs.window.filterErrorAtLldLld", map[string]string{"start": strconv.Itoa(start), "end": strconv.Itoa(end), "reason": reason})
		},
		Filter: LogFilterMessages{
			EmptyValue:        Shared(English, "logs.filter.emptyValue"),
			ExpressionTooLong: Shared(English, "logs.filter.expressionTooLong"),
			InvalidEscape:     Shared(English, "logs.filter.invalidEscape"),
			InvalidLevel:      Shared(English, "logs.filter.invalidLevel"),
			InvalidOperator:   Shared(English, "logs.filter.invalidOperator"),
			InvalidQuote:      Shared(English, "logs.filter.invalidQuote"),
			InvalidRegex:      Shared(English, "logs.filter.invalidRegex"),
			RegexTooLong:      Shared(English, "logs.filter.regexTooLong"),
			UnterminatedQuote: Shared(English, "logs.filter.unterminatedQuote"),
			UnterminatedRegex: Shared(English, "logs.filter.unterminatedRegex"),
		},
		SessionCurrent:    Shared(English, "logs.window.sessionCurrent"),
		SessionPrevious:   Shared(English, "logs.window.sessionPrevious"),
		SessionAll:        Shared(English, "logs.window.sessionAll"),
		TimeRange:         Shared(English, "logs.window.timeRange"),
		StartTime:         Shared(English, "logs.window.startTime"),
		EndTime:           Shared(English, "logs.window.endTime"),
		ClearTimeRange:    Shared(English, "logs.window.clearTimeRange"),
		ReversedTime:      Shared(English, "logs.window.reversedTime"),
		InvalidTime:       Shared(English, "desktop.logs.invalidTime"),
		TimeHelp:          Shared(English, "logs.window.timeHelp"),
		SavedFilters:      Shared(English, "logs.window.savedFilters"),
		NoSavedFilters:    Shared(English, "logs.window.noSavedFilters"),
		SaveCurrentFilter: Shared(English, "logs.window.saveCurrentFilter"),
		NameForFilter:     Shared(English, "logs.window.nameForThisFilter"),
		Columns:           Shared(English, "logs.window.columns"),
		Export:            Shared(English, "logs.window.export"),
		ExportLabel:       Shared(English, "logs.window.exportAccessibility"),
		CollapseRepeats:   Shared(English, "logs.window.collapseRepeats"),
		AbsoluteTime:      Shared(English, "logs.window.absoluteTime"),
		RelativePrevious:  Shared(English, "logs.window.previous"),
		RelativeSelected:  Shared(English, "logs.window.selected"),
		LiveFollow:        Shared(English, "logs.window.liveFollow"),
		Paused:            Shared(English, "desktop.logs.paused"),
		FollowHelp:        Shared(English, "logs.window.followHelp"),
		ClearView:         Shared(English, "logs.window.clearView"),
		ClearViewHelp:     Shared(English, "logs.window.clearOnlyTheDisplayLogFilesAreKept"),
		Maintenance:       Shared(English, "logs.window.maintenance"),
		RevealDirectory:   Shared(English, "logs.window.revealDirectory"),
		ChangeDirectory:   Shared(English, "logs.window.changeDirectory"),
		ChooseDirectory:   Shared(English, "desktop.logs.chooseDirectory"),
		LogDirectory:      Shared(English, "desktop.logs.logDirectory"),
		ClearSearch:       Shared(English, "desktop.logs.clearSearch"),
		Choose:            Shared(English, "desktop.logs.choose"),
		RestoreDirectory:  Shared(English, "logs.window.restoreDirectory"),
		ClearStorage: func(size string) string {
			return SharedFormat(English, "logs.window.clearStorage", map[string]string{"size": size})
		},
		ClearTitle:   Shared(English, "desktop.logs.clearTitle"),
		ClearAction:  Shared(English, "desktop.logs.clearAction"),
		ClearMessage: Shared(English, "desktop.logs.clearMessage"),
		Cancel:       Shared(English, "agent.state.cancel"),
		Save:         Shared(English, "ui.save"),
		Apply:        Shared(English, "desktop.logs.apply"),
		Delete:       Shared(English, "ui.delete"),
		Retry:        Shared(English, "git.log.retry"),
		LoadFailed:   Shared(English, "logs.window.couldNotLoadLogsTryAgain"),
		ViewCleared:  Shared(English, "logs.window.viewClearedFilesOnDiskAreUntouchedNewRecordsWillAppearHere"),
		NoMatches:    Shared(English, "logs.window.noMatchesTryAnotherLevelOrChannel"),
		NewLogs: func(count int) string {
			return SharedFormat(English, "desktop.logs.newLogs", map[string]string{"count": strconv.Itoa(count)})
		},
		EventsOverTime: Shared(English, "logs.window.eventsOverTime"),
		HistogramHint:  Shared(English, "logs.window.clickToJumpDragForTimeRange"),
		HistogramTooltip: func(time string, errors, warnings, other int) string {
			return SharedFormat(English, "desktop.logs.histogramTooltip", map[string]string{"time": time, "errors": strconv.Itoa(errors), "warnings": strconv.Itoa(warnings), "other": strconv.Itoa(other)})
		},
		AllChannels:       Shared(English, "logs.window.allChannels"),
		SelectSeveral:     Shared(English, "logs.window.clickToSelectSeveral"),
		ChannelHelp:       Shared(English, "logs.window.channelHelp"),
		UnreadErrors:      Shared(English, "logs.window.unreadErrors"),
		Diagnostics:       Shared(English, "desktop.logs.diagnostics"),
		DiagnosticsHelp:   Shared(English, "logs.exportV2.diagnosticHint"),
		EnableDiagnostics: Shared(English, "logs.window.enableDiagnostics"),
		DiagnosticsOn:     Shared(English, "logs.window.verboseDiagnosticsOn"),
		Category: func(category string) string {
			return SharedFormat(English, "logs.window.category", map[string]string{"category": category})
		},
		AutoOff: func(remaining string) string {
			return SharedFormat(English, "logs.window.autoOffIn", map[string]string{"remaining": remaining})
		},
		StopDiagnostics: Shared(English, "logs.window.disableDiagnostics"),
		Detail:          Shared(English, "logs.window.detail"),
		CallChain:       Shared(English, "logs.window.callChain"),
		TraceHelp:       Shared(English, "logs.window.traceHelp"),
		CopyJSON:        Shared(English, "logs.window.copyAsJSON"),
		CopyMarkdown:    Shared(English, "logs.window.copyAsMarkdown"),
		FilterChannel:   Shared(English, "logs.window.filterChannel"),
		TraceOperation:  Shared(English, "logs.window.traceOperation"),
		RevealInFinder:  Shared(English, "desktop.logs.revealInFinder"),
		ExportBundle:    Shared(English, "logs.window.bundle"),
		RedactedNote:    Shared(English, "logs.window.redactedValuesWereMaskedByCoreTheWindowAndExportsNeverShowTheOriginal"),
		SourceLine: func(line int) string {
			return SharedFormat(English, "desktop.logs.sourceLine", map[string]string{"line": strconv.Itoa(line)})
		},
		NoOperation: Shared(English, "logs.window.thisRecordHasNoOpId"),
		Operation: func(op string, count int, duration string) string {
			return SharedFormat(English, "desktop.logs.operation", map[string]string{"op": op, "count": strconv.Itoa(count), "duration": duration})
		},
		Tailing:          Shared(English, "logs.window.tailing"),
		PausedScrolledUp: Shared(English, "logs.window.pausedScrolledUp"),
		VisibleCount: func(visible, total, line string) string {
			return SharedFormat(English, "logs.window.visibleCount", map[string]string{"visible": visible, "total": total, "line": line})
		},
		Dropped: func(count int) string {
			return SharedFormat(English, "desktop.logs.dropped", map[string]string{"count": strconv.Itoa(count)})
		},
		WriteFailures: func(count int) string {
			return SharedFormat(English, "desktop.logs.writeFailures", map[string]string{"count": strconv.Itoa(count)})
		},
		Time:    Shared(English, "logs.window.time"),
		Level:   Shared(English, "logs.window.level"),
		Channel: Shared(English, "logs.window.channel"),
		Event:   Shared(English, "logs.window.event"),
		Message: Shared(English, "logs.window.message"),
		Fields:  Shared(English, "logs.window.fields"),
		Repeated: func(count int, last string) string {
			return SharedFormat(English, "desktop.logs.repeated", map[string]string{"count": strconv.Itoa(count), "last": last})
		},
		CopyLine:              Shared(English, "logs.window.copyLine"),
		CopySelectionMarkdown: Shared(English, "logs.window.copySelectionAsMarkdown"),
		ShowOnlyEvent:         Shared(English, "logs.window.showOnlyThisEvent"),
		HideEvent:             Shared(English, "logs.window.hideThisEvent"),
		ShowOnlyChannel:       Shared(English, "logs.window.showOnlyThisChannel"),
		TraceThisOperation:    Shared(English, "logs.window.traceThisOperation"),
		CopyFieldValue:        Shared(English, "logs.window.copyFieldValue"),
		ExportDialog: LogExportMessages{
			Subtitle:           Shared(English, "logs.exportV2.subtitle"),
			Range:              Shared(English, "logs.exportV2.range"),
			CurrentSession:     Shared(English, "desktop.logs.exportDialog.currentSession"),
			RecentSessions:     Shared(English, "logs.exportV2.recentSessions"),
			RecentSessionsHint: Shared(English, "logs.exportV2.recentSessionsHint"),
			Last24Hours:        Shared(English, "logs.exportV2.last24Hours"),
			Channels:           Shared(English, "logs.exportV2.channels"),
			CurrentFilter:      Shared(English, "logs.exportV2.currentFilter"),
			Privacy:            Shared(English, "logs.exportV2.privacy"),
			RedactionNote:      Shared(English, "logs.exportV2.redactionNote"),
			Environment:        Shared(English, "logs.exportV2.environment"),
			EnvironmentHint: func(osName string) string {
				return SharedFormat(English, "desktop.logs.environmentHint", map[string]string{"osName": osName})
			},
			Contents: Shared(English, "logs.exportV2.contents"),
			Packing:  Shared(English, "logs.exportV2.packing"),
			SavedTo: func(path string) string {
				return SharedFormat(English, "desktop.logs.savedTo", map[string]string{"path": path})
			},
			Size: func(size string, count int) string {
				return SharedFormat(English, "logs.exportV2.size", map[string]string{"size": size, "count": strconv.Itoa(count)})
			},
			Export:        Shared(English, "desktop.logs.exportDialog.export"),
			PrepareFailed: Shared(English, "logs.exportV2.prepareFailed"),
			ExportFailed:  Shared(English, "logs.exportV2.exportFailed"),
		},
	},
	Errors:    errorMessages(English),
	Build:     buildMessages(English),
	Tests:     testMessages(English),
	Debug:     debugMessages(English),
	Run:       runMessages(English),
	AI:        aiMessages(English),
	MCP:       mcpMessages(English),
	IDEAPI:    ideAPIMessages(English),
	Sync:      syncMessages(English),
	Worktrees: worktreeMessages(English),
	Search:    searchMessages(English),
	History:   historyMessages(English),
	Keymap:    keymapMessages(English),
	Updates:   updatesMessages(English),
	Commands:  commandMessages(English),
	Console:   consoleMessages(English),
}
