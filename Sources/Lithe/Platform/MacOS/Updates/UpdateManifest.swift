import Foundation

struct UpdateManifest: Decodable, Sendable {
    let schemaVersion: Int
    let version: String
    let releaseURL: URL
    let assets: [String: UpdateManifestAsset]

    func validated(allowingLocalHTTP: Bool = false) throws -> UpdateManifest {
        guard schemaVersion == 1 else {
            throw UpdateCheckError.unsupportedSchema(schemaVersion)
        }
        guard let versionComponents = UpdateVersion.components(version),
              versionComponents.count == 3,
              Self.isAllowedWebURL(releaseURL, allowingLocalHTTP: allowingLocalHTTP),
              !assets.isEmpty else {
            throw UpdateCheckError.invalidManifest
        }

        for asset in assets.values {
            guard Self.isAllowedWebURL(asset.url, allowingLocalHTTP: allowingLocalHTTP),
                  asset.sha256.range(
                    of: #"^[0-9a-fA-F]{64}$"#,
                    options: .regularExpression
                  ) != nil else {
                throw UpdateCheckError.invalidManifest
            }
        }
        return self
    }

    func asset(for architecture: UpdateArchitecture) throws -> UpdateManifestAsset {
        guard let asset = assets[architecture.rawValue] else {
            throw UpdateCheckError.noCompatibleAsset
        }
        return asset
    }

    private static func isAllowedWebURL(_ url: URL, allowingLocalHTTP: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return allowingLocalHTTP
            && scheme == "http"
            && UpdateEndpointConfiguration.isLoopbackHost(host)
    }
}

struct UpdateManifestAsset: Decodable, Equatable, Sendable {
    let url: URL
    let sha256: String

    var normalizedSHA256: String {
        sha256.lowercased()
    }
}

enum UpdateArchitecture: String, Sendable {
    case arm64
    case x86_64

    static var current: UpdateArchitecture? {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return nil
        #endif
    }
}

enum UpdateVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = components(candidate),
              let currentComponents = components(current) else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    static func components(_ version: String) -> [Int]? {
        let normalized = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let rawComponents = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        var values: [Int] = []
        for component in rawComponents {
            guard !component.isEmpty, let value = Int(component), value >= 0 else { return nil }
            values.append(value)
        }
        return values
    }
}

enum UpdateCheckError: Error, Equatable {
    case noPublishedRelease
    case invalidResponse
    case rateLimited
    case httpStatus(Int)
    case timedOut
    case tlsOrProxyFailure
    case connectionFailed
    case invalidManifest
    case unsupportedSchema(Int)
    case noCompatibleAsset
    case checksumMismatch
    case downloadFailed
    case notAppBundle
    case appNotFoundInDiskImage
    case toolFailed(String)

    var userMessage: String {
        switch self {
        case .rateLimited:
            return String(localized: "GitHub rejected the update request because a shared API limit was reached. Open the Release page or try again after the limit resets.")
        case .httpStatus(let status):
            return String(
                format: String(localized: "The update server returned HTTP %@. Open the Release page to download the update manually, or try again later."),
                String(status)
            )
        case .timedOut:
            return String(localized: "The update request timed out. Check your proxy or VPN connection and try again.")
        case .tlsOrProxyFailure:
            return String(localized: "A secure connection to GitHub could not be established. Check TLS inspection, proxy, VPN, or system certificate settings.")
        case .connectionFailed:
            return String(localized: "GitHub could not be reached. Check your internet, proxy, or VPN connection and try again.")
        case .invalidResponse:
            return String(localized: "The update server returned an unexpected response. Open the Release page and download the update manually.")
        case .invalidManifest:
            return String(localized: "The published update manifest is invalid and cannot be trusted. Open the Release page and download the update manually.")
        case .unsupportedSchema(let version):
            return String(
                format: String(localized: "This version of Lithe cannot read update manifest schema %@. Open the Release page and update manually."),
                String(version)
            )
        case .noCompatibleAsset:
            return String(localized: "No update package is available for this Mac architecture. Open the Release page to check available downloads.")
        case .checksumMismatch:
            return String(localized: "The downloaded update failed its SHA-256 verification. Do not install it; retry or use the Release page.")
        case .downloadFailed:
            return String(localized: "The update package could not be downloaded. Check your internet, proxy, or VPN connection and try again.")
        case .notAppBundle:
            return String(localized: "Self-update is only available when Lithe is running from a packaged Lithe.app.")
        case .appNotFoundInDiskImage:
            return String(localized: "The downloaded disk image does not contain Lithe.app.")
        case .toolFailed:
            return String(localized: "macOS could not prepare the update disk image. Open the Release page and install it manually.")
        case .noPublishedRelease:
            return String(localized: "There is no published GitHub Release to check yet.")
        }
    }
}
