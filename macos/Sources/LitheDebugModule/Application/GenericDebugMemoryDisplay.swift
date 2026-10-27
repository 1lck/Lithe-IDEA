import Foundation

/// How a page of bytes is drawn: the number base, how many bytes make one value, how many
/// bytes a row holds and which byte of a value comes first. It never changes the bytes the
/// adapter returned, and it works on the page's own byte indexes, so the host still does
/// no address arithmetic.
public struct GenericDebugMemoryDisplay: Equatable, Codable, Sendable {
    public enum Radix: String, CaseIterable, Codable, Sendable {
        case hexadecimal
        case unsignedDecimal
        case signedDecimal
        case octal
        case binary
        case floatingPoint
    }

    public enum ByteOrder: String, CaseIterable, Codable, Sendable {
        case little
        case big
    }

    /// One value on a row. `index` is the first of its bytes in the page data.
    public struct Cell: Equatable, Sendable {
        public let index: Int
        public let byteCount: Int
        public let text: String
    }

    public struct Row: Identifiable, Equatable, Sendable {
        /// Index of the row's first byte in the page data.
        public let index: Int
        public let cells: [Cell]
        /// One character per byte, with a dot for bytes that are not printable ASCII.
        public let text: String

        public var id: Int { index }
    }

    public static let unitSizes = [1, 2, 4, 8]
    public static let rowSizes = [8, 16, 32, 64]
    public static let standard = GenericDebugMemoryDisplay()

    public var radix: Radix
    public var unitSize: Int
    public var bytesPerRow: Int
    public var byteOrder: ByteOrder
    public var showsText: Bool

    public init(
        radix: Radix = .hexadecimal,
        unitSize: Int = 1,
        bytesPerRow: Int = 16,
        byteOrder: ByteOrder = .little,
        showsText: Bool = true
    ) {
        self.radix = radix
        self.unitSize = unitSize
        self.bytesPerRow = bytesPerRow
        self.byteOrder = byteOrder
        self.showsText = showsText
    }

    // MARK: - Choices

    /// Only 4 and 8 byte values are IEEE floats.
    public static func supportsFloatingPoint(unitSize: Int) -> Bool {
        unitSize == 4 || unitSize == 8
    }

    /// Picks a base. Floating point needs a 4 or 8 byte value, so it widens a smaller one.
    public func selecting(radix: Radix) -> GenericDebugMemoryDisplay {
        var result = self
        result.radix = radix
        if radix == .floatingPoint, !Self.supportsFloatingPoint(unitSize: unitSize) {
            result.unitSize = 4
        }
        return result.normalized()
    }

    /// Picks a value size. A base that does not fit the new size falls back to hexadecimal.
    public func selecting(unitSize: Int) -> GenericDebugMemoryDisplay {
        var result = self
        result.unitSize = unitSize
        return result.normalized()
    }

    /// Repairs a value that came from storage or from an older build.
    public func normalized() -> GenericDebugMemoryDisplay {
        var result = self
        if !Self.unitSizes.contains(result.unitSize) { result.unitSize = 1 }
        if result.radix == .floatingPoint, !Self.supportsFloatingPoint(unitSize: result.unitSize) {
            result.radix = .hexadecimal
        }
        if !Self.rowSizes.contains(result.bytesPerRow) { result.bytesPerRow = 16 }
        // Every row size is a multiple of every value size, but a row must hold a whole value.
        result.bytesPerRow = max(result.bytesPerRow, result.unitSize)
        return result
    }

    // MARK: - Persistence

    public var storedText: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// An empty or unreadable text yields the standard layout.
    public init(storedText: String) {
        let decoded = storedText.data(using: .utf8).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        self = (decoded ?? .standard).normalized()
    }

    // MARK: - Layout

    /// Characters in one value, so columns stay aligned whatever the bytes are.
    public var cellWidth: Int {
        switch radix {
        case .hexadecimal: unitSize * 2
        case .binary: unitSize * 8
        case .unsignedDecimal: Self.decimalWidth(unitSize: unitSize, signed: false)
        case .signedDecimal: Self.decimalWidth(unitSize: unitSize, signed: true)
        case .octal: (unitSize * 8 + 2) / 3
        case .floatingPoint: unitSize == 4 ? 12 : 17
        }
    }

    public var cellsPerRow: Int { bytesPerRow / unitSize }

    /// Characters in a full row of values with a space between them.
    public var rowTextWidth: Int { cellsPerRow * cellWidth + (cellsPerRow - 1) }

    public func rows(of data: Data) -> [Row] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: bytesPerRow).map { start in
            let end = min(start + bytesPerRow, bytes.count)
            var cells: [Cell] = []
            var index = start
            while index < end {
                let length = min(unitSize, end - index)
                // The tail of a page can end inside a value; it is shown as unknown.
                let text = length == unitSize
                    ? format(bytes[index ..< index + length])
                    : String(repeating: "?", count: cellWidth)
                cells.append(Cell(index: index, byteCount: length, text: text))
                index += unitSize
            }
            let printable = bytes[start ..< end].map { byte -> Character in
                (0x20 ... 0x7e).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            return Row(index: start, cells: cells, text: String(printable))
        }
    }

    // MARK: - Formatting

    private static func decimalWidth(unitSize: Int, signed: Bool) -> Int {
        switch (unitSize, signed) {
        case (1, false): 3
        case (2, false): 5
        case (4, false): 10
        case (_, false): 20
        case (1, true): 4
        case (2, true): 6
        case (4, true): 11
        case (_, true): 20
        }
    }

    private func value(of bytes: ArraySlice<UInt8>) -> UInt64 {
        let ordered = byteOrder == .little ? Array(bytes.reversed()) : Array(bytes)
        return ordered.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func format(_ bytes: ArraySlice<UInt8>) -> String {
        let raw = value(of: bytes)
        let width = cellWidth
        switch radix {
        case .hexadecimal:
            return Self.pad(String(raw, radix: 16), to: width, with: "0")
        case .octal:
            return Self.pad(String(raw, radix: 8), to: width, with: "0")
        case .binary:
            return Self.pad(String(raw, radix: 2), to: width, with: "0")
        case .unsignedDecimal:
            return Self.pad(String(raw), to: width, with: " ")
        case .signedDecimal:
            let spare = UInt64(64 - bytes.count * 8)
            let signed = Int64(bitPattern: raw << spare) >> Int64(spare)
            return Self.pad(String(signed), to: width, with: " ")
        case .floatingPoint:
            let text = bytes.count == 4
                ? String(format: "%.6g", Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))))
                : String(format: "%.10g", Double(bitPattern: raw))
            return Self.pad(text, to: width, with: " ")
        }
    }

    private static func pad(_ text: String, to width: Int, with fill: Character) -> String {
        String(repeating: fill, count: max(0, width - text.count)) + text
    }
}
