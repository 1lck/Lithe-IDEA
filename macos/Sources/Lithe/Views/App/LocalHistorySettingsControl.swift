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
    @State private var testPath = ""
    @State private var preview: LocalHistoryIgnorePreview?
    @State private var usage: LocalHistoryUsage?
    @State private var isConfirmingClear = false
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            storageRow
            LitheSettingsSegmentedControl(selection: $kind, options: [.wildcard, .regex], width: 220) {
                $0 == .wildcard ? "Wildcard" : "Regular expression"
            }
            LitheTextEditor(text: kind == .wildcard ? $patternsDraft : $regexesDraft, height: 72)
                .accessibilityLabel(kind == .wildcard ? Text("Wildcard ignore rules") : Text("Regular expression ignore rules"))
            regexErrors
            HStack(spacing: 6) {
                LitheTextField(verbatim: "src/generated/Api.java", text: $testPath)
                    .frame(maxWidth: 260)
                    .accessibilityLabel(Text("Test path"))
                testResult
            }
            HStack(spacing: 6) {
                baselinePills
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
                patterns: lines(patternsDraft),
                regexes: lines(regexesDraft)
            )
            if !Task.isCancelled { preview = result }
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
                LitheSettingsPill(verbatim: "\(Self.bytes(usage.usedBytes)) / \(Self.bytes(usage.limitBytes))", kind: .value)
                    .help(Text("When the limit is reached, the oldest versions are removed first."))
                Spacer(minLength: 8)
                Button { isConfirmingClear = true } label: {
                    isClearing ? Text("Clearing…") : Text("Clear Project History…")
                }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(isClearing || usage.usedBytes == 0)
            } else {
                Text("Open a project to see how much space its history uses.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
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
            Label(resultText(preview.matched), systemImage: recorded ? "checkmark.circle" : "nosign")
                .font(LitheTheme.smallFont)
                .foregroundStyle(recorded ? LitheTheme.success : LitheTheme.warning)
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

    /// Generated folders get no initial copy when a project opens; edits inside them are still recorded.
    @ViewBuilder
    private var baselinePills: some View {
        let names = preview?.baselineExcludedDirectoryNames ?? []
        if !names.isEmpty {
            let shown = names.prefix(3)
            HStack(spacing: 6) {
                Text("No initial copy")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                ForEach(Array(shown), id: \.self) { LitheSettingsPill(verbatim: $0, kind: .value) }
                if names.count > shown.count {
                    LitheSettingsPill(verbatim: "+\(names.count - shown.count)")
                }
            }
            .help(Text(verbatim: names.joined(separator: "   ")))
        }
    }

    private var previewKey: String { [testPath, patternsDraft, regexesDraft].joined(separator: "\u{0}") }

    private var hasChanges: Bool {
        entries(patternsDraft) != settings.localHistoryIgnorePatterns
            || entries(regexesDraft) != settings.localHistoryIgnoreRegexes
    }

    private func syncDrafts() {
        patternsDraft = settings.localHistoryIgnorePatterns.joined(separator: "\n")
        regexesDraft = settings.localHistoryIgnoreRegexes.joined(separator: "\n")
    }

    private func apply() {
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
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
