import Foundation

enum WorkspaceTextFilePolicy {
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
}
