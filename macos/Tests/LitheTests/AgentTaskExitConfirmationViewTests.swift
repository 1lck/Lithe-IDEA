import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct AgentTaskExitConfirmationViewTests {
    private static let presentedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// The command box follows a short command's height and stops growing at
    /// its maximum, so a long JSON argument scrolls instead of stretching the
    /// dialog past the screen.
    @Test func commandBoxFitsShortCommandsAndBoundsLongOnes() throws {
        let settings = "{" + (0..<80).map { #""KEY_\#($0)":"value-\#($0)""# }.joined(separator: ",") + "}"
        let longer = "{" + (0..<160).map { #""KEY_\#($0)":"value-\#($0)""# }.joined(separator: ",") + "}"
        let short = try render(task(command: "npm run dev"), purpose: .quit, name: nil)
        let long = try render(task(command: "/usr/local/bin/claude --verbose --settings " + settings), purpose: .quit, name: nil)
        let longest = try render(task(command: "/usr/local/bin/claude --verbose --settings " + longer), purpose: .quit, name: nil)

        #expect(short.fittingSize.height < long.fittingSize.height)
        #expect(long.fittingSize.height - short.fittingSize.height < AgentTaskExitConfirmationView.maximumCommandHeight)
        #expect(long.fittingSize.height == longest.fittingSize.height)
        #expect(long.fittingSize.width == AgentTaskExitConfirmationView.width)
    }

    @Test func buttonsReportTheChosenAnswer() async throws {
        for (title, expected) in [
            (String(localized: "Keep Running"), AgentTaskExitAnswer.keep),
            (String(localized: "End This Task"), .terminate),
            (String(localized: "Cancel Quit"), .cancel)
        ] {
            var answers: [AgentTaskExitAnswer] = []
            try await withHost(task(command: "npm run dev"), purpose: .quit, onAnswer: { answers.append($0) }) { host in
                let button = try #require(await button(title, in: host))
                #expect(button.accessibilityPerformPress?() == true)
            }
            #expect(answers == [expected], "\(title)")
        }
    }

    /// Closing an Agent connection cannot be cancelled, so the dialog offers no Cancel Quit.
    @Test func onlyQuittingOffersCancel() async throws {
        for purpose in [ProcessConfirmationPurpose.disconnect, .startupSweep] {
            try await withHost(task(command: "npm run dev"), purpose: purpose) { host in
                #expect(await button(String(localized: "Keep Running"), in: host) != nil)
                let titles = accessibilityButtons(in: host).compactMap(label(of:))
                #expect(!titles.contains(String(localized: "Cancel Quit")))
            }
        }
    }

    @Test func copyButtonAsksForTheOriginalCommand() async throws {
        var copies = 0
        try await withHost(task(command: "npm run dev"), purpose: .quit, onCopy: { copies += 1 }) { host in
            let button = try #require(await button(String(localized: "Copy Original Command"), in: host))
            #expect(button.accessibilityPerformPress?() == true)
        }
        #expect(copies == 1)
    }

    /// Writes reference renderings when LITHE_PROCESS_EXIT_SCREENSHOTS names a directory.
    @Test func rendersInDarkAndLightThemes() throws {
        let command = #"/Users/example/.local/bin/claude --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool stdio --resume=0e936a4a-f8d5-474f-848b-2a90b2195d25 --disallowedTools AskUserQuestion --tools default --setting-sources=user,project,local --permission-mode default --include-partial-messages --replay-user-messages --settings {"apiKeyHelper":"","env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:58608/lithe-87f4c2","ANTHROPIC_API_KEY":"example","ANTHROPIC_AUTH_TOKEN":"","CLAUDE_CODE_MAX_RETRIES":"0","CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK":"1","CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_VERTEX":"0","ANTHROPIC_BEDROCK_BASE_URL":"","ANTHROPIC_VERTEX_BASE_URL":""}}"#
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            _ = try render(task(command: command), purpose: .quit, scheme: scheme, name: "agent-task-quit-\(suffix)")
            _ = try render(
                task(command: "npm run dev", directory: "/Users/example/project/web", processCount: 3),
                purpose: .startupSweep,
                scheme: scheme,
                name: "agent-task-sweep-\(suffix)"
            )
        }
    }

    // MARK: - Helpers

    private func task(command: String, directory: String? = nil, processCount: Int = 1) -> AgentTaskCandidate {
        AgentTaskCandidate(
            id: "task",
            agentName: "claude-acp",
            workspace: "/Users/example/project",
            commandLine: command,
            workingDirectory: directory,
            startedAt: Self.presentedAt.addingTimeInterval(-(39 * 60 + 25)),
            processCount: processCount
        )
    }

    private func makeHost(
        _ task: AgentTaskCandidate,
        purpose: ProcessConfirmationPurpose,
        scheme: ColorScheme = .light,
        onCopy: @escaping () -> Void = {},
        onAnswer: @escaping (AgentTaskExitAnswer) -> Void = { _ in }
    ) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: AgentTaskExitConfirmationView(
            task: task,
            position: 1,
            count: 1,
            purpose: purpose,
            presentedAt: Self.presentedAt,
            onCopyCommand: onCopy,
            onAnswer: onAnswer
        ).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return host
    }

    private func render(
        _ task: AgentTaskCandidate,
        purpose: ProcessConfirmationPurpose,
        scheme: ColorScheme = .light,
        name: String?
    ) throws -> NSView {
        let host = makeHost(task, purpose: purpose, scheme: scheme)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let name { try capture(host, name: name) }
        return host
    }

    private func withHost(
        _ task: AgentTaskCandidate,
        purpose: ProcessConfirmationPurpose,
        onCopy: @escaping () -> Void = {},
        onAnswer: @escaping (AgentTaskExitAnswer) -> Void = { _ in },
        _ body: (NSView) async throws -> Void
    ) async throws {
        // SwiftUI only publishes its accessibility tree to an assistive client.
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let host = makeHost(task, purpose: purpose, onCopy: onCopy, onAnswer: onAnswer)
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await body(host)
    }

    /// Waits a bounded time for SwiftUI to publish the button's accessibility node.
    private func button(_ title: String, in host: NSView) async -> AnyObject? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if let match = accessibilityButtons(in: host).first(where: { label(of: $0) == title }) { return match }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }

    private func accessibilityButtons(in element: Any) -> [AnyObject] {
        // SwiftUI nodes expose the native selectors without adopting the full
        // NSAccessibilityProtocol. Optional dispatch also handles ignored views.
        let accessible = element as AnyObject
        let isButton = accessible.accessibilityRole?() == .button
        return (isButton ? [accessible] : [])
            + (accessible.accessibilityChildren?() ?? []).flatMap { accessibilityButtons(in: $0) }
    }

    private func label(of element: AnyObject) -> String? {
        element.accessibilityLabel?() ?? element.accessibilityTitle?()
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LITHE_PROCESS_EXIT_SCREENSHOTS"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
