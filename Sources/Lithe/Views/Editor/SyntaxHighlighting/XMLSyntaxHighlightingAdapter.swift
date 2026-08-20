import AppKit

/// Performs lightweight XML tag, attribute, value, declaration, and comment highlighting.
enum XMLSyntaxHighlightingAdapter {
    private static let declarationExpression = expression(
        #"<\?(?:[A-Za-z_][A-Za-z0-9_.:-]*)|<!DOCTYPE\b"#,
        options: [.caseInsensitive]
    )
    private static let cdataExpression = expression(#"<!\[CDATA\[[\s\S]*?\]\]>"#)
    private static let commentExpression = expression(#"<!--[\s\S]*?-->"#)

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) {
        let source = storage.string as NSString
        apply(declarationExpression, color: palette.annotation, storage: storage, source: source, range: target)
        apply(cdataExpression, color: palette.string, storage: storage, source: source, range: target)
        apply(commentExpression, color: palette.comment, storage: storage, source: source, range: target)
        applyTagsAndAttributes(in: source, storage: storage, palette: palette, target: target)
    }

    private static func applyTagsAndAttributes(
        in source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange
    ) {
        var cursor = 0
        while cursor < source.length {
            guard source.character(at: cursor) == 60 else {
                cursor += 1
                continue
            }

            if hasPrefix("<!--", in: source, at: cursor) {
                cursor = end(of: "-->", in: source, from: cursor + 4)
                continue
            }
            if hasPrefix("<![CDATA[", in: source, at: cursor) {
                cursor = end(of: "]]>", in: source, from: cursor + 9)
                continue
            }
            if hasPrefix("<?", in: source, at: cursor) {
                cursor = end(of: "?>", in: source, from: cursor + 2)
                continue
            }
            if hasPrefix("<!DOCTYPE", in: source, at: cursor, options: [.caseInsensitive]) {
                cursor = doctypeEnd(in: source, from: cursor + 9)
                continue
            }

            guard let tag = tagRange(in: source, from: cursor) else {
                cursor += 1
                continue
            }
            applyTag(tag, in: source, storage: storage, palette: palette, target: target)
            cursor = NSMaxRange(tag.range)
        }
    }

    private static func applyTag(
        _ tag: Tag,
        in source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange
    ) {
        addColor(palette.type, to: storage, range: tag.nameRange, limitedTo: target)
        guard !tag.isClosing else { return }

        var cursor = NSMaxRange(tag.nameRange)
        let limit = NSMaxRange(tag.range) - 1
        while cursor < limit {
            let character = source.character(at: cursor)
            if character == 34 || character == 39 {
                cursor = quotedEnd(in: source, from: cursor, limit: limit)
                continue
            }
            guard isNameStart(character) else {
                cursor += 1
                continue
            }

            let nameStart = cursor
            cursor += 1
            while cursor < limit, isNameCharacter(source.character(at: cursor)) {
                cursor += 1
            }
            let nameRange = NSRange(location: nameStart, length: cursor - nameStart)
            var lookahead = cursor
            while lookahead < limit, isWhitespace(source.character(at: lookahead)) { lookahead += 1 }
            guard lookahead < limit, source.character(at: lookahead) == 61 else { continue }
            addColor(palette.property, to: storage, range: nameRange, limitedTo: target)

            var valueStart = lookahead + 1
            while valueStart < limit, isWhitespace(source.character(at: valueStart)) { valueStart += 1 }
            guard valueStart < limit else { continue }
            let quote = source.character(at: valueStart)
            guard quote == 34 || quote == 39 else {
                cursor = valueStart
                continue
            }
            let valueEnd = quotedEnd(in: source, from: valueStart, limit: limit)
            addColor(
                palette.string,
                to: storage,
                range: NSRange(location: valueStart, length: valueEnd - valueStart),
                limitedTo: target
            )
            cursor = valueEnd
        }
    }

    private struct Tag {
        let range: NSRange
        let nameRange: NSRange
        let isClosing: Bool
    }

    private static func tagRange(in source: NSString, from start: Int) -> Tag? {
        var cursor = start + 1
        var isClosing = false
        if cursor < source.length, source.character(at: cursor) == 47 {
            isClosing = true
            cursor += 1
        }
        while cursor < source.length, isWhitespace(source.character(at: cursor)) { cursor += 1 }
        guard cursor < source.length, isNameStart(source.character(at: cursor)) else { return nil }

        let nameStart = cursor
        cursor += 1
        while cursor < source.length, isNameCharacter(source.character(at: cursor)) { cursor += 1 }
        let nameRange = NSRange(location: nameStart, length: cursor - nameStart)
        let tagEnd = quotedAwareEnd(in: source, from: cursor)
        guard tagEnd < source.length else { return nil }
        return Tag(
            range: NSRange(location: start, length: tagEnd - start + 1),
            nameRange: nameRange,
            isClosing: isClosing
        )
    }

    private static func quotedAwareEnd(in source: NSString, from start: Int) -> Int {
        var cursor = start
        var quote: unichar = 0
        while cursor < source.length {
            let character = source.character(at: cursor)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 62 {
                return cursor
            }
            cursor += 1
        }
        return source.length
    }

    private static func quotedEnd(in source: NSString, from start: Int, limit: Int) -> Int {
        let quote = source.character(at: start)
        var cursor = start + 1
        while cursor < limit {
            if source.character(at: cursor) == quote { return cursor + 1 }
            cursor += 1
        }
        return limit
    }

    private static func doctypeEnd(in source: NSString, from start: Int) -> Int {
        var cursor = start
        var quote: unichar = 0
        var bracketDepth = 0
        while cursor < source.length {
            let character = source.character(at: cursor)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 91 {
                bracketDepth += 1
            } else if character == 93 {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == 62 && bracketDepth == 0 {
                return cursor + 1
            }
            cursor += 1
        }
        return source.length
    }

    private static func end(of terminator: String, in source: NSString, from start: Int) -> Int {
        let searchRange = NSRange(location: min(start, source.length), length: max(0, source.length - start))
        let found = source.range(of: terminator, options: [], range: searchRange)
        return found.location == NSNotFound ? source.length : NSMaxRange(found)
    }

    private static func hasPrefix(
        _ value: String,
        in source: NSString,
        at location: Int,
        options: NSString.CompareOptions = []
    ) -> Bool {
        let length = value.utf16.count
        guard location >= 0, location + length <= source.length else { return false }
        return source.substring(with: NSRange(location: location, length: length))
            .compare(value, options: options) == .orderedSame
    }

    private static func isNameStart(_ character: unichar) -> Bool {
        character == 58 || character == 95 || (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private static func isNameCharacter(_ character: unichar) -> Bool {
        isNameStart(character) || character == 45 || character == 46 || (character >= 48 && character <= 57)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 10 || character == 13 || character == 32
    }

    private static func addColor(_ color: NSColor, to storage: NSTextStorage, range: NSRange, limitedTo target: NSRange) {
        let affectedRange = NSIntersectionRange(range, target)
        guard affectedRange.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: affectedRange)
    }

    private static func apply(
        _ expression: NSRegularExpression,
        captureGroup: Int = 0,
        color: NSColor,
        storage: NSTextStorage,
        source: NSString,
        range: NSRange
    ) {
        expression.enumerateMatches(in: source as String, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            addColor(color, to: storage, range: match.range(at: captureGroup), limitedTo: range)
        }
    }

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
