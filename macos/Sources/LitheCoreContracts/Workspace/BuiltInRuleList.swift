import Foundation

/// A rule list edited as one text box that also shows the built-in rules.
///
/// Settings store only the user's own entries plus a `!entry` for each
/// built-in the user deleted, so built-ins added by a later release still
/// apply. Comparison ignores case, like the rules themselves.
package enum BuiltInRuleList {
    /// The lines to show: built-ins that are still on, then the user's entries.
    package static func displayed(stored: [String], builtIns: [String]) -> [String] {
        let disabled = FileVisibilityRules.disabledEntries(stored)
        let enabled = builtIns.filter { !contains(disabled, $0) }
        let custom = stored
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { entry in
                // A `!` line for a built-in is shown as that built-in's absence.
                !entry.isEmpty && !contains(builtIns, entry)
                    && !(entry.hasPrefix("!") && contains(builtIns, String(entry.dropFirst()).trimmingCharacters(in: .whitespaces)))
            }
        return enabled + custom
    }

    /// What to store for the edited lines: entries that are not built-in,
    /// then a `!` entry for every built-in the lines no longer contain.
    package static func stored(lines: [String], builtIns: [String]) -> [String] {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var custom: [String] = []
        for line in lines where !line.isEmpty && !contains(builtIns, line) && !contains(custom, line) {
            custom.append(line)
        }
        let removed = builtIns.filter { !contains(lines, $0) }
        return custom + removed.map { "!\($0)" }
    }

    private static func contains(_ values: [String], _ value: String) -> Bool {
        values.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }
}
