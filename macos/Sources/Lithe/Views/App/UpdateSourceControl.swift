import LitheModuleAPI
import SwiftUI

/// Edits the stable update source. The field shows the source in use; typing only
/// changes a draft, which is saved after a successful connection test.
struct UpdateSourceControl: View {
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var draft = ""
    @State private var editedSource: URL?
    @State private var probe: UpdateSourceProbeResult?
    @State private var probedBase: URL?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source = updateChecker.effectiveUpdateSource {
                HStack(spacing: 6) {
                    LitheTextField(verbatim: source.baseURL.absoluteString, text: $draft,
                                   isEnabled: updateChecker.canCustomizeUpdateSource)
                        .frame(maxWidth: 420)
                        .onSubmit(test)
                    sourcePill(source)
                }
                if updateChecker.canCustomizeUpdateSource {
                    HStack(spacing: LitheTheme.ActionButton.spacing) {
                        Button(action: test) {
                            Label(isTesting ? "Testing…" : "Test Connection", systemImage: "network")
                        }
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(isTesting || parsedDraft == nil)
                        Button("Apply") { apply(parsedDraft) }
                            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                            .disabled(!canApply)
                        Button("Restore Default") { apply(nil) }
                            .buttonStyle(LitheActionButtonStyle())
                            .disabled(!source.isCustom || !updateChecker.canChangeChannel)
                    }
                    resultLine
                }
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: updateChecker.customUpdateSourceBase) { _ in syncDraft() }
        .onChange(of: draft) { _ in
            if parsedDraft != probedBase { probe = nil }
        }
    }

    private var parsedDraft: URL? { try? AppUpdateSource.parseBase(draft).get() }

    private var canApply: Bool {
        guard case .reachable = probe, let parsedDraft, parsedDraft == probedBase else { return false }
        return parsedDraft != updateChecker.effectiveUpdateSource?.baseURL && updateChecker.canChangeChannel
    }

    @ViewBuilder
    private var resultLine: some View {
        if case .failure(let error) = AppUpdateSource.parseBase(draft), !draft.isEmpty {
            Label(AppUpdateSource.inputMessage(error), systemImage: "exclamationmark.triangle")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.warning)
        } else if case .reachable(let version) = probe {
            Label(String(format: L10n.string("Found Lithe %@ at this source."), version), systemImage: "checkmark.circle.fill")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.success)
        } else if case .failed(let message) = probe {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourcePill(_ source: AppUpdateSource) -> some View {
        Text(source.isCustom ? "Custom" : "Default")
            .font(LitheTheme.uiFont(size: 10.5))
            .foregroundStyle(LitheTheme.settingsPillText)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(LitheTheme.settingsPill))
            .fixedSize()
    }

    private func syncDraft() {
        let current = updateChecker.effectiveUpdateSource?.baseURL
        guard current != editedSource || draft.isEmpty else { return }
        editedSource = current
        draft = current?.absoluteString ?? ""
        probe = nil
        probedBase = nil
    }

    private func test() {
        guard let base = parsedDraft, !isTesting else { return }
        isTesting = true
        probe = nil
        Task {
            let result = await updateChecker.testUpdateSource(base)
            isTesting = false
            guard parsedDraft == base else { return }
            probedBase = base
            probe = result
        }
    }

    private func apply(_ base: URL?) {
        guard updateChecker.applyUpdateSource(base) else { return }
        // Echo what was actually stored, not the draft.
        editedSource = nil
        draft = ""
        syncDraft()
    }
}
