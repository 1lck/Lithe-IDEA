import Foundation

/// Decodes UTF-8 output incrementally without replacing a scalar merely
/// because a pipe read ended in the middle of its byte sequence.
package struct StreamingUTF8Decoder: Sendable {
    private var pending = Data()

    package init() {}

    package mutating func decode(_ bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }
        pending.append(bytes)

        let retainedCount = Self.incompleteSuffixLength(in: pending)
        let readyCount = pending.count - retainedCount
        guard readyCount > 0 else { return "" }

        let output = String(decoding: pending.prefix(readyCount), as: UTF8.self)
        if retainedCount == 0 {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending = Data(pending.suffix(retainedCount))
        }
        return output
    }

    /// Emits an incomplete final sequence once, using Swift's replacement
    /// character behavior, and clears the stream state.
    package mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }

    package mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    private static func incompleteSuffixLength(in bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }

        var leadIndex = bytes.index(before: bytes.endIndex)
        var continuationCount = 0
        while isContinuation(bytes[leadIndex]), continuationCount < 3 {
            continuationCount += 1
            guard leadIndex != bytes.startIndex else { return 0 }
            leadIndex = bytes.index(before: leadIndex)
        }

        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2 ... 0xDF:
            expectedLength = 2
        case 0xE0 ... 0xEF:
            expectedLength = 3
        case 0xF0 ... 0xF4:
            expectedLength = 4
        default:
            return 0
        }

        let availableLength = continuationCount + 1
        guard availableLength < expectedLength else { return 0 }
        guard continuationCount > 0 else { return 1 }

        let secondIndex = bytes.index(after: leadIndex)
        let second = bytes[secondIndex]
        let validSecondByte: Bool
        switch lead {
        case 0xE0:
            validSecondByte = (0xA0 ... 0xBF).contains(second)
        case 0xED:
            validSecondByte = (0x80 ... 0x9F).contains(second)
        case 0xF0:
            validSecondByte = (0x90 ... 0xBF).contains(second)
        case 0xF4:
            validSecondByte = (0x80 ... 0x8F).contains(second)
        default:
            validSecondByte = isContinuation(second)
        }
        return validSecondByte ? availableLength : 0
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80 ... 0xBF).contains(byte)
    }
}
