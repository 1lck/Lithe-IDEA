import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// The host side of function protocol 3: workspace contexts and their
/// generations, the dispatcher's own grant and context checks, the
/// `workspace` service, and when subscriptions are disposed. Every call is
/// awaited directly; nothing waits on a clock.
@MainActor
struct PluginHostServiceDispatchTests {
    private static let pluginID = "dev.lithe.fixture.workspacebackend"

    /// Another workspace in the same window is another context: the old
    /// one closes and its references expire. The same workspace again
    /// changes nothing.
    @Test
    func anotherWorkspaceInTheWindowIsANewContext() throws {
        let contexts = PluginWorkspaceContexts()
        let window = NSObject()
        var closed: [String] = []
        var revisions: [Int] = []
        contexts.observeClose { closed.append($0) }
        contexts.observeRevision { revisions.append($0) }
        let first = contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)
        let same = contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)
        let second = contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/billing"), remote: nil)

        #expect(first == same)
        #expect(first.generation == 1)
        #expect(second.contextID != first.contextID)
        #expect(second.generation == 1)
        #expect(closed == [first.contextID])
        #expect(revisions == [2, 3])
        #expect(throws: PluginHostServiceError.self) { try contexts.resolve(first.reference).get() }
        #expect(try contexts.resolve(second.reference).get() == second)

        contexts.close(owner: window)
        #expect(throws: PluginHostServiceError.self) { try contexts.resolve(second.reference).get() }
        #expect(contexts.contexts.isEmpty)
        #expect(revisions == [2, 3, 4])
    }

    /// A root ID is stable for a plugin and location, differs between
    /// plugins and secrets, and reveals no path.
    @Test
    func rootIDsAreStablePerPluginAndOpaque() {
        let rootIDs = PluginWorkspaceRootIDs(secret: Fixture.rootIDSecret)
        let id = rootIDs.rootID(of: "/Users/me/orders", pluginID: Self.pluginID)
        #expect(id == PluginWorkspaceRootIDs(secret: Fixture.rootIDSecret).rootID(of: "/Users/me/orders", pluginID: Self.pluginID))
        #expect(id != rootIDs.rootID(of: "/Users/me/billing", pluginID: Self.pluginID))
        #expect(id != rootIDs.rootID(of: "/Users/me/orders", pluginID: "dev.example.other"))
        #expect(id != PluginWorkspaceRootIDs(secret: Data(repeating: 9, count: 32)).rootID(of: "/Users/me/orders", pluginID: Self.pluginID))
        #expect(id.count == 17)
        #expect(id.hasPrefix("r"))
        #expect(!id.contains("orders"))
    }

    /// The secret is created once with owner-only access and read back the
    /// same on the next load.
    @Test
    func theRootIDSecretIsCreatedOnceAndKept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-root-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PluginHost/root-id.key")
        let first = MacPluginRootIDSecret.load(from: url)
        let second = MacPluginRootIDSecret.load(from: url)
        #expect(first.count == MacPluginRootIDSecret.byteCount)
        #expect(first == second)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    /// A session serves only its granted services, plus the implicit ones.
    @Test
    func aServiceTheSessionWasNotGrantedIsRefused() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: ["credentials"])

        let outcome = await fixture.dispatcher.dispatch(
            PluginHostRequest(id: "h-1", method: "lithe/host/workspace/listContexts", service: "workspace", params: .null),
            pluginID: Self.pluginID
        )
        #expect(outcome.failureCode == PluginHostErrorCode.permissionDenied.rawValue)

        let notRunning = await fixture.dispatcher.dispatch(
            PluginHostRequest(id: "h-2", method: "lithe/host/workspace/listContexts", service: "workspace", params: .null),
            pluginID: "dev.example.other"
        )
        #expect(notRunning.failureCode == PluginHostErrorCode.backendExited.rawValue)
    }

    /// A granted service with no handler on this host is unavailable.
    @Test
    func aGrantedServiceWithoutAHandlerIsUnavailable() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: ["files"])

        let outcome = await fixture.dispatcher.dispatch(
            PluginHostRequest(id: "h-1", method: "lithe/host/files/read", service: "files", params: .object([:])),
            pluginID: Self.pluginID
        )
        #expect(outcome.failureCode == PluginHostErrorCode.unavailable.rawValue)
    }

    /// `listContexts` and `getContext` describe a local workspace with its
    /// path and a state directory below the plugin's `${stateDir}`.
    @Test
    func aLocalContextIsDescribedWithItsPathAndStateDirectory() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: ["workspace"])
        let window = NSObject()
        let context = fixture.contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)

        let listed = try await fixture.dispatcher.dispatch(
            PluginHostRequest(id: "h-1", method: "lithe/host/workspace/listContexts", service: "workspace", params: .null),
            pluginID: Self.pluginID
        ).get()
        guard case .object(let list) = listed, case .array(let entries)? = list["contexts"] else {
            Issue.record("listContexts returned \(listed)")
            return
        }
        #expect(list["revision"] == .integer(fixture.contexts.revision))
        #expect(entries.count == 1)
        // Listing creates no state directory.
        let workspaces = fixture.stateRoot
            .appendingPathComponent(Self.pluginID, isDirectory: true)
            .appendingPathComponent("backend/workspaces", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: workspaces.path))

        let described = try await fixture.dispatcher.dispatch(
            PluginHostRequest(
                id: "h-2", method: "lithe/host/workspace/getContext", service: "workspace",
                params: .object(["context": Self.reference(context.reference)])
            ),
            pluginID: Self.pluginID
        ).get()
        guard case .object(let object) = described,
              case .string(let stateDirectory)? = object["stateDirectory"],
              case .array(let folders)? = object["folders"],
              case .object(let folder)? = folders.first else {
            Issue.record("getContext returned \(described)")
            return
        }
        var withoutDirectory = object
        withoutDirectory["stateDirectory"] = nil
        #expect(entries.first == .object(withoutDirectory))
        #expect(object["authority"] == .object(["kind": .string("local")]))
        #expect(folder["path"] == .string("/tmp/orders"))
        #expect(folder["rootID"] == .string(Fixture.rootID("/tmp/orders")))
        let expectedRoot = fixture.stateRoot
            .appendingPathComponent(Self.pluginID, isDirectory: true)
            .appendingPathComponent("backend/workspaces", isDirectory: true)
        #expect(stateDirectory.hasPrefix(expectedRoot.path))
        #expect(!stateDirectory.contains("orders"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: stateDirectory, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// A remote workspace has a remote authority and no path: the local
    /// directory is a placeholder that services must never read.
    @Test
    func aRemoteContextCarriesItsAuthorityAndNoPath() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: ["workspace"])
        let window = NSObject()
        let context = fixture.contexts.open(
            owner: window,
            rootURL: URL(fileURLWithPath: "/tmp/placeholder"),
            remote: (connectionID: "conn-1", remoteRoot: "/srv/orders")
        )

        let folders = try await fixture.dispatcher.dispatch(
            PluginHostRequest(
                id: "h-1", method: "lithe/host/workspace/getFolders", service: "workspace",
                params: .object(["context": Self.reference(context.reference)])
            ),
            pluginID: Self.pluginID
        ).get()
        #expect(context.authority == .remote(id: "conn-1"))
        #expect(context.name == "orders")
        #expect(folders == .object(["folders": .array([.object([
            "rootID": .string(Fixture.rootID("remote:conn-1:/srv/orders")),
            "name": .string("orders"),
        ])])]))
    }

    /// A request naming an older generation is told to ask again, and a
    /// malformed reference is invalid params.
    @Test
    func aStaleOrMalformedContextIsRefused() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: ["workspace"])
        let window = NSObject()
        let old = fixture.contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)
        fixture.contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/billing"), remote: nil)

        let stale = await fixture.dispatcher.dispatch(
            PluginHostRequest(
                id: "h-1", method: "lithe/host/workspace/getFolders", service: "workspace",
                params: .object(["context": Self.reference(old.reference)])
            ),
            pluginID: Self.pluginID
        )
        #expect(stale.failureCode == PluginHostErrorCode.contextExpired.rawValue)

        let malformed = await fixture.dispatcher.dispatch(
            PluginHostRequest(
                id: "h-2", method: "lithe/host/workspace/getFolders", service: "workspace",
                params: .object(["context": .object(["contextID": .string(old.contextID)])])
            ),
            pluginID: Self.pluginID
        )
        #expect(malformed.failureCode == PluginHostErrorCode.invalidParams.rawValue)
    }

    /// Subscriptions go with `dispose`, with their context, and with the
    /// session; an unknown ID disposes nothing and succeeds.
    @Test
    func subscriptionsAreDisposedByIDContextAndSession() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.dispatcher.beginSession(pluginID: Self.pluginID, hostServices: [])
        let window = NSObject()
        let context = fixture.contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)
        let log = DisposalLog()
        let subscriptions = fixture.dispatcher.subscriptions
        let byID = subscriptions.add(pluginID: Self.pluginID, contextID: nil) { log.items.append("byID") }
        _ = subscriptions.add(pluginID: Self.pluginID, contextID: context.contextID) { log.items.append("context") }
        _ = subscriptions.add(pluginID: Self.pluginID, contextID: nil) { log.items.append("session") }

        for id in [byID, "s-unknown"] {
            let outcome = try await fixture.dispatcher.dispatch(
                PluginHostRequest(
                    id: "h-\(id)", method: "lithe/host/subscriptions/dispose", service: "subscriptions",
                    params: .object(["subscriptionID": .string(id)])
                ),
                pluginID: Self.pluginID
            ).get()
            #expect(outcome == .null)
        }
        #expect(log.items == ["byID"])

        fixture.contexts.close(owner: window)
        #expect(log.items == ["byID", "context"])

        fixture.dispatcher.endSession(pluginID: Self.pluginID)
        #expect(log.items == ["byID", "context", "session"])
        #expect(subscriptions.count(pluginID: Self.pluginID) == 0)
    }

    /// Typed failures keep their code and details on the way to Core.
    @Test
    func aServiceErrorBecomesAFailureWithItsCode() {
        let failure = PluginHostServiceError(.versionConflict, "changed").failure
        #expect(failure == PluginHostRequestFailure(message: "changed", code: "plugin.host.versionConflict"))
        let detailed = PluginHostServiceError(.versionConflict, "changed", details: ["currentVersion": .integer(4)]).failure
        #expect(detailed.details == .object(["currentVersion": .integer(4)]))
    }

    /// Every error code a host reports is one Core passes on, each once.
    @Test
    func everyHostErrorCodeIsDistinct() {
        let codes = PluginHostErrorCode.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        #expect(codes.contains("plugin.host.rateLimited"))
        #expect(codes.contains("plugin.host.busy"))
    }

    /// Events of a live subscription reach the backend with a sequence that
    /// grows per subscription; a disposed one sends nothing more.
    @Test
    func subscriptionEventsCarryAGrowingSequence() {
        let subscriptions = PluginHostSubscriptions()
        let log = DeliveryLog()
        subscriptions.deliver = { pluginID, params in log.items.append((pluginID, params)) }
        let id = subscriptions.add(pluginID: Self.pluginID, contextID: nil) {}
        subscriptions.notify(pluginID: Self.pluginID, subscriptionID: id, event: ["kind": .string("changed")])
        subscriptions.notify(pluginID: Self.pluginID, subscriptionID: id, event: ["kind": .string("changed")])
        subscriptions.notify(pluginID: "dev.example.other", subscriptionID: id, event: [:])
        subscriptions.dispose(pluginID: Self.pluginID, subscriptionID: id)
        subscriptions.notify(pluginID: Self.pluginID, subscriptionID: id, event: [:])

        #expect(log.items.map(\.0) == [Self.pluginID, Self.pluginID])
        let fields = log.items.map { item -> [String: ToolingJSONValue] in
            guard case .object(let object) = item.1 else { return [:] }
            return object
        }
        #expect(fields.map { $0["sequence"] } == [.integer(1), .integer(2)])
        #expect(fields.first?["subscriptionID"] == .string(id))
        #expect(fields.first?["event"] == .object(["kind": .string("changed")]))
    }

    /// Only a `backend` 2 starts on activation events; a manifest whose
    /// version cannot be read counts as `backend` 1.
    @Test
    func theBackendVersionComesFromRequires() {
        let v2 = Data(#"{"requires":{"backend":2,"serverProcess":1}}"#.utf8)
        let v1 = Data(#"{"requires":{"backend":1}}"#.utf8)
        #expect(MacPluginBackendSessions.backendVersion(ofManifest: v2) == 2)
        #expect(MacPluginBackendSessions.backendVersion(ofManifest: v1) == 1)
        #expect(MacPluginBackendSessions.backendVersion(ofManifest: Data("{}".utf8)) == 1)
    }

    private static func reference(_ reference: PluginWorkspaceContextReference) -> ToolingJSONValue {
        .object(["contextID": .string(reference.contextID), "generation": .integer(reference.generation)])
    }

    @MainActor
    private final class DisposalLog {
        var items: [String] = []
    }

    @MainActor
    private final class DeliveryLog {
        var items: [(String, ToolingJSONValue)] = []
    }

    @MainActor
    private struct Fixture {
        static let rootIDSecret = Data(repeating: 7, count: 32)
        let contexts = PluginWorkspaceContexts()
        let dispatcher: PluginHostServiceDispatcher
        let stateRoot: URL

        init() {
            stateRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("lithe-host-dispatch-\(UUID().uuidString)", isDirectory: true)
            dispatcher = PluginHostServiceDispatcher(contexts: contexts)
            let directories = MacPluginStateDirectories(rootURL: stateRoot)
            dispatcher.register(PluginWorkspaceHostService(
                contexts: contexts,
                backendStateDirectory: { directories.backendStateDirectory(pluginID: $0) },
                rootIDSecret: { Self.rootIDSecret }
            ))
        }

        static func rootID(_ location: String) -> String {
            PluginWorkspaceRootIDs(secret: rootIDSecret).rootID(of: location, pluginID: PluginHostServiceDispatchTests.pluginID)
        }

        func remove() {
            try? FileManager.default.removeItem(at: stateRoot)
        }
    }
}

private extension Result where Success == ToolingJSONValue, Failure == PluginHostRequestFailure {
    var failureCode: String? {
        if case .failure(let failure) = self { return failure.code }
        return nil
    }
}
