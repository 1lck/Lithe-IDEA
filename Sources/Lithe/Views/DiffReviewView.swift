import SwiftUI

struct DiffReviewView: View {
    @EnvironmentObject private var model: AppModel
    let change: GitChange

    @State private var whitespaceMode = DiffWhitespaceMode.doNotIgnore
    @State private var highlightsWords = true
    @State private var selectedDifferenceIndex = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                diffTab
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                diffToolbar(proxy: proxy)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                versionHeader
                Rectangle().fill(LitheTheme.divider).frame(height: 1)

                if model.isLoadingDiff {
                    loadingState
                } else if model.diffRows.isEmpty {
                    emptyState
                } else {
                    diffContent(proxy: proxy)
                }
            }
        }
        .background(LitheTheme.editor)
        .onChange(of: model.diffRows.count) { _, _ in
            selectedDifferenceIndex = 0
        }
        .onChange(of: whitespaceMode) { _, _ in
            selectedDifferenceIndex = 0
        }
    }

    private var diffTab: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 11.5))
                .foregroundStyle(fileIconColor)
            Text(change.url.lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: change.kind.symbol)
                    .font(.system(size: 8, weight: .bold))
                Text(change.kind.title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(changeKindColor)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(changeKindColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(change.isStaged && !change.hasWorkingTreeChange ? "STAGED" : "WORKING TREE")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(change.isStaged ? LitheTheme.success : LitheTheme.warning)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background((change.isStaged ? LitheTheme.success : LitheTheme.warning).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer()
            Button {
                model.selectedChange = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .litheIconButton()
            .help("Close diff")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(LitheTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.accent).frame(height: 2)
        }
    }

    private func diffToolbar(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    navigateDifference(by: -1, proxy: proxy)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .litheIconButton()
                .disabled(differenceStarts.isEmpty)
                .help("Previous difference")

                Button {
                    navigateDifference(by: 1, proxy: proxy)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .litheIconButton()
                .disabled(differenceStarts.isEmpty)
                .help("Next difference")

                toolbarDivider

                toolbarLabel("Side-by-side", systemImage: "rectangle.split.2x1")

                Menu {
                    ForEach(DiffWhitespaceMode.allCases) { mode in
                        Button {
                            whitespaceMode = mode
                        } label: {
                            if whitespaceMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    toolbarLabel(whitespaceMode.title, systemImage: "textformat")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Whitespace comparison")

                Button {
                    highlightsWords.toggle()
                } label: {
                    toolbarLabel(
                        "Highlight words",
                        systemImage: highlightsWords ? "checkmark.square.fill" : "square"
                    )
                }
                .buttonStyle(.plain)
                .help(highlightsWords ? "Disable word-level highlights" : "Enable word-level highlights")

                toolbarDivider

                Text(change.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)

                Text(differenceStarts.count == 1 ? "1 difference" : "\(differenceStarts.count) differences")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 7)

                toolbarDivider

                if change.isStaged && !change.hasWorkingTreeChange {
                    Button("Unstage") {
                        Task { await model.unstageSelectedChange() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Discard") {
                        model.requestDiscardSelectedChange()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stage File") {
                        Task { await model.stageSelectedChange() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LitheTheme.accent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
        }
        .background(LitheTheme.toolHeader)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(LitheTheme.divider)
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(LitheTheme.raised.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var versionHeader: some View {
        HStack(spacing: 0) {
            versionLabel(leftVersionTitle, path: leftVersionPath, systemImage: "lock")
            centerGutter(kind: nil, isSelected: false)
            versionLabel(rightVersionTitle, path: rightVersionPath, systemImage: "checkmark.square")
        }
        .frame(height: 34)
        .background(LitheTheme.window)
    }

    private func versionLabel(_ title: String, path: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Text(path)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Loading diff…")
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 30, weight: .light))
            Text("No textual diff available")
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffContent(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            let contentWidth = max(980, geometry.size.width)

            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.diffRows) { row in
                            let kind = effectiveKind(for: row)
                            let differenceIndex = differenceIndexByRow[row.id]
                            DiffRowView(
                                row: row,
                                kind: kind,
                                fileExtension: change.url.pathExtension,
                                highlightsWords: highlightsWords,
                                isSelectedDifference: differenceIndex == selectedDifferenceIndex
                            )
                            .id(row.id)
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .textSelection(.enabled)
                }
                .frame(width: contentWidth, height: geometry.size.height, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(LitheTheme.editor)
        }
    }

    private var differenceStarts: [UUID] {
        var result: [UUID] = []
        var insideDifference = false
        for row in model.diffRows {
            let isDifference = effectiveKind(for: row).isDifference
            if isDifference && !insideDifference {
                result.append(row.id)
            }
            insideDifference = isDifference
        }
        return result
    }

    private var differenceIndexByRow: [UUID: Int] {
        var result: [UUID: Int] = [:]
        var currentIndex = -1
        var insideDifference = false
        for row in model.diffRows {
            let isDifference = effectiveKind(for: row).isDifference
            if isDifference && !insideDifference {
                currentIndex += 1
            }
            if isDifference {
                result[row.id] = currentIndex
            }
            insideDifference = isDifference
        }
        return result
    }

    private func effectiveKind(for row: DiffRow) -> DiffRowKind {
        guard whitespaceMode == .ignoreWhitespace,
              row.kind == .changed,
              let left = row.left,
              let right = row.right,
              normalizedWhitespace(left) == normalizedWhitespace(right) else {
            return row.kind
        }
        return .context
    }

    private func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func navigateDifference(by offset: Int, proxy: ScrollViewProxy) {
        let starts = differenceStarts
        guard !starts.isEmpty else { return }
        let current = min(max(selectedDifferenceIndex, 0), starts.count - 1)
        let next = (current + offset + starts.count) % starts.count
        selectedDifferenceIndex = next
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(starts[next], anchor: .center)
        }
    }

    private var leftVersionTitle: String {
        if change.kind == .added { return "Empty file" }
        if change.kind == .deleted { return "Deleted version" }
        if change.kind == .moved || change.kind == .copied { return "Original location" }
        if change.hasWorkingTreeChange { return "Index version" }
        return "Repository version"
    }

    private var rightVersionTitle: String {
        if change.kind == .deleted { return "Empty file" }
        if change.kind == .added { return "Added version" }
        if change.kind == .moved { return "Moved version" }
        if change.kind == .copied { return "Copied version" }
        return change.isStaged && !change.hasWorkingTreeChange ? "Staged version" : "Current version"
    }

    private var leftVersionPath: String {
        if change.kind == .added { return "No file" }
        return change.originalPath ?? change.path
    }

    private var rightVersionPath: String {
        change.kind == .deleted ? "No file" : change.path
    }

    private var changeKindColor: Color {
        switch change.kind {
        case .added: LitheTheme.success
        case .modified: LitheTheme.warning
        case .deleted: .red.opacity(0.86)
        case .moved: LitheTheme.accent
        case .copied: Color(red: 0.46, green: 0.72, blue: 0.92)
        }
    }

    private var fileIconColor: Color {
        switch change.url.pathExtension.lowercased() {
        case "swift": .orange
        case "java", "kt", "kts": Color(red: 0.42, green: 0.66, blue: 0.95)
        case "js", "jsx", "ts", "tsx": .yellow
        default: LitheTheme.accent
        }
    }

    private func centerGutter(kind: DiffRowKind?, isSelected: Bool) -> some View {
        ZStack {
            LitheTheme.window
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            if let kind, kind.isDifference {
                Image(systemName: centerSymbol(for: kind))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? LitheTheme.accent : LitheTheme.secondaryText)
            }
        }
        .frame(width: 34)
    }

    private func centerSymbol(for kind: DiffRowKind) -> String {
        switch kind {
        case .addition: "arrow.right"
        case .removal: "arrow.left"
        case .changed: "arrow.left.arrow.right"
        default: "circle"
        }
    }
}

struct DiffRowView: View {
    let row: DiffRow
    let kind: DiffRowKind
    let fileExtension: String
    let highlightsWords: Bool
    let isSelectedDifference: Bool

    var body: some View {
        if kind == .information {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                Text(row.left ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Color(red: 0.50, green: 0.72, blue: 0.98))
            .padding(.horizontal, 12)
            .frame(height: 27)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.13, green: 0.20, blue: 0.30))
        } else {
            HStack(spacing: 0) {
                diffCell(number: row.oldLine, text: row.left, otherText: row.right, side: .left)
                centerGutter
                diffCell(number: row.newLine, text: row.right, otherText: row.left, side: .right)
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if isSelectedDifference {
                    Rectangle().fill(LitheTheme.accent).frame(width: 2)
                }
            }
        }
    }

    private func diffCell(number: Int?, text: String?, otherText: String?, side: DiffSide) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(lineNumberColor(side: side))
                .frame(width: 47, alignment: .trailing)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity)
                .background(LitheTheme.window.opacity(0.62))

            Rectangle()
                .fill(changeMarkerColor(side: side, hasText: text != nil))
                .frame(width: 3)

            Text(
                DiffSyntaxHighlighter.styled(
                    text ?? "",
                    comparing: otherText,
                    fileExtension: fileExtension,
                    side: side,
                    highlightsWords: highlightsWords && kind == .changed
                )
            )
            .font(.system(size: 12.5, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
        }
        .background(backgroundColor(side: side, hasText: text != nil))
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var centerGutter: some View {
        ZStack {
            LitheTheme.window
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            if kind.isDifference {
                Image(systemName: centerSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelectedDifference ? LitheTheme.accent : LitheTheme.secondaryText)
            }
        }
        .frame(width: 34)
    }

    private var centerSymbol: String {
        switch kind {
        case .addition: "arrow.right"
        case .removal: "arrow.left"
        case .changed: "arrow.left.arrow.right"
        default: "circle"
        }
    }

    private func backgroundColor(side: DiffSide, hasText: Bool) -> Color {
        guard hasText else { return LitheTheme.window.opacity(0.36) }
        let selectionBoost = isSelectedDifference ? 0.04 : 0
        switch kind {
        case .changed:
            return side == .left
                ? Color.red.opacity(0.13 + selectionBoost)
                : Color.green.opacity(0.14 + selectionBoost)
        case .removal:
            return side == .left ? Color.red.opacity(0.17 + selectionBoost) : .clear
        case .addition:
            return side == .right ? Color.green.opacity(0.17 + selectionBoost) : .clear
        default:
            return .clear
        }
    }

    private func changeMarkerColor(side: DiffSide, hasText: Bool) -> Color {
        guard hasText else { return .clear }
        switch kind {
        case .addition where side == .right:
            return LitheTheme.success.opacity(0.72)
        case .removal where side == .left:
            return Color.red.opacity(0.72)
        case .changed:
            return side == .left ? Color.red.opacity(0.58) : LitheTheme.success.opacity(0.58)
        default:
            return .clear
        }
    }

    private func lineNumberColor(side: DiffSide) -> Color {
        switch kind {
        case .addition where side == .right: LitheTheme.success.opacity(0.75)
        case .removal where side == .left: Color.red.opacity(0.72)
        default: LitheTheme.secondaryText.opacity(0.78)
        }
    }
}

private enum DiffWhitespaceMode: String, CaseIterable, Identifiable {
    case doNotIgnore
    case ignoreWhitespace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doNotIgnore: "Do not ignore"
        case .ignoreWhitespace: "Ignore whitespace"
        }
    }
}

private enum DiffSide {
    case left
    case right
}

private extension DiffRowKind {
    var isDifference: Bool {
        switch self {
        case .changed, .addition, .removal: true
        case .context, .information: false
        }
    }
}

private enum DiffSyntaxHighlighter {
    private struct Token {
        let text: String
        let color: Color
    }

    private static let keywordColor = Color(red: 0.82, green: 0.52, blue: 0.78)
    private static let typeColor = Color(red: 0.43, green: 0.72, blue: 0.92)
    private static let stringColor = Color(red: 0.58, green: 0.76, blue: 0.49)
    private static let numberColor = Color(red: 0.70, green: 0.76, blue: 0.48)
    private static let commentColor = Color(red: 0.39, green: 0.57, blue: 0.43)
    private static let tagColor = Color(red: 0.82, green: 0.66, blue: 0.37)
    private static let baseColor = LitheTheme.primaryText

    private static let keywords: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "func", "let", "var", "if", "else",
        "guard", "switch", "case", "for", "while", "return", "throw", "throws", "try", "catch",
        "async", "await", "public", "private", "internal", "protected", "static", "final", "new",
        "import", "package", "interface", "implements", "extends", "void", "boolean", "int", "long",
        "const", "function", "def", "in", "from", "as", "true", "false", "null", "nil", "self", "this"
    ]

    static func styled(
        _ text: String,
        comparing otherText: String?,
        fileExtension: String,
        side: DiffSide,
        highlightsWords: Bool
    ) -> AttributedString {
        let tokens = tokenize(text, fileExtension: fileExtension.lowercased())
        let highlightRange = highlightsWords ? changedRange(in: text, comparedTo: otherText) : nil
        let highlightColor = side == .left ? Color.red.opacity(0.38) : Color.green.opacity(0.34)
        var result = AttributedString()
        var globalOffset = 0

        for token in tokens {
            let characters = Array(token.text)
            let tokenStart = globalOffset
            let tokenEnd = tokenStart + characters.count
            let localHighlightStart = highlightRange.map { max(0, $0.lowerBound - tokenStart) } ?? 0
            let localHighlightEnd = highlightRange.map { min(characters.count, $0.upperBound - tokenStart) } ?? 0

            if let highlightRange,
               tokenEnd > highlightRange.lowerBound,
               tokenStart < highlightRange.upperBound,
               localHighlightStart < localHighlightEnd {
                append(characters[0..<localHighlightStart], color: token.color, background: nil, to: &result)
                append(
                    characters[localHighlightStart..<localHighlightEnd],
                    color: token.color,
                    background: highlightColor,
                    to: &result
                )
                append(characters[localHighlightEnd..<characters.count], color: token.color, background: nil, to: &result)
            } else {
                append(characters[0..<characters.count], color: token.color, background: nil, to: &result)
            }
            globalOffset = tokenEnd
        }
        return result
    }

    private static func append(
        _ characters: ArraySlice<Character>,
        color: Color,
        background: Color?,
        to result: inout AttributedString
    ) {
        guard !characters.isEmpty else { return }
        var segment = AttributedString(String(characters))
        segment.foregroundColor = color
        if let background {
            segment.backgroundColor = background
        }
        result += segment
    }

    private static func changedRange(in text: String, comparedTo otherText: String?) -> Range<Int>? {
        guard let otherText else { return nil }
        let source = Array(text)
        let comparison = Array(otherText)
        var prefix = 0
        let sharedCount = min(source.count, comparison.count)
        while prefix < sharedCount, source[prefix] == comparison[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < sharedCount - prefix,
              source[source.count - suffix - 1] == comparison[comparison.count - suffix - 1] {
            suffix += 1
        }

        let end = source.count - suffix
        guard prefix < end else { return nil }
        return prefix..<end
    }

    private static func tokenize(_ text: String, fileExtension: String) -> [Token] {
        if ["xml", "html", "xhtml", "plist"].contains(fileExtension) {
            return tokenizeMarkup(text)
        }
        if ["md", "markdown"].contains(fileExtension), text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return [Token(text: text, color: commentColor)]
        }
        return tokenizeCode(text)
    }

    private static func tokenizeMarkup(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let start = index
            if characters[index] == "<" {
                while index < characters.count, characters[index] != ">" {
                    index += 1
                }
                if index < characters.count { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), color: tagColor))
            } else {
                while index < characters.count, characters[index] != "<" {
                    index += 1
                }
                tokens.append(Token(text: String(characters[start..<index]), color: baseColor))
            }
        }
        return tokens
    }

    private static func tokenizeCode(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let start = index
            let character = characters[index]

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                tokens.append(Token(text: String(characters[index...]), color: commentColor))
                break
            }

            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var escaped = false
                while index < characters.count {
                    let current = characters[index]
                    index += 1
                    if current == quote && !escaped { break }
                    escaped = current == "\\" && !escaped
                    if current != "\\" { escaped = false }
                }
                tokens.append(Token(text: String(characters[start..<index]), color: stringColor))
                continue
            }

            if character.isNumber {
                index += 1
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    index += 1
                }
                tokens.append(Token(text: String(characters[start..<index]), color: numberColor))
                continue
            }

            if character.isLetter || character == "_" || character == "@" {
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                let word = String(characters[start..<index])
                let color: Color
                if word.hasPrefix("@") {
                    color = tagColor
                } else if keywords.contains(word) {
                    color = keywordColor
                } else if word.first?.isUppercase == true {
                    color = typeColor
                } else {
                    color = baseColor
                }
                tokens.append(Token(text: word, color: color))
                continue
            }

            index += 1
            while index < characters.count {
                let next = characters[index]
                if next.isLetter || next.isNumber || next == "_" || next == "@" || next == "\"" || next == "'" {
                    break
                }
                if next == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    break
                }
                index += 1
            }
            tokens.append(Token(text: String(characters[start..<index]), color: baseColor))
        }
        return tokens
    }
}
