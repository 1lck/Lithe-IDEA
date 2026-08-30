import Foundation

/// 文件内查找的匹配选项：Match Case、Whole Words、Regular Expression。
/// 三个选项默认全部关闭，保持既有的大小写与音调不敏感行为。
struct FindInFileOptions: Equatable, Sendable {
    var matchCase = false
    var wholeWords = false
    var regularExpression = false

    static let `default` = FindInFileOptions()
}

/// 按选项枚举文件内匹配并展开替换模板的纯 Foundation 值类型。
/// 不依赖 AppKit，保证匹配结果可确定、可单测。
struct FindInFileMatcher {
    let query: String
    let options: FindInFileOptions

    /// 正则模式编译失败时为 false；其余模式始终有效。
    var isValid: Bool {
        !options.regularExpression || expression != nil
    }

    /// 仅正则模式使用；字面量扫描走 NSString 比较。
    private let expression: NSRegularExpression?

    init(query: String, options: FindInFileOptions) {
        self.query = query
        self.options = options
        if options.regularExpression {
            // Whole Words 与正则同时开启时按设计外包一层 \b(?:…)\b；
            // 使用非捕获分组，保持模板中 $1 等分组编号不变。
            let pattern = options.wholeWords ? "\\b(?:\(query))\\b" : query
            self.expression = try? NSRegularExpression(
                pattern: pattern,
                options: options.matchCase ? [] : [.caseInsensitive]
            )
        } else {
            self.expression = nil
        }
    }

    /// 枚举全文匹配：升序、互不重叠、跳过零宽度匹配。
    func matchRanges(in source: NSString) -> [NSRange] {
        matchRanges(in: source, range: NSRange(location: 0, length: source.length))
    }

    /// 枚举指定范围内的匹配。枚举以全文为底、仅限制范围，
    /// 使 \b 与词边界校验始终基于真实上下文而不是窗口局部文本。
    func matchRanges(in source: NSString, range: NSRange) -> [NSRange] {
        guard !query.isEmpty, range.location >= 0, NSMaxRange(range) <= source.length else { return [] }
        if let expression {
            return regexMatchRanges(expression: expression, in: source, range: range)
        }
        return literalMatchRanges(in: source, range: range)
    }

    /// 展开替换模板：正则模式按 NSRegularExpression 语义（$1、${name}），
    /// 字面量模式原样返回。匹配列表与当前文本不一致时按字面量处理。
    func replacement(for source: NSString, matchRange: NSRange, template: String) -> String {
        guard let expression else { return template }
        let searchRange = NSRange(
            location: matchRange.location,
            length: max(0, source.length - matchRange.location)
        )
        guard let match = expression.firstMatch(in: source as String, range: searchRange),
              match.range == matchRange else {
            return template
        }
        // offset 仅锚定模板中的 \G；$n / ${name} 展开不受影响
        return expression.replacementString(for: match, in: source as String, offset: 0, template: template)
    }

    private func regexMatchRanges(
        expression: NSRegularExpression,
        in source: NSString,
        range: NSRange
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        expression.enumerateMatches(in: source as String, options: [], range: range) { match, _, _ in
            guard let match else { return }
            // 零宽度匹配（如 a*）不参与高亮和替换
            guard match.range.length > 0 else { return }
            ranges.append(match.range)
        }
        return ranges
    }

    private func literalMatchRanges(in source: NSString, range: NSRange) -> [NSRange] {
        let compareOptions: String.CompareOptions = options.matchCase
            ? []
            : [.caseInsensitive, .diacriticInsensitive]
        var ranges: [NSRange] = []
        var cursor = range
        while cursor.length > 0 {
            let found = source.range(of: query, options: compareOptions, range: cursor)
            guard found.location != NSNotFound else { break }
            if !options.wholeWords || isWholeWordMatch(found, in: source) {
                ranges.append(found)
                cursor.location = NSMaxRange(found)
            } else {
                // 拒绝候选后从下一字符继续，保证重叠位置的合法匹配不被漏掉
                cursor.location = found.location + 1
            }
            cursor.length = max(0, NSMaxRange(range) - cursor.location)
        }
        return ranges
    }

    /// 全词判定：匹配两侧都不是词字符（串首串尾视为边界）。
    private func isWholeWordMatch(_ range: NSRange, in source: NSString) -> Bool {
        !Self.isWordCharacter(at: range.location - 1, in: source)
            && !Self.isWordCharacter(at: NSMaxRange(range), in: source)
    }

    /// 词字符 = 字母、数字和下划线；越界（串首串尾）返回 false。
    /// 按 UTF-16 位置判断，必要时组合代理对还原完整字符后再分类。
    private static func isWordCharacter(at index: Int, in source: NSString) -> Bool {
        guard index >= 0, index < source.length else { return false }
        var value = UInt32(source.character(at: index))
        if (0xDC00...0xDFFF).contains(value), index > 0 {
            // 低代理半区：与前面的高代理组合成完整字符
            let previous = UInt32(source.character(at: index - 1))
            guard (0xD800...0xDBFF).contains(previous) else { return false }
            value = 0x10000 + (previous - 0xD800) * 0x400 + (value - 0xDC00)
        } else if (0xD800...0xDBFF).contains(value), index + 1 < source.length {
            let next = UInt32(source.character(at: index + 1))
            guard (0xDC00...0xDFFF).contains(next) else { return false }
            value = 0x10000 + (value - 0xD800) * 0x400 + (next - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar == "_"
            || scalar.properties.isAlphabetic
            || scalar.properties.numericType != nil
    }
}
