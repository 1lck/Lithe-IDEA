import Foundation

/// “Go to Line”输入的解析与文档范围收敛。输入是 1-based 的“120”或
/// “120:35”文本，解析结果为内部 0-based 行列；1-based → 0-based 的换算
/// 只发生在这里，状态栏显示时再 +1，避免多处偏移。
struct GoToLineInput: Equatable {
    let line: Int
    let column: Int

    /// 解析“120”、“120:35”或两侧带空格的等价输入；空串、非数字、多冒号、
    /// 0 与负数都视为非法，返回 `nil` 表示本次跳转应为无操作。
    static func parse(_ text: String) -> GoToLineInput? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let line = oneBasedNumber(in: parts[0]) else { return nil }
        let column = parts.count == 2 ? oneBasedNumber(in: parts[1]) : 1
        guard let column else { return nil }
        return GoToLineInput(line: line - 1, column: column - 1)
    }

    /// 将 0-based 行列收敛到文档内容范围内：行超出收敛到最后一行，列超出
    /// 收敛到行尾，负值收敛到 0；空文档只定位到文档开头。跳转前必须用
    /// 当前文档文本重新收敛，不做陈旧行数缓存。
    static func clamped(line: Int, column: Int, in content: String) -> GoToLineInput {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let clampedLine = min(max(line, 0), lines.count - 1)
        let lineLength = lines[clampedLine].utf16.count
        return GoToLineInput(line: clampedLine, column: min(max(column, 0), lineLength))
    }

    private static func oneBasedNumber(in part: Substring) -> Int? {
        guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            return nil
        }
        return value
    }
}
