import Foundation

/// Orchestrates the Rust-owned Discourse protocol with native browser and
/// credential adapters. It never performs or decodes an HTTP request itself.
@MainActor
final class DiscourseCommunityService {
    enum ServiceError: LocalizedError {
        case missingCredential
        case invalidAuthorizationURL
        case core(RustCoreBridge.CoreCallError)
        case credentialStore(String)

        var errorDescription: String? {
            switch self {
            case .missingCredential:
                "Log in to LINUX DO before loading posts."
            case .invalidAuthorizationURL:
                "LINUX DO returned an invalid authorization URL."
            case .core(let error):
                error.userMessage
            case .credentialStore(let message):
                "Could not update the macOS Keychain: \(message)"
            }
        }
    }

    static let origin = "https://linux.do"
    static let clientID = "app.lithe.desktop.linux-do.v1"
    static let authorizationRedirect = "lithe://auth/linux-do"
    static let credentialKey = "user-api-key"

    private let core: RustCoreBridge
    private let credentialStore: any SecureStore
    private let platformUI: any PlatformUI
    private let callbackRouter: any ExternalAuthorizationCallbackRouting
    private var authorizationFlowID: String?
    var authorizationDidComplete: ((Result<Void, Error>) -> Void)?

    init(
        core: RustCoreBridge,
        credentialStore: any SecureStore,
        platformUI: any PlatformUI,
        callbackRouter: any ExternalAuthorizationCallbackRouting
    ) {
        self.core = core
        self.credentialStore = credentialStore
        self.platformUI = platformUI
        self.callbackRouter = callbackRouter
        callbackRouter.installHandler { [weak self] url in
            guard let self else { return }
            Task { await self.completeAuthorization(callbackURL: url) }
        }
    }

    var isSignedIn: Bool {
        credentialStore.read(key: Self.credentialKey) != nil
    }

    func beginAuthorization() async throws {
        let origin = Self.origin
        let clientID = Self.clientID
        let redirect = Self.authorizationRedirect
        let result = await Task.detached { [core] in
            core.beginDiscourseAuthorization(
                origin: origin,
                clientID: clientID,
                applicationName: "Lithe for LINUX DO",
                authRedirect: redirect,
                scopes: ["read", "session_info"]
            )
        }.value
        let start = try result.mapError(ServiceError.core).get()
        guard let url = URL(string: start.authorizationUrl) else {
            throw ServiceError.invalidAuthorizationURL
        }
        authorizationFlowID = start.flowId
        platformUI.open(url)
    }

    func topics(feed: String, period: String? = nil) async throws -> RustCoreBridge.DiscourseTopicsResponse {
        let key = try credential()
        let origin = Self.origin
        let clientID = Self.clientID
        return try await Task.detached { [core] in
            core.discourseTopics(
                origin: origin,
                userAPIKey: key,
                clientID: clientID,
                feed: feed,
                period: period
            )
        }.value.mapError(ServiceError.core).get()
    }

    func topic(id: UInt64) async throws -> RustCoreBridge.DiscourseTopicResponse {
        let key = try credential()
        let origin = Self.origin
        let clientID = Self.clientID
        return try await Task.detached { [core] in
            core.discourseTopic(
                origin: origin,
                userAPIKey: key,
                clientID: clientID,
                topicID: id
            )
        }.value.mapError(ServiceError.core).get()
    }

    func categories() async throws -> RustCoreBridge.DiscourseCategoriesResponse {
        let key = try credential()
        let origin = Self.origin
        let clientID = Self.clientID
        return try await Task.detached { [core] in
            core.discourseCategories(
                origin: origin,
                userAPIKey: key,
                clientID: clientID
            )
        }.value.mapError(ServiceError.core).get()
    }

    func search(query: String) async throws -> RustCoreBridge.DiscourseSearchResponse {
        let key = try credential()
        let origin = Self.origin
        let clientID = Self.clientID
        return try await Task.detached { [core] in
            core.searchDiscourse(
                origin: origin,
                userAPIKey: key,
                clientID: clientID,
                query: query
            )
        }.value.mapError(ServiceError.core).get()
    }

    func openTopic(id: UInt64, slug: String) {
        guard let url = URL(string: "\(Self.origin)/t/\(slug)/\(id)") else { return }
        platformUI.open(url)
    }

    /// Local deletion is attempted regardless of the remote response so a
    /// failed revoke never leaves the app silently authenticated.
    func signOut() async throws {
        let key = try credential()
        let origin = Self.origin
        let clientID = Self.clientID
        let remoteResult = await Task.detached { [core] in
            core.revokeDiscourseAuthorization(
                origin: origin,
                userAPIKey: key,
                clientID: clientID
            )
        }.value
        do {
            try credentialStore.delete(key: Self.credentialKey)
        } catch {
            throw ServiceError.credentialStore(error.localizedDescription)
        }
        try remoteResult.mapError(ServiceError.core).get()
    }

    private func completeAuthorization(callbackURL: URL) async {
        guard let flowID = authorizationFlowID else { return }
        authorizationFlowID = nil
        let result = await Task.detached { [core] in
            core.completeDiscourseAuthorization(flowID: flowID, callbackURL: callbackURL.absoluteString)
        }.value
        do {
            let credential = try result.mapError(ServiceError.core).get()
            try credentialStore.write(credential.userApiKey, key: Self.credentialKey)
            authorizationDidComplete?(.success(()))
        } catch {
            authorizationDidComplete?(.failure(error))
        }
    }

    private func credential() throws -> String {
        guard let value = credentialStore.read(key: Self.credentialKey), !value.isEmpty else {
            throw ServiceError.missingCredential
        }
        return value
    }
}
