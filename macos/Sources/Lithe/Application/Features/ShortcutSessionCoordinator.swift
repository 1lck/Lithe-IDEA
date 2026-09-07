import Combine

/// Owns native shortcut monitoring for one project session and drops commands
/// queued before that session was deactivated or began recording a shortcut.
@MainActor
final class ShortcutSessionCoordinator {
    private var detector: (any ShortcutDetector)?
    private var observations: [AnyCancellable] = []
    private var isActive = false
    private var isRecording = false
    private var isShutdown = false

    init(
        settings: AppSettings,
        feature: KeyboardShortcutFeatureModel,
        factory: any ShortcutDetectorFactory,
        onRegistrationsChanged: @escaping @MainActor () -> Void,
        onCommand: @escaping @MainActor @Sendable (String) -> Void
    ) {
        detector = factory.make { [weak self] commandID in
            guard let self, self.isActive, !self.isRecording, !self.isShutdown else { return }
            onCommand(commandID)
        }
        observations = [
            settings.$keyboardShortcutOverrides.sink { [weak self, weak feature] overrides in
                guard let self, let feature else { return }
                self.detector?.update(registrations: feature.registrations(for: overrides))
                onRegistrationsChanged()
            },
            feature.$recordingCommandID.sink { [weak self] commandID in
                guard let self else { return }
                self.isRecording = commandID != nil
                self.detector?.setSuspended(self.isRecording)
            }
        ]
    }

    func setActive(_ active: Bool) {
        guard !isShutdown, isActive != active else { return }
        isActive = active
        if active {
            detector?.start()
        } else {
            detector?.stop()
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        setActive(false)
        isShutdown = true
        observations.removeAll()
    }

    deinit {
        if isActive { detector?.stop() }
    }
}
