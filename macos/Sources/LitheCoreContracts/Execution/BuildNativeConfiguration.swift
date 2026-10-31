import Foundation
import LitheModuleAPI

/// Non-sensitive native facts from the selected engine. Full native documents
/// stay in the platform file adapter and never enter the provider wire or UI.
package struct BuildNativeConfiguration: Codable, Equatable, Sendable {
    package struct Field: Codable, Equatable, Sendable, Identifiable {
        package enum Kind: String, Codable, Sendable { case text, file, directory, boolean, stringList }
        package let id: String
        package let kind: Kind
        package let value: ToolingJSONValue
        package let effectiveValue: ToolingJSONValue
        package let effectiveSource: String
    }
    package struct Source: Codable, Equatable, Sendable, Identifiable {
        package enum Scope: String, Codable, Sendable { case installation, user, workspace }
        package let id: String
        package let scope: Scope
        package let uri: String
        package let revision: String
        package let writable: Bool
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

/// Public receipt; native source/replacement bytes never enter the wire.
package struct BuildNativeConfigurationEditReceipt: Decodable, Sendable {
    package let sourceID: String
    package let revision: String
    package let changed: Bool
}

/// Private staging ownership retained through late replies and cancellation.
package struct BuildNativeConfigurationStaging: Sendable {
    package let sourceID: String
    package let sourceURL: URL
    package let url: URL
    package let expected: Data?
    package let outputFile: URL
    package init(sourceID: String, sourceURL: URL, url: URL, expected: Data?, outputFile: URL) {
        self.sourceID = sourceID; self.sourceURL = sourceURL; self.url = url
        self.expected = expected; self.outputFile = outputFile
    }
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
                 edits: BuildNativeConfigurationEdits, stateDirectory: URL) throws -> BuildNativeConfigurationStaging?
    func complete(_ staging: BuildNativeConfigurationStaging, receipt: BuildNativeConfigurationEditReceipt) throws -> BuildNativeConfigurationPreparedWrite?
    func discard(_ staging: BuildNativeConfigurationStaging) throws
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
    func configurationEditPlan(_ target: BuildSystemTarget, context: BuildPlanContext, hints: BuildProviderHints,
                               snapshot: BuildNativeConfiguration, edits: BuildNativeConfigurationEdits, outputFile: URL) throws -> BuildProviderRequest {
        throw PluginFunctionFailure(code: "plugin.build.unavailable", message: L10n.string("Native configuration is unavailable."))
    }
    func decodeConfigurationEdit(_ target: BuildSystemTarget, snapshot: BuildNativeConfiguration,
                                 edits: BuildNativeConfigurationEdits, result: ToolingJSONValue) throws -> BuildNativeConfigurationEditReceipt {
        throw PluginFunctionFailure(code: "plugin.build.unavailable", message: L10n.string("Native configuration is unavailable."))
    }
}
