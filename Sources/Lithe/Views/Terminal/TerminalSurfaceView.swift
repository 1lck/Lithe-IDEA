import AppKit
import SwiftUI
import LitheTerminalModule

struct TerminalSurfaceView: View {
    @ObservedObject var session: TerminalSession
    @State private var focusRequestID = 0

    var body: some View {
        Group {
            if let nativeView = session.nativeView as? NSView {
                TerminalNativeSurface(
                    nativeView: nativeView,
                    focusRequestID: focusRequestID
                )
            } else {
                LitheTheme.editor
            }
        }
        .background(LitheTheme.editor)
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalSurfaceHostView {
        TerminalSurfaceHostView(frame: .zero)
    }

    func updateNSView(_ hostView: TerminalSurfaceHostView, context: Context) {
        hostView.attach(nativeView)
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
        guard terminalView !== view || view.superview !== self else { return }
        terminalView?.removeFromSuperview()
        view.removeFromSuperview()
        terminalView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    func detachCurrentView() {
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.removeFromSuperview()
        self.terminalView = nil
    }
}
