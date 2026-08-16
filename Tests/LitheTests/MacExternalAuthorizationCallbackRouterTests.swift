import Foundation
import Testing
@testable import Lithe

@MainActor
struct MacExternalAuthorizationCallbackRouterTests {
    @Test
    func retainsValidEarlyCallbackUntilHandlerIsInstalled() throws {
        let router = MacExternalAuthorizationCallbackRouter()
        let callback = try #require(URL(string: "lithe://auth/linux-do?payload=fake"))
        var received: URL?

        router.route(callback)
        router.installHandler { received = $0 }

        #expect(received == callback)
    }

    @Test
    func rejectsCallbacksOutsideTheLinuxDoTarget() throws {
        let router = MacExternalAuthorizationCallbackRouter()
        var received: URL?
        router.installHandler { received = $0 }

        router.route(try #require(URL(string: "lithe://auth/another-provider?payload=fake")))
        router.route(try #require(URL(string: "https://auth/linux-do?payload=fake")))

        #expect(received == nil)
    }
}
