import AppKit
import SwiftUI
import LitheTerminalModule

struct TerminalSurfaceView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var focusRequestID = 0

    var body: some View {
        Group {
            if let nativeView = session.nativeView as? NSView {
                TerminalNativeSurface(
                    nativeView: nativeView,
                    focusRequestID: focusRequestID,
                    theme: settings.colorTheme,
                    isDark: colorScheme == .dark,
                    showsWorkbenchBackground: model.workbenchBackgroundFeature.hasImage
                )
            } else {
                model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
        .overlay {
            if let error = session.launchError {
                VStack(spacing: 8) {
                    Text("Unable to start terminal").font(LitheTheme.uiFont(.headline))
                    Text(error).font(LitheTheme.smallFont).textSelection(.enabled)
                    Text("Detect installed shells and choose a shell from the New Terminal menu.")
                        .font(LitheTheme.smallFont)
                }
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
        .litheContextMenu {
            [
                .action("Copy", systemImage: "doc.on.doc", action: {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }),
                .action("Paste", systemImage: "doc.on.clipboard", action: {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }),
                .action("Select All", systemImage: "selection.pin.in.out", action: {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }),
                .separator,
                .action("Clear", systemImage: "eraser", action: session.clear),
                .action("Restart", systemImage: "arrow.clockwise", action: {
                    session.restart()
                    requestInputFocus()
                }),
                .action("Close Terminal", systemImage: "xmark", action: {
                    model.requestCloseTerminalSession(session)
                })
            ]
        }
        .task(id: session.id) {
            requestInputFocus()
        }
    }

    private func requestInputFocus() {
        guard session.isRunning, let nativeView = session.nativeView as? NSView,
              nativeView.window != nil, !nativeView.isHiddenOrHasHiddenAncestor else { return }
        focusRequestID &+= 1
        session.focus()
    }
}

private struct TerminalNativeSurface: NSViewRepresentable {
    let nativeView: NSView
    let focusRequestID: Int
    let theme: AppColorTheme
    let isDark: Bool
    let showsWorkbenchBackground: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalSurfaceHostView {
        let hostView = TerminalSurfaceHostView(frame: .zero)
        hostView.attach(nativeView)
        (nativeView as? LitheTerminalView)?.updateWorkbenchSurface(
            isVisible: showsWorkbenchBackground,
            theme: theme,
            isDark: isDark
        )
        context.coordinator.lastTheme = theme
        context.coordinator.lastIsDark = isDark
        context.coordinator.lastShowsWorkbenchBackground = showsWorkbenchBackground
        return hostView
    }

    func updateNSView(_ hostView: TerminalSurfaceHostView, context: Context) {
        hostView.attach(nativeView)
        if context.coordinator.lastTheme != theme || context.coordinator.lastIsDark != isDark
            || context.coordinator.lastShowsWorkbenchBackground != showsWorkbenchBackground {
            (nativeView as? LitheTerminalView)?.updateWorkbenchSurface(
                isVisible: showsWorkbenchBackground,
                theme: theme,
                isDark: isDark
            )
            context.coordinator.lastTheme = theme
            context.coordinator.lastIsDark = isDark
            context.coordinator.lastShowsWorkbenchBackground = showsWorkbenchBackground
        }
        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async {
            guard nativeView.superview === hostView,
                  !nativeView.isHiddenOrHasHiddenAncestor,
                  let window = nativeView.window,
                  window.firstResponder !== nativeView else { return }
            window.makeFirstResponder(nativeView)
        }
    }

    static func dismantleNSView(_ hostView: TerminalSurfaceHostView, coordinator: Coordinator) {
        hostView.detachCurrentView()
    }

    final class Coordinator: NSObject {
        var lastFocusRequestID = -1
        var lastTheme: AppColorTheme?
        var lastIsDark: Bool?
        var lastShowsWorkbenchBackground: Bool?
    }
}


private final class TerminalSurfaceHostView: NSView {
    private weak var terminalView: NSView?

    func attach(_ view: NSView) {
        // A source host can receive one last update after the persistent
        // terminal view has already moved to its destination. Do not let that
        // stale host reclaim the view or detach it while switching sessions.
        if terminalView === view {
            guard view.superview === self else { return }
            view.frame = bounds
            return
        }
        if let terminalView, terminalView.superview === self {
            terminalView.removeFromSuperview()
        }
        view.removeFromSuperview()
        terminalView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.frame = bounds
    }

    func detachCurrentView() {
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.removeFromSuperview()
        self.terminalView = nil
    }
}
