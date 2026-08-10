import Foundation

/// Resolves Core-produced Java implementation candidates through JDT LS. The
/// editor only draws markers that represent a real implementation relationship.
@MainActor
final class JavaImplementationMarkerService: @unchecked Sendable {
    private struct CacheEntry {
        let fingerprint: Int
        let markers: [JavaImplementationMarker]
    }

    private let languageService: JavaLanguageService
    private var cache: [URL: CacheEntry] = [:]

    init(languageService: JavaLanguageService) {
        self.languageService = languageService
    }

    func invalidate(_ document: EditorDocument) {
        cache[document.url.standardizedFileURL] = nil
    }

    func markers(
        for document: EditorDocument,
        candidates: [JavaImplementationMarker]
    ) async -> [JavaImplementationMarker] {
        guard document.url.pathExtension.lowercased() == "java" else { return [] }

        let url = document.url.standardizedFileURL
        let fingerprint = document.text.hashValue
        if let cached = cache[url], cached.fingerprint == fingerprint {
            return cached.markers
        }

        let limitedCandidates = Array(candidates.prefix(60))
        guard !limitedCandidates.isEmpty else {
            cache[url] = CacheEntry(fingerprint: fingerprint, markers: [])
            return []
        }

        var resolved: [JavaImplementationMarker] = []
        // Four requests at a time keeps JDT LS responsive while avoiding a
        // burst of requests for large interfaces.
        for start in stride(from: 0, to: limitedCandidates.count, by: 4) {
            let end = min(start + 4, limitedCandidates.count)
            let batch = Array(limitedCandidates[start..<end])
            let batchResults = await withTaskGroup(
                of: JavaImplementationMarker?.self,
                returning: [JavaImplementationMarker].self
            ) { group in
                for candidate in batch {
                    group.addTask { @MainActor @Sendable [weak self, weak document] in
                        guard let self, let document else { return nil }
                        let locations = await self.requestLocations(
                            for: document,
                            candidate: candidate
                        )
                        let ownURL = document.url.standardizedFileURL
                        let implementations = locations.filter {
                            !(
                                $0.url.standardizedFileURL == ownURL &&
                                $0.line == candidate.line
                            )
                        }
                        guard !implementations.isEmpty else { return nil }
                        return JavaImplementationMarker(
                            line: candidate.line,
                            utf16Column: candidate.utf16Column,
                            implementationCount: implementations.count,
                            direction: candidate.direction
                        )
                    }
                }

                var results: [JavaImplementationMarker] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }
            resolved.append(contentsOf: batchResults)
        }

        let sorted = resolved.sorted {
            if $0.line == $1.line { return $0.utf16Column < $1.utf16Column }
            return $0.line < $1.line
        }
        cache[url] = CacheEntry(fingerprint: fingerprint, markers: sorted)
        return sorted
    }

    private func requestLocations(
        for document: EditorDocument,
        candidate: JavaImplementationMarker
    ) async -> [LanguageNavigationLocation] {
        await withCheckedContinuation { continuation in
            languageService.locations(
                method: "textDocument/implementation",
                document: document,
                line: candidate.line,
                utf16Column: candidate.utf16Column
            ) { result in
                switch result {
                case .success(let locations): continuation.resume(returning: locations)
                case .failure: continuation.resume(returning: [])
                }
            }
        }
    }
}
