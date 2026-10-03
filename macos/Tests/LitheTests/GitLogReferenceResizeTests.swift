import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheGitModule

@MainActor
@Suite("Git Log reference resize integration", .serialized)
struct GitLogReferenceResizeTests {
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func loadedBranchesRemainLazyDuringHeightChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-reference-resize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) async throws -> String {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0, "\(String(decoding: result.output, as: UTF8.self))")
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["-c", "user.name=Lithe Test", "-c", "user.email=test@example.invalid",
                          "commit", "-q", "--allow-empty", "-m", "Initial"])
        let hash = try await git(["rev-parse", "HEAD"])
        let count = 1_000
        let refs = (0..<count).map { "\(hash) refs/heads/branch-\(String(format: "%04d", $0))" }.joined(separator: "\n")
        try Data((refs + "\n").utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let suite = "lithe-reference-resize-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true },
                          notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        try #require(feature.gitReferences.count == count + 1)
        let content = GitLogView(feature: feature, workbench: model.workbenchFeature,
            background: model.workbenchBackgroundFeature, projectName: "Resize fixture",
            navigation: GitLogNavigation(compareWithWorkingTree: { _ in }, compareReferences: { _, _ in }, openCommitDiff: { _ in }),
            worktreeActions: GitWorktreeActions(openProject: { _ in }, reveal: { _ in }, copyPath: { _ in }, chooseParentDirectory: { nil }))
            .environmentObject(settings).workbenchHoverTooltipScope()
        let host = NSHostingView(rootView: LitheSplitPaneView(axis: .vertical, placement: .trailing,
            defaultSize: 350, minimum: 100, maximum: 550, sized: { content }, flexible: { Color.clear }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menus() -> [NSView] {
            descendants(host).filter { String(describing: type(of: $0)) == "LitheRightClickCaptureView" }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while menus().isEmpty && clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        try #require(!menus().isEmpty, "Git Log did not mount branch rows before the deadline")
        let before = menus().count
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }
            .first { $0.axis == .vertical })
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x, y: origin.y + offset),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        var durations: [Duration] = []
        for offset: CGFloat in [150, -150, 100, -50, 200, 0] {
            let start = clock.now
            handle.mouseDragged(with: try event(.leftMouseDragged, offset: offset))
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            durations.append(start.duration(to: clock.now))
        }
        handle.mouseUp(with: try event(.leftMouseUp))
        host.layoutSubtreeIfNeeded()
        print("GIT_LOG_RESIZE refs=\(count) mounted=\(before)->\(menus().count) layouts=\(durations)")
        #expect(menus().count < 100, "Offscreen branches must not mount their native row controls")
    }
}
