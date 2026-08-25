import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct SettingsAppearanceContainerTests {
    @Test
    func changingAppearanceKeepsTheContentIdentity() {
        let recorder = SettingsContentIdentityRecorder()
        let hostingView = NSHostingView(rootView: makeContent(
            themePreference: .light,
            recorder: recorder
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        hostingView.layoutSubtreeIfNeeded()
        let initialSnapshot = recorder.snapshots.last

        hostingView.rootView = makeContent(themePreference: .dark, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        let darkSnapshot = recorder.snapshots.last

        hostingView.rootView = makeContent(themePreference: .system, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        let systemSnapshot = recorder.snapshots.last

        #expect(initialSnapshot != nil)
        #expect(darkSnapshot?.identity == initialSnapshot?.identity)
        #expect(systemSnapshot?.identity == initialSnapshot?.identity)
        #expect(darkSnapshot?.draft == "unsaved draft")
        #expect(systemSnapshot?.draft == "unsaved draft")
    }

    private func makeContent(
        themePreference: AppThemePreference,
        recorder: SettingsContentIdentityRecorder
    ) -> SettingsAppearanceContainer<SettingsContentIdentityProbe> {
        SettingsAppearanceContainer(themePreference: themePreference) {
            SettingsContentIdentityProbe(recorder: recorder)
        }
    }
}

@MainActor
private final class SettingsContentIdentityRecorder {
    struct Snapshot {
        let identity: ObjectIdentifier
        let draft: String
    }

    var snapshots: [Snapshot] = []
}

@MainActor
private final class SettingsContentState: ObservableObject {
    var draft = ""
}

@MainActor
private struct SettingsContentIdentityProbe: View {
    @StateObject private var state = SettingsContentState()
    let recorder: SettingsContentIdentityRecorder

    var body: some View {
        SettingsContentIdentityReporter(
            state: state,
            recorder: recorder
        )
    }
}

@MainActor
private struct SettingsContentIdentityReporter: NSViewRepresentable {
    let state: SettingsContentState
    let recorder: SettingsContentIdentityRecorder

    func makeNSView(context: Context) -> NSView {
        state.draft = "unsaved draft"
        recordIdentity()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recordIdentity()
    }

    private func recordIdentity() {
        recorder.snapshots.append(.init(
            identity: ObjectIdentifier(state),
            draft: state.draft
        ))
    }
}
