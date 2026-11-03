import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Static editor resources are independent of language-server and Run providers.
struct PluginEditorLanguageSet: Equatable {
    var languages: [ToolingJSONValue] = []
    var pluginIDs: [String: String] = [:]

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


extension PluginEditorLanguageSet {
    /// Browser grammar failures retain plugin identity even when the language is
    /// outside the stricter routing-segment alphabet or exceeds its byte budget.
    func recordGrammarFailures(_ failures: [[String: Any]], sink: (any LogSink)?) {
        for failure in failures {
            guard let language = failure["id"] as? String,
                  let raw = pluginIDs[language], let plugin = LogSegment(raw) else { continue }
            sink?.emit(PluginsGrammarLoadFailed(language: language.utf8.count <= 64 ? language : nil, plugin: plugin))
        }
    }
}
