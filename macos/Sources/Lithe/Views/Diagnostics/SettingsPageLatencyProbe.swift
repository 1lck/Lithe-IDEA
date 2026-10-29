import AppKit
import SwiftUI

/// Diagnostic-only presentation milestones. This observes a normal window
/// update; it never forces layout, reads AX, or changes the settings selection.
@MainActor
enum SettingsPageLatencyTrace {
    struct InputCorrelation {
        struct Input {
            let id: Int64
            let input: UInt64
            let received: UInt64
        }
        private var lastCapturedID: Int64?
        private var pending: Input?

        mutating func receive(id: Int64, input: UInt64, at time: UInt64) -> Input? {
            guard id > 0 else { pending = nil; return nil }
            guard id != lastCapturedID else { return nil }
            lastCapturedID = id
            let value = Input(id: id, input: input, received: time)
            pending = value
            return value
        }

        mutating func take(eventID: Int64?, isMouse: Bool, at time: UInt64) -> Input? {
            defer { pending = nil }
            guard let value = pending, isMouse, eventID == value.id,
                  time >= value.received, time - value.received < 1_000_000_000 else { return nil }
            return value
        }
    }

    struct Visit {
        let category: String
        let eventID: Int64
        let input: UInt64
        let received: UInt64
        let selected: UInt64
    }

    private static var eventMonitor: Any?
    private static var terminationObserver: NSObjectProtocol?
    private static var inputCorrelation = InputCorrelation()
    private(set) static var visit: Visit?

    static func installIfEnabled() {
        guard LitheSignpost.settingsLatencyTracingEnabled, eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                if event.window?.identifier?.rawValue == "settings", let native = event.cgEvent {
                    let id = native.getIntegerValueField(.eventSourceUserData)
                    // Only explicitly tagged diagnostic input is correlated.
                    let now = DispatchTime.now().uptimeNanoseconds
                    if let value = inputCorrelation.receive(id: id, input: native.timestamp, at: now) {
                        LitheSignpost.settingsLatencyEvent("inputReceived", category: "-", eventID: value.id,
                                                           input: value.input, received: value.received, selected: 0)
                    }
                    if id <= 0 {
                        visit = nil
                    }
                }
            }
            return event
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                eventMonitor = nil
                if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
                terminationObserver = nil
            }
        }
    }

    static func selected(_ category: String) {
        guard LitheSignpost.settingsLatencyTracingEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let event = NSApp.currentEvent
        let isMouse = event?.type == .leftMouseDown || event?.type == .leftMouseUp
        guard let input = inputCorrelation.take(eventID: event?.cgEvent?.getIntegerValueField(.eventSourceUserData),
                                                isMouse: isMouse, at: now) else {
            visit = nil
            return
        }
        let value = Visit(category: category, eventID: input.id, input: input.input,
                          received: input.received, selected: now)
        visit = value
        record("selected", value)
    }

    static func record(_ phase: String, _ value: Visit) {
        LitheSignpost.settingsLatencyEvent(phase, category: value.category, eventID: value.eventID,
                                           input: value.input, received: value.received, selected: value.selected)
    }

    static func completed(_ value: Visit) {
        if visit?.eventID == value.eventID { visit = nil }
    }
}

struct SettingsPageLatencyProbe: NSViewRepresentable {
    let category: String

    func makeNSView(context: Context) -> SettingsPageLatencyProbeView {
        SettingsPageLatencyProbeView(category: category)
    }

    func updateNSView(_ view: SettingsPageLatencyProbeView, context: Context) {
        view.arm()
    }

    static func dismantleNSView(_ view: SettingsPageLatencyProbeView, coordinator: ()) {
        view.stopObserving()
    }
}

final class SettingsPageLatencyProbeView: NSView {
    private let category: String
    private var observer: NSObjectProtocol?
    private var pending: SettingsPageLatencyTrace.Visit?
    private var lastEventID: Int64?

    init(category: String) {
        self.category = category
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        arm()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowUpdated() }
        }
    }

    func arm() {
        guard window != nil, let value = SettingsPageLatencyTrace.visit,
              value.category == category, value.eventID != lastEventID else { return }
        pending = value
        lastEventID = value.eventID
        SettingsPageLatencyTrace.record("contentMounted", value)
    }

    private func windowUpdated() {
        guard let value = pending, window?.isVisible == true, !bounds.isEmpty else { return }
        pending = nil
        guard SettingsPageLatencyTrace.visit?.eventID == value.eventID else { return }
        SettingsPageLatencyTrace.record("windowUpdated", value)
        SettingsPageLatencyTrace.completed(value)
        DispatchQueue.main.async {
            SettingsPageLatencyTrace.record("mainQueueAvailable", value)
        }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending = nil
    }
}
