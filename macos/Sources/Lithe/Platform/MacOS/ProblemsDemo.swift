#if DEBUG
import AppKit
import LitheModuleAPI
import SwiftUI

/// Debug-only native demo; all writable files and settings belong to this instance.
@MainActor
final class ProblemsDemo: NSObject, NSApplicationDelegate {
    private let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lithe-Problems-Demo-\(UUID().uuidString)", isDirectory: true)
    private let settingsDomain = "Lithe.ProblemsDemo.\(UUID().uuidString)"
    private let logSink = MacLogStore()
    private var model: AppModel?
    private var window: NSWindow?
    private var loadTask: Task<Void, Never>?
    private var closing = false
    private var quitMonitor: Any?

    static func run() {
        let app = NSApplication.shared
        let delegate = ProblemsDemo()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            for (path, text) in ProblemsDemoData.files {
                let url = workspace.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            guard let defaults = UserDefaults(suiteName: settingsDomain) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let store = MacUserDefaultsStore(defaults: defaults)
            let settings = AppSettings(store: store, logDirectoryProvider: MacServiceContainer.makeLogDirectoryProvider())
            settings.language = .english
            settings.themePreference = .dark
            MacBundledFontRegistry.registerFonts(logSink: logSink)
            let model = AppModel(settings: settings,
                services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode, applicationLogging: logSink).services)
            self.model = model
            // Seed only the fixture root; do not start normal workspace scanners or language servers.
            model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
            let root = ProblemsView(initialScope: .file, previewEnabled: true)
                .environmentObject(model).environmentObject(settings)
                .environmentObject(model.editorDiagnosticsStore)
                .environment(\.locale, settings.language.locale)
                .environment(\.colorScheme, .dark)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Lithe — Problems Demo (all diagnostic types)"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentMinSize = NSSize(width: 600, height: 350)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            self.window = window
            quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                return event
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            loadTask = Task { [weak self] in
                guard let self else { return }
                await model.documentFeature.openFileAsync(workspace.appendingPathComponent("Main.txt"),
                    isReadOnly: true, displayPath: nil, activateWhenReady: true)
                guard !Task.isCancelled else { return }
                model.editorDiagnosticsStore.replace(ProblemsDemoData.diagnostics(at: workspace))
            }
        } catch {
            logSink.emit(AppDemoFailed(error: error, stage: "prepare"))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closing else { return .terminateLater }
        closing = true
        loadTask?.cancel()
        Task { @MainActor in
            let deadline = Task { @MainActor in
                // log-exempt: 用户取消：调用方取消采样或超时等待时结束任务
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                cleanup()
                sender.reply(toApplicationShouldTerminate: true)
            }
            await model?.shutdownProjectSession()
            deadline.cancel()
            cleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func cleanup() {
        if let quitMonitor { NSEvent.removeMonitor(quitMonitor); self.quitMonitor = nil }
        UserDefaults.standard.removePersistentDomain(forName: settingsDomain)
        do {
            if FileManager.default.fileExists(atPath: workspace.path) { try FileManager.default.removeItem(at: workspace) }
        } catch {
            logSink.emit(AppDemoFailed(error: error, stage: "cleanup"))
        }
    }
}

/// Synthetic data never enters the normal workspace or language-server pipeline.
enum ProblemsDemoData {
    static let files: [String: String] = [
        "Main.txt": """
        # Demo document
        section demo
        begin
        count = "not a number"
        token = null
        unused = 0
        oldApi()
        print("Information: a newer API is available")
        unknownProvider()
        longMessage = "Demonstrates truncation and a complete tooltip"
        print("中文 · Unicode · emoji 🔎")
        end
        """,
        "config/settings.yml": """
        server:
          port: invalid
        demo:
          missing-property: true
        """,
        "Clean.txt": "clean\n"
    ]

    static func diagnostics(at root: URL) -> [URL: [EditorDiagnostic]] {
        let main = root.appendingPathComponent("Main.txt")
        let config = root.appendingPathComponent("config/settings.yml")
        func problem(_ id: String, file: URL, line: Int, severity: DiagnosticSeverity, message: String,
                     tags: Set<DiagnosticTag> = [], related: [DiagnosticRelatedInformation] = []) -> EditorDiagnostic {
            EditorDiagnostic(id: id, fileURL: file, line: line, utf16Column: 4,
                endLine: line, endUTF16Column: 8, severity: severity, message: message,
                source: "Demo", code: id, tags: tags, relatedInformation: related)
        }
        return [
            main: [
                problem("type-mismatch", file: main, line: 3, severity: .error,
                    message: "Type mismatch: cannot convert from String to int",
                    related: [.init(fileURL: main, line: 3, utf16Column: 4, message: "Expected an integer value here")]),
                problem("possible-null", file: main, line: 4, severity: .warning, message: "Variable 'token' may be null"),
                problem("unused-variable", file: main, line: 5, severity: .hint, message: "Variable 'unused' is never used", tags: [.unnecessary]),
                problem("deprecated-api", file: main, line: 6, severity: .warning, message: "'oldApi()' is deprecated", tags: [.deprecated]),
                problem("api-information", file: main, line: 7, severity: .information, message: "A newer API is available"),
                problem("unknown-severity", file: main, line: 8, severity: .unknown, message: "Diagnostic without a recognized severity"),
                problem("long-description", file: main, line: 9, severity: .information,
                    message: "This deliberately long diagnostic verifies that the message truncates in narrow panels while the complete description, source, code and related information remain available in the tooltip.\nSecond line of the diagnostic.",
                    related: [.init(fileURL: config, line: 1, utf16Column: 2, message: "Related configuration location")]),
                problem("unicode", file: main, line: 10, severity: .hint, message: "Unicode message: 中文 · café · 🔎")
            ],
            config: [
                problem("invalid-port", file: config, line: 1, severity: .error, message: "'invalid' is not a valid integer port"),
                problem("unknown-property", file: config, line: 3, severity: .warning, message: "Unknown configuration property 'demo.missing-property'")
            ]
        ]
    }
}
#endif
