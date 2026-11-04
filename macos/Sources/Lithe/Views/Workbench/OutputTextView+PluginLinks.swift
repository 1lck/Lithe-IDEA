import AppKit
import Foundation

extension OutputTextView {
    /// Makes console text a link where an enabled plugin's output link matcher finds one.
    /// Rust Core does the matching; this only styles the ranges and routes the clicks.
    @MainActor
    func pluginLinks(in model: AppModel, scope: PluginOutputLinkService.Scope, searchRoots: [URL]) -> OutputTextView {
        var view = self
        let decorateBefore = decorateOutput
        view.decorateOutput = { [weak model] text, isDark in
            decorateBefore?(text, isDark)
            guard let model else { return }
            let marks = model.pluginOutputLinkMarks(in: text.string, scope: scope, searchRoots: searchRoots)
            Self.apply(marks, to: text, isDark: isDark)
        }
        view.onOpenPluginLink = { [weak model] url in model?.openPluginOutputLink(url) }
        return view
    }

    /// A located file opens like the host's own console links; a link the plugin must resolve
    /// carries its question and opens through `onOpenPluginLink`.
    private static func apply(_ marks: [PluginOutputLinkService.Mark], to text: NSMutableAttributedString, isDark: Bool) {
        for mark in marks where NSMaxRange(mark.range) <= text.length {
            switch mark.destination {
            case .file(let path, let line, let column):
                text.addAttribute(.link, value: locationURL(path: path, line: line ?? 1, column: column), range: mark.range)
            case .ask(let question):
                text.addAttribute(.link, value: question.url, range: mark.range)
            }
            text.addAttribute(.foregroundColor, value: LitheConsoleStyle.hyperlink(dark: isDark), range: mark.range)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: mark.range)
        }
    }
}
