import AppKit

/// Performs lightweight XML tag, attribute, value, declaration, and comment highlighting.
enum XMLSyntaxHighlightingAdapter {
    private enum ActiveConstructKind: String {
        case cdata
        case comment
        case doctype
        case processingInstruction
        case tag
    }

    private struct CachedLexicalState: Equatable {
        let activeKind: ActiveConstructKind?
        let distanceToStart: Int

        static let normal = CachedLexicalState(activeKind: nil, distanceToStart: 0)
    }

    private struct Construct {
        let kind: ActiveConstructKind
        let end: Int
        let isTerminated: Bool
    }

    private struct ScanResult {
        let lineCount: Int
        let end: Int
    }

    private struct CachedCheckpoint {
        let state: CachedLexicalState
        let lineEnd: Int
    }

    private static let lexicalStateAttribute = NSAttributedString.Key("lithe.xml.lexical-state")
    private static let checkpointLineInterval = 256

    @discardableResult
    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) -> Int {
        let source = storage.string as NSString
        guard source.length > 0, target.length > 0 else { return 0 }
        let targetStart = lineRange(containing: target.location, in: source).location
        let requiredEnd = NSMaxRange(
            lineRange(containing: max(target.location, NSMaxRange(target) - 1), in: source)
        )
        let cacheIsInitialized = cachedLexicalState(
            after: lineRange(containing: 0, in: source),
            in: storage
        ) != nil
        let checkpoint = cacheIsInitialized
            ? cachedCheckpoint(before: targetStart, source: source, storage: storage)
            : nil
        let shouldConverge = checkpoint != nil
        let scanStart: Int
        if let checkpoint {
            if checkpoint.state.activeKind != nil {
                scanStart = max(0, checkpoint.lineEnd - checkpoint.state.distanceToStart)
            } else {
                scanStart = checkpoint.lineEnd
            }
        } else {
            scanStart = 0
        }

        // Sparse line-ending checkpoints move with NSTextStorage edits. They bound
        // normal rescans without creating one attributed-string run per source line.
        let result = scan(
            source: source,
            storage: storage,
            palette: palette,
            target: target,
            from: scanStart,
            requiredEnd: requiredEnd,
            shouldConverge: shouldConverge
        )
        let propagationStart = NSMaxRange(target)
        if result.end > propagationStart {
            let propagationRange = NSRange(
                location: propagationStart,
                length: result.end - propagationStart
            )
            storage.addAttribute(.foregroundColor, value: palette.text, range: propagationRange)
            applyColors(
                source: source,
                storage: storage,
                palette: palette,
                target: propagationRange,
                from: scanStart,
                through: result.end
            )
        }
        return result.lineCount
    }

    private static func scan(
        source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange,
        from scanStart: Int,
        requiredEnd: Int,
        shouldConverge: Bool
    ) -> ScanResult {
        var cursor = scanStart
        var currentLine = lineRange(containing: scanStart, in: source)
        var scannedLineCount = 0
        var scannedEnd = scanStart
        var linesSinceCheckpoint = 0
        var stopped = false

        func finishCurrentLine(with state: CachedLexicalState) {
            let cachedExitState = cachedLexicalState(after: currentLine, in: storage)
            scannedLineCount += 1
            linesSinceCheckpoint += 1
            scannedEnd = NSMaxRange(currentLine)
            stopped = shouldStop(
                after: currentLine,
                requiredEnd: requiredEnd,
                shouldConverge: shouldConverge,
                cachedExitState: cachedExitState,
                state: state,
                sourceLength: source.length
            )
            if currentLine.location == 0
                || linesSinceCheckpoint >= checkpointLineInterval
                || cachedExitState != nil
                || scannedEnd >= source.length {
                cache(state, after: currentLine, in: storage)
                linesSinceCheckpoint = 0
            }

            let lineEnd = NSMaxRange(currentLine)
            if !stopped, lineEnd < source.length {
                currentLine = lineRange(containing: lineEnd, in: source)
            } else if lineEnd >= source.length {
                currentLine = NSRange(location: source.length, length: 0)
            }
        }

        while cursor < source.length, !stopped {
            if cursor >= NSMaxRange(currentLine) {
                finishCurrentLine(with: .normal)
                continue
            }

            guard source.character(at: cursor) == 60 else {
                cursor += 1
                continue
            }

            guard let construct = applyConstruct(
                at: cursor,
                in: source,
                storage: storage,
                palette: palette,
                target: target
            ) else {
                cursor += 1
                continue
            }

            while !stopped {
                let lineEnd = NSMaxRange(currentLine)
                let remainsActive = construct.isTerminated
                    ? lineEnd < construct.end
                    : lineEnd <= construct.end
                guard remainsActive else { break }
                finishCurrentLine(
                    with: CachedLexicalState(
                        activeKind: construct.kind,
                        distanceToStart: lineEnd - cursor
                    )
                )
            }
            cursor = construct.end
        }

        if !stopped, currentLine.length > 0, currentLine.location < source.length {
            finishCurrentLine(with: .normal)
        }
        return ScanResult(lineCount: scannedLineCount, end: scannedEnd)
    }

    private static func applyColors(
        source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange,
        from scanStart: Int,
        through scanEnd: Int
    ) {
        var cursor = scanStart
        while cursor < scanEnd {
            guard source.character(at: cursor) == 60,
                  let construct = applyConstruct(
                      at: cursor,
                      in: source,
                      storage: storage,
                      palette: palette,
                      target: target
                  ) else {
                cursor += 1
                continue
            }
            cursor = construct.end
        }
    }

    private static func applyConstruct(
        at start: Int,
        in source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange
    ) -> Construct? {
        if hasPrefix("<!--", in: source, at: start) {
            let result = end(of: "-->", in: source, from: start + 4)
            if result.isTerminated {
                addColor(
                    palette.comment,
                    to: storage,
                    range: NSRange(location: start, length: result.end - start),
                    limitedTo: target
                )
            }
            return Construct(kind: .comment, end: result.end, isTerminated: result.isTerminated)
        }
        if hasPrefix("<![CDATA[", in: source, at: start) {
            let result = end(of: "]]>", in: source, from: start + 9)
            if result.isTerminated {
                addColor(
                    palette.string,
                    to: storage,
                    range: NSRange(location: start, length: result.end - start),
                    limitedTo: target
                )
            }
            return Construct(kind: .cdata, end: result.end, isTerminated: result.isTerminated)
        }
        if hasPrefix("<?", in: source, at: start) {
            if let declarationRange = processingInstructionNameRange(in: source, from: start) {
                addColor(palette.annotation, to: storage, range: declarationRange, limitedTo: target)
            }
            let result = end(of: "?>", in: source, from: start + 2)
            return Construct(
                kind: .processingInstruction,
                end: result.end,
                isTerminated: result.isTerminated
            )
        }
        if hasPrefix("<!DOCTYPE", in: source, at: start, options: [.caseInsensitive]) {
            let declarationLength = "<!DOCTYPE".utf16.count
            let boundary = start + declarationLength
            if boundary >= source.length || !isWordCharacter(source.character(at: boundary)) {
                addColor(
                    palette.annotation,
                    to: storage,
                    range: NSRange(location: start, length: declarationLength),
                    limitedTo: target
                )
            }
            let result = doctypeEnd(in: source, from: boundary)
            return Construct(kind: .doctype, end: result.end, isTerminated: result.isTerminated)
        }
        guard let tag = tagRange(in: source, from: start) else { return nil }
        applyTag(tag, in: source, storage: storage, palette: palette, target: target)
        return Construct(kind: .tag, end: NSMaxRange(tag.range), isTerminated: true)
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

    private static func doctypeEnd(in source: NSString, from start: Int) -> (end: Int, isTerminated: Bool) {
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
                return (cursor + 1, true)
            }
            cursor += 1
        }
        return (source.length, false)
    }

    private static func end(
        of terminator: String,
        in source: NSString,
        from start: Int
    ) -> (end: Int, isTerminated: Bool) {
        let searchRange = NSRange(location: min(start, source.length), length: max(0, source.length - start))
        let found = source.range(of: terminator, options: [], range: searchRange)
        guard found.location != NSNotFound else { return (source.length, false) }
        return (NSMaxRange(found), true)
    }

    private static func processingInstructionNameRange(in source: NSString, from start: Int) -> NSRange? {
        var cursor = start + 2
        guard cursor < source.length, isNameStart(source.character(at: cursor)) else { return nil }
        cursor += 1
        while cursor < source.length, isNameCharacter(source.character(at: cursor)) {
            cursor += 1
        }
        return NSRange(location: start, length: cursor - start)
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

    private static func isWordCharacter(_ character: unichar) -> Bool {
        character == 95 || (character >= 48 && character <= 57)
            || (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 10 || character == 13 || character == 32
    }

    private static func addColor(_ color: NSColor, to storage: NSTextStorage, range: NSRange, limitedTo target: NSRange) {
        let affectedRange = NSIntersectionRange(range, target)
        guard affectedRange.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: affectedRange)
    }

    private static func cache(
        _ state: CachedLexicalState,
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) {
        guard lineRange.length > 0 else { return }
        let value: String
        if let activeKind = state.activeKind {
            value = "\(activeKind.rawValue):\(state.distanceToStart)"
        } else {
            value = "normal"
        }
        storage.addAttribute(
            lexicalStateAttribute,
            value: value,
            range: NSRange(location: NSMaxRange(lineRange) - 1, length: 1)
        )
    }

    private static func cachedLexicalState(at location: Int, in storage: NSTextStorage) -> CachedLexicalState? {
        guard location >= 0, location < storage.length,
              let value = storage.attribute(
                  lexicalStateAttribute,
                  at: location,
                  effectiveRange: nil
              ) as? String else {
            return nil
        }
        guard value != "normal" else { return .normal }
        let components = value.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let kind = ActiveConstructKind(rawValue: String(components[0])),
              let distance = Int(components[1]) else {
            return nil
        }
        return CachedLexicalState(activeKind: kind, distanceToStart: distance)
    }

    private static func cachedLexicalState(
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) -> CachedLexicalState? {
        cachedLexicalState(at: NSMaxRange(lineRange) - 1, in: storage)
    }

    private static func cachedCheckpoint(
        before location: Int,
        source: NSString,
        storage: NSTextStorage
    ) -> CachedCheckpoint? {
        guard location > 0 else { return nil }
        var probe = location - 1
        while probe >= 0 {
            let lineRange = lineRange(containing: probe, in: source)
            if let state = cachedLexicalState(after: lineRange, in: storage) {
                return CachedCheckpoint(state: state, lineEnd: NSMaxRange(lineRange))
            }
            guard lineRange.location > 0 else { return nil }
            probe = lineRange.location - 1
        }
        return nil
    }

    private static func shouldStop(
        after lineRange: NSRange,
        requiredEnd: Int,
        shouldConverge: Bool,
        cachedExitState: CachedLexicalState?,
        state: CachedLexicalState,
        sourceLength: Int
    ) -> Bool {
        let lineEnd = NSMaxRange(lineRange)
        guard lineEnd >= requiredEnd else { return false }
        guard shouldConverge else {
            return lineEnd >= sourceLength || state == .normal
        }
        guard lineRange.location >= requiredEnd else { return false }
        return lineEnd >= sourceLength || cachedExitState == state
    }

    private static func lineRange(containing location: Int, in source: NSString) -> NSRange {
        source.lineRange(
            for: NSRange(location: min(max(0, location), max(0, source.length - 1)), length: 0)
        )
    }
}
