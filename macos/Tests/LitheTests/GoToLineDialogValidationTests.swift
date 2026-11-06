import AppKit
import Combine
import Testing
@testable import Lithe

@Suite("Go to Line validation", .serialized)
@MainActor
struct GoToLineDialogValidationTests {
    @Test
    func returnDuringValidationWaitsForTheCurrentResult() async {
        let started = TestGate()
        let release = TestGate()
        let confirmed = TestGate()
        defer { release.open() }
        let coordinator = GoToLineDialogCoordinator(parseInput: { _ in
            started.open()
            guard await release.waitUntilOpen() else { return nil }
            return GoToLineInput(line: 11, column: 2, hasExplicitColumn: true)
        }, waitForQuiet: { true })
        let field = NSTextField()
        field.stringValue = "12:3"
        coordinator.field = field
        coordinator.onConfirm = { confirmed.open() }
        coordinator.validate(field.stringValue)
        #expect(await started.waitUntilOpen())
        coordinator.confirmFromField()
        #expect(!confirmed.isOpen)
        release.open()
        #expect(await confirmed.waitUntilOpen())
        #expect(coordinator.confirmedInput == GoToLineInput(line: 11, column: 2, hasExplicitColumn: true))
    }

    @Test
    func validationCompletesInsideTheNativeModalRunLoop() async throws {
        guard ProcessInfo.processInfo.environment["LITHE_GOTO_LINE_MODAL_CHILD"] == "1" else {
            try await runModalValidationInChild()
            return
        }
        let app = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField()
        panel.contentView?.addSubview(field)
        let coordinator = GoToLineDialogCoordinator(parseInput: { _ in
            GoToLineInput(line: 11, column: 2, hasExplicitColumn: true)
        })
        coordinator.field = field
        coordinator.onConfirm = { app.stopModal(withCode: .OK) }
        // A native modal loop has no async test deadline; this watchdog closes
        // the owned panel if its main-actor validation cannot run.
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { app.stopModal(withCode: .cancel) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        defer { watchdog.invalidate(); panel.close() }
        field.stringValue = "12:3"
        coordinator.validate(field.stringValue)
        coordinator.confirmFromField()
        panel.orderFront(nil)
        let response = app.runModal(for: panel)
        #expect(response == .OK)
        #expect(coordinator.confirmedInput == GoToLineInput(line: 11, column: 2, hasExplicitColumn: true))
    }

    @Test
    func modalValidationDoesNotInterruptALaterWebPreview() async throws {
        try await runModalValidationInChild()
        let browser = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { browser.tearDown() }
        browser.show("<title>ready</title><p>project page</p>")
        #expect(await browser.waitForTitle("ready"))
    }

    private func runModalValidationInChild() async throws {
        let image = try #require(Bundle(for: GoToLineModalBundleMarker.self).executableURL)
        var environment = ProcessInfo.processInfo.environment
        environment["LITHE_GOTO_LINE_MODAL_CHILD"] = "1"
        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: ["--test-bundle-path", image.path, "--testing-library", "swift-testing", "--filter",
                "GoToLineDialogValidationTests.*validationCompletesInsideTheNativeModalRunLoop"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: environment, timeout: .seconds(10)
        )
        let output = String(decoding: result.output, as: UTF8.self)
        try #require(result.terminationStatus == 0, "Native modal validation failed: \(output)")
        #expect(output.contains("Test run with 1 test in 1 suite passed"),
            "Native modal validation must finish before the child exits: \(output)")
    }

    @Test
    func staleValidationCannotReplaceTheCurrentInput() async throws {
        let firstStarted = TestGate()
        let firstRelease = TestGate()
        let firstReturned = TestGate()
        let currentPublished = TestGate()
        let confirmed = TestGate()
        defer { firstRelease.open() }
        let coordinator = GoToLineDialogCoordinator(parseInput: { text in
            if text == "1" {
                firstStarted.open()
                _ = await firstRelease.waitUntilOpen()
                firstReturned.open()
                return GoToLineInput(line: 0, column: 0)
            }
            return GoToLineInput(line: 1, column: 2, hasExplicitColumn: true)
        }, waitForQuiet: { true })
        let field = NSTextField()
        coordinator.field = field
        coordinator.onConfirm = { confirmed.open() }
        let observation = coordinator.$canConfirm.dropFirst().sink { value in
            if value { currentPublished.open() }
        }
        defer { observation.cancel() }
        field.stringValue = "1"
        coordinator.validate("1")
        #expect(await firstStarted.waitUntilOpen())
        coordinator.confirmFromField()
        field.stringValue = "2:3"
        coordinator.validate("2:3")
        #expect(await currentPublished.waitUntilOpen())
        firstRelease.open()
        #expect(await firstReturned.waitUntilOpen())
        #expect(!confirmed.isOpen)
        coordinator.confirmFromButton()
        #expect(coordinator.confirmedInput == GoToLineInput(line: 1, column: 2, hasExplicitColumn: true))
    }
}

private final class GoToLineModalBundleMarker: NSObject {}
