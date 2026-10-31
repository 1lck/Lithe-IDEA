import LitheCoreContracts
import LitheLocalHistoryModule
import LitheModuleAPI
import SwiftUI

/// Local history storage, ignore rules and No initial copy folders. Rules are
/// edited as drafts and only saved by Apply; the test path is checked against
/// the drafts as they change.
struct LocalHistorySettingsControl: View {
    private enum RuleKind: Hashable { case wildcard, regex, baseline }

    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settings: AppSettings
    @State private var kind = RuleKind.wildcard
    @State private var patternsDraft = ""
    @State private var regexesDraft = ""
    @State private var baselineDraft = ""
    /// Rust Core owns the built-in folder list; it arrives with the first preview.
    @State private var baselineBuiltIns: [String]?
    @State private var testPath = ""
    @State private var preview: LocalHistoryIgnorePreview?
    @State private var usage: LocalHistoryUsage?
    @State private var isConfirmingClear = false
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            storageRow
            LitheSettingsSegmentedControl(selection: $kind, options: [.wildcard, .regex, .baseline], width: 360) {
                switch $0 {
                case .wildcard: "Wildcard"
                case .regex: "Regular expression"
                case .baseline: "No initial copy"
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
        .onChange(of: settings.localHistoryBaselineExcludedDirectoryNames) { _ in syncDrafts() }
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
            if baselineBuiltIns == nil, let builtIns = result?.builtInBaselineExcludedDirectoryNames {
                baselineBuiltIns = builtIns
                baselineDraft = BuiltInRuleList.displayed(
                    stored: settings.localHistoryBaselineExcludedDirectoryNames, builtIns: builtIns
                ).joined(separator: "\n")
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
            LitheTextEditor(text: $patternsDraft, height: 72)
                .accessibilityLabel(Text("Wildcard ignore rules"))
        case .regex:
            LitheTextEditor(text: $regexesDraft, height: 72)
                .accessibilityLabel(Text("Regular expression ignore rules"))
        case .baseline:
            LitheTextEditor(text: $baselineDraft, height: 120)
                .accessibilityLabel(Text("No initial copy folders"))
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
            let recorded = preview.matched == nil || preview.matched.map(Self.isBaselineOnly) == true
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
        case .baselineExcluded(let directory):
            String(format: L10n.string("In %@: no initial copy, edits are recorded"), directory)
        case .pattern(let index):
            String(format: L10n.string("Ignored by wildcard line %lld"), index + 1)
        case .regex(let index):
            String(format: L10n.string("Ignored by regular expression line %lld"), index + 1)
        }
    }

    private static func isBaselineOnly(_ match: LocalHistoryIgnoreMatch) -> Bool {
        if case .baselineExcluded = match { return true }
        return false
    }

    private var previewKey: String { [testPath, patternsDraft, regexesDraft, baselineDraft].joined(separator: "\u{0}") }

    /// The drafts as rules, with the saved hidden paths so a shown built-in previews as visible.
    private var draftRules: LocalHistoryVisibilityRules {
        LocalHistoryVisibilityRules(
            hiddenDirectoryNames: [],
            hiddenFilePatterns: settings.fileVisibilityRules.hiddenFilePatterns,
            ignorePatterns: lines(patternsDraft),
            ignoreRegexes: lines(regexesDraft),
            baselineExcludedDirectoryNames: storedBaseline
        )
    }

    /// Saved form of the folder draft; the saved value until the built-ins are known.
    private var storedBaseline: [String] {
        guard let baselineBuiltIns else { return settings.localHistoryBaselineExcludedDirectoryNames }
        return BuiltInRuleList.stored(lines: lines(baselineDraft), builtIns: baselineBuiltIns)
    }

    private var hasChanges: Bool {
        entries(patternsDraft) != settings.localHistoryIgnorePatterns
            || entries(regexesDraft) != settings.localHistoryIgnoreRegexes
            || storedBaseline != settings.localHistoryBaselineExcludedDirectoryNames
    }

    private func syncDrafts() {
        patternsDraft = settings.localHistoryIgnorePatterns.joined(separator: "\n")
        regexesDraft = settings.localHistoryIgnoreRegexes.joined(separator: "\n")
        if let baselineBuiltIns {
            baselineDraft = BuiltInRuleList.displayed(
                stored: settings.localHistoryBaselineExcludedDirectoryNames, builtIns: baselineBuiltIns
            ).joined(separator: "\n")
        }
    }

    private func apply() {
        settings.localHistoryBaselineExcludedDirectoryNames = storedBaseline
        settings.localHistoryIgnorePatterns = entries(patternsDraft)
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
