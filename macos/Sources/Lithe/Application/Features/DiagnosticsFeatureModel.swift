import Combine
import Foundation

/// UI-facing projection for the diagnostic-bundle export flow. Owns sheet
/// presentation state so Views depend on this feature model instead of the
/// underlying service directly.
@MainActor
final class DiagnosticsFeatureModel: ObservableObject {
    private let service: DiagnosticsExportService
    private var observation: AnyCancellable?

    @Published private(set) var state: DiagnosticsExportService.ExportState
    @Published var isPresented = false

    init(service: DiagnosticsExportService) {
        self.service = service
        _state = Published(initialValue: service.state)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.state = self.service.state
        }
    }

    func presentExport() {
        isPresented = true
        Task { await service.prepare() }
    }

    func dismiss() {
        service.cancel()
        isPresented = false
    }

    func export(to destinationURL: URL) async {
        await service.export(to: destinationURL)
    }
}
