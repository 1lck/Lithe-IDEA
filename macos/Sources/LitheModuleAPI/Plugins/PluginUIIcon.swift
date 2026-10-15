import Foundation

/// Portable declaration; native hosts own resource validation and presentation.
public struct PluginUIIcon: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case template, original }
    public let host: String?
    public let path: String?
    public let darkPath: String?
    public let mode: Mode

    public init(host: String? = nil, path: String? = nil, darkPath: String? = nil, mode: Mode = .template) {
        self.host = host
        self.path = path
        self.darkPath = darkPath
        self.mode = mode
    }
}

/// Validated immutable bytes from one installed package version. No UI or path
/// types cross the platform boundary; no runtime file cache is created.
public struct PluginUIIconResources: Sendable {
    public let light: Data
    public let dark: Data?
    public init(light: Data, dark: Data? = nil) { self.light = light; self.dark = dark }
}
