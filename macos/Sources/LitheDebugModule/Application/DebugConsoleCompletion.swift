import Foundation
import LitheCoreContracts

/// Turns adapter proposals and plugin-declared commands into the suggestions the
/// Debug Console offers for one typed line, and applies the one the user picks.
///
/// All offsets count UTF-16 units from 0, the unit `NSTextView` and the DAP
/// `completions` request share.
public enum DebugConsoleCompletion {
    public struct Suggestion: Identifiable, Equatable, Sendable {
        public let name: String
        public let detail: String?
        public let kind: String?
        /// Typed text this suggestion replaces: `replacementStart ..< replacementStart + replacementLength`.
        public let replacementStart: Int
        public let replacementLength: Int
        public let insertion: String

        public var id: String { "\(replacementStart):\(replacementLength):\(insertion)\u{0}\(name)" }

        public init(
            name: String,
            detail: String?,
            kind: String?,
            replacementStart: Int,
            replacementLength: Int,
            insertion: String
        ) {
            self.name = name
            self.detail = detail
            self.kind = kind
            self.replacementStart = replacementStart
            self.replacementLength = replacementLength
            self.insertion = insertion
        }
    }

    /// Longest list the popup shows; the rest is reachable by typing more.
    public static let maximumSuggestions = 60

    /// Separates a command from its description in adapter labels such as
    /// lldb-dap's `b -- Set a breakpoint using one of several shorthand formats.`.
    private static let labelSeparator = " -- "

    /// The line and caret to send the adapter when its plugin declared a command prefix,
    /// and how far the line moved, so the proposals can be moved back with `restoring`.
    /// A line that already starts with the prefix is sent as typed.
    public static func adapterRequest(
        text: String,
        caret: Int,
        commandPrefix: String?
    ) -> (text: String, caret: Int, shift: Int) {
        guard let prefix = commandPrefix, !prefix.isEmpty, !text.hasPrefix(prefix) else {
            return (text, caret, 0)
        }
        let shift = prefix.utf16.count
        return (prefix + text, caret + shift, shift)
    }

    /// Proposals for a line sent `shift` units further right, moved back onto the typed
    /// line. A range that began inside the prefix starts at the line's first unit.
    public static func restoring(_ items: [DebugCompletionItem], shift: Int) -> [DebugCompletionItem] {
        guard shift > 0 else { return items }
        return items.map { item in
            guard let start = item.start, let length = item.length else { return item }
            let end = max(start + length - shift, 0)
            let movedStart = max(start - shift, 0)
            return DebugCompletionItem(
                label: item.label,
                text: item.text,
                detail: item.detail,
                kind: item.kind,
                start: movedStart,
                length: max(end - movedStart, 0)
            )
        }
    }

    /// Merges what the adapter proposed with the commands the plugin declared.
    /// Adapter proposals keep the adapter's order and come first; a declared
    /// command the adapter already proposed is not listed twice.
    public static func suggestions(
        text: String,
        caret: Int,
        adapterItems: [DebugCompletionItem],
        declared: [DebugConsoleCommand]
    ) -> [Suggestion] {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        var result: [Suggestion] = []
        var seen = Set<String>()
        func add(_ suggestion: Suggestion) {
            guard result.count < maximumSuggestions,
                  seen.insert(suggestion.insertion.lowercased()).inserted else { return }
            result.append(suggestion)
        }
        for item in adapterItems {
            guard let suggestion = suggestion(for: item, units: units, caret: caret) else { continue }
            add(suggestion)
        }
        for command in declared {
            guard let suggestion = suggestion(for: command, units: units, caret: caret) else { continue }
            add(suggestion)
        }
        return result
    }

    /// The line after choosing `suggestion`, and where the caret goes.
    public static func apply(_ suggestion: Suggestion, to text: String) -> (text: String, caret: Int) {
        let units = Array(text.utf16)
        let start = min(max(suggestion.replacementStart, 0), units.count)
        let end = min(start + max(suggestion.replacementLength, 0), units.count)
        let inserted = Array(suggestion.insertion.utf16)
        let replaced = Array(units[..<start]) + inserted + Array(units[end...])
        return (String(decoding: replaced, as: UTF16.self), start + inserted.count)
    }

    /// The suggestion that extends the typed word as far as every proposal agrees, for a
    /// first Tab that narrows the list before a choice is needed. Nil when the proposals
    /// replace different text or share no start.
    public static func commonExtension(of suggestions: [Suggestion]) -> Suggestion? {
        guard let first = suggestions.first else { return nil }
        var common = first.insertion
        for suggestion in suggestions.dropFirst() {
            guard suggestion.replacementStart == first.replacementStart,
                  suggestion.replacementLength == first.replacementLength else { return nil }
            common = String(zip(common, suggestion.insertion).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { return nil }
        }
        return Suggestion(
            name: common,
            detail: nil,
            kind: nil,
            replacementStart: first.replacementStart,
            replacementLength: first.replacementLength,
            insertion: common
        )
    }

    private static func suggestion(
        for item: DebugCompletionItem,
        units: [UInt16],
        caret: Int
    ) -> Suggestion? {
        guard !item.text.isEmpty else { return nil }
        let parts = item.label.components(separatedBy: labelSeparator)
        let name: String
        let detail: String?
        if parts.count > 1, !parts[0].isEmpty {
            name = parts[0]
            detail = parts.dropFirst().joined(separator: labelSeparator)
        } else {
            name = item.label.isEmpty ? item.text : item.label
            detail = item.detail
        }
        let start: Int
        let length: Int
        if let itemStart = item.start, let itemLength = item.length {
            start = min(max(itemStart, 0), units.count)
            length = min(max(itemLength, 0), units.count - start)
        } else {
            // No range from the adapter: replace the longest tail of the typed text
            // that the proposal begins with, or insert at the caret when none does.
            length = overlap(of: item.text, endingAt: caret, units: units)
            start = caret - length
        }
        return Suggestion(
            name: name,
            detail: detail.flatMap { firstLine(of: $0) },
            kind: item.kind,
            replacementStart: start,
            replacementLength: length,
            insertion: item.text
        )
    }

    /// Some adapters send a multi-paragraph description; the popup row shows its first line.
    private static func firstLine(of description: String) -> String? {
        let line = description
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A declared command completes the line from its first non-space character,
    /// so `breakpoint s` offers `breakpoint set` but `set` alone does not.
    private static func suggestion(
        for command: DebugConsoleCommand,
        units: [UInt16],
        caret: Int
    ) -> Suggestion? {
        let leading = units.prefix { $0 == 0x20 || $0 == 0x09 }.count
        guard caret > leading else { return nil }
        let typed = String(decoding: units[leading..<caret], as: UTF16.self)
        let name = command.name
        // A fully typed command has nothing left to complete.
        guard name.count > typed.count, name.lowercased().hasPrefix(typed.lowercased()) else { return nil }
        return Suggestion(
            name: name,
            detail: command.detail,
            kind: nil,
            replacementStart: leading,
            replacementLength: caret - leading,
            insertion: name
        )
    }

    /// UTF-16 length of the longest tail of the text before `caret` that `proposal` starts with,
    /// ignoring case; 0 when none does.
    private static func overlap(of proposal: String, endingAt caret: Int, units: [UInt16]) -> Int {
        let prefix = String(decoding: units[..<caret], as: UTF16.self)
        let characters = Array(prefix)
        let lowered = proposal.lowercased()
        var count = min(characters.count, proposal.count)
        while count > 0 {
            let tail = String(characters.suffix(count))
            if lowered.hasPrefix(tail.lowercased()) { return tail.utf16.count }
            count -= 1
        }
        return 0
    }
}
