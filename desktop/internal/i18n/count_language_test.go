package i18n

import (
	"regexp"
	"strings"
	"testing"
)

// These count-bearing English notices must read grammatically for 0, 1, and 2+
// items without introducing a second plural-selection rule in Go.
func TestCountNoticesUseNumberNeutralEnglish(t *testing.T) {
	tests := []struct {
		name, key string
		values    map[string]string
		want      string
	}{
		// Search
		{"one search match", "desktop.search.count", map[string]string{"count": "1", "files": "1"}, "Matches: 1 · Files: 1"},
		{"multiple search matches", "desktop.search.count", map[string]string{"count": "2", "files": "3"}, "Matches: 2 · Files: 3"},
		{"one loaded match", "desktop.search.loadedCount", map[string]string{"count": "1", "files": "1"}, "Loaded matches: 1 · Files: 1"},
		{"multiple loaded matches", "desktop.search.loadedCount", map[string]string{"count": "3", "files": "2"}, "Loaded matches: 3 · Files: 2"},
		{"one total occurrence", "desktop.search.totalCount", map[string]string{"count": "1", "files": "1"}, "Occurrences: 1 · Files: 1"},
		{"multiple total occurrences", "desktop.search.totalCount", map[string]string{"count": "5", "files": "2"}, "Occurrences: 5 · Files: 2"},
		{"one replace summary occurrence", "desktop.search.replaceSummary", map[string]string{"occurrences": "1", "files": "1"}, "Occurrences: 1 · Files: 1"},
		{"multiple replace summary occurrences", "desktop.search.replaceSummary", map[string]string{"occurrences": "4", "files": "2"}, "Occurrences: 4 · Files: 2"},
		{"replace done one file", "desktop.search.replaceDone", map[string]string{"files": "1"}, "Replaced · Files updated: 1"},
		{"replace done multiple files", "desktop.search.replaceDone", map[string]string{"files": "3"}, "Replaced · Files updated: 3"},
		{"replace skipped one file", "desktop.search.replaceSkipped", map[string]string{"changed": "1", "skipped": "1"}, "Replaced · Files updated: 1; unchanged (modified or not UTF-8): 1"},
		{"replace skipped multiple files", "desktop.search.replaceSkipped", map[string]string{"changed": "2", "skipped": "3"}, "Replaced · Files updated: 2; unchanged (modified or not UTF-8): 3"},
		{"replace partly failed one", "desktop.search.replacePartlyFailed", map[string]string{"changed": "1", "failed": "1", "reason": "read-only"}, "Replaced · Files updated: 1; failed (1): read-only"},
		{"replace partly failed multiple", "desktop.search.replacePartlyFailed", map[string]string{"changed": "0", "failed": "2", "reason": "conflict"}, "Replaced · Files updated: 0; failed (2): conflict"},

		// Editor & Semantics
		{"editor find replaced one", "desktop.editorFind.replaced", map[string]string{"count": "1"}, "Replaced occurrences: 1."},
		{"editor find replaced many", "desktop.editorFind.replaced", map[string]string{"count": "4"}, "Replaced occurrences: 4."},
		{"rename applied one file", "desktop.semantics.renameApplied", map[string]string{"count": "1"}, "Renamed · Files updated: 1."},
		{"rename applied many files", "desktop.semantics.renameApplied", map[string]string{"count": "3"}, "Renamed · Files updated: 3."},
		{"indent one space", "desktop.status.indentSpaces", map[string]string{"count": "1"}, "Spaces: 1"},
		{"indent four spaces", "desktop.status.indentSpaces", map[string]string{"count": "4"}, "Spaces: 4"},

		// Git, Console, Diff, History, Rebase, Worktrees & VCS
		{"git log limit one commit", "desktop.git.log.limitReached", map[string]string{"count": "1"}, "Commits read: 1; older commits are beyond the read limit"},
		{"git log limit many commits", "desktop.git.log.limitReached", map[string]string{"count": "200"}, "Commits read: 200; older commits are beyond the read limit"},
		{"git console one temporary setting", "desktop.git.console.expandConfiguration", map[string]string{"count": "1"}, "Show temporary settings (1)"},
		{"git console many temporary settings", "desktop.git.console.expandConfiguration", map[string]string{"count": "3"}, "Show temporary settings (3)"},
		{"git rebase one conflict", "desktop.rebase.conflicts", map[string]string{"count": "1"}, "Conflicted files: 1"},
		{"git rebase many conflicts", "desktop.rebase.conflicts", map[string]string{"count": "2"}, "Conflicted files: 2"},
		{"git console fold one line", "git.console.fold.lines", map[string]string{"count": "1"}, "Expand lines (1)"},
		{"git console fold many lines", "git.console.fold.lines", map[string]string{"count": "5"}, "Expand lines (5)"},
		{"git console one match", "git.console.matches", map[string]string{"count": "1"}, "Matches: 1"},
		{"git console many matches", "git.console.matches", map[string]string{"count": "7"}, "Matches: 7"},
		{"git console search limit one", "git.console.searchLimit", map[string]string{"count": "1"}, "First 1 shown"},
		{"git console search limit many", "git.console.searchLimit", map[string]string{"count": "200"}, "First 200 shown"},
		{"git diff zero differences", "git.diff.differences", map[string]string{"count": "0"}, "Differences: 0"},
		{"git diff one difference", "git.diff.differences", map[string]string{"count": "1"}, "Differences: 1"},
		{"git diff many differences", "git.diff.differences", map[string]string{"count": "2"}, "Differences: 2"},
		{"git history review one affected", "git.historyReview.affected", map[string]string{"count": "1"}, "Affected commits: 1 (oldest first)"},
		{"git history review many affected", "git.historyReview.affected", map[string]string{"count": "4"}, "Affected commits: 4 (oldest first)"},
		{"git history review squash one", "git.historyReview.squashCommits", map[string]string{"count": "1"}, "Combine selected commits into 1 (1). The message below includes every selected commit, from oldest to newest; later descendants receive new commit IDs."},
		{"git history review squash many", "git.historyReview.squashCommits", map[string]string{"count": "3"}, "Combine selected commits into 1 (3). The message below includes every selected commit, from oldest to newest; later descendants receive new commit IDs."},
		{"git branch rollback impossible one repo", "desktop.branch.rollbackImpossible", map[string]string{"repositories": "app"}, "Not on a branch before, so rollback is unavailable: app."},
		{"git branch rollback impossible many repos", "desktop.branch.rollbackImpossible", map[string]string{"repositories": "app, core"}, "Not on a branch before, so rollback is unavailable: app, core."},
		{"git sync diverged one commit", "desktop.sync.divergedPrompt", map[string]string{"name": "main", "upstream": "origin/main", "ahead": "1", "behind": "1"}, "main and origin/main have diverged (commits ahead: 1, behind: 1). Choose how to combine them."},
		{"git sync diverged many commits", "desktop.sync.divergedPrompt", map[string]string{"name": "main", "upstream": "origin/main", "ahead": "2", "behind": "3"}, "main and origin/main have diverged (commits ahead: 2, behind: 3). Choose how to combine them."},
		{"git rollback one path", "git.rollbackPathsConfirm", map[string]string{"count": "1"}, "Roll back changes in selected paths (1)? This cannot be undone."},
		{"git rollback many paths", "git.rollbackPathsConfirm", map[string]string{"count": "3"}, "Roll back changes in selected paths (3)? This cannot be undone."},
		{"git untracked directory one file", "git.untrackedDirectorySummary", map[string]string{"path": "tmp", "count": "1"}, "tmp — Untracked files: 1. Expand to list its contents."},
		{"git untracked directory many files", "git.untrackedDirectorySummary", map[string]string{"path": "tmp", "count": "9"}, "tmp — Untracked files: 9. Expand to list its contents."},
		{"git line history single line", "desktop.lineHistory.lines", map[string]string{"file": "main.go", "start": "5", "end": "5"}, "main.go, line range 5-5"},
		{"git line history multi line", "desktop.lineHistory.lines", map[string]string{"file": "main.go", "start": "5", "end": "12"}, "main.go, line range 5-12"},
		{"git line history inserted one", "desktop.lineHistory.inserted", map[string]string{"lines": "5"}, "Newly inserted (no history yet): 5."},
		{"git line history inserted many", "desktop.lineHistory.inserted", map[string]string{"lines": "5, 8"}, "Newly inserted (no history yet): 5, 8."},
		{"git line history rewritten one", "desktop.lineHistory.rewritten", map[string]string{"lines": "5"}, "Rewritten (history cannot be matched reliably): 5."},
		{"git line history rewritten many", "desktop.lineHistory.rewritten", map[string]string{"lines": "5, 8"}, "Rewritten (history cannot be matched reliably): 5, 8."},
		{"vcs zero files selected", "native.arg1FilesSelected", map[string]string{"arg1": "0"}, "Files selected: 0"},
		{"vcs one file selected", "native.arg1FilesSelected", map[string]string{"arg1": "1"}, "Files selected: 1"},
		{"vcs many files selected", "native.arg1FilesSelected", map[string]string{"arg1": "3"}, "Files selected: 3"},
		{"worktree one changed file", "native.lldChangedFiles", map[string]string{"arg1": "1"}, "Changed files: 1"},
		{"worktree many changed files", "native.lldChangedFiles", map[string]string{"arg1": "4"}, "Changed files: 4"},
		{"shelf one file", "native.lldFileS", map[string]string{"arg1": "1", "arg2": "today"}, "Files: 1 · today"},
		{"shelf many files", "native.lldFileS", map[string]string{"arg1": "3", "arg2": "today"}, "Files: 3 · today"},
		{"diff one unchanged line", "native.lldUnchangedLines", map[string]string{"arg1": "1"}, "Unchanged lines: 1"},
		{"diff many unchanged lines", "native.lldUnchangedLines", map[string]string{"arg1": "12"}, "Unchanged lines: 12"},
		{"worktree one stale record", "native.lldWorktreeRecordsNeedAttention", map[string]string{"arg1": "1"}, "Worktree records needing attention: 1"},
		{"worktree many stale records", "native.lldWorktreeRecordsNeedAttention", map[string]string{"arg1": "2"}, "Worktree records needing attention: 2"},

		// Logs
		{"logs one new log", "desktop.logs.newLogs", map[string]string{"count": "1"}, "↓ New logs (1), jump to latest"},
		{"logs many new logs", "desktop.logs.newLogs", map[string]string{"count": "5"}, "↓ New logs (5), jump to latest"},
		{"logs operation one record", "desktop.logs.operation", map[string]string{"op": "abc", "count": "1", "duration": "4 ms"}, "Op abc · Records: 1 · 4 ms"},
		{"logs operation many records", "desktop.logs.operation", map[string]string{"op": "abc", "count": "7", "duration": "12 ms"}, "Op abc · Records: 7 · 12 ms"},
		{"logs repeated once", "desktop.logs.repeated", map[string]string{"count": "1", "last": "12:00"}, "Repeat count: 1 · last 12:00"},
		{"logs repeated many", "desktop.logs.repeated", map[string]string{"count": "6", "last": "12:00"}, "Repeat count: 6 · last 12:00"},
		{"logs export one file", "logs.exportV2.size", map[string]string{"size": "12 KB", "count": "1"}, "≈ 12 KB · Files: 1"},
		{"logs export many files", "logs.exportV2.size", map[string]string{"size": "1.2 MB", "count": "4"}, "≈ 1.2 MB · Files: 4"},
		{"logs visible one row", "logs.window.visibleCount", map[string]string{"visible": "1", "total": "1", "line": "1"}, "Rows: 1 / 1 · line 1"},
		{"logs visible many rows", "logs.window.visibleCount", map[string]string{"visible": "10", "total": "25", "line": "3"}, "Rows: 10 / 25 · line 3"},

		// Remote
		{"remote one core", "desktop.remote.host.cores", map[string]string{"count": "1"}, "Cores: 1"},
		{"remote many cores", "desktop.remote.host.cores", map[string]string{"count": "8"}, "Cores: 8"},
		{"one failed forward", "desktop.remote.ports.restoreFailed", map[string]string{"count": "1"}, "Forwards not restored after reconnecting: 1. See the affected rows for details."},
		{"multiple failed forwards", "desktop.remote.ports.restoreFailed", map[string]string{"count": "2"}, "Forwards not restored after reconnecting: 2. See the affected rows for details."},
		{"remote port limit one", "desktop.remote.ports.limit", map[string]string{"maximum": "1"}, "Forwarding limit reached for this connection (1). Stop an active forward first."},
		{"remote port limit many", "desktop.remote.ports.limit", map[string]string{"maximum": "8"}, "Forwarding limit reached for this connection (8). Stop an active forward first."},
		{"remote close running", "desktop.remote.close.running", map[string]string{"connection": "devbox"}, "Still running on devbox:"},
		{"remote kept text one", "desktop.remote.kept.text", map[string]string{"connection": "devbox", "count": "1"}, "Programs kept running on devbox from a closed window (1):"},
		{"remote kept text many", "desktop.remote.kept.text", map[string]string{"connection": "devbox", "count": "3"}, "Programs kept running on devbox from a closed window (3):"},
		{"remote connected one window", "desktop.remote.connectedWindows", map[string]string{"count": "1"}, "Open windows: 1"},
		{"remote connected many windows", "desktop.remote.connectedWindows", map[string]string{"count": "2"}, "Open windows: 2"},
		{"remote import one host", "desktop.remote.import.count", map[string]string{"count": "1"}, "Hosts to import: 1"},
		{"remote import many hosts", "desktop.remote.import.count", map[string]string{"count": "4"}, "Hosts to import: 4"},
		{"remote import done one", "desktop.remote.import.done", map[string]string{"count": "1"}, "Hosts imported: 1"},
		{"remote import done many", "desktop.remote.import.done", map[string]string{"count": "3"}, "Hosts imported: 3"},
		{"remote import footer one", "desktop.remote.import.footer", map[string]string{"count": "1"}, "Hosts to import: 1"},
		{"remote import footer many", "desktop.remote.import.footer", map[string]string{"count": "3"}, "Hosts to import: 3"},
		{"remote import footer groups one", "desktop.remote.import.footerGroups", map[string]string{"count": "1", "groupCount": "1", "groups": "Prod"}, "Hosts to import: 1 · New groups: 1 (Prod)"},
		{"remote import footer groups many", "desktop.remote.import.footerGroups", map[string]string{"count": "3", "groupCount": "2", "groups": "Prod, Staging"}, "Hosts to import: 3 · New groups: 2 (Prod, Staging)"},
		{"remote import motty one", "desktop.remote.import.mottyFound", map[string]string{"hosts": "1", "groups": "1", "format": "v2"}, "Hosts found: 1 · Groups: 1 · data format v2"},
		{"remote import motty many", "desktop.remote.import.mottyFound", map[string]string{"hosts": "5", "groups": "2", "format": "v2"}, "Hosts found: 5 · Groups: 2 · data format v2"},

		// Plugins, Settings, Run & Process Lifecycle
		{"marketplace auto updated one plugin", "desktop.marketplace.autoUpdated", map[string]string{"count": "1"}, "Automatically updated plugins: 1. Restart Lithe to finish updating."},
		{"marketplace auto updated many plugins", "desktop.marketplace.autoUpdated", map[string]string{"count": "3"}, "Automatically updated plugins: 3. Restart Lithe to finish updating."},
		{"credentials import legacy one each", "desktop.credentials.importLegacyDone", map[string]string{"imported": "1", "kept": "1", "failed": "1"}, "Plugin credentials — imported: 1; kept existing: 1; unreadable: 1."},
		{"credentials import legacy zero failed", "desktop.credentials.importLegacyDone", map[string]string{"imported": "2", "kept": "0", "failed": "0"}, "Plugin credentials — imported: 2; kept existing: 0; unreadable: 0."},
		{"keymap import summary ones", "desktop.keymapImport.summary", map[string]string{"imported": "1", "skipped": "1", "conflicts": "1"}, "Actions to import: 1 · Rules skipped: 1 · Conflicts: 1"},
		{"keymap import summary mixed", "desktop.keymapImport.summary", map[string]string{"imported": "4", "skipped": "0", "conflicts": "2"}, "Actions to import: 4 · Rules skipped: 0 · Conflicts: 2"},
		{"source settings one entry", "desktop.sourceSettings.fileCount", map[string]string{"count": "1"}, "1 configured"},
		{"source settings many entries", "desktop.sourceSettings.fileCount", map[string]string{"count": "3"}, "3 configured"},
		{"settings unknown kept one", "desktop.settings.unknownKept", map[string]string{"count": "1", "keys": "alpha"}, "Settings file items not recognized by this version: 1 (alpha). Kept untouched so compatible versions still read what was saved."},
		{"settings unknown kept many", "desktop.settings.unknownKept", map[string]string{"count": "2", "keys": "alpha, beta"}, "Settings file items not recognized by this version: 2 (alpha, beta). Kept untouched so compatible versions still read what was saved."},
		{"network ignored one exclusion", "desktop.settings.network.ignoredExclusions", map[string]string{"entries": "bad"}, "Ignored exclusions (unsupported format): bad"},
		{"network ignored many exclusions", "desktop.settings.network.ignoredExclusions", map[string]string{"entries": "*, a..b"}, "Ignored exclusions (unsupported format): *, a..b"},
		{"legacy import one project", "desktop.legacyImport.recentCount", map[string]string{"count": "1"}, "Projects: 1"},
		{"legacy import many projects", "desktop.legacyImport.recentCount", map[string]string{"count": "4"}, "Projects: 4"},
		{"title hidden one run configuration", "desktop.title.hiddenRunConfigurations", map[string]string{"count": "1"}, "Saved configurations hidden (not runnable): 1"},
		{"title hidden many run configurations", "desktop.title.hiddenRunConfigurations", map[string]string{"count": "3"}, "Saved configurations hidden (not runnable): 3"},
		{"debug port timeout one second", "desktop.build.debugPortTimeout", map[string]string{"seconds": "1"}, "The run did not wait for a debugger within the 1 s timeout, so it was stopped. See the Run window for its output."},
		{"debug port timeout many seconds", "desktop.build.debugPortTimeout", map[string]string{"seconds": "15"}, "The run did not wait for a debugger within the 15 s timeout, so it was stopped. See the Run window for its output."},
		{"command install timeout one second", "desktop.plugins.commandInstallTimedOut", map[string]string{"seconds": "1"}, "The installation did not finish within the 1 s timeout and was stopped."},
		{"command install timeout many seconds", "desktop.plugins.commandInstallTimedOut", map[string]string{"seconds": "300"}, "The installation did not finish within the 300 s timeout and was stopped."},
		{"startup sweep one process", "desktop.startupSweep.body", map[string]string{"arg1": "1"}, "Processes still running from an earlier Lithe session: 1. Choosing End stops what is listed below."},
		{"startup sweep many processes", "desktop.startupSweep.body", map[string]string{"arg1": "2"}, "Processes still running from an earlier Lithe session: 2. Choosing End stops what is listed below."},
		{"exit body one process", "desktop.exit.body", map[string]string{"processes": "• Run “app”"}, "Programs started by Lithe (stopped on close):\n• Run “app”"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := SharedFormat(English, test.key, test.values); got != test.want {
				t.Fatalf("format %s: got %q, want %q", test.key, got, test.want)
			}
		})
	}
}

func TestNumberNeutralEnglishKeepsExistingChineseTranslations(t *testing.T) {
	for _, tc := range []struct {
		key    string
		values map[string]string
		want   string
	}{
		{"desktop.search.count", map[string]string{"count": "1", "files": "1"}, "1 个文件中有 1 行匹配"},
		{"desktop.search.loadedCount", map[string]string{"count": "1", "files": "1"}, "已加载 1 个文件的 1 行匹配"},
		{"desktop.search.totalCount", map[string]string{"count": "1", "files": "1"}, "1 个文件中有 1 处匹配"},
		{"desktop.search.replaceSummary", map[string]string{"occurrences": "1", "files": "1"}, "1 个文件中的 1 处"},
		{"desktop.search.replaceDone", map[string]string{"files": "1"}, "已在 1 个文件中替换"},
		{"desktop.search.replaceSkipped", map[string]string{"changed": "1", "skipped": "1"}, "已在 1 个文件中替换；1 个文件已变化或不是 UTF-8，未修改"},
		{"desktop.search.replacePartlyFailed", map[string]string{"changed": "1", "failed": "1", "reason": "错误"}, "已在 1 个文件中替换；1 个失败：错误"},
		{"desktop.editorFind.replaced", map[string]string{"count": "1"}, "已替换 1 处。"},
		{"desktop.semantics.renameApplied", map[string]string{"count": "1"}, "已在 1 个文件中重命名。"},
		{"desktop.status.indentSpaces", map[string]string{"count": "1"}, "1 个空格"},
		{"desktop.git.log.limitReached", map[string]string{"count": "1"}, "已读取 1 条提交，更早的提交超出可读取范围"},
		{"desktop.git.console.expandConfiguration", map[string]string{"count": "1"}, "显示 1 项临时配置"},
		{"desktop.rebase.conflicts", map[string]string{"count": "1"}, "1 个冲突文件"},
		{"git.console.fold.lines", map[string]string{"count": "1"}, "展开中间 1 行"},
		{"git.console.matches", map[string]string{"count": "1"}, "1 处匹配"},
		{"git.console.searchLimit", map[string]string{"count": "1"}, "前 1 个位置"},
		{"git.diff.differences", map[string]string{"count": "1"}, "1 处差异"},
		{"git.historyReview.affected", map[string]string{"count": "1"}, "受影响历史：1 个提交（从旧到新）"},
		{"git.historyReview.squashCommits", map[string]string{"count": "1"}, "将 1 个提交压缩为 1 个。下方消息已按从旧到新的顺序包含所有选中提交；后续提交也将获得新的提交 ID。"},
		{"desktop.branch.rollbackImpossible", map[string]string{"repositories": "app"}, "app 在操作前不在任何分支上，无法回滚。"},
		{"desktop.sync.divergedPrompt", map[string]string{"name": "main", "upstream": "origin/main", "ahead": "1", "behind": "1"}, "“main”与“origin/main”已分叉：领先 1 个提交，落后 1 个。请选择合并方式。"},
		{"git.rollbackPathsConfirm", map[string]string{"count": "1"}, "确定回滚选中的 1 个路径吗？此操作无法撤销。"},
		{"git.untrackedDirectorySummary", map[string]string{"path": "tmp", "count": "1"}, "tmp — 1 个未跟踪文件，展开可查看内容。"},
		{"desktop.lineHistory.lines", map[string]string{"file": "main.go", "start": "5", "end": "5"}, "main.go，第 5-5 行"},
		{"desktop.lineHistory.inserted", map[string]string{"lines": "5"}, "第 5 行是新插入的，尚无提交历史。"},
		{"desktop.lineHistory.rewritten", map[string]string{"lines": "5"}, "第 5 行被改写，无法可靠对应提交历史。"},
		{"native.arg1FilesSelected", map[string]string{"arg1": "1"}, "已选择 1 个文件"},
		{"native.lldChangedFiles", map[string]string{"arg1": "1"}, "1 个文件有更改"},
		{"native.lldFileS", map[string]string{"arg1": "1", "arg2": "今天"}, "1 个文件 · 今天"},
		{"native.lldUnchangedLines", map[string]string{"arg1": "1"}, "1 行未更改"},
		{"native.lldWorktreeRecordsNeedAttention", map[string]string{"arg1": "1"}, "1 个工作树需要修复"},
		{"desktop.logs.newLogs", map[string]string{"count": "1"}, "↓ 1 条新日志，回到最新"},
		{"desktop.logs.operation", map[string]string{"op": "abc", "count": "1", "duration": "4 毫秒"}, "操作 abc · 1 条 · 共 4 毫秒"},
		{"desktop.logs.repeated", map[string]string{"count": "1", "last": "12:00"}, "重复 1 次 · 末次 12:00"},
		{"logs.exportV2.size", map[string]string{"size": "12 KB", "count": "1"}, "约 12 KB · 1 个文件"},
		{"logs.window.visibleCount", map[string]string{"visible": "1", "total": "1", "line": "1"}, "1 / 1 条 · 第 1 行"},
		{"desktop.remote.host.cores", map[string]string{"count": "1"}, "1 核"},
		{"desktop.remote.ports.restoreFailed", map[string]string{"count": "1"}, "重新连接后有 1 个转发无法恢复，原因见对应行。"},
		{"desktop.remote.ports.limit", map[string]string{"maximum": "1"}, "此连接已转发 1 个端口，达到上限，请先停止一个。"},
		{"desktop.remote.close.running", map[string]string{"connection": "devbox"}, "以下进程仍在 devbox 上运行："},
		{"desktop.remote.kept.text", map[string]string{"connection": "devbox", "count": "1"}, "上次关闭时保留在 devbox 上的 1 个进程仍在运行："},
		{"desktop.remote.connectedWindows", map[string]string{"count": "1"}, "1 个窗口已打开"},
		{"desktop.remote.import.count", map[string]string{"count": "1"}, "可导入 1 台主机"},
		{"desktop.remote.import.done", map[string]string{"count": "1"}, "已导入 1 台主机"},
		{"desktop.remote.import.footer", map[string]string{"count": "1"}, "将导入 1 个连接"},
		{"desktop.remote.import.footerGroups", map[string]string{"count": "1", "groupCount": "1", "groups": "Prod"}, "将导入 1 个连接、新建 1 个分组（Prod）"},
		{"desktop.remote.import.mottyFound", map[string]string{"hosts": "1", "groups": "1", "format": "v2"}, "找到 1 台主机、1 个分组 · 数据格式 v2"},
		{"desktop.marketplace.autoUpdated", map[string]string{"count": "1"}, "已自动更新 1 个插件。重启 Lithe 后生效。"},
		{"desktop.credentials.importLegacyDone", map[string]string{"imported": "1", "kept": "1", "failed": "1"}, "已导入 1 项插件凭据；保留 1 项已有凭据；1 项无法读取。"},
		{"desktop.keymapImport.summary", map[string]string{"imported": "1", "skipped": "1", "conflicts": "1"}, "可导入 1 项操作 · 跳过 1 条规则 · 1 处冲突"},
		{"desktop.sourceSettings.fileCount", map[string]string{"count": "1"}, "1 项"},
		{"desktop.settings.unknownKept", map[string]string{"count": "1", "keys": "alpha"}, "设置文件中有 1 项此版本无法识别的设置（alpha）。此版本不会使用它们，但会原样保留，换回能识别它们的版本时仍然有效。"},
		{"desktop.settings.network.ignoredExclusions", map[string]string{"entries": "bad"}, "以下排除项不是支持的格式，已忽略：bad"},
		{"desktop.legacyImport.recentCount", map[string]string{"count": "1"}, "1 个项目"},
		{"desktop.title.hiddenRunConfigurations", map[string]string{"count": "1"}, "已隐藏 1 条无法运行的已保存配置"},
		{"desktop.build.debugPortTimeout", map[string]string{"seconds": "1"}, "运行在 1 秒内没有等待调试器连接，已停止。输出见运行窗口。"},
		{"desktop.plugins.commandInstallTimedOut", map[string]string{"seconds": "1"}, "安装超过 1 秒仍未完成，已停止。"},
		{"desktop.startupSweep.body", map[string]string{"arg1": "1"}, "上次运行 Lithe 启动的 1 个进程仍在运行。结束它们会停止这些进程。"},
		{"desktop.exit.body", map[string]string{"processes": "• 运行“app”"}, "关闭后将结束下列由 Lithe 启动的程序：\n• 运行“app”"},
	} {
		if got := SharedFormat(Chinese, tc.key, tc.values); got != tc.want {
			t.Fatalf("Chinese %s: got %q, want %q", tc.key, got, tc.want)
		}
	}
}

// TestDesktopSharedCatalogHasNoUnguardedCountPluralMismatches guards the entire
// desktop en-US shared catalog against introducing unguarded "{count} <plural>"
// or "word(s)" templates when a count can be 1.
func TestDesktopSharedCatalogHasNoUnguardedCountPluralMismatches(t *testing.T) {
	// Keys that already have an explicit Go singular branch (n == 1) or are only
	// called when count > 1 (or use fixed plural values such as byte-width choices).
	guardedOrMultiOnly := map[string]bool{
		"desktop.branch.deleteManyFailed":                    true, // len(results) > 1
		"desktop.branch.deleteManyTitle":                     true, // len(b.deleting) > 1
		"desktop.branch.deletedMany":                         true, // len(results) > 1
		"desktop.buildSettings.debuggerCount":                true, // build_style.go: n == 1 -> debuggerCountOne
		"desktop.buildSettings.directoryDebuggers":           true, // build_style.go: n == 1 -> directoryDebuggersOne
		"desktop.buildSettings.directoryDebuggersCustomized": true, // build_style.go: n == 1 -> directoryDebuggersOneCustomized
		"desktop.buildSettings.directoryToolchains":          true, // build_style.go: tools==1 / plugins==1 branches
		"desktop.buildSettings.directoryToolchainsOnePlugin": true, // build_style.go: tools != 1
		"desktop.buildSettings.directoryToolchainsOneTool":   true, // build_style.go: plugins != 1
		"desktop.buildSettings.kindPageCount":                true, // build_style.go: n == 1 -> kindPageCountOne
		"desktop.buildSettings.listCount":                    true, // build_style.go: total == 1 -> listCountOne
		"desktop.buildSettings.trustBanner":                  true, // build_style.go: n == 1 -> trustBannerOne
		"desktop.debug.memoryRowBytes":                       true, // fixed choices: 8, 16, 32, 64 bytes
		"desktop.files.batchDelete":                          true, // len(nodes) > 1
		"desktop.files.batchDeletePrompt":                    true, // len(r.paths) > 1
		"desktop.git.console.queryOutput":                    true, // console_messages.go: n == 1 -> queryOutputOne
		"desktop.git.repo.several":                           true, // walksSeveral() -> len > 1
		"desktop.memory.processCount":                        true, // line.processes > 1
		"desktop.notifications.meta":                         true, // entry.count > 1
		"desktop.references.resultCount":                     true, // references_view.go: n == 1 -> resultCountOne
		"desktop.references.usageCount":                      true, // references_view.go: n == 1 -> usageCountOne
		"desktop.status.problems":                            true, // runtime_messages.go: count == 1 -> oneProblem
		"footer.changes":                                     true, // runtime_messages.go: count == 1 -> footer.change
		"git.conflictedFiles":                                true, // git_history_view.go: conflicts == 1 -> git.conflictedFile
		"git.log.filesCount":                                 true, // runtime_messages.go: count == 1 -> fileCountOne; difftab_view > 1
		"git.worktreesCount":                                 true, // worktree_messages.go: count == 1 -> git.worktreeCount
	}

	parenthesizedPlural := regexp.MustCompile(`[A-Za-z]\(s\)`)
	paramPlural := regexp.MustCompile(`\{[a-zA-Z0-9_]+\}[ \t]+([a-zA-Z]+)`)
	nonPluralSuffixWords := map[string]bool{
		"s": true, "ms": true, "is": true, "as": true, "was": true, "has": true,
		"does": true, "this": true, "its": true, "actions": true, "options": true,
		"requires": true, "wants": true, "installs": true, "listens": true,
		"shares": true, "conflicts": true, "holds": true, "starts": true, "tracks": true,
	}

	for key, text := range sharedCatalogs["en-US"] {
		if parenthesizedPlural.MatchString(text) {
			t.Errorf("%s contains (s) workaround %q; use count-neutral wording", key, text)
		}
		if guardedOrMultiOnly[key] {
			continue
		}
		for _, match := range paramPlural.FindAllStringSubmatch(text, -1) {
			word := strings.ToLower(match[1])
			if strings.HasSuffix(word, "s") && !nonPluralSuffixWords[word] {
				t.Errorf("%s has unguarded plural %q in %q", key, match[0], text)
			}
		}
	}
}

func TestSingularBranchedCatalogHelpersKeepSingularForOne(t *testing.T) {
	en := For(English)
	if got := en.Status.Problems(1); got != "1 problem" {
		t.Fatalf("Status.Problems(1) = %q, want %q", got, "1 problem")
	}
	if got := en.Status.Problems(2); got != "2 problems" {
		t.Fatalf("Status.Problems(2) = %q, want %q", got, "2 problems")
	}
	if got := en.Console.QueryOutput(1); got != "Read output, 1 line" {
		t.Fatalf("Console.QueryOutput(1) = %q, want %q", got, "Read output, 1 line")
	}
	if got := en.Console.QueryOutput(2); got != "Read output, 2 lines" {
		t.Fatalf("Console.QueryOutput(2) = %q, want %q", got, "Read output, 2 lines")
	}
	if got := en.Worktrees.Count(1); got != "1 worktree" {
		t.Fatalf("Worktrees.Count(1) = %q, want %q", got, "1 worktree")
	}
	if got := en.Worktrees.Count(2); got != "2 worktrees" {
		t.Fatalf("Worktrees.Count(2) = %q, want %q", got, "2 worktrees")
	}
}
