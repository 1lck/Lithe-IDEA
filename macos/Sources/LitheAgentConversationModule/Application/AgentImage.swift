import CryptoKit
import Foundation
import ImageIO

/// An image the Agent produced or the user attached, shown beside the tool call
/// or message that carries it. Inline bytes stay bounded; file references are
/// decoded lazily by the view layer so replaying a long history never decodes pixels.
public struct AgentImage: Identifiable, Equatable, Sendable {
    public enum Source: Sendable {
        case data(Data)
        /// Absolute path of an image on disk, such as a screenshot the Agent read.
        case file(String)
    }

    public let id: String
    public var title: String?
    public let source: Source

    /// Larger payloads are dropped: they would sit in the transcript state for the whole session.
    public static let maximumBytes = 10_000_000
    /// One tool result rarely returns more; the cap keeps a runaway tool from filling memory.
    public static let maximumPerMessage = 24
    public static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "bmp"]

    public init(data: Data, title: String? = nil) {
        self.id = "data:\(data.count):\(Self.fingerprint(data))"
        self.title = title
        self.source = .data(data)
    }

    public init(filePath: String, title: String? = nil) {
        self.id = "file:\(filePath)"
        self.title = title ?? (filePath as NSString).lastPathComponent
        self.source = .file(filePath)
    }

    // Identity is the content fingerprint or path; comparing megabytes of pixels
    // on every transcript diff would make scrolling pay for each image.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title }

    public static func isImageFile(_ path: String) -> Bool {
        fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Reads an ACP `image` content block: base64 `data` with `mimeType`, or a local `file:` `uri`.
    static func parse(block: [String: Any]) -> Self? {
        guard block["type"] as? String == "image" else { return nil }
        let uri = block["uri"] as? String
        let uriTitle = uri.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        if let encoded = block["data"] as? String, !encoded.isEmpty {
            let mime = (block["mimeType"] as? String)?.lowercased()
            if let mime, !mime.hasPrefix("image/") { return nil }
            // Base64 inflates by a third; refuse before allocating the decoded copy.
            guard encoded.utf8.count <= maximumBytes / 3 * 4,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty,
                  data.count <= maximumBytes, isDecodable(data) else { return nil }
            return Self(data: data, title: uriTitle)
        }
        if let uri, let url = URL(string: uri), url.isFileURL, isImageFile(url.path) {
            return Self(filePath: url.path)
        }
        return nil
    }

    /// Reads only the container header, so a payload that no decoder recognises
    /// never becomes a thumbnail that stays blank.
    private static func isDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// SHA-256 is hardware accelerated, so even a 10 MB payload hashes in a few
    /// milliseconds on the main actor; a byte loop over `Data` is far slower.
    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

extension Sequence where Element == AgentImage {
    /// Keeps the first of each id. `ForEach` and the viewer's paging need unique ids,
    /// and the same screenshot read twice would otherwise appear twice.
    public var uniquedByID: [AgentImage] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// A user message's text split from the image attachments it lists.
public struct AgentUserMessageContent: Equatable, Sendable {
    public var text: String
    public var images: [AgentImage]
    /// Image references beyond `AgentImage.maximumPerMessage`: removed from the text, not shown.
    public var hiddenImageCount = 0

    private static let attachmentMarker = "📎 "

    /// `[@name](file:///path.png)` as Claude Code replays a referenced file, or a bare `file://` URL.
    private static let fileLink = try! NSRegularExpression(
        pattern: #"(?:\[[^\]\n]*\]\((file://[^)\n]+)\)|(file://[^\s)\]]+))"#)

    /// Claude Code's image placeholders: `[Image: source: /path]` names the file,
    /// `[Image: original 3840x2486, displayed at ...]` only helps the model map coordinates.
    private static let imagePlaceholder = try! NSRegularExpression(
        pattern: #"\[Image: (?:source: ([^\]\n]+)|original [^\]\n]*)\]"#)

    /// The composer's `📎 /path` line, with its line break.
    private static let attachmentLine = try! NSRegularExpression(pattern: "^📎 ([^\\n]*)(?:\\n|$)", options: .anchorsMatchLines)

    /// One image reference found in the message: where it sits and the file it names.
    /// `path` is nil for a placeholder that carries no file; it is removed without a thumbnail.
    private struct Reference {
        var range: NSRange
        var path: String?
    }

    /// Image attachments become thumbnails; other attachments and the user's own
    /// words stay as text. Two shapes occur: the composer's `📎 /path` lines, and
    /// file links (`[@name](file:///path)`, bare `file://` URLs) that an agent
    /// replays for a referenced file, which would otherwise show as raw addresses.
    public static func parse(_ message: String) -> Self {
        guard message.contains(attachmentMarker) || message.contains("file://") || message.contains("[Image: ") else {
            return Self(text: message, images: [])
        }
        let ns = message as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func isImagePath(_ path: String) -> Bool { path.hasPrefix("/") && AgentImage.isImageFile(path) }
        func path(ofFileURL raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed), url.isFileURL { return url.path }
            // An unencoded space makes the address an invalid URL; decode it by hand.
            return trimmed.hasPrefix("file://") ? String(trimmed.dropFirst("file://".count)).removingPercentEncoding : nil
        }

        // Every candidate is located in the original text, so thumbnails follow reading order.
        var found: [Reference] = []
        for match in fileLink.matches(in: message, range: whole) {
            let raw = ns.substring(with: match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2))
            if let filePath = path(ofFileURL: raw), isImagePath(filePath) { found.append(Reference(range: match.range, path: filePath)) }
        }
        for match in imagePlaceholder.matches(in: message, range: whole) {
            let source = match.range(at: 1)
            if source.location == NSNotFound {
                found.append(Reference(range: match.range, path: nil))
            } else if isImagePath(ns.substring(with: source)) {
                found.append(Reference(range: match.range, path: ns.substring(with: source)))
            }
        }
        for match in attachmentLine.matches(in: message, range: whole) {
            let value = ns.substring(with: match.range(at: 1))
            if isImagePath(value) { found.append(Reference(range: match.range, path: value)) }
        }
        found.sort { $0.range.location < $1.range.location }

        var images: [AgentImage] = []
        var seen = Set<String>()
        var hidden = 0
        var removed: [NSRange] = []
        for reference in found {
            // An earlier reference already claimed this text (a link inside a 📎 line).
            if let last = removed.last, NSMaxRange(last) > reference.range.location { continue }
            if let path = reference.path {
                if seen.insert((path as NSString).standardizingPath).inserted {
                    if images.count < AgentImage.maximumPerMessage { images.append(AgentImage(filePath: path)) } else { hidden += 1 }
                }
            }
            removed.append(reference.range)
        }
        guard !removed.isEmpty else { return Self(text: message, images: []) }
        var working = message
        for range in removed.reversed() {
            if let swift = Range(range, in: working) { working.replaceSubrange(swift, with: "") }
        }
        guard !images.isEmpty || hidden > 0 else { return Self(text: message, images: []) }
        let text = working.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(text: text, images: images, hiddenImageCount: hidden)
    }
}

/// Claude Code reports finished background work as a `<task-notification>` block
/// inside a user message. It is protocol markup, not something the user typed.
public struct AgentTaskNotification: Equatable, Sendable {
    public var taskID: String?
    public var status: String?
    public var summary: String?
    public var outputFile: String?

    /// Statuses that mean the task did not finish normally.
    public var isFailure: Bool {
        ["failed", "error", "killed", "stopped"].contains(status?.lowercased() ?? "")
    }

    /// Nil unless the whole message consists of one or more notification blocks.
    public static func parse(_ message: String) -> [Self]? {
        let open = "<task-notification>", close = "</task-notification>"
        var rest = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.hasPrefix(open) else { return nil }
        var result: [Self] = []
        while !rest.isEmpty {
            guard rest.hasPrefix(open), let end = rest.range(of: close) else { return nil }
            let body = String(rest[rest.index(rest.startIndex, offsetBy: open.count)..<end.lowerBound])
            result.append(Self(taskID: tag("task-id", in: body), status: tag("status", in: body),
                               summary: tag("summary", in: body), outputFile: tag("output-file", in: body)))
            rest = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    private static func tag(_ name: String, in body: String) -> String? {
        guard let start = body.range(of: "<\(name)>"),
              let end = body.range(of: "</\(name)>", range: start.upperBound..<body.endIndex) else { return nil }
        let value = body[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// One visible item of a user message that Claude Code filled with its own markup.
public enum AgentClaudeCodeEntry: Equatable, Sendable {
    case taskNotification(AgentTaskNotification)
    /// A slash command the user ran, such as `/clear`, with its arguments.
    case command(name: String, arguments: String?)
    /// Output of a local command or shell escape; `isError` for stderr.
    case output(String, isError: Bool)
    /// A shell escape typed with `!`.
    case shell(String)
    /// `[Request interrupted by user]` and its variants.
    case interrupted(String)
    /// The recap Claude Code inserts when a conversation outgrows its context.
    case summary(String, tools: String?)
    /// A skill's instructions, expanded into the conversation when the skill is invoked.
    case skill(name: String, body: String)
    /// Context injected by a host application, kept collapsed.
    case context(name: String, body: String)
}

/// Claude Code stores slash commands, local command output, shell escapes,
/// compaction summaries and reminders for the model as user messages, some wrapped
/// in pseudo-XML. Those are not what the user typed, so they are rendered as quiet
/// status lines or collapsed blocks, or hidden when they only instruct the model.
public enum AgentClaudeCodeMarkup {
    /// Wrappers that exist only for the model; they produce no entry.
    private static let hiddenTags = ["local-command-caveat", "system-reminder", "user-prompt-submit-hook"]
    /// Wrappers whose whole body is shown collapsed, with the tag as its name.
    private static let contextTags: Set<String> = [
        "lithe_workspace_context", "side-sessions-event", "create-pr-command", "ci-monitor-event",
    ]
    /// Claude Desktop's harness notices about other sessions, written as `[Label] text`.
    private static let desktopNotices = ["Cross-session idle notice", "Cross-session delivery notice", "handback-send-enforce"]
    private static let knownTags: Set<String> = contextTags.union([
        "task-notification", "command-name", "command-message", "command-args",
        "local-command-stdout", "local-command-stderr", "bash-input", "bash-stdout", "bash-stderr",
    ])
    private static let summaryPrefix = "This session is being continued from a previous conversation"
    private static let skillPrefix = "Base directory for this skill:"
    /// Removes model-only blocks that open or close the message, which is where
    /// Claude Code adds them. A block the user quoted in the middle of their own
    /// words stays, so what they typed is never swallowed.
    public static func removingModelOnlyBlocks(_ message: String) -> String {
        guard hiddenTags.contains(where: { message.contains("<\($0)>") }) else { return message }
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedAny = true
        while removedAny {
            removedAny = false
            for tag in hiddenTags {
                let open = "<\(tag)>", close = "</\(tag)>"
                if text.hasPrefix(open), let end = text.range(of: close) {
                    text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    removedAny = true
                } else if text.hasSuffix(close), let start = text.range(of: open, options: .backwards),
                          !text[start.upperBound...].dropLast(close.count).contains(close) {
                    text = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    removedAny = true
                }
            }
        }
        return text
    }


    /// Nil unless the whole message is Claude Code markup. An empty result means
    /// the message is entirely model-only and should not be shown.
    public static func parse(_ message: String) -> [AgentClaudeCodeEntry]? {
        let stripped = removingModelOnlyBlocks(message)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return stripped == message ? nil : [] }
        if trimmed.hasPrefix("[Request interrupted by user"), trimmed.hasSuffix("]"), !trimmed.contains("\n") {
            return [.interrupted(String(trimmed.dropFirst().dropLast()))]
        }
        if trimmed.hasPrefix(summaryPrefix) { return [summary(trimmed)] }
        if let notice = desktopNotices.first(where: { trimmed.hasPrefix("[\($0)]") }) {
            let body = trimmed.dropFirst(notice.count + 2).trimmingCharacters(in: .whitespacesAndNewlines)
            return [.context(name: notice, body: body.isEmpty ? trimmed : body)]
        }
        if trimmed.hasPrefix(skillPrefix) {
            let first = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
            let directory = first.dropFirst(skillPrefix.count).trimmingCharacters(in: .whitespaces)
            return [.skill(name: (directory as NSString).lastPathComponent, body: trimmed)]
        }
        var rest = Substring(trimmed)
        var entries: [AgentClaudeCodeEntry] = []
        var commandName: String?
        var commandArguments: String?
        func flushCommand() {
            if let name = commandName { entries.append(.command(name: name, arguments: commandArguments)) }
            commandName = nil
            commandArguments = nil
        }
        while !rest.isEmpty {
            guard rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") else { return nil }
            // Desktop's event wrappers can carry attributes, such as the pull request a CI event is about.
            let opening = rest[rest.index(after: rest.startIndex)..<close]
            let tag = String(opening.prefix { !$0.isWhitespace })
            guard knownTags.contains(tag), tag == opening || contextTags.contains(tag), let end = rest.range(of: "</\(tag)>") else { return nil }
            let body = String(rest[rest.index(after: close)..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "task-notification":
                flushCommand()
                if let parsed = AgentTaskNotification.parse("<\(tag)>\(body)</\(tag)>")?.first {
                    entries.append(.taskNotification(parsed))
                }
            case "command-name":
                flushCommand()
                if !body.isEmpty { commandName = body }
            case "command-args":
                if !body.isEmpty { commandArguments = body }
            case "command-message":
                break
            case "local-command-stdout", "bash-stdout":
                flushCommand()
                if !body.isEmpty { entries.append(.output(body, isError: false)) }
            case "local-command-stderr", "bash-stderr":
                flushCommand()
                if !body.isEmpty { entries.append(.output(body, isError: true)) }
            case "bash-input":
                flushCommand()
                if !body.isEmpty { entries.append(.shell(body)) }
            default:
                flushCommand()
                if contextTags.contains(tag), !body.isEmpty { entries.append(.context(name: tag, body: body)) }
            }
            rest = rest[end.upperBound...]
            while let first = rest.first, first.isWhitespace { rest = rest.dropFirst() }
        }
        flushCommand()
        return entries
    }

    /// The recap text without its `<tools-used-before-summary>` header line.
    private static func summary(_ text: String) -> AgentClaudeCodeEntry {
        let open = "<tools-used-before-summary>", close = "</tools-used-before-summary>"
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
            return .summary(text, tools: nil)
        }
        let tools = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text
        body.removeSubrange(start.lowerBound..<end.upperBound)
        return .summary(body.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), tools: tools.isEmpty ? nil : tools)
    }
}
