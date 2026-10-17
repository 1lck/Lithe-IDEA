import Foundation
import LitheCoreContracts
@testable import LitheDebugModule
import Testing

@MainActor
struct DebugVariableJSONSnapshotTests {
    private func variable(_ name: String, _ value: String = "Object@1", _ type: String? = nil, reference: Int = 0) -> DebugVariable {
        DebugVariable(id: name, name: name, value: value, type: type, evaluateName: name, variablesReference: reference)
    }
    private func decode(_ text: String) throws -> ToolingJSONValue {
        try JSONDecoder().decode(ToolingJSONValue.self, from: Data(text.utf8))
    }

    @Test func nestedObjectsAndArraysLoadWithoutExpandingTheTree() async throws {
        var requests: [Int] = []
        let pages = [
            1: [variable("profile", reference: 2), variable("orders", reference: 3)],
            2: [variable("name", "\"张三\"", "String"), variable("id", "9223372036854775807", "long")],
            3: [variable("[1]", "2", "int"), variable("[0]", "1", "int")]
        ]
        let loader = DebugVariableJSONSnapshot { reference, count in
            #expect(count == 101)
            requests.append(reference)
            return pages[reference] ?? []
        }
        let value = try decode(try await loader.render([variable("request", reference: 1)]))
        #expect(value == .object(["request": .object([
            "profile": .object(["name": .string("张三"), "id": .integer(Int.max)]),
            "orders": .array([.integer(1), .integer(2)])
        ])]))
        #expect(requests == [1, 2, 3])
    }

    @Test func cyclesAreMarkedButSharedReferencesAreNotMistakenForCycles() async throws {
        var requests = 0
        let loader = DebugVariableJSONSnapshot { _, _ in
            requests += 1
            return [self.variable("self", reference: 1), self.variable("ok", "true", "boolean")]
        }
        let text = try await loader.render([variable("a", reference: 1), variable("b", reference: 1)])
        #expect(requests == 1)
        #expect(text.contains("Circular reference"))
        guard case let .object(root) = try decode(text) else { Issue.record("Expected root object"); return }
        #expect(root["a"] == root["b"])
    }

    @Test func anExactChildPageIsCompleteButAnExtraChildIsMarked() async throws {
        var limits = DebugVariableJSONSnapshot.Limits()
        limits.children = 2
        for childCount in [2, 3] {
            let loader = DebugVariableJSONSnapshot(limits: limits) { _, count in
                #expect(count == 3)
                return (0..<childCount).map { self.variable("field\($0)", "\($0)", "int") }
            }
            let text = try await loader.render([variable("root", reference: 1)])
            _ = try decode(text)
            #expect(text.contains("Additional fields omitted") == (childCount > 2))
        }
    }

    @Test func scalarTypesAndOversizedIntegersRemainExact() {
        #expect(DebugVariableJSONSnapshot.scalar(variable("s", "123", "String")) == .string("123"))
        #expect(DebugVariableJSONSnapshot.scalar(variable("x", "18446744073709551615", "ulong")) == .string("18446744073709551615"))
        #expect(DebugVariableJSONSnapshot.scalar(variable("n", "null")) == .null)
        #expect(DebugVariableJSONSnapshot.scalar(variable("f", "3.14", "double")) == .number(3.14))
        #expect(DebugVariableJSONSnapshot.scalar(variable("n", "NaN", "double")) == .string("NaN"))
    }

    @Test func limitsAndUnavailableFieldsStayValidJSONAndExplicitlyMarked() async throws {
        var limits = DebugVariableJSONSnapshot.Limits()
        limits.children = 2
        limits.depth = 1
        let loader = DebugVariableJSONSnapshot(limits: limits) { _, _ in
            [self.variable("$lithe", "real", "String"), self.variable("deep", reference: 2), self.variable("omitted", "3")]
        }
        let text = try await loader.render([variable("root", reference: 1)], rootsArePartial: true)
        _ = try decode(text)
        #expect(text.contains("Depth limit"))
        #expect(text.contains("Additional fields"))
        #expect(text.contains("$lithe#2"))
        #expect(text.contains("Root variables limited"))
        let failed = DebugVariableJSONSnapshot { _, _ in throw URLError(.cannotConnectToHost) }
        let failure = try await failed.render([variable("root", reference: 1)])
        _ = try decode(failure)
        #expect(failure.contains("Cannot load fields"))
    }

    @Test func cancellationPropagatesInsteadOfProducingAPartialSuccess() async {
        let loader = DebugVariableJSONSnapshot { _, _ in throw CancellationError() }
        do { _ = try await loader.render([variable("root", reference: 1)]); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func aCancelledPendingRequestRejectsALateProviderReply() async {
        let session = SnapshotSession()
        var operation: Task<[DebugVariable], Error>?
        session.request = { _ in operation?.cancel() }
        operation = Task { try await DebugVariableJSONRequest.read(session: session, reference: 1, count: 2) }
        defer { operation?.cancel(); session.request = nil; session.pending = nil }
        do { _ = try await operation?.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        // A provider response after cancellation must not resume the continuation twice.
        session.pending?(.success([]))
        session.pending = nil
    }

    @Test func aSilentProviderHasABoundedRequestDeadline() async {
        let session = SnapshotSession()
        do {
            _ = try await DebugVariableJSONRequest.read(session: session, reference: 1, count: 2, timeout: .zero)
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("did not return object fields")) }
        session.pending?(.success([]))
        session.pending = nil
    }

    @Test func featureSnapshotPreservesTreeStateAndRejectsResumedFrames() async throws {
        let session = SnapshotSession()
        session.pages = [100: [variable("request", reference: 1)], 1: [variable("count", "42", "int")]]
        let manager = DebugAdapterSessionManager(providers: [DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset(); session.request = nil; session.pending = nil }
        let root = URL(fileURLWithPath: "/snapshot-fixture")
        #expect(feature.start(fileURL: root.appendingPathComponent("Main.java"), rootURL: root,
                              configuration: DebugLaunchConfiguration(name: "Snapshot", request: .launch, arguments: [:])))
        session.state = .paused
        session.onStateChange?(.paused)
        session.onEvent?(.stopped(reason: "breakpoint", threadID: 1, description: nil))
        #expect(try await feature.variableJSONSnapshot().contains("42"))
        #expect(feature.expandedVariableIDs.isEmpty)
        #expect(feature.variableChildren.isEmpty)
        session.request = { completion in
            session.state = .running
            session.onStateChange?(.running)
            completion(.success([]))
        }
        do { _ = try await feature.variableJSONSnapshot(); Issue.record("Expected stale frame cancellation") }
        catch { #expect(error is CancellationError) }
        session.pending = nil
    }

    @Test func nodeValueAndOutputLimitsAreBounded() async throws {
        var limits = DebugVariableJSONSnapshot.Limits()
        limits.nodes = 1
        let loader = DebugVariableJSONSnapshot(limits: limits) { _, _ in [] }
        let text = try await loader.render([variable("a", "1"), variable("b", "2")])
        #expect(text.contains("Node limit"))
        limits.valueBytes = 2
        let values = DebugVariableJSONSnapshot(limits: limits) { _, _ in [] }
        #expect(try await values.render([variable("a", "长内容")]).contains("size limit"))
        let names = DebugVariableJSONSnapshot(limits: limits) { _, _ in [] }
        #expect(try await names.render([variable("oversized name", "1")]).contains("Field name"))
        limits.outputBytes = 1
        let output = DebugVariableJSONSnapshot(limits: limits) { _, _ in [] }
        let limited = try await output.render([variable("a", "1")])
        _ = try decode(limited)
        #expect(limited.contains("output size limit"))
    }
}

@MainActor
private final class SnapshotSession: DebugAdapterControllingSession {
    var isRunning = false
    var state: DebugAdapterState = .idle
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    var pages: [Int: [DebugVariable]] = [:]
    var pending: ((Result<[DebugVariable], Error>) -> Void)?
    var request: (((Result<[DebugVariable], Error>) -> Void) -> Void)?
    func start(rootURL: URL) throws { isRunning = true; state = .ready }
    func stop() { isRunning = false; pending = nil }
    func launch(_ configuration: DebugLaunchConfiguration) throws { state = .running }
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {}
    func execute(_ command: DebugExecutionCommand, threadID: Int?) {}
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        completion(.success([DebugThread(id: 1, name: "main")]))
    }
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void) {
        completion(.success([DebugStackFrame(id: 1, name: "main", sourceURL: nil, line: 1, column: 1)]))
    }
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void) {
        completion(.success([DebugScope(id: 100, name: "Locals", variablesReference: 100, expensive: false)]))
    }
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void) {
        if let request { pending = completion; request(completion) }
        else if let page = pages[reference] { completion(.success(page)) }
        else { pending = completion }
    }
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void) {
        completion(.failure(URLError(.unsupportedURL)))
    }
}
