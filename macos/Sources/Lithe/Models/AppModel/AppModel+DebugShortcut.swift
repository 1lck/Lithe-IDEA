import LitheModuleAPI

@MainActor
extension AppModel {
    func startOrContinueDebugging() {
        let feature = genericDebugFeatureIfActive
        guard let decide = services.debugStartOrContinue else { return }
        let action: DebugStartOrContinueAction
        do {
            action = try decide(feature?.isSessionActive == true, feature?.state == .paused,
                                feature?.isExecutionRequestPending == true)
        } catch {
            services.logSink?.emit(DebugShortcutDecisionFailed(error: error))
            return
        }
        switch action {
        case .start: startDebugging()
        case .continue: resumeDebugging()
        case .none: break
        }
    }
}
