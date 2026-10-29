import AppKit
import Testing

/// Locate the actual product control instead of assuming toolbar order or offsets.
@MainActor
enum AgentNativeControlTestSupport {
    static func frame(of identifier: String, in view: NSView) async throws -> NSRect {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            view.layoutSubtreeIfNeeded()
            if let window = view.window,
               let control = elements(in: view).first(where: { $0.accessibilityIdentifier?() == identifier }),
               let screenFrame = control.accessibilityFrame?(), !screenFrame.isEmpty {
                let frame = view.convert(window.convertFromScreen(screenFrame), from: nil)
                if view.bounds.intersects(frame) { return frame }
            }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("The native control \(identifier) did not publish a visible frame within two seconds")
        throw MissingControl()
    }

    /// Whether the product control reports itself as usable, after it has published a frame.
    static func isEnabled(_ identifier: String, in view: NSView) async throws -> Bool {
        _ = try await frame(of: identifier, in: view)
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        guard let control = elements(in: view).first(where: { $0.accessibilityIdentifier?() == identifier }) else {
            Issue.record("The native control \(identifier) disappeared before its state was read")
            throw MissingControl()
        }
        return control.isAccessibilityEnabled?() ?? true
    }

    private struct MissingControl: Error {}

    private static func elements(in element: Any) -> [AnyObject] {
        let accessible = element as AnyObject
        let children = accessible.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [accessible] + descendants.flatMap { elements(in: $0) }
    }
}
