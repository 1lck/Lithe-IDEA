import Foundation

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// Finds installations of tools for the New Project window, where there is no
/// project yet to resolve them against.
///
/// It runs the toolchain discovery the settings pages use, with an empty
/// scratch directory standing in for the workspace. Discovery needs a real
/// directory because Core refuses homes inside it; an empty one matches
/// nothing, so only machine-wide installations are found. The directory lives
/// in the temporary directory and is removed afterwards, so nothing is written
/// to a plugin package, the app bundle, or a user workspace.
struct MacProjectToolInstallations: Sendable {
    private let discover: @Sendable (MacToolchainDiscovery.Request) async -> MacToolchainDiscovery.Result
    private let environment: @Sendable () -> [String: String]
    private let scratchParent: URL

    init(
        discover: @escaping @Sendable (MacToolchainDiscovery.Request) async -> MacToolchainDiscovery.Result,
        environment: @escaping @Sendable () -> [String: String] = {
            MacLoginShellEnvironment.shared.merged(ProcessInfo.processInfo.environment)
        },
        scratchParent: URL = FileManager.default.temporaryDirectory
    ) {
        self.discover = discover
        self.environment = environment
        self.scratchParent = scratchParent
    }

    /// The installations of each tool, best first. A tool no enabled plugin
    /// defines, or one with nothing installed, maps to an empty list.
    func installations(
        of tools: [String], sources: [ToolchainSettingsPluginSource]
    ) async -> [String: [ProjectToolInstallation]] {
        let enabled = sources.filter(\.isEnabled)
        guard !tools.isEmpty, !enabled.isEmpty, let scratch = makeScratchDirectory() else { return [:] }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let request = MacToolchainDiscovery.Request(
            workspace: scratch, sources: enabled, environment: environment()
        )
        let result = await discover(request)

        var found: [String: [ProjectToolInstallation]] = [:]
        for tool in tools {
            found[tool] = (result.detections[tool]?.installations ?? []).map {
                ProjectToolInstallation(home: $0.home, executable: $0.executable, version: $0.version)
            }
        }
        return found
    }

    private func makeScratchDirectory() -> URL? {
        let directory = scratchParent.appendingPathComponent(
            "lithe-new-project-tools-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        } catch {
            return nil
        }
    }
}
