import Testing
@testable import Lithe

@Suite("LSP Control Center presentation")
struct LSPControlCenterPresentationTests {
    @Test
    func runtimeStateAloneDeterminesServerStatus() {
        // Code diagnostics are deliberately unrelated to this resolver. A ready
        // session remains active even when the editor has an error diagnostic.
        let unrelatedEditorSeverity = DiagnosticSeverity.error

        #expect(unrelatedEditorSeverity == .error)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .startingProcess
        ) == .starting)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .initializing
        ) == .initializing)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .ready
        ) == .active)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .stopping
        ) == .stopping)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .stopped
        ) == .stopped)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: nil
        ) == .stopped)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: false,
            sessionState: .failed(exitCode: 1, message: "crashed")
        ) == .error)
    }

    @Test
    func disabledWorkspaceSettingTakesPrecedenceOverRuntimeState() {
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: true,
            sessionState: .ready
        ) == .disabled)
    }

    @Test
    func negotiatedCapabilitiesAreUnknownUntilInitializationCompletes() {
        #expect(LSPControlCenterPresenter.negotiatedCapabilityState(
            .completion,
            sessionState: .initializing,
            features: .completion
        ) == .unknown)
        #expect(LSPControlCenterPresenter.negotiatedCapabilityState(
            .completion,
            sessionState: .ready,
            features: []
        ) == .unsupported)
        #expect(LSPControlCenterPresenter.negotiatedCapabilityState(
            .completion,
            sessionState: .ready,
            features: .completion
        ) == .available)
    }

    @Test
    func versionComesOnlyFromInitializeServerInfo() {
        #expect(LSPControlCenterPresenter.reportedServerVersion(nil) == nil)
        #expect(LSPControlCenterPresenter.reportedServerVersion(
            LanguageServerInfo(name: "gopls", version: nil)
        ) == nil)
        #expect(LSPControlCenterPresenter.reportedServerVersion(
            LanguageServerInfo(name: "gopls", version: " 0.20.0 ")
        ) == "0.20.0")
    }

    @Test
    func integrationAvailabilityIsNotReportedAsAFalseServerCapability() {
        #expect(LSPControlCenterPresenter.integrationState(
            isAvailable: false
        ) == .unsupported)
        #expect(LSPControlCenterPresenter.integrationState(
            isAvailable: true
        ) == .available)
        #expect(LSPControlCenterPresenter.integrationState(
            isAvailable: true,
            isActive: true
        ) == .active)
    }
}
