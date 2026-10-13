import Foundation
import LitheRustCore

/// Core owns the Unicode control-character policy; native adapters own decoding.
enum RustTextContentPolicy {
    static func isPlainText(_ text: String) -> Bool {
        let length = text.utf8.count
        let result = text.withCString { bytes in
            bytes.withMemoryRebound(to: UInt8.self, capacity: length + 1) {
                lithe_bridge_is_plain_text($0, length)
            }
        }
        if result < 0 { NSLog("Rust text classification unavailable or invalid UTF-8 input") }
        return result == 1
    }
}
