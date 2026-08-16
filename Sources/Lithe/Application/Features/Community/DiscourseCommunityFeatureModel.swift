import Foundation

@MainActor
final class DiscourseCommunityFeatureModel: ObservableObject {
    enum State: Equatable {
        case signedOut
        case authorizing
        case loading
        case ready
        case failed(String)
    }

    enum Feed: String, CaseIterable, Identifiable {
        case latest
        case top

        var id: String { rawValue }
    }

    @Published private(set) var state: State
    @Published private(set) var topics: [RustCoreBridge.DiscourseTopicSummary] = []
    @Published private(set) var categories: [RustCoreBridge.DiscourseCategory] = []
    @Published private(set) var selectedTopic: RustCoreBridge.DiscourseTopicResponse?
    @Published var selectedFeed: Feed = .latest
    @Published var searchQuery = ""

    private let service: DiscourseCommunityService

    init(service: DiscourseCommunityService) {
        self.service = service
        state = service.isSignedIn ? .ready : .signedOut
        service.authorizationDidComplete = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Task { await self.refresh() }
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func authorize() async {
        state = .authorizing
        do {
            try await service.beginAuthorization()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        state = .loading
        do {
            async let topicPage = service.topics(feed: selectedFeed.rawValue)
            async let categoryPage = service.categories()
            let (topicResult, categoryResult) = try await (topicPage, categoryPage)
            topics = topicResult.topics
            categories = categoryResult.categories
            selectedTopic = nil
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func selectTopic(_ topic: RustCoreBridge.DiscourseTopicSummary) async {
        state = .loading
        do {
            selectedTopic = try await service.topic(id: topic.id)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func closeTopic() {
        selectedTopic = nil
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await refresh()
            return
        }
        state = .loading
        do {
            let result = try await service.search(query: query)
            topics = result.topics
            selectedTopic = nil
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        do {
            try await service.signOut()
            topics = []
            categories = []
            selectedTopic = nil
            state = .signedOut
        } catch {
            // The service clears Keychain after every remote revoke attempt.
            topics = []
            selectedTopic = nil
            state = .failed(error.localizedDescription)
        }
    }

    func topicURL(id: UInt64, slug: String) -> URL? {
        URL(string: "\(DiscourseCommunityService.origin)/t/\(slug)/\(id)")
    }

    func openTopic(id: UInt64, slug: String) {
        service.openTopic(id: id, slug: slug)
    }
}
