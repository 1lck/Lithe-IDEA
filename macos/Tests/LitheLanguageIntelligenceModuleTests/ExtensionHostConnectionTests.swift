import Foundation
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import Testing

@MainActor
struct ExtensionHostConnectionTests {
    @Test func preservesSplitUTF8AndNotificationOrder() {
        let transport = RecordingExtensionTransport()
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        var values: [ToolingJSONValue] = []
        connection.onNotification = { _, value in values.append(value) }
        let bytes = Data("{\"kind\":\"notification\",\"method\":\"lithe/log\",\"params\":\"中文😀\"}\n{\"kind\":\"notification\",\"method\":\"lithe/log\",\"params\":2}\n".utf8)
        for byte in bytes { connection.receive(Data([byte])) }
        #expect(values == [.string("中文😀"), .integer(2)])
    }

    @Test func matchesResponseAndIgnoresLateDuplicate() async throws {
        let transport = RecordingExtensionTransport()
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        transport.onSend = { _ in
            connection.receive(Data("{\"kind\":\"response\",\"id\":1,\"result\":42}\n{\"kind\":\"response\",\"id\":1,\"result\":99}\n".utf8))
        }
        let value = try await connection.request("host/executeCommand", timeout: .seconds(1))
        #expect(value == .integer(42))
        #expect(transport.messages.count == 1)
    }

    @Test func closeFailsPendingAndRejectsNewRequests() async throws {
        let transport = RecordingExtensionTransport()
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        transport.onSend = { _ in connection.close() }
        for _ in 0..<2 {
            do {
                _ = try await connection.request("host/executeCommand", timeout: .seconds(1))
                Issue.record("Closed connection accepted a request")
            } catch let error as ExtensionHostFailure {
                #expect(error.code == "shuttingDown")
            }
        }
        #expect(transport.messages.count == 1)
    }

    @Test func deadlineFailsUnansweredRequest() async throws {
        let transport = RecordingExtensionTransport()
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        do {
            _ = try await connection.request("host/executeCommand", timeout: .zero)
            Issue.record("Unanswered request did not expire")
        } catch let error as ExtensionHostFailure {
            #expect(error.code == "timeout")
        }
    }

    @Test func cancellationDiscardsLateResponse() async throws {
        let transport = RecordingExtensionTransport()
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        var caller: Task<ToolingJSONValue, Error>?
        transport.onSend = { data in
            let message = try? JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
            if message?["kind"] == .string("request") {
                caller?.cancel()
            } else {
                connection.receive(Data("{\"kind\":\"response\",\"id\":1,\"result\":99}\n".utf8))
            }
        }
        let task = Task { try await connection.request("host/executeCommand", timeout: .seconds(1)) }
        caller = task
        defer { task.cancel() }
        do {
            _ = try await task.value
            Issue.record("Cancelled request returned a late response")
        } catch let error as ExtensionHostFailure {
            #expect(error.code == "cancelled")
        }
    }

    @Test func transportFailureFailsRequest() async throws {
        let transport = RecordingExtensionTransport()
        transport.failure = ExtensionHostFailure("internalError", "Broken pipe")
        let connection = ExtensionHostConnection(transport: transport)
        defer { connection.close() }
        do {
            _ = try await connection.request("host/initialize", timeout: .seconds(1))
            Issue.record("Broken transport accepted a request")
        } catch let error as ExtensionHostFailure {
            #expect(error == transport.failure)
        }
    }
}

@MainActor
private final class RecordingExtensionTransport: ExtensionHostTransport {
    var messages: [Data] = []
    var onSend: ((Data) -> Void)?
    var failure: ExtensionHostFailure?

    func send(_ data: Data) async throws {
        if let failure { throw failure }
        messages.append(data)
        onSend?(data)
    }
}
