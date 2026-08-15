import Foundation
import LitheCoreContracts

final class MacGitHubHTTPTransport: GitHubHTTPTransport, @unchecked Sendable {
    enum TransportError: LocalizedError {
        case invalidPlan
        case missingCredential
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidPlan: "GitHub produced an invalid request"
            case .missingCredential: "Connect a GitHub account before continuing"
            case .invalidResponse: "GitHub returned an invalid HTTP response"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func execute(plan: GitHubRequestPlan, token: String?) async throws -> GitHubHTTPResponse {
        if plan.requiresAuthentication, token?.isEmpty != false {
            throw TransportError.missingCredential
        }
        let baseURL: URL
        switch plan.host {
        case .api: baseURL = URL(string: "https://api.github.com")!
        case .web: baseURL = URL(string: "https://github.com")!
        }
        let url = try Self.requestURL(baseURL: baseURL, plan: plan)

        var request = URLRequest(url: url)
        request.httpMethod = plan.method
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lithe", forHTTPHeaderField: "User-Agent")
        if let body = plan.body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if plan.requiresAuthentication, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        return GitHubHTTPResponse(
            status: response.statusCode,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }

    static func requestURL(baseURL: URL, plan: GitHubRequestPlan) throws -> URL {
        guard plan.path.hasPrefix("/"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidPlan
        }
        // Rust Core returns an already percent-encoded path. Assigning it directly
        // prevents branch separators and UTF-8 names from being encoded twice.
        components.percentEncodedPath = plan.path
        if !plan.query.isEmpty {
            components.queryItems = plan.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw TransportError.invalidPlan }
        return url
    }
}
