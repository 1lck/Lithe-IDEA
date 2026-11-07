import Foundation

/// Thin adapter over Core's `keymap.modifierGestureStep`. The double-Shift state machine and its
/// time threshold live in rust/lithe-core-rules; Windows runs the same Rust source as wasm. This
/// type only carries the state Core returned between events and converts AppKit input to the
/// rule's input. Each call is one synchronous FFI round trip with a ~100 byte JSON body.
struct DoubleShiftGestureRecognizer {
    /// Core-owned state. Swift never reads or branches on the fields; it only sends them back.
    private struct State: Codable {
        var shiftWasDown = false
        var currentPressIsStandalone = false
        var lastStandaloneTap: TimeInterval?
    }

    private enum Event: Encodable {
        case keyDown
        case reset
        case flags(shift: Bool, otherModifiers: Bool)

        private enum Keys: String, CodingKey { case kind, shift, otherModifiers }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .keyDown: try container.encode("keyDown", forKey: .kind)
            case .reset: try container.encode("reset", forKey: .kind)
            case let .flags(shift, otherModifiers):
                try container.encode("flags", forKey: .kind)
                try container.encode(shift, forKey: .shift)
                try container.encode(otherModifiers, forKey: .otherModifiers)
            }
        }
    }

    private struct Request: Encodable {
        let state: State
        let event: Event
        let timestamp: TimeInterval
    }

    private struct Response: Decodable {
        let state: State
        let triggered: Bool
    }

    private let core: RustCoreBridge
    private var state = State()

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    mutating func handleKeyDown() {
        _ = step(.keyDown, timestamp: 0)
    }

    mutating func reset() {
        _ = step(.reset, timestamp: 0)
    }

    mutating func handleFlagsChanged(
        isShiftDown: Bool,
        hasOtherModifiers: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        step(.flags(shift: isShiftDown, otherModifiers: hasOtherModifiers), timestamp: timestamp)
    }

    private mutating func step(_ event: Event, timestamp: TimeInterval) -> Bool {
        let result: Result<Response, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "keymap.modifierGestureStep",
            payload: Request(state: state, event: event, timestamp: timestamp)
        )
        switch result {
        case let .success(response):
            state = response.state
            return response.triggered
        case .failure:
            // A valid request cannot fail unless the linked Core is broken; there is no
            // second implementation to fall back to, so the gesture simply does not fire.
            assertionFailure("keymap.modifierGestureStep failed")
            return false
        }
    }
}
