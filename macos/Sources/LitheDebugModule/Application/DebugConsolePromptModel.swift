import Combine
import Foundation

/// State behind the Debug Console prompt: which suggestions the popup lists and which
/// one is chosen. The text field owns the typed line and reports every edit here, so
/// the model never holds text of its own.
@MainActor
public final class DebugConsolePromptModel: ObservableObject {
    public typealias Suggestion = DebugConsoleCompletion.Suggestion
    public typealias Provider = (
        _ text: String,
        _ caret: Int,
        _ completion: @escaping ([Suggestion]) -> Void
    ) -> Void

    /// What a pressed Tab did to the line.
    public enum TabResult: Equatable {
        /// The line and caret the field must show now.
        case replace(text: String, caret: Int)
        /// Nothing to fill; the popup opens once suggestions arrive.
        case requested
    }

    @Published public private(set) var suggestions: [Suggestion] = []
    @Published public private(set) var selectedIndex = 0

    /// True once the user moved the highlight themselves, so Enter then takes that row
    /// instead of running the line as typed.
    public private(set) var isSelectionChosen = false

    public var isPopupOpen: Bool { !suggestions.isEmpty }
    public var selectedSuggestion: Suggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    /// Where suggestions come from; the feature model sets it once it exists.
    public var provider: Provider?
    private var generation = 0

    public init(provider: Provider? = nil) {
        self.provider = provider
    }

    /// The user edited the line. A blank line closes the popup.
    public func textDidChange(_ text: String, caret: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dismiss()
            return
        }
        request(text: text, caret: caret)
    }

    /// Closes the popup and discards any reply still on its way.
    public func dismiss() {
        generation += 1
        if !suggestions.isEmpty { suggestions = [] }
        selectedIndex = 0
        isSelectionChosen = false
    }

    /// Moves the highlight by `delta` rows, wrapping at both ends. False when the popup
    /// is closed, so the caller can use the key for history instead.
    @discardableResult
    public func moveSelection(by delta: Int) -> Bool {
        guard !suggestions.isEmpty else { return false }
        let count = suggestions.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        isSelectionChosen = true
        return true
    }

    public func select(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selectedIndex = index
        isSelectionChosen = true
    }

    /// Applies the highlighted suggestion and closes the popup. Nil when none is open.
    public func acceptSelected(into text: String) -> (text: String, caret: Int)? {
        guard let suggestion = selectedSuggestion else { return nil }
        let result = DebugConsoleCompletion.apply(suggestion, to: text)
        dismiss()
        return result
    }

    /// Enter on a popup row the user moved to. Nil when the highlight was never moved, so
    /// the line is run as typed.
    public func acceptChosen(into text: String) -> (text: String, caret: Int)? {
        guard isSelectionChosen else { return nil }
        return acceptSelected(into: text)
    }

    /// Tab: with several proposals, first extend the line as far as they all agree and
    /// keep listing what is left; otherwise fill the highlighted one. With the popup
    /// closed it asks for suggestions.
    public func tab(text: String, caret: Int) -> TabResult {
        guard !suggestions.isEmpty else {
            request(text: text, caret: caret)
            return .requested
        }
        if suggestions.count > 1,
           let common = DebugConsoleCompletion.commonExtension(of: suggestions) {
            let extended = DebugConsoleCompletion.apply(common, to: text)
            if extended.text.utf16.count > text.utf16.count {
                request(text: extended.text, caret: extended.caret)
                return .replace(text: extended.text, caret: extended.caret)
            }
        }
        guard let filled = acceptSelected(into: text) else { return .requested }
        return .replace(text: filled.text, caret: filled.caret)
    }

    private func request(text: String, caret: Int) {
        generation += 1
        let mine = generation
        provider?(text, caret) { [weak self] proposed in
            guard let self, self.generation == mine else { return }
            // A proposal that would leave the line unchanged is not worth a row.
            let useful = proposed.filter { DebugConsoleCompletion.apply($0, to: text).text != text }
            self.suggestions = useful
            self.selectedIndex = 0
            self.isSelectionChosen = false
        }
    }
}
