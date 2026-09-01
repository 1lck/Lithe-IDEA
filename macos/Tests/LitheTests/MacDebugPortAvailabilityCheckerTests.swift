import Darwin
import Testing
@testable import Lithe

@Suite("macOS Debug port availability")
@MainActor
struct MacDebugPortAvailabilityCheckerTests {
    @Test
    func reportsAListeningPortAsUnavailableAndAReleasedPortAsAvailable() throws {
        var descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(descriptor, 1) == 0)

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        #expect(nameResult == 0)
        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        #expect(port > 0)

        let checker = MacDebugPortAvailabilityChecker()
        #expect(!checker.isPortAvailable(port))
        #expect(close(descriptor) == 0)
        descriptor = -1
        #expect(checker.isPortAvailable(port))
    }
}
