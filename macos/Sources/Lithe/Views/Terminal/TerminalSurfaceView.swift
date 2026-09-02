import AppKit
import SwiftUI
import LitheTerminalModule

struct TerminalSurfaceView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var model: AppModel
    @State private var focusRequestID = 0

    var body: some View {
        Group {
            if let nativeView = session.nativeView as? NSView {
                TerminalNativeSurface(
                    nativeView: nativeView,
                    focusRequestID: focusRequestID,
                    showsWorkbenchBackground: model.workbenchBackgroundFeature.hasImage
                )
            } else {
                model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
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
                    session.focus()
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
        guard session.isRunning else { return }
        focusRequestID &+= 1
        session.focus()
    }
}

private struct TerminalNativeSurface: NSViewRepresentable {
    let nativeView: NSView
    let focusRequestID: Int
    let showsWorkbenchBackground: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalSurfaceHostView {
        let hostView = TerminalSurfaceHostView(frame: .zero)
        hostView.attach(nativeView)
        (nativeView as? WorkbenchBackgroundRendering)?
            .setWorkbenchBackgroundVisible(showsWorkbenchBackground)
        return hostView
    }

    func updateNSView(_ hostView: TerminalSurfaceHostView, context: Context) {
        hostView.attach(nativeView)
        (nativeView as? WorkbenchBackgroundRendering)?
            .setWorkbenchBackgroundVisible(showsWorkbenchBackground)
        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async {
            guard nativeView.superview === hostView,
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
