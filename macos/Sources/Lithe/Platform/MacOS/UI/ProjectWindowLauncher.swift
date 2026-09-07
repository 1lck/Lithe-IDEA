import Foundation

@MainActor
final class ProjectWindowLauncher: ObservableObject {
    var presentProjectWindow: ((UUID) -> Void)?
    var dismissProjectWindow: ((UUID) -> Void)?
    var presentPrimaryWindow: (() -> Void)?

    func present(_ windowID: UUID) {
        presentProjectWindow?(windowID)
    }

    func dismiss(_ windowID: UUID) {
        dismissProjectWindow?(windowID)
    }

    func presentPrimary() {
        presentPrimaryWindow?()
    }
}
