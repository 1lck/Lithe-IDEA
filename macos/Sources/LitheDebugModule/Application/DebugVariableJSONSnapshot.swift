import Foundation
import LitheCoreContracts

/// A bounded projection of DAP fields, never target-side serialization or getter evaluation.
@MainActor
final class DebugVariableJSONSnapshot {
    struct Limits {
        var depth = 10
        var nodes = 1_000
        var children = 100
        var valueBytes = 4_096
        var outputBytes = 512_000
    }
    private let limits: Limits
    private let request: (Int, Int) async throws -> [DebugVariable]
    private var remaining: Int
    private var cache: [Int: [DebugVariable]] = [:]
    private let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    init(limits: Limits = Limits(), request: @escaping (Int, Int) async throws -> [DebugVariable]) {
        self.limits = limits
        self.request = request
        remaining = limits.nodes
    }

    func render(_ variables: [DebugVariable], rootsArePartial: Bool = false) async throws -> String {
        var object: [String: ToolingJSONValue] = [:]
        for variable in variables.prefix(limits.children) {
            try Task.checkCancellation()
            guard variable.name.utf8.count <= limits.valueBytes else {
                object[uniqueKey("$lithe", in: object)] = marker("Field name exceeds the size limit.")
                continue
            }
            object[uniqueKey(variable.name, in: object)] = try await visit(variable, depth: 0, ancestors: [])
        }
        if rootsArePartial || variables.count > limits.children {
            object[uniqueKey("$lithe", in: object)] = .string("Root variables limited; use the tree view to load more.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ToolingJSONValue.object(object))
        if data.count > limits.outputBytes {
            return String(decoding: try encoder.encode(marker("Snapshot exceeds the output size limit.")), as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func visit(_ variable: DebugVariable, depth: Int, ancestors: Set<Int>) async throws -> ToolingJSONValue {
        try Task.checkCancellation()
        guard remaining > 0 else { return marker("Node limit reached.") }
        remaining -= 1
        guard variable.value.utf8.count <= limits.valueBytes else { return marker("Value exceeds the size limit.") }
        guard variable.isExpandable else { return Self.scalar(variable) }
        let reference = variable.variablesReference
        guard !ancestors.contains(reference) else { return marker("Circular reference: \(reference)") }
        guard depth < limits.depth else { return marker("Depth limit reached.") }
        guard ContinuousClock.now < deadline else { return marker("Snapshot time limit reached.") }
        let children: [DebugVariable]
        do {
            if let cached = cache[reference] { children = cached }
            else {
                children = try await request(reference, limits.children + 1)
                cache[reference] = Array(children.prefix(limits.children + 1))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return marker("Cannot load fields: \(error.localizedDescription)") }
        let partial = children.count > limits.children || variable.namedVariables > limits.children
            || variable.indexedVariables > limits.children - min(limits.children, variable.namedVariables)
        let page = Array(children.prefix(limits.children))
        let indices = page.compactMap { Self.index($0.name) }
        let isArray = !page.isEmpty && indices.count == page.count && indices.sorted() == Array(0..<page.count)
        let nextAncestors = ancestors.union([reference])
        if isArray || (page.isEmpty && variable.type?.hasSuffix("[]") == true) {
            var array: [ToolingJSONValue] = []
            for child in page.sorted(by: { (Self.index($0.name) ?? 0) < (Self.index($1.name) ?? 0) }) {
                array.append(try await visit(child, depth: depth + 1, ancestors: nextAncestors))
            }
            if partial { array.append(marker("Additional items omitted.")) }
            return .array(array)
        }
        var object: [String: ToolingJSONValue] = [:]
        for child in page {
            guard child.name.utf8.count <= limits.valueBytes else {
                object[uniqueKey("$lithe", in: object)] = marker("Field name exceeds the size limit.")
                continue
            }
            object[uniqueKey(child.name, in: object)] = try await visit(child, depth: depth + 1, ancestors: nextAncestors)
        }
        if partial { object[uniqueKey("$lithe", in: object)] = .string("Additional fields omitted.") }
        return .object(object)
    }

    private func marker(_ message: String) -> ToolingJSONValue {
        .object(["$lithe": .string(String(decoding: message.utf8.prefix(1_024), as: UTF8.self))])
    }
    private func uniqueKey(_ name: String, in object: [String: ToolingJSONValue]) -> String {
        var key = name, suffix = 2
        while object[key] != nil { key = "\(name)#\(suffix)"; suffix += 1 }
        return key
    }
    private static func index(_ name: String) -> Int? {
        let raw = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        return Int(raw)
    }
    static func scalar(_ variable: DebugVariable) -> ToolingJSONValue {
        let value = variable.value
        let type = variable.type?.lowercased() ?? ""
        if type.contains("string") || type == "char" || type == "character" {
            return .string((try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value)
        }
        // Integers outside Int's exact range stay text rather than losing bits in Double.
        if !value.contains(".") && !value.lowercased().contains("e"),
           value.first?.isNumber == true || value.first == "-", Int(value) == nil { return .string(value) }
        if let scalar = try? JSONDecoder().decode(ToolingJSONValue.self, from: Data(value.utf8)) {
            switch scalar {
            case .array, .object: return .string(value)
            default: return scalar
            }
        }
        return .string(value)
    }
}

/// One DAP request owns one continuation and a deadline; cancellation never cancels unrelated inspection.
@MainActor
final class DebugVariableJSONRequest {
    private var continuation: CheckedContinuation<[DebugVariable], Error>?
    private var timeout: Task<Void, Never>?

    static func read(session: any DebugAdapterControllingSession, reference: Int, count: Int, timeout: Duration = .seconds(3)) async throws -> [DebugVariable] {
        let ticket = DebugVariableJSONRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ticket.continuation = continuation
                ticket.timeout = Task { [weak ticket] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    ticket?.finish(.failure(DebugVariableJSONError.timedOut))
                }
                session.requestVariables(reference: reference, filter: nil, start: 0, count: count) { result in
                    ticket.finish(result)
                }
            }
        } onCancel: { Task { @MainActor in ticket.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<[DebugVariable], Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel(); timeout = nil
        pending?.resume(with: result)
    }
}

private enum DebugVariableJSONError: LocalizedError {
    case timedOut
    var errorDescription: String? { "The debugger did not return object fields in time." }
}
