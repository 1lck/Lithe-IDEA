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
}
