import Darwin
import Foundation
import LitheModuleAPI

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Resolves host names with the system resolver and, on request, looks up
/// where a public address is registered at ipinfo.io over HTTPS. Private
/// and reserved addresses are answered locally and never sent.
struct MacRemoteHostLocator: RemoteHostLocating {
    private static let lookupTimeout: TimeInterval = 10

    func resolveAddress(of host: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.resolve(host))
            }
        }
    }

    func locate(_ address: String) async -> Result<RemoteHostLocation, RemoteProbeFailure> {
        if Self.isPrivate(address) {
            return .success(RemoteHostLocation(isPrivate: true))
        }
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipinfo.io/\(encoded)/json") else {
            return .failure(RemoteProbeFailure(code: "invalidAddress", message: L10n.string("The address is invalid.")))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.lookupTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure(RemoteProbeFailure(code: "lookupFailed", message: L10n.string("The location service did not answer.")))
            }
            struct Answer: Decodable {
                let city: String?
                let region: String?
                let country: String?
                let org: String?
                let bogon: Bool?
            }
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            return .success(RemoteHostLocation(
                city: answer.city, region: answer.region, country: answer.country,
                organization: answer.org, isPrivate: answer.bogon ?? false
            ))
        } catch {
            return .failure(RemoteProbeFailure(code: "lookupFailed", message: error.localizedDescription))
        }
    }

    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// RFC 1918, loopback, unspecified, link-local, CGNAT, benchmarking, documentation,
    /// multicast/reserved and IPv6 unique-local ranges, including IPv4-mapped forms.
    static func isPrivate(_ address: String) -> Bool {
        var lower = address.lowercased()
        // An IPv4-mapped IPv6 address is judged by the IPv4 address inside.
        if lower.hasPrefix("::ffff:"), lower.contains(".") { lower = String(lower.dropFirst("::ffff:".count)) }
        let octets = lower.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1], octets[2]) {
            case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _): return true
            case (172, 16...31, _), (100, 64...127, _), (198, 18...19, _), (192, 0, 0), (192, 0, 2): return true
            case (224..., _, _): return true  // multicast, reserved and broadcast
            default: return false
            }
        }
        return lower == "::" || lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc")
            || lower.hasPrefix("fd") || lower.hasPrefix("ff")
    }
}
