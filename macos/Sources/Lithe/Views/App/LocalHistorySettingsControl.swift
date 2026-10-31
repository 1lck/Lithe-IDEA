import LitheCoreContracts
import LitheLocalHistoryModule
import LitheModuleAPI
import SwiftUI

/// Local history storage and ignore rules. Rules are edited as drafts and only
/// saved by Apply; the test path is checked against the drafts as they change.
struct LocalHistorySettingsControl: View {
    private enum RuleKind: Hashable { case wildcard, regex }

    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settings: AppSettings
    @State private var kind = RuleKind.wildcard
    @State private var patternsDraft = ""
    @State private var regexesDraft = ""
    /// Rust Core owns the built-in wildcard rules; they arrive with the first preview.
    @State private var builtInPatterns: [String]?
    @State private var testPath = ""
    @State private var preview: LocalHistoryIgnorePreview?
    @State private var usage: LocalHistoryUsage?
    @State private var isConfirmingClear = false
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            storageRow
            LitheSettingsSegmentedControl(selection: $kind, options: [.wildcard, .regex], width: 240) {
                switch $0 {
                case .wildcard: "Wildcard"
                case .regex: "Regular expression"
                }
            }
            editor
            regexErrors
            HStack(spacing: 6) {
                Text("Test path")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                LitheInfoTip("Type a path inside the project to check it against the rules above as you edit them: whether local history records the file, and whether Git ignores it. Git ignore rules do not affect local history.")
                LitheTextField(verbatim: "src/generated/Api.java", text: $testPath)
                    .frame(maxWidth: 260)
                    .accessibilityLabel(Text("Test path"))
                testResult
            }
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                Button("Apply") { apply() }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(!hasChanges)
            }
        }
        .onAppear(perform: syncDrafts)
        .onChange(of: settings.localHistoryIgnorePatterns) { _ in syncDrafts() }
        .onChange(of: settings.localHistoryIgnoreRegexes) { _ in syncDrafts() }
        .task { usage = await model.localHistoryUsage() }
        .task(id: previewKey) {
            // Debounce typing; a newer draft cancels this task.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let result = await model.localHistoryIgnorePreview(
                path: testPath.trimmingCharacters(in: .whitespaces),
                rules: draftRules
            )
            guard !Task.isCancelled else { return }
            preview = result
            if builtInPatterns == nil, let builtIns = result?.builtInIgnorePatterns {
                builtInPatterns = builtIns
                syncDrafts()
            }
        }
        .alert("Clear this project's local history?", isPresented: $isConfirmingClear) {
            Button("Clear", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved version of this project's files is deleted. Open files are not changed.")
        }
    }

    // MARK: Storage

    @ViewBuilder
    private var storageRow: some View {
        HStack(spacing: 6) {
            if let usage {
                Text("Used")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                LitheSettingsPill(verbatim: Self.bytes(usage.usedBytes), kind: .value)
                Text(verbatim: "/")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                limitStepper
                Spacer(minLength: 8)
                Button { isConfirmingClear = true } label: {
                    isClearing ? Text("Clearing…") : Text("Clear Project History…")
                }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(isClearing || usage.usedBytes == 0)
            } else {
                Text("Limit per project")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                limitStepper
                Spacer(minLength: 8)
                Text("Open a project to see how much space its history uses.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
    }

    /// Applies at once; older versions over a lower limit are removed at the next save.
    private var limitStepper: some View {
        LitheSettingsStepper(
            value: $settings.localHistoryStorageLimitMegabytes,
            in: AppSettings.localHistoryStorageLimitRange,
            step: 50,
            width: 126,
            accessibilityLabel: "Local history limit per project",
            title: { "\($0) MB" },
            parse: { Int($0.filter(\.isNumber)) }
        )
        .help(Text("When the limit is reached, the oldest versions are removed first."))
    }

    private func clear() {
        isClearing = true
        Task {
            _ = await model.clearLocalHistory()
            usage = await model.localHistoryUsage()
            isClearing = false
        }
    }

    // MARK: Rules

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .wildcard:
            LitheTextEditor(text: $patternsDraft, height: 120)
                .accessibilityLabel(Text("Wildcard ignore rules"))
        case .regex:
            LitheTextEditor(text: $regexesDraft, height: 120)
                .accessibilityLabel(Text("Regular expression ignore rules"))
        }
    }

    @ViewBuilder
    private var regexErrors: some View {
        if kind == .regex, let errors = preview?.regexErrors, !errors.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(errors.keys.sorted(), id: \.self) { index in
                    Label(String(format: L10n.string("Line %lld is not a valid regular expression and is skipped."), index + 1),
                          systemImage: "exclamationmark.triangle")
                        .help(Text(verbatim: errors[index] ?? ""))
                }
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.warning)
        }
    }

    @ViewBuilder
    private var testResult: some View {
        if !testPath.trimmingCharacters(in: .whitespaces).isEmpty, let preview {
            let recorded = preview.matched == nil
            VStack(alignment: .leading, spacing: 2) {
                Label(String(format: L10n.string("Local history: %@"), resultText(preview.matched)),
                      systemImage: recorded ? "checkmark.circle" : "nosign")
                    .foregroundStyle(recorded ? LitheTheme.success : LitheTheme.warning)
                // Informational only: local history does not follow Git ignore rules.
                if let gitIgnored = preview.gitIgnored {
                    Label(gitIgnored ? L10n.string("Git: ignored") : L10n.string("Git: not ignored"),
                          systemImage: "arrow.triangle.branch")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .font(LitheTheme.smallFont)
            .lineLimit(2)
        }
    }

    private func resultText(_ match: LocalHistoryIgnoreMatch?) -> String {
        switch match {
        case nil:
            L10n.string("Recorded")
        case .hidden:
            L10n.string("Hidden in the project tree, not recorded")
        case .pattern(let pattern):
            String(format: L10n.string("Ignored by wildcard rule %@"), pattern)
        case .regex(let index):
            String(format: L10n.string("Ignored by regular expression line %lld"), index + 1)
        }
    }

    private var previewKey: String { [testPath, patternsDraft, regexesDraft].joined(separator: "\u{0}") }

    /// The drafts as rules, with the saved hidden paths so a shown built-in previews as visible.
    private var draftRules: LocalHistoryVisibilityRules {
        LocalHistoryVisibilityRules(
            hiddenDirectoryNames: [],
            hiddenFilePatterns: settings.fileVisibilityRules.hiddenFilePatterns,
            ignorePatterns: storedPatterns,
            ignoreRegexes: lines(regexesDraft)
        )
    }

    /// Saved form of the wildcard draft: the user's lines plus `!rule` for each
    /// deleted built-in. The saved value until the built-ins are known.
    private var storedPatterns: [String] {
        guard let builtInPatterns else { return settings.localHistoryIgnorePatterns }
        return BuiltInRuleList.stored(lines: entries(patternsDraft), builtIns: builtInPatterns)
    }

    private var hasChanges: Bool {
        storedPatterns != settings.localHistoryIgnorePatterns
            || entries(regexesDraft) != settings.localHistoryIgnoreRegexes
    }

    private func syncDrafts() {
        // Until the built-ins arrive the editor stays empty rather than showing a partial list.
        if let builtInPatterns {
            patternsDraft = BuiltInRuleList.displayed(
                stored: settings.localHistoryIgnorePatterns, builtIns: builtInPatterns
            ).joined(separator: "\n")
        }
        regexesDraft = settings.localHistoryIgnoreRegexes.joined(separator: "\n")
    }

    private func apply() {
        settings.localHistoryIgnorePatterns = storedPatterns
        settings.localHistoryIgnoreRegexes = entries(regexesDraft)
        // Echo what was stored, without the blank lines.
        syncDrafts()
    }

    /// Raw lines keep their numbers, so errors and matches point at the line the user sees.
    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private func entries(_ text: String) -> [String] {
        lines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func bytes(_ count: Int64) -> String {
        // The limit is 100 MiB; binary units show it as 100 MB rather than 104.9 MB.
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
