import Foundation

/// 编辑器行级编辑快捷键背后的纯文本变换：给定源文本与 UTF-16 选区，产出
/// 替换文本、替换范围和需要恢复的选区。全部函数不触碰 AppKit，便于单元
/// 测试；NSTextView 接线在 CodeEditorView.swift。
enum LineEditingOperations {
    struct Edit: Equatable {
        /// 替换 replacedRange 区域的新文本（不是整个文档）
        let text: String
        /// 被替换的 UTF-16 范围（插入时 length 为 0）
        let replacedRange: NSRange
        /// 编辑完成后应恢复的选区
        let selection: NSRange
    }

    enum MoveDirection {
        case up
        case down
    }

    // MARK: - 注释符映射

    /// 按文件扩展名返回行注释符；首版覆盖常用语言，未知类型返回 nil，
    /// 此时 Cmd+/ 不拦截按键。
    static func lineCommentToken(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hxx", "java", "kt", "kts",
             "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "go", "rs",
             "cs", "php", "dart", "scala", "groovy", "m", "mm":
            return "//"
        case "py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml", "ini",
             "cfg", "conf", "properties", "env", "r", "pl":
            return "#"
        case "sql", "lua", "hs":
            return "--"
        default:
            return nil
        }
    }

    // MARK: - Cmd+/ 行注释切换

    /// 对选区覆盖的完整行切换行注释：任一非空行未注释则整体加注释，
    /// 全部已注释则整体去注释；空行在两个方向都跳过。
    static func toggleLineComment(
        in source: String,
        selection: NSRange,
        token: String
    ) -> Edit? {
        let ns = source as NSString
        let spans = coveredLines(for: selection, in: ns)
        guard let firstSpan = spans.first, let lastSpan = spans.last else { return nil }

        struct LineInfo {
            let contentStart: Int
            let content: String
            let firstContentOffset: Int
        }
        let lineInfos: [LineInfo] = spans.map { span in
            let content = ns.substring(with: span.range)
            let leadingWhitespace = content.prefix { $0 == " " || $0 == "\t" }
            return LineInfo(
                contentStart: span.range.location,
                content: content,
                firstContentOffset: leadingWhitespace.utf16.count
            )
        }
        let nonBlank = lineInfos.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !nonBlank.isEmpty else { return nil }

        struct PositionEdit {
            let position: Int
            let removedLength: Int
            let inserted: String
        }
        let tokenLength = (token as NSString).length
        let allCommented = nonBlank.allSatisfy { info in
            (info.content as NSString)
                .substring(from: info.firstContentOffset)
                .hasPrefix(token)
        }
        let positionEdits: [PositionEdit]
        if allCommented {
            positionEdits = nonBlank.map { info in
                let nsContent = info.content as NSString
                let tokenLocation = info.contentStart + info.firstContentOffset
                // 去注释时同时移除注释符后紧跟的一个空格
                var removedLength = tokenLength
                let afterToken = tokenLocation + tokenLength
                if afterToken < info.contentStart + (info.content as NSString).length,
                   nsContent.character(at: afterToken) == unichar(UnicodeScalar(" ").value) {
                    removedLength += 1
                }
                return PositionEdit(position: tokenLocation, removedLength: removedLength, inserted: "")
            }
        } else {
            positionEdits = nonBlank.map { info in
                PositionEdit(
                    position: info.contentStart + info.firstContentOffset,
                    removedLength: 0,
                    inserted: "\(token) "
                )
            }
        }

        let region = NSRange(
            location: firstSpan.range.location,
            length: NSMaxRange(lastSpan.range) - firstSpan.range.location
        )
        let rebuilt = NSMutableString(capacity: region.length + tokenLength)
        var cursor = region.location
        for edit in positionEdits {
            rebuilt.append(ns.substring(with: NSRange(location: cursor, length: edit.position - cursor)))
            rebuilt.append(edit.inserted)
            cursor = edit.position + edit.removedLength
        }
        rebuilt.append(ns.substring(with: NSRange(location: cursor, length: NSMaxRange(region) - cursor)))

        return Edit(
            text: rebuilt as String,
            replacedRange: region,
            selection: mapSelection(selection, edits: positionEdits.map {
                ($0.position, $0.removedLength, ($0.inserted as NSString).length)
            })
        )
    }

    // MARK: - Cmd+D 复制行 / 选区

    /// 无选区时复制光标所在整行并保持列位置；有选区时在选区之后原样
    /// 复制选中文本并选中新副本（与 IDEA 行为一致）。
    static func duplicate(in source: String, selection: NSRange) -> Edit? {
        let ns = source as NSString
        guard ns.length > 0 else { return nil }
        if selection.length > 0 {
            let selected = ns.substring(with: selection)
            let insertPosition = min(NSMaxRange(selection), ns.length)
            return Edit(
                text: selected,
                replacedRange: NSRange(location: insertPosition, length: 0),
                selection: NSRange(location: insertPosition, length: (selected as NSString).length)
            )
        }
        let bounds = lineBounds(at: selection.location, in: ns)
        let separatorLength = bounds.endWithSeparator - bounds.contentEnd
        let contentRange = NSRange(
            location: bounds.start,
            length: bounds.contentEnd - bounds.start
        )
        let content = ns.substring(with: contentRange)
        // 行尾已有换行符时沿用原分隔符；末行无换行符时补一个 \n 分隔
        let separator = separatorLength > 0
            ? ns.substring(with: NSRange(location: bounds.contentEnd, length: separatorLength))
            : "\n"
        let text: String
        if separatorLength > 0 {
            text = content + separator
        } else {
            text = separator + content
        }
        // 光标列 = 原列 + 行内容长度 + 分隔符长度，落到复制行的同列
        return Edit(
            text: text,
            replacedRange: NSRange(location: bounds.endWithSeparator, length: 0),
            selection: NSRange(
                location: selection.location + contentRange.length + (separator as NSString).length,
                length: 0
            )
        )
    }

    // MARK: - Option+Shift+↑/↓ 移动行

    /// 将选区覆盖的完整行作为整体与相邻行交换；光标与选区随行整体平移。
    static func moveLines(
        in source: String,
        selection: NSRange,
        direction: MoveDirection
    ) -> Edit? {
        let ns = source as NSString
        let spans = coveredLines(for: selection, in: ns)
        guard let first = spans.first, let last = spans.last else { return nil }
        let blockStart = first.range.location
        let lastBounds = lineBounds(at: last.range.location, in: ns)
        let blockEnd = lastBounds.endWithSeparator
        let blockContent = ns.substring(with: NSRange(location: blockStart, length: blockEnd - blockStart))
        let blockSeparatorLength = blockEnd - lastBounds.contentEnd

        let region: NSRange
        let text: String
        let displacement: Int
        switch direction {
        case .up:
            guard blockStart > 0 else { return nil }
            // blockStart-1 是上一行分隔符的末字符，lineBounds 归属上一行
            let aboveBounds = lineBounds(at: blockStart - 1, in: ns)
            let aboveStart = aboveBounds.start
            let aboveWithSeparator = ns.substring(
                with: NSRange(location: aboveStart, length: blockStart - aboveStart)
            )
            let aboveSeparatorLength = blockStart - aboveBounds.contentEnd
            let aboveContent = (aboveWithSeparator as NSString).substring(
                with: NSRange(location: 0, length: (aboveWithSeparator as NSString).length - aboveSeparatorLength)
            )
            let aboveSeparator = (aboveWithSeparator as NSString).substring(
                with: NSRange(
                    location: (aboveWithSeparator as NSString).length - aboveSeparatorLength,
                    length: aboveSeparatorLength
                )
            )
            region = NSRange(location: aboveStart, length: blockEnd - aboveStart)
            if blockSeparatorLength > 0 {
                // 常规交换：块与上一行都自带换行分隔符
                text = blockContent + aboveWithSeparator
            } else {
                // 块位于文件末尾且无换行符：原分隔符移到块与上一行之间
                text = blockContent + aboveSeparator + aboveContent
            }
            displacement = aboveStart - blockStart
        case .down:
            guard blockEnd < ns.length else { return nil }
            let belowBounds = lineBounds(at: blockEnd, in: ns)
            let belowEnd = belowBounds.endWithSeparator
            let belowWithSeparator = ns.substring(
                with: NSRange(location: blockEnd, length: belowEnd - blockEnd)
            )
            let belowSeparatorLength = belowEnd - belowBounds.contentEnd
            region = NSRange(location: blockStart, length: belowEnd - blockStart)
            if belowSeparatorLength > 0 {
                text = belowWithSeparator + blockContent
                displacement = belowEnd - blockEnd
            } else {
                // 下一行是末行且无换行符：块的分隔符移到下一行与块之间
                let blockContentWithoutSeparator = (blockContent as NSString).substring(
                    with: NSRange(location: 0, length: (blockContent as NSString).length - blockSeparatorLength)
                )
                let blockSeparator = (blockContent as NSString).substring(
                    with: NSRange(
                        location: (blockContent as NSString).length - blockSeparatorLength,
                        length: blockSeparatorLength
                    )
                )
                text = belowWithSeparator + blockSeparator + blockContentWithoutSeparator
                displacement = belowEnd - blockEnd + blockSeparatorLength
            }
        }

        return Edit(
            text: text,
            replacedRange: region,
            selection: NSRange(
                location: selection.location + displacement,
                length: selection.length
            )
        )
    }

    // MARK: - 行范围工具

    /// 行内容范围，不含行尾换行分隔符。
    private struct LineSpan {
        let range: NSRange
    }

    /// 一行的边界：内容起止与含换行分隔符的结束位置。
    private struct LineBounds {
        let start: Int
        let contentEnd: Int
        let endWithSeparator: Int
    }

    private static func isSeparator(_ char: unichar) -> Bool {
        char == unichar(0x0A) || char == unichar(0x0D)
    }

    /// 指定下标处分隔符的长度（\r\n 为 2，\n 或 \r 为 1）。
    private static func separatorLength(_ source: NSString, at index: Int) -> Int {
        if source.character(at: index) == unichar(0x0D),
           index + 1 < source.length,
           source.character(at: index + 1) == unichar(0x0A) {
            return 2
        }
        return 1
    }

    /// offset 所在行的边界。光标落在换行分隔符上时归属该分隔符终止的行；
    /// offset 位于 EOF 时返回最后一个分隔符之后的空行。
    /// 不使用 NSString.lineRange(for:)：它对落在行边界上的空 range 的归属
    /// 语义不明确，这里手工扫描保证确定性。
    private static func lineBounds(at offset: Int, in source: NSString) -> LineBounds {
        let length = source.length
        let location = min(max(offset, 0), length)
        if location == length {
            var start = 0
            var index = length - 1
            while index >= 0 {
                if isSeparator(source.character(at: index)) {
                    var separatorStart = index
                    if source.character(at: index) == unichar(0x0A),
                       index > 0,
                       source.character(at: index - 1) == unichar(0x0D) {
                        separatorStart = index - 1
                    }
                    start = separatorStart + separatorLength(source, at: separatorStart)
                    break
                }
                index -= 1
            }
            return LineBounds(start: start, contentEnd: length, endWithSeparator: length)
        }
        let separatorStart: Int
        if isSeparator(source.character(at: location)) {
            // \r\n 的 \n 部分归属同一行，分隔符起点回退到 \r
            if source.character(at: location) == unichar(0x0A),
               location > 0,
               source.character(at: location - 1) == unichar(0x0D) {
                separatorStart = location - 1
            } else {
                separatorStart = location
            }
        } else {
            var index = location
            while index < length, !isSeparator(source.character(at: index)) {
                index += 1
            }
            separatorStart = index
        }
        let separatorEnd = separatorStart < length
            ? separatorStart + separatorLength(source, at: separatorStart)
            : length
        var start = 0
        var index = separatorStart - 1
        while index >= 0 {
            if isSeparator(source.character(at: index)) {
                var separatorStartIndex = index
                if source.character(at: index) == unichar(0x0A),
                   index > 0,
                   source.character(at: index - 1) == unichar(0x0D) {
                    separatorStartIndex = index - 1
                }
                start = separatorStartIndex + separatorLength(source, at: separatorStartIndex)
                break
            }
            index -= 1
        }
        return LineBounds(start: start, contentEnd: separatorStart, endWithSeparator: separatorEnd)
    }

    private static func isLineStart(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0 else { return true }
        return isSeparator(source.character(at: offset - 1))
    }

    /// 选区覆盖的完整行：起点取选区起始处所在行的行首；选区终点恰好落在
    /// 某行行首时该行不计入（与 IDEA 的行级操作语义一致）。
    private static func coveredLines(for selection: NSRange, in source: NSString) -> [LineSpan] {
        let length = source.length
        guard length > 0 else { return [] }
        var bounds = lineBounds(at: selection.location, in: source)
        var end = min(max(NSMaxRange(selection), 0), length)
        if selection.length > 0, end > bounds.start, isLineStart(end, in: source) {
            end = lineBounds(at: end - 1, in: source).start
        }
        var spans: [LineSpan] = []
        while true {
            spans.append(
                LineSpan(
                    range: NSRange(
                        location: bounds.start,
                        length: bounds.contentEnd - bounds.start
                    )
                )
            )
            if bounds.endWithSeparator >= end || bounds.endWithSeparator >= length { break }
            bounds = lineBounds(at: bounds.endWithSeparator, in: source)
        }
        return spans
    }

    /// 注释切换后的选区映射：插入点之前的偏移不动，之后的按增量平移；
    /// 落在删除区间内部的偏移收紧到删除起点。
    private static func mapSelection(
        _ selection: NSRange,
        edits: [(position: Int, removedLength: Int, insertedLength: Int)]
    ) -> NSRange {
        func mapOffset(_ offset: Int) -> Int {
            var mapped = offset
            for edit in edits {
                if edit.removedLength == 0 {
                    if offset > edit.position {
                        mapped += edit.insertedLength
                    }
                } else if offset >= edit.position + edit.removedLength {
                    mapped -= edit.removedLength
                } else if offset > edit.position {
                    mapped = edit.position
                }
            }
            return mapped
        }
        var location = mapOffset(min(selection.location, NSMaxRange(selection)))
        let maxLocation = mapOffset(NSMaxRange(selection))
        if location > maxLocation {
            location = maxLocation
        }
        return NSRange(location: location, length: maxLocation - location)
    }
}
