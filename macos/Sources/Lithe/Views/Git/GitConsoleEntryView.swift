import AppKit
import SwiftUI
import LitheGitModule

/// Keeps disclosure state local to a command while output snapshots arrive.
struct GitConsoleEntryView: View {
    let entry: GitConsoleEntry
    let wrapsLines: Bool
    @State private var showsConfiguration = false
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(Text(command))
                .help("Click the folded options to expand; right-click for command details.")
                .environment(\.openURL, OpenURLAction { url in
                    switch url.host {
                    case "configuration": showsConfiguration.toggle()
                    default: return .discarded
                    }
                    return .handled
                })
            ForEach(Array(entry.outputLines.enumerated()), id: \.offset) { _, output in
                line(Text(verbatim: output.text.isEmpty ? " " : output.text)
                    .foregroundColor(output.stream == .standardError ? LitheTheme.error : outputColor))
            }
            if let progress = entry.progressText {
                line(Text(verbatim: progress).foregroundColor(LitheTheme.secondaryText))
            }
            if entry.isOutputTruncated {
                line(Text("Earlier Git output was omitted to limit memory use.").foregroundColor(LitheTheme.secondaryText))
            }
            if let error = entry.operationErrorMessage {
                line(Text(verbatim: error).foregroundColor(LitheTheme.error))
            }
            if entry.state == .unconfirmed {
                line(Text("No completed Git invocation was reported").foregroundColor(LitheTheme.error))
            } else if entry.state == .completed && entry.exitCode != 0 {
                line(Text("Git exited with code \(entry.exitCode)").foregroundColor(LitheTheme.error))
            }
            if showsDetails { details }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .textSelection(.enabled)
        .padding(.bottom, 4)
        .contextMenu {
            Button("Command details") { showsDetails.toggle() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.copyText, forType: .string)
            }
        }
    }

    private var command: AttributedString {
        var text = AttributedString("\(Self.timestampFormatter.string(from: entry.timestamp)): [\(entry.workingDirectory.path)] git ")
        text.foregroundColor = commandColor
        if !entry.formattedTemporaryConfiguration.isEmpty {
            var configuration = AttributedString(showsConfiguration ? entry.formattedTemporaryConfiguration : "-c …")
            configuration.link = URL(string: "lithe-git-console://configuration")
            configuration.foregroundColor = outputColor
            configuration.backgroundColor = LitheTheme.accent.opacity(0.12)
            text.append(configuration)
            text.append(AttributedString(" "))
        }
        var arguments = AttributedString(entry.formattedArguments)
        arguments.foregroundColor = commandColor
        text.append(arguments)
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

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
