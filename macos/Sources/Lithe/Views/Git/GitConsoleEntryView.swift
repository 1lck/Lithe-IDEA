import AppKit
import SwiftUI
import LitheGitModule

/// Keeps disclosure state local to a command while output snapshots arrive.
struct GitConsoleEntryView: View {
    let entry: GitConsoleEntry
    let wrapsLines: Bool
    var presentation: GitConsolePresentation.Entry? = nil
    var selectedHit: GitConsolePresentation.SearchHit? = nil
    @Binding var expanded: Set<String>
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(Text(command))
                .id(commandAnchor)
                .help("\(entry.workingDirectory.path) · \(String(describing: entry.state)) · \(entry.exitCode)")
                .environment(\.openURL, OpenURLAction { url in
                    guard url.host == "fragment" else { return .discarded }
                    let id = url.lastPathComponent
                    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                    return .handled
                })
            if let presentation {
                ForEach(presentation.output) { fragment in
                    if fragment.kind != "text" {
                        Button {
                            if isExpanded(fragment) {
                                expanded.remove(fragment.id); expanded.remove("running-output")
                            } else {
                                expanded.insert(fragment.id)
                                if entry.state == .running { expanded.insert("running-output") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isExpanded(fragment) ? "▾" : "▸")
                                outputLabel(fragment)
                                if fragment.matches > 0 { Text(" · \(fragment.matches) matches") }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .accessibilityValue(isExpanded(fragment) ? Text("Expanded") : Text("Collapsed"))
                    }
                    if fragment.kind == "text" || isExpanded(fragment) {
                        ForEach(fragment.start..<min(fragment.end, entry.outputLines.count), id: \.self) { index in
                            outputLine(index)
                        }
                    }
                }
            } else {
                ForEach(entry.outputLines.indices, id: \.self) { outputLine($0) }
            }
            if let progress = entry.progressText {
                line(Text(verbatim: progress).foregroundColor(LitheTheme.secondaryText))
                    .id(entry.id.uuidString + ":progress")
            }
            if let notice = presentation?.notice {
                switch notice {
                case "waitingForOutput": line(Text("Running Git; waiting for output.").foregroundColor(LitheTheme.secondaryText))
                case "completedWithoutOutput": line(Text("Git completed successfully with no output.").foregroundColor(LitheTheme.secondaryText))
                case "fetchUnchanged": line(Text("Fetch completed with no reference changes.").foregroundColor(LitheTheme.secondaryText))
                default: EmptyView()
                }
            }
            if entry.isOutputTruncated {
                line(Text("Earlier Git output was omitted to limit memory use.").foregroundColor(LitheTheme.secondaryText))
            }
            if let error = entry.operationErrorMessage {
                line(Text(verbatim: error).foregroundColor(LitheTheme.error))
                    .id(entry.id.uuidString + ":error")
            }
            if entry.state == .unconfirmed {
                line(Text("No completed Git invocation was reported").foregroundColor(LitheTheme.error))
            } else if entry.state == .completed && entry.exitCode != 0 && !entry.expectedExit {
                line(Text("Git exited with code \(entry.exitCode)").foregroundColor(LitheTheme.error))
            }
            if showsDetails { details }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .textSelection(.enabled)
        .padding(.bottom, 4)
        .litheContextMenu {
            [
                .action("Copy repository path") { copy(entry.workingDirectory.path) },
                .action("Copy complete command") { copy(entry.completeCommandLine) },
                .action("Copy complete output") { copy(entry.output) },
                .action("Command details") { showsDetails.toggle() },
                .action("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.copyText, forType: .string)
                }
            ]
        }
    }

    private func isExpanded(_ fragment: GitConsolePresentation.OutputFragment) -> Bool {
        expanded.contains(fragment.id) || expanded.contains("running-output")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var commandAnchor: String {
        if let selectedHit, selectedHit.recordId == entry.id.uuidString, selectedHit.lineIndex == nil, selectedHit.fragmentId != "error", selectedHit.fragmentId != "progress" {
            return selectedHit.anchor
        }
        return entry.id.uuidString + ":command"
    }

    private func outputLine(_ index: Int) -> some View {
        let output = entry.outputLines[index]
        let anchor = entry.id.uuidString + ":line-\(index)"
        return line(Text(verbatim: output.text.isEmpty ? " " : output.text)
            .foregroundColor(output.stream == .standardError ? LitheTheme.error : outputColor))
            .background(selectedHit?.anchor == anchor ? LitheTheme.accent.opacity(0.18) : .clear)
            .id(anchor)
    }

    @ViewBuilder private func outputLabel(_ fragment: GitConsolePresentation.OutputFragment) -> some View {
        switch fragment.kind {
        case "progress": Text(verbatim: entry.outputLines[min(fragment.end, entry.outputLines.count) - 1].text)
        case "repeat": Text("Repeated \(fragment.count) times")
        case "files": Text("Other \(fragment.count) files")
        case "branches": Text("Other \(fragment.count) branches")
        case "tags": Text("Other \(fragment.count) tags")
        case "commits": Text("Other \(fragment.count) commits")
        case "references": Text("Other reference changes: \(fragment.added) added, \(fragment.updated) updated, \(fragment.deleted) deleted")
        default: Text("Expand \(fragment.count) lines")
        }
    }

    private func commandPreview(_ fragment: GitConsolePresentation.CommandFragment) -> String {
        if !fragment.preview.isEmpty { return fragment.preview }
        let key = fragment.kind == "files" ? "… %lld more files" : "… %lld more references"
        return String(format: NSLocalizedString(key, comment: "Git argument disclosure"), fragment.count)
    }

    private var command: AttributedString {
        var text = AttributedString("\(Self.timestampFormatter.string(from: entry.timestamp)): [\(presentation?.repositoryLabel ?? entry.workingDirectory.path)] git ")
        text.foregroundColor = commandColor
        if let presentation {
            for (index, fragment) in presentation.command.enumerated() {
                if index > 0 { text.append(AttributedString(" ")) }
                let isFold = fragment.kind != "text"
                var part = AttributedString(isFold && !expanded.contains(fragment.id) ? commandPreview(fragment) : fragment.text)
                part.foregroundColor = commandColor
                if isFold {
                    part.link = URL(string: "lithe-git-console://fragment/" + fragment.id)
                    part.backgroundColor = LitheTheme.accent.opacity(0.12)
                    if !expanded.contains(fragment.id), fragment.matches > 0 {
                        part.append(AttributedString(String(format: NSLocalizedString(" · %lld matches", comment: "Hidden search matches"), fragment.matches)))
                    }
                }
                if selectedHit?.recordId == entry.id.uuidString, selectedHit?.fragmentId == fragment.id {
                    part.backgroundColor = LitheTheme.accent.opacity(0.24)
                }
                text.append(part)
            }
        } else {
            // A failed projection preserves full retained command data.
            text.append(AttributedString(entry.formattedTemporaryConfiguration + " " + entry.commandLine.dropFirst(4)))
        }
        return text
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch entry.state {
            case .planned: line(Text("Planned Git command — waiting to start"))
            case .running: line(Text("Git command is running"))
            case .unconfirmed: line(Text("No completed Git invocation was reported"))
            case .completed:
                line(Text(LocalizedStringKey(entry.succeeded ? "Git command succeeded" : "Git command failed")))
            }
            if let executable = entry.executable { line(Text("Git executable: \(executable)")) }
            if let duration = entry.durationMilliseconds { line(Text("Duration: \(duration) ms")) }
            if entry.state == .completed { line(Text("Git exited with code \(entry.exitCode)")) }
            if let outcome = entry.remoteResult { remoteDetails(outcome) }
        }
        .foregroundStyle(LitheTheme.secondaryText)
    }

    private func remoteDetails(_ outcome: GitRemoteOutcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            line(Text("Remote: \(outcome.remote)"))
            line(Text(LocalizedStringKey(outcome.succeeded ? "Remote Fetch succeeded" : "Remote Fetch failed")))
            if outcome.truncated {
                line(Text("Reference list truncated; total updated: \(outcome.updatedCount), deleted: \(outcome.deletedCount)"))
            }
            if !outcome.referencesAvailable { line(Text("Reference changes could not be inspected")) }
            if !outcome.updatedReferences.isEmpty {
                line(Text("Updated references: \(outcome.updatedReferences.joined(separator: ", "))"))
            }
            if !outcome.deletedReferences.isEmpty {
                line(Text("Deleted references: \(outcome.deletedReferences.joined(separator: ", "))"))
            }
        }
    }

    private func line(_ text: Text) -> some View {
        text.frame(maxWidth: wrapsLines ? .infinity : nil, minHeight: 20, alignment: .leading)
            .fixedSize(horizontal: !wrapsLines, vertical: true)
    }

    private var outputColor: Color {
        LitheTheme.primaryText
    }

    private var commandColor: Color {
        LitheTheme.link
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
