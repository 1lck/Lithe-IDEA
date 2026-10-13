import AppKit
import SwiftUI

/// Follows the existing native viewport, without asking a lazy stack to locate
/// an off-screen row while its height and the permission area are changing.
struct AgentTranscriptScrollAnchor: NSViewRepresentable {
    struct Revision: Equatable {
        let lastMessageID: String?
        let lastText: String?
        let lastUserMessageID: String?
        let messageCount: Int
        let completedTurns: Int
        let permissionID: String?
        let isResponding: Bool
    }

    let sessionID: String?
    let enabled: Bool
    let revision: Revision

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.update(sessionID: sessionID, enabled: enabled, revision: revision)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var insetObservation: NSKeyValueObservation?
        private var pendingFollow: DispatchWorkItem?
        private var followGeneration: UInt64 = 0
        private var sessionID: String?
        private var revision: Revision?
        private var enabled = false
        private var followsLatest = true
        private var isUserScrolling = false
        private var viewportSize: NSSize = .zero
        private static let bottomTolerance: CGFloat = 32

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        override func layout() { super.layout(); attach() }

        func update(sessionID: String?, enabled: Bool, revision: Revision) {
            let changedSession = self.sessionID != sessionID
            let changedContent = self.revision != revision
            let resumedFollowing = enabled && !self.enabled
            let sentMessage = self.revision?.lastUserMessageID != revision.lastUserMessageID
            if changedSession || sentMessage {
                cancelFollow()
                followsLatest = true
                isUserScrolling = false
            }
            self.sessionID = sessionID
            self.enabled = enabled
            self.revision = revision
            attach()
            if !enabled { cancelFollow() }
            else if changedSession || changedContent || resumedFollowing { requestFollow() }
        }

        private func attach() {
            guard window != nil, let enclosing = enclosingScrollView else { return }
            guard scrollView !== enclosing else { return }
            detach()
            scrollView = enclosing
            let clip = enclosing.contentView
            viewportSize = clip.bounds.size
            clip.postsBoundsChangedNotifications = true
            // safeAreaInset reserves permission space through native content
            // insets without changing the clip's bounds size.
            insetObservation = enclosing.observe(\.contentInsets, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.requestFollow() }
            }
            observe(NSView.boundsDidChangeNotification, object: clip) { probe in
                guard let clip = probe.scrollView?.contentView, probe.viewportSize != clip.bounds.size else { return }
                probe.viewportSize = clip.bounds.size
                probe.requestFollow()
            }
            observe(NSScrollView.willStartLiveScrollNotification, object: enclosing) { probe in
                probe.isUserScrolling = true
                probe.cancelFollow()
            }
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observe(name, object: enclosing) { probe in
                    guard let scroll = probe.scrollView else { return }
                    let clip = scroll.contentView
                    probe.followsLatest = Self.bottomOrigin(in: scroll).y - clip.bounds.minY <= Self.bottomTolerance
                    if name == NSScrollView.didEndLiveScrollNotification {
                        probe.isUserScrolling = false
                        probe.requestFollow()
                    }
                }
            }
            requestFollow()
        }

        private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping (Probe) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }

        private func requestFollow() {
            guard enabled, followsLatest, !isUserScrolling, pendingFollow == nil, scrollView != nil else { return }
            // One pending operation per viewport; document-size estimation must
            // never schedule another scroll in response to our own scroll.
            let generation = followGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.followGeneration == generation else { return }
                self.pendingFollow = nil
                guard self.window != nil, self.enabled, self.followsLatest, !self.isUserScrolling,
                      let scroll = self.scrollView else { return }
                let clip = scroll.contentView
                let target = Self.bottomOrigin(in: scroll)
                guard abs(target.y - clip.bounds.minY) > 0.5 else { return }
                clip.scroll(to: target)
                scroll.reflectScrolledClipView(clip)
            }
            pendingFollow = work
            DispatchQueue.main.async(execute: work)
        }

        private static func bottomOrigin(in scroll: NSScrollView) -> NSPoint {
            let clip = scroll.contentView
            let document = scroll.documentView?.frame ?? clip.documentRect
            var bounds = clip.bounds
            bounds.origin.y = max(document.minY - scroll.contentInsets.top,
                document.maxY + scroll.contentInsets.bottom - bounds.height)
            return clip.constrainBoundsRect(bounds).origin
        }

        private func cancelFollow() {
            followGeneration &+= 1
            pendingFollow?.cancel()
            pendingFollow = nil
        }

        func detach() {
            cancelFollow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            insetObservation?.invalidate()
            insetObservation = nil
            scrollView = nil
            isUserScrolling = false
        }
        deinit {
            pendingFollow?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
