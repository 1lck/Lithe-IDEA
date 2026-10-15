import CoreFoundation
import CryptoKit
import Foundation

/// Byte conversion stays in the native file adapter; editor and LSP buffers remain Unicode.
enum MacDocumentEncoding {
    static func decode(_ bytes: Data, encoding: DocumentEncoding?) throws -> DocumentReadDetails {
        let selected: DocumentEncoding
        if let encoding { selected = encoding }
        else if bytes.starts(with: bomBytes(.utf8Bom)) { selected = .utf8Bom }
        // UTF-16 text never validates as UTF-8, so only its BOM identifies it.
        else if bytes.starts(with: bomBytes(.utf16LEBom)) { selected = .utf16LEBom }
        else if bytes.starts(with: bomBytes(.utf16BEBom)) { selected = .utf16BEBom }
        else if String(data: bytes, encoding: .utf8) != nil { selected = .utf8 }
        else if let text = String(data: bytes, encoding: codec(.gb18030)) {
            // GB18030 is a superset of GBK. A four-byte sequence must keep its
            // original codec even if its decoded character is representable in GBK.
            selected = (try? encode(text, encoding: .gbk)) == bytes ? .gbk : .gb18030
        } else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let bom = bomBytes(selected)
        let payload = bytes.starts(with: bom) ? Data(bytes.dropFirst(bom.count)) : bytes
        let text: String
        if encoding != nil {
            // An explicit reopen is a request to inspect the bytes through that
            // codec. Replacement characters make an incorrect choice visible
            // in the editor instead of leaving the previous decoded buffer on
            // screen. Automatic detection below remains strict.
            text = decodeLossy(payload, encoding: codec(selected))
        } else if let decoded = String(data: payload, encoding: codec(selected)) {
            text = decoded
        } else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return DocumentReadDetails(text: text, encoding: selected, identity: identity(bytes))
    }

    static func encode(_ text: String, encoding: DocumentEncoding) throws -> Data {
        guard var bytes = text.data(using: codec(encoding), allowLossyConversion: false),
              let decoded = String(data: bytes, encoding: codec(encoding)),
              Array(decoded.utf16) == Array(text.utf16) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if encoding == .utf8Bom || encoding == .utf16LEBom || encoding == .utf16BEBom {
            bytes.insert(contentsOf: bomBytes(encoding), at: 0)
        }
        return bytes
    }

    /// Plain UTF-8 has no BOM of its own but still tolerates one, so reopening
    /// a BOM file as UTF-8 does not put U+FEFF in the buffer.
    private static func bomBytes(_ encoding: DocumentEncoding) -> [UInt8] {
        switch encoding {
        case .utf8, .utf8Bom: [0xEF, 0xBB, 0xBF]
        case .utf16LEBom: [0xFF, 0xFE]
        case .utf16BEBom: [0xFE, 0xFF]
        case .gbk, .gb18030, .shiftJIS, .windows1252: []
        }
    }

    static func identity(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeLossy(_ data: Data, encoding: String.Encoding) -> String {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
            // Foundation's strict UTF-16 decoder rejects the whole buffer on a
            // lone surrogate; the stdlib repairs each one with U+FFFD instead.
            let bytes = Array(data)
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { index in
                encoding == .utf16LittleEndian
                    ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                    : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            }
            return String(decoding: units, as: UTF16.self) + (bytes.count.isMultiple(of: 2) ? "" : "\u{FFFD}")
        }

        // Foundation exposes strict decoding for legacy codecs. Decode the
        // largest complete sequence available at each position and emit U+FFFD
        // for an invalid byte. This keeps conversion owned by Foundation while
        // making the selected codec observable during an explicit reopen.
        let bytes = Array(data)
        let maximumSequenceLength = encoding == .shiftJIS ? 2 : 4
        var result = String()
        var index = 0
        while index < bytes.count {
            let upperBound = min(bytes.count, index + maximumSequenceLength)
            var decoded: String?
            var length = 0
            for candidateLength in stride(from: upperBound - index, through: 1, by: -1) {
                let candidate = Data(bytes[index..<(index + candidateLength)])
                if let value = String(data: candidate, encoding: encoding) {
                    decoded = value
                    length = candidateLength
                    break
                }
            }
            if let decoded {
                result.append(decoded)
                index += length
            } else {
                result.append("\u{FFFD}")
                index += 1
            }
        }
        return result
    }

    private static func codec(_ encoding: DocumentEncoding) -> String.Encoding {
        switch encoding {
        case .utf8, .utf8Bom: .utf8
        case .utf16LEBom: .utf16LittleEndian
        case .utf16BEBom: .utf16BigEndian
        case .gbk: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        case .gb18030: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .shiftJIS: .shiftJIS
        case .windows1252: .windowsCP1252
        }
    }
}
