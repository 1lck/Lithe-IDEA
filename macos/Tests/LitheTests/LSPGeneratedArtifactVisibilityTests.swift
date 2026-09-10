import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("LSP generated artifact visibility")
struct LSPGeneratedArtifactVisibilityTests {
    @Test
    func recommendedPatternsInsertAndRemoveWithoutDuplicates() {
        let inserted = LSPGeneratedArtifactVisibility.inserting(into: ["*.generated.swift"])
        #expect(inserted.contains(".factorypath"))
        #expect(inserted.contains("*.generated.swift"))
        #expect(
            LSPGeneratedArtifactVisibility.inserting(into: inserted)
                .filter { $0 == ".factorypath" }
                .count == 1
        )

        let removed = LSPGeneratedArtifactVisibility.removing(from: inserted)
        #expect(!removed.contains(".factorypath"))
        #expect(removed.contains("*.generated.swift"))
        #expect(LSPGeneratedArtifactVisibility.removing(from: removed) == removed)
    }

    @Test
    func defaultVisibilityRulesDoNotHideFactorypath() {
        #expect(!FileVisibilityRules.default.hiddenFilePatterns.contains(".factorypath"))
        #expect(LSPGeneratedArtifactVisibility.filePatterns == [".factorypath"])
    }

    @Test
    @MainActor
    func serialActionQueuePreservesClickOrderAcrossAwaitedBoundaries() async {
        let queue = SerialMainActorActionQueue()
        let firstStarted = TestGate()
        let releaseFirst = TestGate()
        var order: [Bool] = []

        queue.enqueue {
            firstStarted.open()
            #expect(await releaseFirst.waitUntilOpen(timeout: .seconds(2)))
            order.append(true)
        }
        queue.enqueue {
            order.append(false)
        }

        #expect(await firstStarted.waitUntilOpen(timeout: .seconds(2)))
        #expect(queue.isBusy)
        #expect(order.isEmpty)
        releaseFirst.open()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, order != [true, false] {
            await Task.yield()
        }
        #expect(order == [true, false])
        #expect(!queue.isBusy)
    }

    @Test
    func hiddenPathsDraftDirtinessRequiresApplyBeforeRecommendedRules() {
        let directories = ["build", "target"]
        let files = [".DS_Store"]
        #expect(
            !LSPGeneratedArtifactVisibilityRulesDraft.hasUnappliedChanges(
                directoriesDraft: directories.joined(separator: "\n"),
                filePatternsDraft: files.joined(separator: "\n"),
                persistedDirectories: directories,
                persistedFilePatterns: files
            )
        )
        #expect(
            LSPGeneratedArtifactVisibilityRulesDraft.hasUnappliedChanges(
                directoriesDraft: "build\ncache",
                filePatternsDraft: files.joined(separator: "\n"),
                persistedDirectories: directories,
                persistedFilePatterns: files
            )
        )
        #expect(
            LSPGeneratedArtifactVisibilityRulesDraft.hasUnappliedChanges(
                directoriesDraft: directories.joined(separator: "\n"),
                filePatternsDraft: "*.scratch",
                persistedDirectories: directories,
                persistedFilePatterns: files
            )
        )
    }
}

enum LSPGeneratedArtifactVisibilityRulesDraft {
    static func hasUnappliedChanges(
        directoriesDraft: String,
        filePatternsDraft: String,
        persistedDirectories: [String],
        persistedFilePatterns: [String]
    ) -> Bool {
        entries(from: directoriesDraft) != persistedDirectories
            || entries(from: filePatternsDraft) != persistedFilePatterns
    }

    private static func entries(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
