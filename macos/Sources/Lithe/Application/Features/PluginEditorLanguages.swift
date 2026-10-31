import Combine
import Foundation
import LitheCoreContracts

/// Static editor resources are independent of language-server and Run providers.
struct PluginEditorLanguageSet: Equatable {
    var languages: [ToolingJSONValue] = []

    var editorPayload: [String: Any] {
        let values = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(languages))) ?? []
        return ["languages": values]
    }
}

@MainActor
protocol PluginEditorLanguageProviding: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    func current() -> PluginEditorLanguageSet
}
