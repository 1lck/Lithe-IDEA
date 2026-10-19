import AppKit
import SwiftUI

/// IDEA Islands tool-window tabs share colors and geometry across tool windows.
struct LitheToolWindowTabStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false
    let isSelected: Bool
    let isActive: Bool
    var fileColor: Color? = nil

    func body(content: Content) -> some View {
        content
            .frame(height: 28)
            .background {
                if let fileColor {
                    // IslandsTabPainter: colored editor tabs retain the editor surface and border.
                    if isSelected {
                        LitheTheme.editor
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(fileColor.opacity(tabIsActive ? 1 : 0.4))
                            .padding(3)
                    } else {
                        fileColor.opacity(0.4)
                        if isHovered { hoverBackground }
                    }
                } else {
                    isSelected ? (isHovered && !tabIsActive ? hoverBackground : selectedTabBackground)
                               : isHovered ? hoverBackground : .clear
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? selectedTabBorder : .clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }

    static func testSourceColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 28/255, green: 38/255, blue: 28/255)
                        : Color(red: 237/255, green: 250/255, blue: 239/255)
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
            let clickedInside = !view.isHiddenOrHasHiddenAncestor
                && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            context.coordinator.queuePointerActivity(clickedInside)
            return event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.updateBinding($isActive)
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
        private var eventVersion = 0
        private let schedule: (@escaping () -> Void) -> Void

        func updateBinding(_ binding: Binding<Bool>) { _isActive = binding }

        func queuePointerActivity(_ clickedInside: Bool) {
            guard let window = view?.window else { return }
            eventVersion += 1
            let version = eventVersion
            let owner = Self.focusOwner(window.firstResponder)
            schedule { [weak self, weak window] in
                guard let self, let window, self.view?.window === window,
                      self.eventVersion == version else { return }
                if Self.focusOwner(window.firstResponder) !== owner {
                    self.synchronizeFocus()
                } else if self.isActive != clickedInside {
                    self.isActive = clickedInside
                }
            }
        }

        private func synchronizeFocus() {
            eventVersion += 1
            guard let view, let window = view.window else { isActive = false; return }
            lastResponder = Self.focusOwner(window.firstResponder)
            guard let responder = lastResponder as? NSView else { isActive = false; return }
            let rect = view.convert(responder.visibleRect.intersection(responder.bounds), from: responder)
            let active = !view.isHiddenOrHasHiddenAncestor && !responder.isHiddenOrHasHiddenAncestor
                && view.bounds.intersects(rect)
            if isActive != active { isActive = active }
        }

        func stopObservingFocus() {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            focusObserver = nil; lastResponder = nil
            eventVersion += 1
            let version = eventVersion
            // SwiftUI may be destroying its graph here; publish only after that transaction ends.
            schedule { [self] in
                guard eventVersion == version else { return }
                if isActive { isActive = false }
            }
        }

        private func queueFocusSynchronization() {
            eventVersion += 1
            let version = eventVersion
            schedule { [weak self] in
                guard let self, self.eventVersion == version else { return }
                self.synchronizeFocus()
            }
        }

        func observeFocus() {
            stopObservingFocus()
            guard let window = view?.window else { return }
            lastResponder = Self.focusOwner(window.firstResponder)
            // Mount callbacks can also run during a SwiftUI graph update; read the final layout next turn.
            queueFocusSynchronization()
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, let window = view.window else { return }
                    let owner = Self.focusOwner(window.firstResponder)
                    guard self.lastResponder !== owner else { return }
                    self.lastResponder = owner
                    self.queueFocusSynchronization()
                }
            }
        }

        // Fields in the same window share a native field editor; track the edited control instead.
        private static func focusOwner(_ responder: NSResponder?) -> NSResponder? {
            guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder }
            return editor.delegate as? NSView ?? editor
        }

        init(isActive: Binding<Bool>, schedule: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }) {
            _isActive = isActive
            self.schedule = schedule
        }
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
