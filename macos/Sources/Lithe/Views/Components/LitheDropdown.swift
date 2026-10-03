import AppKit
import SwiftUI

/// Product dropdown entry points. Visuals remain owned by LitheContextMenu.swift.
@resultBuilder
enum LitheMenuItemsBuilder {
    static func buildExpression(_ item: LitheContextMenuItem) -> [LitheContextMenuItem] { [item] }
    static func buildExpression(_ items: [LitheContextMenuItem]) -> [LitheContextMenuItem] { items }
    static func buildBlock(_ parts: [LitheContextMenuItem]...) -> [LitheContextMenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ items: [LitheContextMenuItem]?) -> [LitheContextMenuItem] { items ?? [] }
    static func buildEither(first: [LitheContextMenuItem]) -> [LitheContextMenuItem] { first }
    static func buildEither(second: [LitheContextMenuItem]) -> [LitheContextMenuItem] { second }
    static func buildArray(_ parts: [[LitheContextMenuItem]]) -> [LitheContextMenuItem] { parts.flatMap { $0 } }
}

extension LitheContextMenuItem {
    static func submenu(_ title: String, @LitheMenuItemsBuilder items: () -> [Self]) -> Self {
        submenu(title, items: items())
    }

    static func toggle(_ title: String, isOn: Binding<Bool>) -> Self {
        .action(title, systemImage: isOn.wrappedValue ? "checkmark" : nil) { isOn.wrappedValue.toggle() }
    }

    static func heading(_ title: String) -> Self { .action(title, isEnabled: false) {} }

    func disabled(_ value: Bool) -> Self {
        var item = self
        item.isEnabled = item.isEnabled && !value
        return item
    }
}

struct LitheMenu<Label: View>: View {
    @State private var isPresented = false
    let opensToSide: Bool
    let items: () -> [LitheContextMenuItem]
    let label: () -> Label

    init(opensToSide: Bool = false, @LitheMenuItemsBuilder content: @escaping () -> [LitheContextMenuItem],
         @ViewBuilder label: @escaping () -> Label) {
        self.opensToSide = opensToSide
        items = content
        self.label = label
    }

    var body: some View {
        let menuItems = items()
        let button = Button { isPresented.toggle() } label: { label() }
            .overlay {
                LitheDropdownPopover(opensToSide: opensToSide, isPresented: $isPresented, items: menuItems) { EmptyView() }
            }
            .disabled(menuItems.isEmpty)
        if opensToSide {
            button.buttonStyle(LitheDropdownRowStyle(isSelected: isPresented))
        } else {
            button
        }
    }
}

extension View {
    func litheDropdown<Content: View>(isPresented: Binding<Bool>, opensUpward: Bool = false, searchOnTyping: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay { LitheDropdownPopover(opensUpward: opensUpward, searchOnTyping: searchOnTyping, isPresented: isPresented, content: content) }
    }
}

/// The anchor only measures; clicks and hover belong to the underlying control.
final class LitheDropdownAnchorView: NSView {
    var onDetach: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }
}

enum LitheDropdownAnchorGeometry {
    @MainActor
    static func isAnchorClick(_ event: NSEvent?, anchorWindow: NSWindow?, anchorFrame: NSRect?) -> Bool {
        guard let event, event.type == .leftMouseDown,
              let anchorWindow, let anchorFrame,
              event.windowNumber == anchorWindow.windowNumber else { return false }
        return anchorFrame.contains(anchorWindow.convertPoint(toScreen: event.locationInWindow))
    }
}

/// Position searchable filters using the same borderless host as Project menus.
struct LitheDropdownPopover<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    var opensUpward = false
    var opensToSide = false
    var searchOnTyping = false
    @Binding var isPresented: Bool
    var items: [LitheContextMenuItem]? = nil
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, content: content)
    }

    func makeNSView(context: Context) -> NSView {
        let view = LitheDropdownAnchorView()
        view.onDetach = { [weak coordinator = context.coordinator] in coordinator?.dismiss() }
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.content = content
        context.coordinator.items = items
        context.coordinator.environment = environment
        context.coordinator.environment.colorScheme = colorScheme
        context.coordinator.opensUpward = opensUpward
        context.coordinator.opensToSide = opensToSide
        context.coordinator.searchOnTyping = searchOnTyping
        context.coordinator.isPresented = $isPresented
        guard isPresented, let window = nsView.window else {
            if !isPresented { context.coordinator.dismiss() }
            return
        }
        context.coordinator.present(relativeTo: nsView, in: window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? LitheDropdownAnchorView)?.onDetach = nil
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject {
        var isPresented: Binding<Bool>
        var content: () -> Content
        var environment = EnvironmentValues()
        var opensUpward = false
        var opensToSide = false
        var searchOnTyping = false
        private let presenter = LitheContextMenuPresenter()
        var items: [LitheContextMenuItem]?
        private var menuIsPresented = false
        private var hostingController: LitheDropdownHostingController?

        init(isPresented: Binding<Bool>, content: @escaping () -> Content) {
            self.isPresented = isPresented
            self.content = content
        }

        func present(relativeTo anchor: NSView, in window: NSWindow) {
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let point = NSPoint(x: rect.minX, y: opensUpward ? rect.maxY : rect.minY)
            let appearance = NSAppearance(named: environment.colorScheme == .dark ? .darkAqua : .aqua)
            if let items {
                guard !menuIsPresented else { return }
                menuIsPresented = true
                presenter.show(
                    items: items, at: point, appearance: appearance,
                    locale: environment.locale, opensUpward: opensUpward, anchored: true,
                    adjacentTo: opensToSide ? NSRect(x: window.frame.minX, y: rect.minY,
                        width: window.frame.width, height: rect.height) : nil, parentWindow: window, trigger: anchor
                ) { [weak self] in
                    guard let self else { return }
                    self.menuIsPresented = false
                    self.isPresented.wrappedValue = false
                }
                return
            }
            let root = AnyView(content().litheContextMenuSurface().environment(\.self, environment))
            if let hostingController {
                hostingController.rootView = root
                presenter.resize(contentController: hostingController)
                return
            }
            let controller = LitheDropdownHostingController(rootView: root)
            hostingController = controller
            presenter.show(
                contentController: controller, at: point,
                appearance: appearance, opensUpward: opensUpward,
                searchOnTyping: searchOnTyping, parentWindow: window, trigger: anchor
            ) { [weak self] in
                guard let self else { return }
                self.hostingController = nil
                self.isPresented.wrappedValue = false
            }
        }

        func dismiss() {
            if menuIsPresented { presenter.dismiss() }
            guard let hostingController else { return }
            presenter.dismiss(contentController: hostingController)
            self.hostingController = nil
        }
    }
}
