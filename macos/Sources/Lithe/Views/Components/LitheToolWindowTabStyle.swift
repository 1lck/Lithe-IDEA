import AppKit
import SwiftUI

/// IDEA Islands tool-window tabs share colors and geometry across tool windows.
struct LitheToolWindowTabStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false
    let isSelected: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: 28)
            .background(isSelected ? (isHovered && !tabIsActive ? hoverBackground : selectedTabBackground)
                                   : isHovered ? hoverBackground : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? selectedTabBorder : .clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }

    private var selectedTabBackground: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return tabIsActive ? LitheTheme.activeTabBackground : LitheTheme.subtleSelection
        }
        if colorScheme == .dark {
            return tabIsActive ? Color(red: 35/255, green: 53/255, blue: 88/255)
                                    : Color(red: 38/255, green: 40/255, blue: 44/255)
        }
        return tabIsActive ? Color(red: 227/255, green: 235/255, blue: 254/255)
                                : Color(red: 233/255, green: 234/255, blue: 238/255)
    }

    private var selectedTabBorder: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return tabIsActive ? LitheTheme.accent.opacity(0.45) : LitheTheme.divider
        }
        if colorScheme == .dark {
            return tabIsActive ? Color(red: 46/255, green: 77/255, blue: 137/255)
                                    : Color(red: 64/255, green: 67/255, blue: 74/255)
        }
        return tabIsActive ? Color(red: 167/255, green: 197/255, blue: 255/255)
                                : Color(red: 209/255, green: 211/255, blue: 217/255)
    }

    private var tabIsActive: Bool { isActive && controlActiveState == .key }

    private var hoverBackground: Color {
        guard LitheTheme.activeTheme == .lithe else { return LitheTheme.subtleSelection }
        // IDEA Islands tab-bg-hovered: #FFFFFF17 dark, #00000012 light.
        return colorScheme == .dark ? .white.opacity(23.0/255) : .black.opacity(18.0/255)
    }

}

/// Tracks clicks across the whole tool window, including embedded AppKit content.
struct LitheToolWindowActivityTracker: NSViewRepresentable {
    @Binding var isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        context.coordinator.view = view
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.observeFocus() }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let view = context.coordinator.view, let window = view.window,
                  event.window === window else { return event }
            let clickedInside = view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            if context.coordinator.isActive != clickedInside {
                DispatchQueue.main.async {
                    guard context.coordinator.view != nil else { return }
                    context.coordinator.isActive = clickedInside
                }
            }
            return event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
    }

    func makeCoordinator() -> Coordinator { Coordinator(isActive: $isActive) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        coordinator.stopObservingFocus()
        (view as? TrackingView)?.windowChanged = nil
        coordinator.view = nil
    }

    final class Coordinator {
        @Binding var isActive: Bool
        weak var view: NSView?
        var monitor: Any?
        private var focusObserver: NSObjectProtocol?
        private weak var lastResponder: NSResponder?

        func stopObservingFocus() {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            focusObserver = nil; lastResponder = nil
        }

        func observeFocus() {
            stopObservingFocus()
            guard let window = view?.window else { return }
            lastResponder = window.firstResponder
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, let window = view.window,
                          self.lastResponder !== window.firstResponder else { return }
                    self.lastResponder = window.firstResponder
                    guard let responder = window.firstResponder as? NSView else { return }
                    let rect = view.convert(responder.visibleRect.intersection(responder.bounds), from: responder)
                    let active = view.bounds.intersects(rect) && !responder.isHiddenOrHasHiddenAncestor
                    if self.isActive != active { self.isActive = active }
                }
            }
        }

        init(isActive: Binding<Bool>) { _isActive = isActive }
    }

    private final class TrackingView: NSView {
        var windowChanged: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The circular hover background is part of IDEA's CloseHovered SVG.
struct LitheToolWindowTabCloseButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            LitheIDEAIcon(
                resourcePath: isHovered && isEnabled
                    ? "expui/general/closeSmallHovered.svg" : "expui/general/closeSmall.svg",
                size: 16,
                fallbackSystemImage: "xmark",
                preservesOriginalColors: true
            )
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close tab")
    }
}

/// Shared Islands header separator; retain Lithe's requested 1pt side inset.
struct LitheToolWindowHeaderDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme)).frame(height: 1)
            .padding(.horizontal, 1)
    }
}
