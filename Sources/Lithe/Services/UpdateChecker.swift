import AppKit
import Foundation

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let prerelease: Bool
    let draft: Bool

    var displayVersion: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case prerelease
        case draft
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let downloadURL: URL?
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published var notice: UpdateNotice?

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/1lck/Lithe-IDEA/releases/latest")!
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let lastAutomaticCheckKey = "lithe.update.lastAutomaticCheck"

    private let currentVersion: String

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !isChecking else { return }
        if !manual, !shouldPerformAutomaticCheck() { return }

        isChecking = true
        defer { isChecking = false }

        if !manual {
            UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticCheckKey)
        }

        do {
            let release = try await fetchLatestRelease()
            guard !release.draft, !release.prerelease else { return }

            if isNewer(release.displayVersion, than: currentVersion) {
                notice = UpdateNotice(
                    title: "Lithe \(release.displayVersion) is available",
                    message: "You are using Lithe \(currentVersion). Download the latest version from GitHub Releases.",
                    downloadURL: release.htmlURL
                )
            } else if manual {
                notice = UpdateNotice(
                    title: "Lithe is up to date",
                    message: "You are using the latest published version, Lithe \(currentVersion).",
                    downloadURL: nil
                )
            }
        } catch UpdateCheckError.noPublishedRelease {
            if manual {
                notice = UpdateNotice(
                    title: "No release is available yet",
                    message: "There is no published GitHub Release to check yet.",
                    downloadURL: Self.releasePageURL
                )
            }
        } catch {
            if manual {
                notice = UpdateNotice(
                    title: "Could not check for updates",
                    message: "Check your internet connection and try again later.",
                    downloadURL: nil
                )
            }
        }
    }

    func openRelease(_ url: URL?) {
        guard let url else { return }
        notice = nil
        NSWorkspace.shared.open(url)
    }

    private static let releasePageURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lithe/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            throw UpdateCheckError.noPublishedRelease
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func shouldPerformAutomaticCheck() -> Bool {
        guard let lastCheck = UserDefaults.standard.object(forKey: Self.lastAutomaticCheckKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = versionComponents(candidate),
              let currentComponents = versionComponents(current) else {
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

    private func versionComponents(_ version: String) -> [Int]? {
        let normalized = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let components = normalized.split(separator: ".", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }

        var values: [Int] = []
        for component in components {
            guard let value = Int(component) else { return nil }
            values.append(value)
        }
        return values
    }
}

private enum UpdateCheckError: Error {
    case noPublishedRelease
    case invalidResponse
    case httpStatus(Int)
}
