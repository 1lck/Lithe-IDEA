import CoreFoundation
import CryptoKit
import Foundation

/// Byte conversion stays in the native file adapter; editor and LSP buffers remain Unicode.
enum MacDocumentEncoding {
    static func decode(_ bytes: Data, encoding: DocumentEncoding?) throws -> DocumentReadDetails {
        let selected: DocumentEncoding
        if let encoding { selected = encoding }
        else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { selected = .utf8Bom }
        else if String(data: bytes, encoding: .utf8) != nil { selected = .utf8 }
        else if let text = String(data: bytes, encoding: codec(.gb18030)) {
            // GB18030 is a superset of GBK. A four-byte sequence must keep its
            // original codec even if its decoded character is representable in GBK.
            selected = (try? encode(text, encoding: .gbk)) == bytes ? .gbk : .gb18030
        } else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let payload = (selected == .utf8 || selected == .utf8Bom) && bytes.starts(with: [0xEF, 0xBB, 0xBF])
            ? Data(bytes.dropFirst(3)) : bytes
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
        if encoding == .utf8Bom { bytes.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return bytes
    }

    static func identity(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeLossy(_ data: Data, encoding: String.Encoding) -> String {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }

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
        case .gbk: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        case .gb18030: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .shiftJIS: .shiftJIS
        case .windows1252: .windowsCP1252
        }
    }
}
