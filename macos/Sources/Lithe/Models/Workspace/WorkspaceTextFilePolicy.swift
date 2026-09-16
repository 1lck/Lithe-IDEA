import Foundation

enum WorkspaceTextFilePolicy {
    static let standaloneFileByteLimit = 32 * 1024 * 1024

    private static let extensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
        "jsx", "kt", "kts", "md", "m", "mm", "php", "plist", "properties", "py", "rb",
        "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]

    static func isReadableTextFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty
    }

    /// Reject the control characters that are strong indicators of binary
    /// data while allowing normal whitespace such as tabs and newlines.
    static func isPlainText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value != 0 &&
                !(value < 0x09 || (value > 0x0D && value < 0x20) || value == 0x7F)
        }
    }

    static func isPlainText(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return isPlainText(text)
    }

    /// Validates a bounded file prefix while allowing up to three look-ahead
    /// bytes to complete a UTF-8 scalar split at the sampling boundary.
    static func isPlainTextPrefix(_ data: Data, byteLimit: Int) -> Bool {
        guard byteLimit > 0 else { return data.isEmpty }
        let maximumCount = min(data.count, byteLimit + 3)
        let minimumCount = min(data.count, byteLimit)
        for count in minimumCount...maximumCount {
            let candidate = data.prefix(count)
            if let text = String(data: candidate, encoding: .utf8) {
                return isPlainText(text)
            }
        }
        return false
    }
}
