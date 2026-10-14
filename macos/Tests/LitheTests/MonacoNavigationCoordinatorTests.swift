import Combine
import Foundation
import Testing
@testable import Lithe

/// When a navigation target turns into a Monaco jump: once per target, only
/// in the document it names, and re-presented for jumps inside the open
/// document only after the editor is ready.
@MainActor
@Suite("Monaco navigation coordinator")
struct MonacoNavigationCoordinatorTests {
    private let main = URL(fileURLWithPath: "/project/main.lua")
    private let other = URL(fileURLWithPath: "/project/other.lua")

    @Test
    func consecutiveJumpsInTheSameDocumentAreEachAppliedOnce() {
        let navigation = MonacoNavigationCoordinator()
        let first = EditorNavigationTarget(url: main, line: 0, utf16Column: 15)
        let second = EditorNavigationTarget(url: main, line: 4, utf16Column: 6)

        #expect(navigation.jump(for: first, in: main) == first)
        // A later present of the same target, for example after a keystroke, must not move the caret back.
        #expect(navigation.jump(for: first, in: main) == nil)
        #expect(navigation.jump(for: second, in: main) == second)
        #expect(navigation.jump(for: nil, in: main) == nil)
    }

    @Test
    func jumpToAnotherDocumentWaitsForThatDocument() {
        let navigation = MonacoNavigationCoordinator()
        let target = EditorNavigationTarget(url: other, line: 2, utf16Column: 0)

        #expect(navigation.jump(for: target, in: main) == nil)
        #expect(navigation.jump(for: target, in: URL(fileURLWithPath: "/project/./other.lua")) == target)
    }

    @Test
    func targetChangesPresentOnlyOnceTheEditorIsReady() {
        let navigation = MonacoNavigationCoordinator()
        let targets = PassthroughSubject<EditorNavigationTarget?, Never>()
        var ready = false
        var presented = 0
        navigation.observe(targets.eraseToAnyPublisher(), isReady: { ready }, present: { presented += 1 })
        // A second mount observing again must not present every change twice.
        navigation.observe(targets.eraseToAnyPublisher(), isReady: { ready }, present: { presented += 1 })

        targets.send(EditorNavigationTarget(url: main, line: 0, utf16Column: 15))
        #expect(presented == 0)

        ready = true
        targets.send(EditorNavigationTarget(url: main, line: 4, utf16Column: 6))
        targets.send(EditorNavigationTarget(url: other, line: 1, utf16Column: 0))
        #expect(presented == 2)
    }
}
