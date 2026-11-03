import LitheModuleAPI
import Foundation
import LitheRustCore

/// Core owns the Unicode control-character policy; native adapters own decoding.
enum RustTextContentPolicy {
    static func isPlainText(_ text: String, logSink: (any LogSink)? = nil) -> Bool {
        let length = text.utf8.count
        let result = text.withCString { bytes in
            bytes.withMemoryRebound(to: UInt8.self, capacity: length + 1) {
                lithe_bridge_is_plain_text($0, length)
            }
        }
        if result < 0 { logSink?.emit(EditorTextClassificationFailed()) }
        return result == 1
    }
}
