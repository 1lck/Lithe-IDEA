import Foundation

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
            if let mime = block["mimeType"] as? String, !mime.lowercased().hasPrefix("image/") { return nil }
            // Base64 inflates by a third; refuse before allocating the decoded copy.
            guard encoded.utf8.count <= maximumBytes / 3 * 4,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty,
                  data.count <= maximumBytes else { return nil }
            return Self(data: data, title: uriTitle)
        }
        if let uri, let url = URL(string: uri), url.isFileURL, isImageFile(url.path) {
            return Self(filePath: url.path)
        }
        return nil
    }

    /// FNV-1a over the bytes: stable within a run and cheap next to base64 decoding.
    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

/// A user message's text split from the image attachments it lists.
public struct AgentUserMessageContent: Equatable, Sendable {
    public var text: String
    public var images: [AgentImage]

    private static let attachmentMarker = "📎 "

    /// Composer prompts list attachments as `📎 /path` lines. Image files become
    /// thumbnails; other attachments and the user's own words stay as text.
    public static func parse(_ message: String) -> Self {
        guard message.contains(attachmentMarker) else { return Self(text: message, images: []) }
        var images: [AgentImage] = []
        var kept: [Substring] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(attachmentMarker) {
                let path = String(line.dropFirst(attachmentMarker.count))
                if path.hasPrefix("/"), AgentImage.isImageFile(path), images.count < AgentImage.maximumPerMessage {
                    images.append(AgentImage(filePath: path))
                    continue
                }
            }
            kept.append(line)
        }
        guard !images.isEmpty else { return Self(text: message, images: []) }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(text: text, images: images)
    }
}

/// Claude Code reports finished background work as a `<task-notification>` block
/// inside a user message. It is protocol markup, not something the user typed.
public struct AgentTaskNotification: Equatable, Sendable {
    public var taskID: String?
    public var status: String?
    public var summary: String?
    public var outputFile: String?

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
