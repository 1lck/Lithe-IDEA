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
        let secondFinished = TestGate()
        queue.enqueue {
            order.append(false)
            secondFinished.open()
        }

        #expect(await firstStarted.waitUntilOpen(timeout: .seconds(2)))
        #expect(queue.isBusy)
        #expect(order.isEmpty)
        releaseFirst.open()

        #expect(
            await secondFinished.waitUntilOpen(timeout: .seconds(2)),
            "serial queue should finish both actions in click order"
        )
        #expect(order == [true, false])
        #expect(!queue.isBusy)
    }

    @Test
    func gitExcludeOutcomeClassifiesMissingRepositoryAndGenericFailure() {
        #expect(
            LSPGeneratedArtifactGitExcludeOutcome.classify(
                succeeded: true,
                output: "",
                operationErrorMessage: nil
            ) == .updated
        )
        #expect(
            LSPGeneratedArtifactGitExcludeOutcome.classify(
                succeeded: false,
                output: "Not a Git repository",
                operationErrorMessage: nil
            ) == .noRepository
        )
        #expect(
            LSPGeneratedArtifactGitExcludeOutcome.classify(
                succeeded: false,
                output: "ignored",
                operationErrorMessage: "Not a Git repository: fatal: not a git repository"
            ) == .noRepository
        )
        #expect(
            LSPGeneratedArtifactGitExcludeOutcome.classify(
                succeeded: false,
                output: "Another Git write operation is running in this repository",
                operationErrorMessage: nil
            ) == .failed
        )
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
