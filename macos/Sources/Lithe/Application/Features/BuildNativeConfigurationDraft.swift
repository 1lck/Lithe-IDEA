import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A source's editable raw values. Inherited effective values are populated in
/// controls but remain absent from edits until the user enables an override.
struct BuildNativeConfigurationDraft: Equatable {
    let source: BuildNativeConfiguration.Source
    private(set) var values: [String: ToolingJSONValue]
    private(set) var overrides: Set<String>

    init(source: BuildNativeConfiguration.Source) {
        self.source = source
        values = Dictionary(uniqueKeysWithValues: source.fields.map {
            ($0.id, $0.value == .null ? $0.effectiveValue : $0.value)
        })
        overrides = Set(source.fields.filter { $0.value != .null }.map(\.id))
    }

    var edits: BuildNativeConfigurationEdits {
        var changed: [String: ToolingJSONValue] = [:]
        for field in source.fields {
            let next = overrides.contains(field.id) ? (values[field.id] ?? .null) : .null
            if next != field.value { changed[field.id] = next }
        }
        return BuildNativeConfigurationEdits(sourceID: source.id, revision: source.revision, values: changed)
    }
    var isDirty: Bool { !edits.values.isEmpty }

    mutating func setOverride(_ enabled: Bool, fieldID: String) {
        if enabled { overrides.insert(fieldID) } else { overrides.remove(fieldID) }
    }
    mutating func setValue(_ value: ToolingJSONValue, fieldID: String) {
        guard source.fields.contains(where: { $0.id == fieldID }) else { return }
        values[fieldID] = value
    }
    func text(_ fieldID: String) -> String {
        switch values[fieldID] {
        case .string(let value): value
        case .array(let items): items.compactMap { if case .string(let value) = $0 { value } else { nil } }.joined(separator: "\n")
        default: ""
        }
    }
    mutating func setText(_ text: String, field: BuildNativeConfiguration.Field) {
        if field.kind == .stringList {
            setValue(.array(text.split(whereSeparator: \.isNewline).map { .string(String($0)) }), fieldID: field.id)
        } else { setValue(.string(text), fieldID: field.id) }
    }
}
