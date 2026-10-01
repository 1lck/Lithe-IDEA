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
    let items: () -> [LitheContextMenuItem]
    let label: () -> Label

    init(@LitheMenuItemsBuilder content: @escaping () -> [LitheContextMenuItem],
         @ViewBuilder label: @escaping () -> Label) {
        items = content
        self.label = label
    }

    var body: some View {
        let menuItems = items()
        Button { isPresented.toggle() } label: { label() }
            .overlay {
                LitheDropdownPopover(isPresented: $isPresented, items: menuItems) { EmptyView() }
            }
            .disabled(menuItems.isEmpty)
    }
}

extension View {
    func litheDropdown<Content: View>(isPresented: Binding<Bool>, opensUpward: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay { LitheDropdownPopover(opensUpward: opensUpward, isPresented: isPresented, content: content) }
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

/// Position searchable filters using the same borderless host as Project menus.
struct LitheDropdownPopover<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    var opensUpward = false
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
        context.coordinator.opensUpward = opensUpward
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
            if let items {
                guard !menuIsPresented else { return }
                menuIsPresented = true
                presenter.show(
                    items: items, at: point, appearance: anchor.effectiveAppearance,
                    locale: environment.locale, opensUpward: opensUpward, anchored: true, parentWindow: window
                ) { [weak self] in
                    guard let self else { return }
                    self.menuIsPresented = false
                    self.isPresented.wrappedValue = false
                }
                return
            }
            let root = AnyView(content().environment(\.self, environment).litheContextMenuSurface())
            if let hostingController {
                hostingController.rootView = root
                presenter.resize(contentController: hostingController)
                return
            }
            let controller = LitheDropdownHostingController(rootView: root)
            hostingController = controller
            presenter.show(
                contentController: controller, at: point,
                appearance: anchor.effectiveAppearance, opensUpward: opensUpward, parentWindow: window
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
