import AppKit
import SwiftUI

/// A local edge trigger for existing lazy SwiftUI lists. Geometry stays in the
/// native viewport; only one action per continuation reaches the feature model.
struct LitheScrollLoadTrigger: NSViewRepresentable {
    static let prefetchDistance = LitheTheme.Tree.rowHeight * 10
    let continuationID: String?
    let isEnabled: Bool
    let load: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.configure(continuationID: continuationID, isEnabled: isEnabled, load: load)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private var continuationID: String?
        private var requestedID: String?
        private var isEnabled = false
        private var load: (() -> Void)?
        private weak var scroll: NSScrollView?
        private var observations: [NSObjectProtocol] = []
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(continuationID: String?, isEnabled: Bool, load: @escaping () -> Void) {
            if self.continuationID != continuationID { requestedID = nil }
            self.continuationID = continuationID
            self.isEnabled = isEnabled
            self.load = load
            schedule()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { schedule() }
        }

        override func layout() { super.layout(); schedule() }

        func detach() {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations = []
            scroll = nil
        }

        deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }

        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.checkViewport()
            }
        }

        private func checkViewport() {
            guard window != nil, !isHiddenOrHasHiddenAncestor, let enclosing = enclosingScrollView else { return }
            if scroll !== enclosing {
                detach()
                scroll = enclosing
                enclosing.contentView.postsBoundsChangedNotifications = true
                enclosing.contentView.postsFrameChangedNotifications = true
                observations.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: enclosing.contentView, queue: .main
                ) { [weak self] _ in self?.schedule() })
                observations.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: enclosing.contentView, queue: .main
                ) { [weak self] _ in self?.schedule() })
                if let document = enclosing.documentView {
                    document.postsFrameChangedNotifications = true
                    observations.append(NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: document, queue: .main
                    ) { [weak self] _ in self?.schedule() })
                }
            }
            guard isEnabled, let continuationID, requestedID != continuationID,
                  let document = enclosing.documentView, enclosing.contentView.bounds.height > 0 else { return }
            let viewport = enclosing.contentView.bounds.insetBy(dx: 0, dy: -LitheScrollLoadTrigger.prefetchDistance)
            guard viewport.intersects(convert(bounds, to: document)) else { return }
            requestedID = continuationID
            load?()
        }
    }
}
