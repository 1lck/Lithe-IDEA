import AppKit
import SwiftUI
import LitheAgentConversationModule

/// Destination of a Markdown link in an Agent reply. Agents cite workspace files
/// as relative or absolute paths, often with a `:line` suffix or `#L12` anchor;
/// those open in the editor instead of being handed to the system.
enum AgentMarkdownLink: Equatable {
    case file(AgentToolDetails.Location, isDocument: Bool)
    case github
    case web

    private static let webSchemes: Set<String> = ["http", "https", "mailto"]
    private static let documentExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", "pdf", "doc", "docx"]

    init(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if let scheme, Self.webSchemes.contains(scheme) {
            let host = url.host?.lowercased() ?? ""
            self = host == "github.com" || host.hasSuffix(".github.com") ? .github : .web
            return
        }
        // `README.md:12` parses with `README.md` as its scheme; a real scheme has no dot.
        let isPath = scheme == nil || scheme == "file" || scheme?.contains(".") == true
        guard isPath, let location = Self.location(url) else {
            self = .web
            return
        }
        let fileExtension = (location.path as NSString).pathExtension.lowercased()
        self = .file(location, isDocument: fileExtension.isEmpty || Self.documentExtensions.contains(fileExtension))
    }

    private static func location(_ url: URL) -> AgentToolDetails.Location? {
        var raw = url.scheme == "file" ? url.path : url.absoluteString
        var line: Int?
        if let fragment = url.fragment, let range = fragment.range(of: #"^L(\d+)"#, options: .regularExpression) {
            line = Int(fragment[range].dropFirst())
            if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
        }
        raw = raw.removingPercentEncoding ?? raw
        if let suffix = raw.range(of: #":(\d+)(:\d+)?$"#, options: .regularExpression) {
            line = line ?? Int(raw[suffix].dropFirst().prefix { $0.isNumber })
            raw = String(raw[..<suffix.lowerBound])
        }
        guard !raw.isEmpty else { return nil }
        return AgentToolDetails.Location(path: raw, line: line)
    }

    @MainActor
    func icon(size: CGFloat) -> Text? {
        switch self {
        case .file(_, let isDocument):
            return Text(Image(systemName: isDocument ? "doc" : "chevron.left.forwardslash.chevron.right"))
                .font(LitheTheme.uiFont(size: size - 2))
                .foregroundColor(LitheTheme.accent)
        case .github:
            guard let image = Self.githubMark(size: size) else { return nil }
            return Text(Image(nsImage: image)).foregroundColor(LitheTheme.accent)
        case .web:
            return nil
        }
    }

    /// Opens workspace files in the editor; everything else goes to the system.
    static func openAction(onOpenFile: @escaping (AgentToolDetails.Location) -> Void) -> OpenURLAction {
        OpenURLAction { url in
            guard case .file(let location, _) = AgentMarkdownLink(url) else { return .systemAction }
            onOpenFile(location)
            return .handled
        }
    }

    @MainActor private static var githubMarks: [CGFloat: NSImage] = [:]

    /// IntelliJ's GitHub vendor icon as a template image, tinted like the link text.
    @MainActor
    private static func githubMark(size: CGFloat) -> NSImage? {
        if let cached = githubMarks[size] { return cached }
        guard let source = LitheIcons.ideaImage(resourcePath: "vcs/vendors/github.svg"),
              let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size - 1, height: size - 1)
        image.isTemplate = true
        githubMarks[size] = image
        return image
    }
}
