import Foundation

struct MacDatabaseSidecarLocator: Sendable {
    private let bundle: Bundle
    private let environment: [String: String]
    private let fileStorage: any FileStorage

    init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileStorage: any FileStorage = MacFileStorage()
    ) {
        self.bundle = bundle
        self.environment = environment
        self.fileStorage = fileStorage
    }

    func executableURL() -> URL? {
        if let override = environment["LITHE_DB_SIDECAR_EXECUTABLE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileStorage.isExecutable(at: url) ? url : nil
        }
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/lithe-db-sidecar"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/Database/lithe-db-sidecar")
        ]
        return candidates.first(where: fileStorage.isExecutable(at:))
    }
}
