import Foundation

enum WorkspaceTextFilePolicy {
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
