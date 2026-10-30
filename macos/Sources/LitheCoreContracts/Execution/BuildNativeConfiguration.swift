import Foundation
import LitheModuleAPI

/// Non-sensitive native facts from the selected engine. Full native documents
/// stay in the platform file adapter and never enter the provider wire or UI.
package struct BuildNativeConfiguration: Codable, Equatable, Sendable {
    package struct Root: Codable, Equatable, Sendable {
        package let name: String
        package let namespace: String
    }
    package struct Field: Codable, Equatable, Sendable, Identifiable {
        package enum Kind: String, Codable, Sendable { case text, file, directory, boolean, stringList }
        package let id: String
        package let kind: Kind
        package let value: ToolingJSONValue
        package let effectiveValue: ToolingJSONValue
        package let effectiveSource: String
        package let path: [String]
        package let itemElement: String?
    }
    package struct Source: Codable, Equatable, Sendable, Identifiable {
        package enum Scope: String, Codable, Sendable { case installation, user, workspace }
        package let id: String
        package let scope: Scope
        package let uri: String
        package let revision: String
        package let writable: Bool
        package let rootElement: Root
        package let fields: [Field]
    }
    package let format: String
    package let version: Int
    package let sources: [Source]
}

package struct BuildNativeConfigurationEdits: Codable, Equatable, Sendable {
    package let sourceID: String
    package let revision: String
    package let values: [String: ToolingJSONValue]
    package init(sourceID: String, revision: String, values: [String: ToolingJSONValue]) {
        self.sourceID = sourceID; self.revision = revision; self.values = values
    }
}

/// Host/Core-only replacement. It can contain unrelated secret fields and must
/// never be sent to a provider, rendered, or included in logs.
package struct BuildNativeConfigurationDocumentEdit: Decodable, Sendable {
    package let document: String?
    package let revision: String
    package let changed: Bool
}

/// A prepared write contains native bytes, exclusively for the storage adapter.
/// Preparation runs on a worker; commit follows a current-operation check on
/// the owner actor so a workspace switch cannot publish an old draft.
package struct BuildNativeConfigurationPreparedWrite: Sendable {
    package let url: URL
    package let sourceURL: URL
    package let expected: Data?
    package let replacement: Data
    package let revision: String
    package init(url: URL, sourceURL: URL? = nil, expected: Data?, replacement: Data, revision: String) {
        self.url = url; self.sourceURL = sourceURL ?? url
        self.expected = expected; self.replacement = replacement; self.revision = revision
    }
}

package protocol BuildNativeConfigurationStoring: Sendable {
    func prepare(target: BuildSystemTarget, snapshot: BuildNativeConfiguration,
                 edits: BuildNativeConfigurationEdits) throws -> BuildNativeConfigurationPreparedWrite?
    func commit(_ write: BuildNativeConfigurationPreparedWrite) throws
}

package extension BuildSystemPlanning {
    func configurationPlan(_ target: BuildSystemTarget, context: BuildPlanContext,
                           hints: BuildProviderHints) throws -> BuildProviderRequest {
        throw PluginFunctionFailure(code: "plugin.build.unavailable", message: L10n.string("Native configuration is unavailable."))
    }
    func decodeConfiguration(_ target: BuildSystemTarget, result: ToolingJSONValue) throws -> BuildNativeConfiguration {
        throw PluginFunctionFailure(code: "plugin.build.unavailable", message: L10n.string("Native configuration is unavailable."))
    }
    func editConfigurationDocument(_ target: BuildSystemTarget, snapshot: BuildNativeConfiguration,
                                   edits: BuildNativeConfigurationEdits, document: String?) throws -> BuildNativeConfigurationDocumentEdit {
        throw PluginFunctionFailure(code: "plugin.build.unavailable", message: L10n.string("Native configuration is unavailable."))
    }
}
