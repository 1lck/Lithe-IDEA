import SwiftUI
import LitheAgentConversationModule

/// Readable sections of a tool call's evidence. Commands and command results
/// arrive as raw JSON; the fields every shell tool shares are lifted out so a
/// row reads `$ git log` and its output instead of serialized objects.
enum AgentToolEvidencePresentation {
    struct Section: Equatable {
        enum Style: Equatable { case plain, command, error }
        let title: String
        var detail: String?
        var exitCode: Int?
        let text: String
        var style = Style.plain
    }

    /// Result fields that carry a shell's combined or standard output, in preference order.
    private static let outputKeys = ["formatted_output", "aggregated_output", "stdout", "output"]

    static func sections(_ details: AgentToolDetails) -> [Section] {
        var sections: [Section] = []
        if let input = details.input?.trimmed, !input.isEmpty {
            sections.append(command(from: input) ?? Section(title: "Input", text: input))
        }
        let result = details.output.flatMap { output(from: $0) }
        let resultText = result?.first?.text
        for content in details.content {
            let text = content.text.trimmed
            // A terminal entry is only an opaque terminal ID, and the output
            // block usually repeats the parsed result.
            guard content.title != "Terminal", !text.isEmpty, text != resultText else { continue }
            sections.append(Section(title: content.title, text: text))
        }
        if let result { sections += result }
        else if let output = details.output?.trimmed, !output.isEmpty {
            sections.append(Section(title: "Result", text: output))
        }
        return sections
    }

    private static func command(from input: String) -> Section? {
        guard let object = jsonObject(input) else { return nil }
        let line: String
        if let text = object["command"] as? String {
            line = text
        } else if let parts = object["command"] as? [String], !parts.isEmpty {
            // `["/bin/zsh", "-lc", "git log"]` is a shell wrapper around one command line.
            line = parts.count == 3 && ["-c", "-lc"].contains(parts[1]) ? parts[2] : parts.joined(separator: " ")
        } else {
            return nil
        }
        let directory = (object["cwd"] ?? object["workdir"]) as? String
        return Section(title: "Command", detail: directory, text: line.trimmed, style: .command)
    }

    private static func output(from raw: String) -> [Section]? {
        guard let object = jsonObject(raw) else { return nil }
        let exitCode = (object["exit_code"] ?? object["exitCode"]) as? Int
        let text = outputKeys.lazy.compactMap { (object[$0] as? String)?.trimmed }.first { !$0.isEmpty }
        guard text != nil || exitCode != nil else { return nil }
        var sections = [Section(title: "Output", exitCode: exitCode, text: text ?? "")]
        if let stderr = (object["stderr"] as? String)?.trimmed, !stderr.isEmpty, stderr != text {
            sections.append(Section(title: "Errors", text: stderr, style: .error))
        }
        return sections
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A tool call's locations and evidence as wrapped code blocks. Blocks have no
/// scroll views of their own: they sit inside the transcript or the activity
/// popup's single scroll view, and long text folds behind "Show all".
struct AgentToolEvidenceView: View {
    let details: AgentToolDetails
    let onOpenFile: (AgentToolDetails.Location) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(details.locations.enumerated()), id: \.offset) { _, location in
                locationButton(location)
            }
            ForEach(Array(AgentToolEvidencePresentation.sections(details).enumerated()), id: \.offset) { _, section in
                AgentEvidenceBlock(section: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func locationButton(_ location: AgentToolDetails.Location) -> some View {
        let label = location.path + (location.line.map { ":\($0)" } ?? "")
        return Button { onOpenFile(location) } label: {
            Label(label, systemImage: "doc")
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
        .foregroundStyle(AgentPanelStyle.focus)
        .help(location.path)
    }
}

private struct AgentEvidenceBlock: View {
    @Environment(\.locale) private var locale
    let section: AgentToolEvidencePresentation.Section

    static let collapsedLineLimit = 12

    @State private var showsAll = false
    @State private var isHovered = false

    private var lineCount: Int { section.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var folds: Bool { lineCount > Self.collapsedLineLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !section.text.isEmpty { block }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: AgentLocalization.string(String.LocalizationValue(section.title), locale: locale))
                .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.tertiaryText)
            if let detail = section.detail {
                Text(verbatim: detail)
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(detail)
            }
            Spacer(minLength: 0)
            if let exitCode = section.exitCode {
                Text(String(format: AgentLocalization.string("Exit code %lld", locale: locale), exitCode))
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(exitCode == 0 ? LitheTheme.success : LitheTheme.error)
            }
        }
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if section.style == .command {
                    Text(verbatim: "$").foregroundStyle(LitheTheme.tertiaryText)
                }
                Text(verbatim: section.text)
                    .foregroundStyle(section.style == .error ? LitheTheme.error : LitheTheme.primaryText)
                    .lineLimit(folds && !showsAll ? Self.collapsedLineLimit : nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(LitheTheme.uiFont(size: 11, design: .monospaced))
            .lineSpacing(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.trailing, 16)
            if folds {
                Divider().overlay(LitheTheme.panelBorder)
                Button { showsAll.toggle() } label: {
                    Text(showsAll ? AgentLocalization.string("Show less", locale: locale)
                         : String(format: AgentLocalization.string("Show all %lld lines", locale: locale), lineCount))
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
            }
        }
        .background(LitheTheme.toolHeaderInactive.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            AgentCopyButton(text: section.text)
                .padding(3)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .onHover { isHovered = $0 }
    }
}
