import AppKit
import Foundation
import LitheGitModule
import Testing
@testable import Lithe

@Suite("App localization")
@MainActor
struct AppLocalizationTests {
    @Test
    func languageDefaultsToEnglishAndPersistsChanges() {
        let store = LocalizationTestKeyValueStore()
        let settings = AppSettings(store: store)

        #expect(settings.language == .english)
        #expect(settings.language.locale.identifier == "en")

        settings.language = .simplifiedChinese
        let reloadedSettings = AppSettings(store: store)

        #expect(reloadedSettings.language == .simplifiedChinese)
        #expect(reloadedSettings.language.locale.identifier == "zh-Hans")

        reloadedSettings.restoreDefaults()
        #expect(AppSettings(store: store).language == .english)
    }

    @Test
    func simplifiedChineseResourcesCoverSettingsLanguageControls() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Settings"] == "设置")
        #expect(translations["General"] == "通用")
        #expect(translations["Language"] == "语言")
        #expect(translations["English"] == "英文")
        #expect(
            translations["The interface language changes immediately. English is the default."]
                == "界面语言会立即生效。默认语言为英文。"
        )
    }

    @Test
    func simplifiedChineseResourcesCoverWorkbenchBackgroundSettings() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Workbench background"] == "工作台背景")
        #expect(translations["No background image selected"] == "未选择背景图片")
        #expect(translations["Choose Image…"] == "选择图片…")
        #expect(translations["Workbench background opacity"] == "工作台不透明度")
    }

    @Test
    func simplifiedChineseResourcesCoverLogDirectorySettings() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Logs"] == "日志")
        #expect(translations["Log directory"] == "日志目录")
        #expect(translations["Default directory"] == "默认目录")
        #expect(translations["Selected directory"] == "当前选择的目录")
        #expect(translations["Choose Directory"] == "选择目录")
        #expect(translations["Choose Log Directory"] == "选择日志目录")
        #expect(translations["Restore Default"] == "恢复默认")
    }

    @Test
    func simplifiedChineseResourcesCoverUpdateFailures() throws {
        let translations = try simplifiedChineseTranslations()
        let requiredKeys = [
            "GitHub rejected the update request because a shared API limit was reached. Open the Release page or try again after the limit resets.",
            "The update server returned HTTP %@. Open the Release page to download the update manually, or try again later.",
            "The update request timed out. Check your proxy or VPN connection and try again.",
            "A secure connection to GitHub could not be established. Check TLS inspection, proxy, VPN, or system certificate settings.",
            "GitHub could not be reached. Check your internet, proxy, or VPN connection and try again.",
            "The update server returned an unexpected response. Open the Release page and download the update manually.",
            "The published update manifest is invalid and cannot be trusted. Open the Release page and download the update manually.",
            "This version of Lithe cannot read update manifest schema %@. Open the Release page and update manually.",
            "No update package is available for this Mac architecture. Open the Release page to check available downloads.",
            "The downloaded update failed its SHA-256 verification. Do not install it; retry or use the Release page.",
            "The update package could not be downloaded. Check your internet, proxy, or VPN connection and try again.",
            "Self-update is only available when Lithe is running from a packaged Lithe.app.",
            "The downloaded disk image does not contain Lithe.app.",
            "macOS could not prepare the update disk image. Open the Release page and install it manually.",
            "There is no published GitHub Release to check yet."
        ]

        for key in requiredKeys {
            #expect(translations[key] != nil, "Missing update translation: \(key)")
        }
    }

    @Test
    func simplifiedChineseResourcesCoverGitHubPullRequests() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Pull Requests"] == "拉取请求")
        #expect(translations["Sign in to GitHub"] == "登录 GitHub")
        #expect(translations["Authorize in your browser"] == "在浏览器中授权")
        #expect(translations["Select a pull request"] == "选择一个拉取请求")
        #expect(translations["Request changes"] == "请求修改")
        #expect(translations["Create Pull Request"] == "创建拉取请求")
        #expect(translations["Comparing changes"] == "比较更改")
        #expect(translations["Ready to create"] == "可以创建拉取请求")
        #expect(translations["Select branch"] == "选择分支")
        #expect(translations["Search branches"] == "搜索分支")
        #expect(translations["Generate with AI"] == "AI 生成")
        #expect(translations["Pull request description generation"] == "拉取请求描述生成")
        #expect(translations["Custom template"] == "自定义模板")
        #expect(translations["Publish this worktree"] == "发布当前工作树")
        #expect(translations["Publish Branch"] == "发布分支")
        #expect(
            translations["Uncommitted changes stay in this worktree and are not included in the pull request."]
                == "未提交的更改会保留在当前工作树中，不会包含在拉取请求里。"
        )
        #expect(
            translations["The selected branch diff is sent to the active AI provider when you generate."]
                == "生成时，所选分支的差异内容会发送给当前 AI 服务商。"
        )
    }

    @Test
    func simplifiedChineseResourcesCoverGitWorktreeWorkbench() throws {
        let translations = try simplifiedChineseTranslations()
        let expected = [
            "Worktrees": "工作树",
            "New Worktree": "新建工作树",
            "Commit History": "提交历史",
            "Repair Worktree Records": "修复工作树记录",
            "Prune Stale Records": "清理陈旧记录",
            "No local changes": "没有本地更改",
            "Worktree Settings": "工作树设置",
            "Danger Zone": "危险操作",
            "Checkout Path Missing": "检出路径不存在"
            ,"Recommended: keep worktrees in a persistent folder next to the repository. You can choose /private/tmp manually for disposable checkouts.": "建议将工作树放在仓库旁的持久目录中。临时检出时可以手动选择 /private/tmp。"
        ]

        for (key, value) in expected {
            #expect(translations[key] == value, "Missing or incorrect worktree translation: \(key)")
        }
    }

    @Test
    func simplifiedChineseResourcesCoverGitHistoryPagination() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Load more commits"] == "加载更多提交")
        #expect(translations["Loading commits…"] == "正在加载提交…")
        #expect(translations["Older commits are outside the loaded history"] == "更早的提交不在当前加载的历史范围内")
        #expect(translations["Copy Commit Hash"] == "复制提交哈希")
        #expect(translations["Copy Short Hash"] == "复制短哈希")
        #expect(translations["New Tag…"] == "新建标签…")
        #expect(translations["Cherry-pick Commit…"] == "拣选提交…")
        #expect(translations["Revert Commit…"] == "反向提交（保留历史）…")
        #expect(translations["Reset Current Branch to Here…"] == "将当前分支重置到这里…")
        #expect(translations["Undo Commit…"] == "撤销最近一次提交（保留更改）…")
        #expect(translations["Edit Commit Message…"] == "编辑提交消息…")
        #expect(translations["Squash Commits…"] == "合并所选提交…")
        #expect(translations["Drop Commit…"] == "从历史中移除提交…")
        #expect(translations["Interactively Rebase from Here…"] == "从此处交互式变基…")
        #expect(translations["Create Patch Between Commits…"] == "导出两次提交间的补丁…")

        // Dynamic dialog labels must resolve through the same language resources as the menu.
        for operation in GitHistoryRewriteOperation.allCases {
            #expect(translations[operation.menuTitle.replacingOccurrences(of: "…", with: "")] != nil)
            #expect(translations[operation.actionTitle] != nil)
        }
    }

    @Test
    func simplifiedChineseResourcesCoverKeymapControls() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Keymap"] == "快捷键")
        #expect(translations["Search actions or shortcuts"] == "搜索操作或快捷键")
        #expect(translations["Restore All Defaults"] == "全部恢复默认")
        #expect(translations["Not Assigned"] == "未分配")
        #expect(translations["Press shortcut…"] == "请按下快捷键…")
        #expect(
            translations["Shortcut needs Command, Control, or Option"]
                == "快捷键需要包含 Command、Control 或 Option"
        )
        #expect(translations["Conflicts with %@"] == "与 %@ 冲突")
        #expect(translations["No matching commands"] == "没有匹配的命令")
        for command in LitheCommandCatalog.commands {
            #expect(translations[command.title] != nil, "Missing title: \(command.title)")
            #expect(translations[command.subtitle] != nil, "Missing subtitle: \(command.subtitle)")
        }
    }

    @Test
    func simplifiedChineseResourcesCoverPluginLanguageGrouping() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["More Language Support"] == "扩展更多语言")
        #expect(
            translations["%lld languages · %lld enabled"]
                == "%lld 种语言 · 已启用 %lld 个"
        )
        #expect(translations["Expanded"] == "已展开")
        #expect(translations["Collapsed"] == "已收起")
    }

    @Test
    func simplifiedChineseResourcesCoverJavaLanguageServiceFeedback() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Java service is preparing"] == "Java 服务正在准备")
        #expect(translations["Java service is ready"] == "Java 服务已就绪")
        #expect(translations["Java service preparation timed out"] == "Java 服务准备超时")
        #expect(translations["Java service failed to start"] == "Java 服务启动失败")
        #expect(translations["Java service failed to start: %@"] == "Java 服务启动失败：%@")
    }

    @Test
    func simplifiedChineseResourcesCoverBreakpointManager() throws {
        let translations = try simplifiedChineseTranslations()
        let requiredKeys = [
            "View Breakpoints",
            "Manage all project breakpoints",
            "View breakpoints (⌘⇧F8)",
            "View breakpoints",
            "Loading breakpoints…",
            "Manage project breakpoints without starting a debug session",
            "Line Breakpoints",
            "Exception Breakpoints",
            "Method Breakpoints",
            "Field Breakpoints",
            "Mute Line Breakpoints",
            "Unmute Line Breakpoints",
            "Click the editor gutter to add a breakpoint",
            "Add a class or method name",
            "Right-click a field while paused to add a breakpoint",
            "Remove All",
            "Disable breakpoint",
            "Enable breakpoint",
            "Edit…",
            "Edit exception breakpoint",
            "Add method breakpoint",
            "Breakpoint actions",
            "Line breakpoint actions",
            "If: %@",
            "Hit: %@",
            "Verified",
            "Pending verification"
        ]

        for key in requiredKeys {
            #expect(translations[key] != nil, "Missing breakpoint manager translation: \(key)")
        }
    }

    private func simplifiedChineseTranslations() throws -> [String: String] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceURL = repositoryRoot
            .appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let data = try Data(contentsOf: resourceURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try #require(propertyList as? [String: String])
    }
}

private final class LocalizationTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite("Git localization")
struct GitLocalizationTests {
    @Test(arguments: ["en", "zh-Hans"])
    func gitControlsHaveTranslationsWithMatchingPlaceholders(language: String) throws {
        let bundle = try resourceBundle(language)
        let keys = [
            "Revert this commit?", "Revert", "Create a new commit that reverses %@.",
            "Cherry-pick this commit?", "Apply %@ to the current branch.",
            "Reset current branch?", "Reset (Mixed)",
            "Move the current branch to %@ and keep changes unstaged.",
            "Delete branch?", "Merge branch?", "Rebase branch?",
            "Checkout and rebase branch?", "Pull remote branch with rebase?",
            "Pull remote branch with merge?", "New Tag", "Tag name",
            "Delete tag '%@'?", "Deleted tag '%@'", "Deleted branch '%@'",
            "Branch", "User", "Date", "Path", "HEAD (Current Branch)",
            "Text, me, author:, branch:, path:", "Any Time", "Today", "Yesterday",
            "Last 7 Days", "Last 30 Days", "Loading commits…", "Load more commits",
            "Clear Git console", "Git exited with code %d", "%lld files",
            "%lld worktrees", "Worktree action unavailable", "Invalid Git tag name."
        ]
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@)"#)
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(value != "MISSING", "Missing \(language) translation for \(key)")
            if language == "zh-Hans" {
                #expect(value != key, "Untranslated Git control: \(key)")
            }
            func placeholders(_ text: String) -> [String] {
                pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                    (text as NSString).substring(with: $0.range)
                }.sorted()
            }
            #expect(placeholders(key) == placeholders(value), "Format mismatch: \(key)")
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func formattedMenusPreserveReferenceNamesAndExplicitLanguage(language: String) throws {
        let bundle = try resourceBundle(language)
        let locale = Locale(identifier: language)
        // Reference names that resemble translation keys, contain Unicode, or
        // include percent signs must remain data when formatting translated UI.
        let source = "Today"
        let target = "feature/中文-100%"
        let title = gitLocalizedFormat("Compare '%@' with '%@'", source, target, locale: locale, bundle: bundle)
        #expect(title == (language == "en"
            ? "Compare 'Today' with 'feature/中文-100%'"
            : "比较“Today”与“feature/中文-100%”"))
        let revert = gitLocalizedFormat("Create a new commit that reverses %@.", "8c8286c", locale: locale, bundle: bundle)
        #expect(revert == (language == "en"
            ? "Create a new commit that reverses 8c8286c."
            : "创建一个新提交，撤销提交 8c8286c 的更改。"))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func pushDestinationUsesTheRequestedLanguage(language: String) throws {
        let bundle = try resourceBundle(language)
        for upstream in [nil, "origin/Today"] as [String?] {
            let reference = GitReference(fullName: "refs/heads/Today", shortName: "Today", kind: .local,
                                         isCurrent: true, upstreamShortName: upstream)
            let presentation = GitPushDialogPresentation(reference: reference, locale: Locale(identifier: language), bundle: bundle)
            let expected: String
            if upstream != nil {
                expected = language == "en" ? "Tracking origin/Today" : "跟踪 origin/Today"
            } else {
                expected = language == "en" ? "Publish Today (Core selects default remote)" : "发布 Today（自动选择默认远程仓库）"
            }
            #expect(presentation.destination == expected)
        }
    }

    @Test @MainActor
    func nativeRowsRefreshOnlyWhenContentOrLanguageChanges() {
        let view = GitWorktreeRowsNSView()
        let snapshot = GitWorktreeRowsSnapshot(identity: .changes(inspectionVersion: 1), rows: [])
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        #expect(view.update(snapshot: snapshot, rowHeight: 35, locale: english))
        #expect(!view.update(snapshot: snapshot, rowHeight: 35, locale: english))
        #expect(view.update(snapshot: snapshot, rowHeight: 35, locale: chinese))
        #expect(!view.update(snapshot: snapshot, rowHeight: 35, locale: chinese))
    }

    @Test @MainActor
    func nativeFileTreeRefreshesCachedLabelsWhenLanguageChanges() {
        let view = GitCommitFileTreeNSView()
        func update(_ language: String) -> Bool {
            view.update(locale: Locale(identifier: language), items: [], selectedFileID: nil,
                        rootSubtitle: nil, collapsedFolderIDs: [], onToggleFolder: { _ in }, onSelectFile: { _ in })
        }
        _ = update("en")
        #expect(!update("en"))
        #expect(update("zh-Hans"))
        #expect(!update("zh-Hans"))
    }

    private func resourceBundle(_ language: String) throws -> Bundle {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        return try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
    }
}
